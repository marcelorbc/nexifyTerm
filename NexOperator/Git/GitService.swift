import Foundation

actor GitService {
    let repoPath: String

    init(repoPath: String) {
        self.repoPath = repoPath
    }

    // MARK: - Shell Execution

    private func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown git error"
            throw GitError.commandFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
