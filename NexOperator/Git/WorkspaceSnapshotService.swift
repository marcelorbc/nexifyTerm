import Foundation

/// Lightweight, parallel-friendly status capture for the Cockpit. Independent
/// of `GitService` (which is per-repo `actor` with auto-refresh + caching) so
/// we can fan out to N repos cheaply without spinning up N actors and N
/// timers. Each `snapshot(at:)` call shells out only twice:
///
///   1) `git status --porcelain=v2 --branch` — gives us in one shot the
///      branch, upstream, ahead/behind and per-file dirty state.
///   2) `git log -1 --format=%s|%an|%ar` — last-commit summary.
///
/// All shell work runs on a global QoS queue and the parsing is pure, so the
/// service itself is `Sendable` — instances are stateless and reusable.
struct WorkspaceSnapshotService: Sendable {
    static let shared = WorkspaceSnapshotService()

    /// Captures a full `RepoSnapshot` for the given path. Never throws —
    /// every error becomes a `RepoSnapshot.State.notARepo` or `.error(…)`
    /// so the Cockpit can render a consistent grid.
    func snapshot(at path: String) async -> RepoSnapshot {
        let now = Date()
        let normalized = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalized) else {
            return makeSnapshot(path: normalized, state: .notARepo, measuredAt: now)
        }

        let statusOutput: String
        do {
            statusOutput = try await run(
                args: ["status", "--porcelain=v2", "--branch"],
                cwd: normalized
            )
        } catch let GitProcessError.failed(stderr) {
            // `git status` outside of a repo gives "fatal: not a git repository".
            if stderr.contains("not a git repository") {
                return makeSnapshot(path: normalized, state: .notARepo, measuredAt: now)
            }
            return makeSnapshot(path: normalized, state: .error(stderr), measuredAt: now)
        } catch {
            return makeSnapshot(
                path: normalized,
                state: .error(error.localizedDescription),
                measuredAt: now
            )
        }

        let parsed = parseStatusV2(statusOutput)

        // Last commit info — best-effort. An empty repo (no commits yet) makes
        // this fail, which is fine.
        var subject = ""
        var author = ""
        var relative = ""
        if let logOutput = try? await run(
            args: ["log", "-1", "--format=%s|%an|%ar"],
            cwd: normalized
        ) {
            let parts = logOutput.components(separatedBy: "|")
            if parts.count >= 3 {
                subject = parts[0]
                author = parts[1]
                relative = parts[2]
            }
        }

        return RepoSnapshot(
            path: normalized,
            state: .ok,
            branch: parsed.branch,
            aheadBehind: parsed.aheadBehind,
            hasUpstream: parsed.upstream != nil,
            stagedCount: parsed.stagedCount,
            unstagedCount: parsed.unstagedCount,
            untrackedCount: parsed.untrackedCount,
            lastCommitSubject: subject,
            lastCommitAuthor: author,
            lastCommitRelative: relative,
            measuredAt: now
        )
    }

    /// Captures snapshots for every project in parallel with bounded
    /// concurrency. We cap at 8 to stay polite to spinning disks and to keep
    /// `Process` count reasonable on machines that already have a busy
    /// terminal session running.
    func snapshotAll(
        paths: [String],
        maxConcurrent: Int = 8
    ) async -> [RepoSnapshot] {
        guard !paths.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, paths.count))

        return await withTaskGroup(of: (Int, RepoSnapshot).self) { group in
            var iterator = paths.enumerated().makeIterator()
            var inFlight = 0

            // Prime the pipeline.
            while inFlight < limit, let next = iterator.next() {
                group.addTask {
                    let snap = await snapshot(at: next.element)
                    return (next.offset, snap)
                }
                inFlight += 1
            }

            var results: [(Int, RepoSnapshot)] = []
            while let done = await group.next() {
                results.append(done)
                if let next = iterator.next() {
                    group.addTask {
                        let snap = await snapshot(at: next.element)
                        return (next.offset, snap)
                    }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Bulk operations

    enum BulkAction: String {
        case fetch
        case fetchPrune
        case pull
        case pullRebase

        fileprivate var args: [String] {
            switch self {
            case .fetch:       return ["fetch", "--all"]
            case .fetchPrune:  return ["fetch", "--all", "--prune"]
            case .pull:        return ["pull", "--ff-only"]
            case .pullRebase:  return ["pull", "--rebase"]
            }
        }
    }

    struct BulkResult: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let success: Bool
        let message: String
    }

    /// Runs the same git action on every path concurrently. Returns
    /// per-repo success/error so the UI can show a green/red column.
    func bulk(
        action: BulkAction,
        paths: [String],
        maxConcurrent: Int = 6
    ) async -> [BulkResult] {
        guard !paths.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, paths.count))

        return await withTaskGroup(of: (Int, BulkResult).self) { group in
            var iterator = paths.enumerated().makeIterator()
            var inFlight = 0

            while inFlight < limit, let next = iterator.next() {
                group.addTask {
                    let r = await bulkOne(action: action, path: next.element)
                    return (next.offset, r)
                }
                inFlight += 1
            }

            var results: [(Int, BulkResult)] = []
            while let done = await group.next() {
                results.append(done)
                if let next = iterator.next() {
                    group.addTask {
                        let r = await bulkOne(action: action, path: next.element)
                        return (next.offset, r)
                    }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func bulkOne(action: BulkAction, path: String) async -> BulkResult {
        let normalized = (path as NSString).standardizingPath
        do {
            let out = try await run(args: action.args, cwd: normalized)
            let summary = out.isEmpty ? "OK" : out.components(separatedBy: "\n").first ?? "OK"
            return BulkResult(path: normalized, success: true, message: summary)
        } catch let GitProcessError.failed(stderr) {
            return BulkResult(
                path: normalized,
                success: false,
                message: stderr.components(separatedBy: "\n").first ?? "Erro"
            )
        } catch {
            return BulkResult(path: normalized, success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Process

    fileprivate enum GitProcessError: Error {
        case failed(String)
    }

    private func run(args: [String], cwd: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    let s = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: s.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let e = String(data: errData, encoding: .utf8) ?? "Unknown git error"
                    continuation.resume(throwing: GitProcessError.failed(
                        e.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
        }
    }

    // MARK: - Status v2 parser

    /// Output of `git status --porcelain=v2 --branch` looks like:
    /// ```
    /// # branch.oid <sha>
    /// # branch.head main
    /// # branch.upstream origin/main
    /// # branch.ab +2 -1
    /// 1 .M N... ... ... ... ... NexOperator/Foo.swift
    /// 2 R. N... ... ... ... ... new -> old
    /// ? Untracked.swift
    /// u UU N... ... ... ... ... Conflicted.swift
    /// ```
    private func parseStatusV2(_ raw: String) -> ParsedStatus {
        var branch = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        var staged = 0
        var unstaged = 0
        var untracked = 0

        for line in raw.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let abPart = line.dropFirst("# branch.ab ".count)
                let toks = abPart.split(separator: " ")
                if toks.count >= 2 {
                    ahead = Int(toks[0].dropFirst()) ?? 0   // drops "+"
                    behind = Int(toks[1].dropFirst()) ?? 0  // drops "-"
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // Field 2 is the XY status (2 chars). X=index, Y=worktree.
                let toks = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard toks.count >= 2 else { continue }
                let xy = toks[1]
                if xy.count >= 2 {
                    let x = xy[xy.startIndex]
                    let y = xy[xy.index(after: xy.startIndex)]
                    if x != "." { staged += 1 }
                    if y != "." { unstaged += 1 }
                }
            } else if line.hasPrefix("? ") {
                untracked += 1
            } else if line.hasPrefix("u ") {
                // Unmerged — count both sides as needing attention.
                staged += 1
                unstaged += 1
            }
        }

        let ab: (ahead: Int, behind: Int)? = (upstream != nil) ? (ahead, behind) : nil
        return ParsedStatus(
            branch: branch,
            upstream: upstream,
            aheadBehind: ab,
            stagedCount: staged,
            unstagedCount: unstaged,
            untrackedCount: untracked
        )
    }

    private struct ParsedStatus {
        let branch: String
        let upstream: String?
        let aheadBehind: (ahead: Int, behind: Int)?
        let stagedCount: Int
        let unstagedCount: Int
        let untrackedCount: Int
    }

    // MARK: - Helpers

    private func makeSnapshot(path: String, state: RepoSnapshot.State, measuredAt: Date) -> RepoSnapshot {
        RepoSnapshot(
            path: path,
            state: state,
            branch: "",
            aheadBehind: nil,
            hasUpstream: false,
            stagedCount: 0,
            unstagedCount: 0,
            untrackedCount: 0,
            lastCommitSubject: "",
            lastCommitAuthor: "",
            lastCommitRelative: "",
            measuredAt: measuredAt
        )
    }
}
