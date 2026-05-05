import Foundation

actor GitService {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    // MARK: - Shell Execution

    /// Wave 4 · M2: hops off the actor's executor onto a background queue so the
    /// blocking `waitUntilExit()` no longer parks the actor's serialization
    /// queue. Without this, a slow git command (push/pull/log on a huge repo)
    /// would block every other concurrent caller of this service — including
    /// the 5s status timer — making the Git tab feel frozen.
    private nonisolated func run(_ arguments: [String]) async throws -> String {
        let path = repoPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: path)

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

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                guard process.terminationStatus == 0 else {
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown git error"
                    continuation.resume(throwing: GitError.commandFailed(
                        errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }

                let result = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Validation

    func isGitRepository() async -> Bool {
        do {
            _ = try await run(["rev-parse", "--is-inside-work-tree"])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Log

    func log(skip: Int = 0, limit: Int = 200) async throws -> [GitCommit] {
        let format = "%H|%P|%an|%ae|%aI|%s|%D"
        let output = try await run([
            "log", "--format=\(format)", "--all",
            "--skip=\(skip)", "-n", "\(limit)"
        ])
        guard !output.isEmpty else { return [] }
        return GitLogParser.parse(output)
    }

    // MARK: - Branches

    func branches() async throws -> [GitBranch] {
        let current = try? await currentBranch()
        let output = try await run([
            "for-each-ref", "refs/heads/", "refs/remotes/",
            "--format=%(refname)|%(refname:short)|%(objectname:short)|%(upstream:short)"
        ])
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4 else { return nil }
            let refname = parts[0]
            let shortName = parts[1]
            let hash = parts[2]
            let tracking = parts[3].isEmpty ? nil : parts[3]
            let isRemote = refname.hasPrefix("refs/remotes/")
            let isCurrent = !isRemote && shortName == current
            return GitBranch(
                name: shortName,
                isRemote: isRemote,
                isCurrent: isCurrent,
                trackingBranch: tracking,
                commitHash: hash
            )
        }
    }

    func currentBranch() async throws -> String {
        try await run(["rev-parse", "--abbrev-ref", "HEAD"])
    }

    /// Returns how many commits the local branch is ahead/behind its upstream.
    /// `nil` when the branch has no upstream configured (e.g. brand-new local
    /// branch) — the UI uses that to show "sem upstream" instead of "0/0".
    /// Implementation: `git rev-list --left-right --count HEAD...@{u}` returns
    /// `<ahead>\t<behind>`. We swallow only the "no upstream" failure; any
    /// other error propagates.
    func aheadBehind(branch: String? = nil) async -> (ahead: Int, behind: Int)? {
        let target: String
        if let branch, !branch.isEmpty {
            target = "\(branch)...\(branch)@{u}"
        } else {
            target = "HEAD...@{u}"
        }
        do {
            let raw = try await run(["rev-list", "--left-right", "--count", target])
            let parts = raw.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2,
                  let ahead = Int(parts[0]),
                  let behind = Int(parts[1])
            else { return nil }
            return (ahead, behind)
        } catch {
            return nil
        }
    }

    // MARK: - Tags

    func tags() async throws -> [GitTag] {
        let output = try await run([
            "tag", "-l", "--format=%(refname:short)|%(objectname:short)|%(subject)"
        ])
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { return nil }
            return GitTag(
                name: parts[0],
                commitHash: parts[1],
                message: parts.count > 2 ? parts[2] : nil
            )
        }
    }

    // MARK: - Stashes

    func stashes() async throws -> [GitStash] {
        let output = try await run(["stash", "list", "--format=%gd|%s"])
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { return nil }
            let msg = parts[1]
            let branchMatch = msg.range(of: "on (.+?):", options: .regularExpression)
            let branch = branchMatch.map { String(msg[$0]).replacingOccurrences(of: "on ", with: "").replacingOccurrences(of: ":", with: "") }
            return GitStash(id: index, message: msg, branchName: branch)
        }
    }

    // MARK: - Status

    func status() async throws -> (staged: [GitFileStatus], unstaged: [GitFileStatus]) {
        let output = try await run(["status", "--porcelain=v1"])
        guard !output.isEmpty else { return ([], []) }

        var staged: [GitFileStatus] = []
        var unstaged: [GitFileStatus] = []

        for line in output.components(separatedBy: "\n") {
            guard line.count >= 3 else { continue }
            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workTreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let filePath = String(line.dropFirst(3))

            if indexStatus != " " && indexStatus != "?" {
                let kind = GitFileStatusKind(rawValue: String(indexStatus)) ?? .modified
                staged.append(GitFileStatus(path: filePath, status: kind, oldPath: nil))
            }

            if workTreeStatus != " " {
                let kind: GitFileStatusKind
                if indexStatus == "?" {
                    kind = .untracked
                } else {
                    kind = GitFileStatusKind(rawValue: String(workTreeStatus)) ?? .modified
                }
                unstaged.append(GitFileStatus(path: filePath, status: kind, oldPath: nil))
            }
        }

        return (staged, unstaged)
    }

    // MARK: - Stage / Unstage

    func stage(files: [String]) async throws {
        guard !files.isEmpty else { return }
        try await run(["add"] + files)
    }

    func stageAll() async throws {
        try await run(["add", "-A"])
    }

    func unstage(files: [String]) async throws {
        guard !files.isEmpty else { return }
        try await run(["restore", "--staged"] + files)
    }

    func unstageAll() async throws {
        try await run(["reset", "HEAD"])
    }

    // MARK: - Commit

    func commit(message: String) async throws {
        guard !message.isEmpty else { throw GitError.emptyCommitMessage }
        try await run(["commit", "-m", message])
    }

    // MARK: - Push / Pull

    func push(remote: String = "origin", branch: String? = nil) async throws {
        var args = ["push", remote]
        if let branch { args.append(branch) }
        try await run(args)
    }

    func pull(remote: String = "origin", branch: String? = nil) async throws {
        var args = ["pull", remote]
        if let branch { args.append(branch) }
        try await run(args)
    }

    /// `git pull --rebase` — comum em times com history linear. Mantém a
    /// branch local em cima do upstream sem criar merge commits.
    func pullRebase(remote: String = "origin", branch: String? = nil) async throws {
        var args = ["pull", "--rebase", remote]
        if let branch { args.append(branch) }
        try await run(args)
    }

    /// `git fetch` — apenas atualiza refs remotas, sem mexer no working tree.
    /// Usado pelo botão Fetch e pelo cálculo de ahead/behind.
    func fetch(remote: String = "origin", prune: Bool = true) async throws {
        var args = ["fetch", remote]
        if prune { args.append("--prune") }
        try await run(args)
    }

    /// `git fetch --all --prune` — para repos com vários remotes. Usado pela
    /// ação "Fetch tudo".
    func fetchAll(prune: Bool = true) async throws {
        var args = ["fetch", "--all"]
        if prune { args.append("--prune") }
        try await run(args)
    }

    // MARK: - Init

    /// Inicializa um repositório Git no `repoPath`. Idempotente: chamar duas
    /// vezes não falha graças a `git init` aceitar diretório já-repo.
    /// Retorna a branch default criada (geralmente `main` ou `master`).
    func initRepo(initialBranch: String = "main") async throws -> String {
        try await run(["init", "-b", initialBranch])
        return initialBranch
    }

    // MARK: - Branch Operations

    func checkout(branch: String) async throws {
        try await run(["checkout", branch])
    }

    func createBranch(name: String, checkout: Bool = true) async throws {
        if checkout {
            try await run(["checkout", "-b", name])
        } else {
            try await run(["branch", name])
        }
    }

    func deleteBranch(name: String, force: Bool = false) async throws {
        try await run(["branch", force ? "-D" : "-d", name])
    }

    /// Branches já mergeadas em `target`. Útil para sugerir limpeza após
    /// PRs aprovados. Por default ignora a branch corrente, `target` em si
    /// e branches "famosas" (main/master/develop/...).
    func mergedBranches(into target: String = "main") async throws -> [String] {
        let raw = try await run(["branch", "--merged", target, "--format=%(refname:short)"])
        let current = (try? await currentBranch()) ?? ""
        let exclude: Set<String> = GitProtectedBranches.names.union([target, current])
        return raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !exclude.contains($0.lowercased()) && !$0.contains("HEAD detached") }
    }

    /// Branches locais ordenadas pela data do último commit, com a idade em
    /// segundos. Quem decide o que é "stale" é a UI (default 60 dias).
    struct BranchAge: Equatable {
        let name: String
        let lastCommitDate: Date
        let lastCommitSubject: String
        let isCurrent: Bool

        var daysSinceLastCommit: Int {
            Int(-lastCommitDate.timeIntervalSinceNow / 86400)
        }
    }

    func branchesByAge() async throws -> [BranchAge] {
        let raw = try await run([
            "for-each-ref",
            "--sort=-committerdate",
            "refs/heads/",
            "--format=%(refname:short)|%(committerdate:iso8601)|%(subject)"
        ])
        guard !raw.isEmpty else { return [] }
        let current = (try? await currentBranch()) ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]

        return raw.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let dateStr = parts[1].trimmingCharacters(in: .whitespaces)
            let subject = parts.count > 2 ? parts[2] : ""
            // `for-each-ref` ISO uses `2024-04-30 15:32:11 -0300` format.
            let normalized = dateStr.replacingOccurrences(of: " ", with: "T", options: .literal, range: dateStr.range(of: " "))
            let date = formatter.date(from: normalized) ?? Date.distantPast
            return BranchAge(
                name: name,
                lastCommitDate: date,
                lastCommitSubject: subject,
                isCurrent: name == current
            )
        }
    }

    func merge(branch: String) async throws {
        try await run(["merge", branch])
    }

    func rebase(onto branch: String) async throws {
        try await run(["rebase", branch])
    }

    func rebaseAbort() async throws {
        try await run(["rebase", "--abort"])
    }

    // MARK: - Revert / Reset / Cherry-pick

    func revert(commitHash: String) async throws {
        try await run(["revert", "--no-edit", commitHash])
    }

    func resetHard(to commitHash: String) async throws {
        try await run(["reset", "--hard", commitHash])
    }

    func resetSoft(to commitHash: String) async throws {
        try await run(["reset", "--soft", commitHash])
    }

    func resetMixed(to commitHash: String) async throws {
        try await run(["reset", "--mixed", commitHash])
    }

    func cherryPick(commitHash: String) async throws {
        try await run(["cherry-pick", commitHash])
    }

    func createTag(name: String, message: String? = nil) async throws {
        if let message {
            try await run(["tag", "-a", name, "-m", message])
        } else {
            try await run(["tag", name])
        }
    }

    // MARK: - Stash Operations

    func stashSave(message: String? = nil) async throws {
        var args = ["stash", "push"]
        if let message {
            args += ["-m", message]
        }
        try await run(args)
    }

    func stashPop(index: Int = 0) async throws {
        try await run(["stash", "pop", "stash@{\(index)}"])
    }

    func stashDrop(index: Int) async throws {
        try await run(["stash", "drop", "stash@{\(index)}"])
    }

    /// Loads the file list and full unified diff for a single stash. Used by
    /// the expandable stash row + the "Ver diff" modal.
    func stashShow(index: Int) async throws -> GitStashDetails {
        let ref = "stash@{\(index)}"
        // --name-status gives us per-file change kinds (M/A/D/R/C).
        let nameStatus = (try? await run([
            "stash", "show", "--name-status", ref
        ])) ?? ""

        var files: [GitFileStatus] = []
        for line in nameStatus.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let statusChar = String(parts[0].prefix(1))
            let filePath = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let kind = GitFileStatusKind(rawValue: statusChar) ?? .modified
            files.append(GitFileStatus(path: filePath, status: kind, oldPath: nil))
        }

        let diff = (try? await run([
            "stash", "show", "-p", "--no-color", ref
        ])) ?? ""

        return GitStashDetails(index: index, files: files, rawDiff: diff)
    }

    // MARK: - Performance Diagnostic

    /// Runs a small benchmark over local Git operations and produces a
    /// human-readable report. Each measurement is wall-clock; thresholds are
    /// tuned for "feels-instant" (<200ms), "feels-okay" (<1s), "lento" (>1s).
    /// This is local only — we never run `fetch` here, since that depends on
    /// network conditions outside the user's machine.
    func runPerformance() async throws -> GitPerfReport {
        var samples: [GitPerfSample] = []
        var suggestions: [String] = []

        // 1) git status (warm)
        samples.append(await measure(label: "git status") {
            _ = try await self.run(["status", "--porcelain"])
            return "Working-tree scan"
        })

        // 2) git log -200
        samples.append(await measure(label: "git log -200") {
            _ = try await self.run(["log", "--format=%H", "-n", "200", "--all"])
            return "Histórico recente"
        })

        // 3) git for-each-ref (branches + tags)
        samples.append(await measure(label: "git for-each-ref") {
            _ = try await self.run([
                "for-each-ref", "refs/heads/", "refs/remotes/", "refs/tags/",
                "--format=%(refname)"
            ])
            return "Refs (branches/tags)"
        })

        // 4) Object count + repo size (no time pressure — but informative)
        var repoSizeMB: Double = 0
        var objectCount: Int = 0
        if let countOut = try? await run(["count-objects", "-vH"]) {
            objectCount = Self.parseCountObjects(field: "count", from: countOut)
            let inPack = Self.parseCountObjects(field: "in-pack", from: countOut)
            objectCount += inPack
            repoSizeMB = Self.parseSizeMB(from: countOut)
        }
        let sizeRating: GitPerfSample.Rating
        if repoSizeMB > 500 { sizeRating = .slow }
        else if repoSizeMB > 100 { sizeRating = .medium }
        else { sizeRating = .fast }
        samples.append(GitPerfSample(
            label: ".git size",
            durationSeconds: 0,
            rating: sizeRating,
            detail: "\(formatMB(repoSizeMB)) · \(objectCount.formatted()) objects"
        ))

        // 5) Tracked-files count
        var trackedCount: Int = 0
        let trackedSample = await measure(label: "ls-files (tracked)") {
            let out = try await self.run(["ls-files"])
            trackedCount = out.split(separator: "\n").count
            return "\(trackedCount.formatted()) arquivos rastreados"
        }
        samples.append(trackedSample)

        // 6) Loose objects → suggests `git gc`
        if let countOut = try? await run(["count-objects", "-v"]) {
            let loose = Self.parseCountObjects(field: "count", from: countOut)
            let looseKB = Self.parseLooseSizeKB(from: countOut)
            let rating: GitPerfSample.Rating
            if loose > 5_000 { rating = .slow }
            else if loose > 1_000 { rating = .medium }
            else { rating = .fast }
            samples.append(GitPerfSample(
                label: "Loose objects",
                durationSeconds: 0,
                rating: rating,
                detail: "\(loose.formatted()) loose · \(formatKB(Double(looseKB)))"
            ))
            if rating != .fast {
                suggestions.append("Rode `git gc --aggressive` para empacotar \(loose.formatted()) objetos soltos")
            }
        }

        // 7) Stash count (informative)
        if let stashOut = try? await run(["stash", "list"]) {
            let count = stashOut.isEmpty ? 0 : stashOut.split(separator: "\n").count
            let rating: GitPerfSample.Rating = count > 10 ? .medium : .fast
            samples.append(GitPerfSample(
                label: "Stashes",
                durationSeconds: 0,
                rating: rating,
                detail: "\(count) salvos"
            ))
            if count > 10 {
                suggestions.append("Você tem \(count) stashes — considere descartar (`git stash drop`) os antigos")
            }
        }

        // Add suggestions based on slow timed samples.
        for s in samples where s.rating == .slow && s.durationSeconds > 0 {
            switch s.label {
            case "git status":
                suggestions.append("`git status` lento (\(formatSeconds(s.durationSeconds))): verifique submódulos, hooks ou repositório com muitos arquivos não rastreados")
            case "git log -200":
                suggestions.append("`git log` lento (\(formatSeconds(s.durationSeconds))): rode `git gc` para reempacotar a história")
            case "ls-files (tracked)":
                suggestions.append("Listagem de arquivos lenta — repo possivelmente tem milhões de arquivos")
            default: break
            }
        }
        if repoSizeMB > 500 {
            suggestions.append("Repositório com \(formatMB(repoSizeMB)) — considere `git filter-repo` para remover blobs grandes ou converter binários para Git LFS")
        }
        if suggestions.isEmpty {
            suggestions.append("Tudo verde. Nenhuma ação necessária.")
        }

        let worst: GitPerfSample.Rating = {
            if samples.contains(where: { $0.rating == .slow || $0.rating == .error }) { return .slow }
            if samples.contains(where: { $0.rating == .medium }) { return .medium }
            return .fast
        }()

        return GitPerfReport(
            measuredAt: Date(),
            repoPath: repoPath,
            samples: samples,
            overallRating: worst,
            suggestions: suggestions
        )
    }

    /// Times an async closure and converts the result into a `GitPerfSample`.
    /// Thresholds (in seconds): <0.2 fast, <1.0 medium, ≥1.0 slow.
    private func measure(
        label: String,
        op: () async throws -> String
    ) async -> GitPerfSample {
        let start = Date()
        do {
            let detail = try await op()
            let elapsed = -start.timeIntervalSinceNow
            let rating: GitPerfSample.Rating
            if elapsed < 0.2 { rating = .fast }
            else if elapsed < 1.0 { rating = .medium }
            else { rating = .slow }
            return GitPerfSample(
                label: label,
                durationSeconds: elapsed,
                rating: rating,
                detail: "\(formatSeconds(elapsed)) · \(detail)"
            )
        } catch {
            return GitPerfSample(
                label: label,
                durationSeconds: 0,
                rating: .error,
                detail: error.localizedDescription
            )
        }
    }

    private nonisolated static func parseCountObjects(field: String, from output: String) -> Int {
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == field {
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    /// Parses the human-readable size from `git count-objects -vH` (e.g.
    /// `size-pack: 145.2 MiB` or `size: 12 KiB`). Returns size in MB.
    private nonisolated static func parseSizeMB(from output: String) -> Double {
        var totalMB: Double = 0
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "size" || key == "size-pack" || key == "size-garbage" else { continue }
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            let toks = val.components(separatedBy: " ")
            guard let num = Double(toks[0]) else { continue }
            let unit = toks.count > 1 ? toks[1].uppercased() : ""
            if unit.hasPrefix("G") { totalMB += num * 1024 }
            else if unit.hasPrefix("M") { totalMB += num }
            else if unit.hasPrefix("K") { totalMB += num / 1024 }
            else { totalMB += num / (1024 * 1024) }
        }
        return totalMB
    }

    /// `count-objects -v` returns `size:` in KiB by default (no -H).
    private nonisolated static func parseLooseSizeKB(from output: String) -> Int {
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == "size" {
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                return Int(val) ?? 0
            }
        }
        return 0
    }

    private nonisolated func formatSeconds(_ s: Double) -> String {
        if s < 1.0 { return String(format: "%.0f ms", s * 1000) }
        return String(format: "%.2f s", s)
    }

    private nonisolated func formatMB(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", mb * 1024)
    }

    private nonisolated func formatKB(_ kb: Double) -> String {
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return String(format: "%.0f KB", kb)
    }

    // MARK: - Commit Detail

    func commitDetail(hash: String) async throws -> GitCommitDetail {
        let format = "%H|%P|%an|%ae|%aI|%s|%b|%D"
        let info = try await run(["log", "-1", "--format=\(format)", hash])

        let parts = info.components(separatedBy: "|")
        guard parts.count >= 6 else {
            throw GitError.commandFailed("Formato de commit inválido")
        }

        let fullHash = parts[0]
        let parents = parts[1].isEmpty ? [] : parts[1].components(separatedBy: " ")
        let authorName = parts[2]
        let authorEmail = parts[3]
        let dateStr = parts[4]
        let subject = parts[5]
        let body = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let decorations = parts.count > 7 ? parts[7] : ""

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: dateStr) ?? Date()

        var branches: [String] = []
        var tags: [String] = []
        if !decorations.isEmpty {
            for ref in decorations.components(separatedBy: ", ") {
                let trimmed = ref.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("tag: ") {
                    tags.append(String(trimmed.dropFirst(5)))
                } else if !trimmed.isEmpty && trimmed != "HEAD" && !trimmed.hasPrefix("HEAD -> ") {
                    branches.append(trimmed)
                } else if trimmed.hasPrefix("HEAD -> ") {
                    branches.append(String(trimmed.dropFirst(8)))
                }
            }
        }

        let changedFiles = try await commitFiles(hash: fullHash)

        let statOutput = try await run(["diff", "--shortstat", "\(fullHash)^...\(fullHash)"])
        let (adds, dels) = parseShortStat(statOutput)

        return GitCommitDetail(
            hash: fullHash,
            shortHash: String(fullHash.prefix(7)),
            authorName: authorName,
            authorEmail: authorEmail,
            date: date,
            subject: subject,
            body: body,
            parentHashes: parents,
            branches: branches,
            tags: tags,
            changedFiles: changedFiles,
            additions: adds,
            deletions: dels
        )
    }

    func commitFiles(hash: String) async throws -> [GitFileStatus] {
        let output = try await run(["diff-tree", "--no-commit-id", "--name-status", "-r", hash])
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count >= 2 else { return nil }
            let statusChar = String(parts[0].prefix(1))
            let filePath = String(parts[1])
            let kind = GitFileStatusKind(rawValue: statusChar) ?? .modified
            return GitFileStatus(path: filePath, status: kind, oldPath: nil)
        }
    }

    func commitDiffForFile(hash: String, path: String) async throws -> GitFileDiff {
        let raw = try await run(["show", "--no-color", "-U3", "\(hash)", "--", path])
        return GitDiffParser.parse(raw, filePath: path)
    }

    private func parseShortStat(_ stat: String) -> (Int, Int) {
        var adds = 0
        var dels = 0
        let parts = stat.components(separatedBy: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("insertion") {
                adds = Int(trimmed.components(separatedBy: " ").first ?? "0") ?? 0
            } else if trimmed.contains("deletion") {
                dels = Int(trimmed.components(separatedBy: " ").first ?? "0") ?? 0
            }
        }
        return (adds, dels)
    }

    // MARK: - Diff

    func diff(file: String? = nil, staged: Bool = false) async throws -> String {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let file { args.append(file) }
        return try await run(args)
    }

    func diffForFile(_ path: String, staged: Bool) async throws -> GitFileDiff {
        let raw = try await diff(file: path, staged: staged)
        return GitDiffParser.parse(raw, filePath: path)
    }

    func stagedDiffSummary() async throws -> String {
        let stat = try await run(["diff", "--cached", "--stat"])
        let shortDiff = try await run(["diff", "--cached", "--no-color", "-U2"])
        let maxChars = 6000
        let truncated = shortDiff.count > maxChars
            ? String(shortDiff.prefix(maxChars)) + "\n... (truncated)"
            : shortDiff
        return "Stats:\n\(stat)\n\nDiff:\n\(truncated)"
    }
}

// MARK: - Errors

enum GitError: LocalizedError {
    case commandFailed(String)
    case emptyCommitMessage
    case notAGitRepository

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "Git: \(msg)"
        case .emptyCommitMessage: return "Mensagem de commit vazia"
        case .notAGitRepository: return "Diretório não é um repositório Git"
        }
    }
}
