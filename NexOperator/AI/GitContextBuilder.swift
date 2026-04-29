import Foundation

struct GitContext {
    let repoPath: String
    let currentBranch: String
    let localBranches: [String]
    let remoteBranches: [String]
    let stagedFiles: [(path: String, status: String)]
    let unstagedFiles: [(path: String, status: String)]
    let recentCommits: [(hash: String, subject: String, author: String)]
    let stashes: [(index: Int, message: String)]
    let diffSummary: String
    let aheadBehind: (ahead: Int, behind: Int)?

    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasUnstagedChanges: Bool { !unstagedFiles.isEmpty }
    var hasChanges: Bool { hasStagedChanges || hasUnstagedChanges }
    var totalChangedFiles: Int { stagedFiles.count + unstagedFiles.count }
}

struct GitContextBuilder {

    static func build(from viewModel: GitViewModel) -> GitContext {
        let staged = viewModel.stagedFiles.map { ($0.path, $0.status.rawValue) }
        let unstaged = viewModel.unstagedFiles.map { ($0.path, $0.status.rawValue) }

        let recentCommits = viewModel.commits.prefix(10).map {
            ($0.shortHash, $0.subject, $0.authorName)
        }

        let stashes = viewModel.stashes.map { ($0.id, $0.message) }

        let localBranches = viewModel.localBranches.map(\.name)
        let remoteBranches = viewModel.remoteBranches.map(\.name)

        return GitContext(
            repoPath: viewModel.repoPath,
            currentBranch: viewModel.currentBranch,
            localBranches: localBranches,
            remoteBranches: remoteBranches,
            stagedFiles: staged,
            unstagedFiles: unstaged,
            recentCommits: recentCommits,
            stashes: stashes,
            diffSummary: "",
            aheadBehind: nil
        )
    }

    static func formatForPrompt(_ ctx: GitContext) -> String {
        var prompt = """
        === CONTEXTO GIT ===
        Repositório: \(ctx.repoPath)
        Branch atual: \(ctx.currentBranch)
        Branches locais: \(ctx.localBranches.joined(separator: ", "))
        """

        if !ctx.remoteBranches.isEmpty {
            prompt += "\nBranches remotas: \(ctx.remoteBranches.prefix(15).joined(separator: ", "))"
            if ctx.remoteBranches.count > 15 {
                prompt += " (+\(ctx.remoteBranches.count - 15) mais)"
            }
        }

        if let ab = ctx.aheadBehind {
            prompt += "\nStatus remoto: \(ab.ahead) commits à frente, \(ab.behind) commits atrás"
        }

        prompt += "\n\nArquivos staged (\(ctx.stagedFiles.count)):"
        if ctx.stagedFiles.isEmpty {
            prompt += "\n  (nenhum)"
        } else {
            for f in ctx.stagedFiles.prefix(30) {
                prompt += "\n  [\(f.status)] \(f.path)"
            }
            if ctx.stagedFiles.count > 30 {
                prompt += "\n  ... +\(ctx.stagedFiles.count - 30) arquivos"
            }
        }

        prompt += "\n\nArquivos unstaged/untracked (\(ctx.unstagedFiles.count)):"
        if ctx.unstagedFiles.isEmpty {
            prompt += "\n  (nenhum)"
        } else {
            for f in ctx.unstagedFiles.prefix(30) {
                prompt += "\n  [\(f.status)] \(f.path)"
            }
            if ctx.unstagedFiles.count > 30 {
                prompt += "\n  ... +\(ctx.unstagedFiles.count - 30) arquivos"
            }
        }

        if !ctx.diffSummary.isEmpty {
            prompt += "\n\nResumo do diff staged:\n\(ctx.diffSummary.prefix(2000))"
        }

        prompt += "\n\nÚltimos commits:"
        if ctx.recentCommits.isEmpty {
            prompt += "\n  (nenhum commit ainda)"
        } else {
            for c in ctx.recentCommits {
                prompt += "\n  \(c.hash) — \(c.subject) (\(c.author))"
            }
        }

        if !ctx.stashes.isEmpty {
            prompt += "\n\nStashes (\(ctx.stashes.count)):"
            for s in ctx.stashes.prefix(5) {
                prompt += "\n  stash@{\(s.index)}: \(s.message)"
            }
        }

        prompt += "\n=== FIM CONTEXTO GIT ==="
        return prompt
    }
}
