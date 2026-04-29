import Foundation

enum InputIntent {
    case terminalCommand
    case aiRequest
}

struct InputClassifier {

    private static let shellCommands: Set<String> = [
        "ls", "cd", "pwd", "cat", "head", "tail", "echo", "mkdir", "touch",
        "rm", "mv", "cp", "chmod", "chown", "grep", "find", "awk", "sed",
        "sort", "uniq", "wc", "diff", "tar", "zip", "unzip", "curl", "wget",
        "ssh", "scp", "git", "docker", "brew", "npm", "node", "python",
        "python3", "pip", "ruby", "swift", "xcodebuild", "make", "cargo",
        "go", "java", "javac", "which", "where", "man", "top", "htop",
        "ps", "kill", "killall", "df", "du", "free", "uname", "whoami",
        "hostname", "ifconfig", "ping", "traceroute", "netstat", "lsof",
        "open", "pbcopy", "pbpaste", "say", "defaults", "launchctl",
        "softwareupdate", "system_profiler", "sw_vers", "diskutil",
        "hdiutil", "pmset", "caffeinate", "screen", "tmux", "vim", "nano",
        "less", "more", "file", "stat", "md5", "shasum", "base64",
        "env", "export", "source", "alias", "history", "clear", "exit"
    ]

    private static let gitIntentKeywords: Set<String> = [
        "commit", "push", "pull", "merge", "rebase", "branch", "checkout",
        "stash", "tag", "revert", "cherry-pick", "cherrypick", "reset",
        "stage", "unstage", "diff", "blame", "log", "histórico", "historico",
        "mudou", "mudanças", "mudancas", "alterou", "alterações", "alteracoes",
        "conflito", "conflitos", "gerar", "mensagem"
    ]

    private static let explorerIntentKeywords: Set<String> = [
        "arquivo", "arquivos", "pasta", "pastas", "renomear", "renomeie",
        "mover", "mova", "deletar", "delete", "apagar", "excluir",
        "comprimir", "compactar", "zip", "descompactar", "duplicar",
        "criar", "crie", "organizar", "organize", "limpar", "limpe",
        "duplicados", "duplicatas", "maior", "maiores", "menor", "menores",
        "tamanho", "encontrar", "encontre", "buscar", "busque",
        "temporários", "temporarios", "abrir", "abra", "terminal"
    ]

    static func classify(_ input: String) -> InputIntent {
        classify(input, tabMode: .terminal)
    }

    static func classify(_ input: String, tabMode: TabMode) -> InputIntent {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .terminalCommand }

        if trimmed.hasPrefix("!") || trimmed.hasPrefix(">") {
            return .terminalCommand
        }

        if trimmed.hasPrefix("?") || trimmed.hasPrefix("ai ") || trimmed.hasPrefix("ask ") {
            return .aiRequest
        }

        switch tabMode {
        case .git:
            if looksLikeGitIntent(trimmed) { return .aiRequest }
        case .explorer:
            if looksLikeExplorerIntent(trimmed) { return .aiRequest }
        default:
            break
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("..") {
            return .terminalCommand
        }

        let firstWord = String(trimmed.split(separator: " ", maxSplits: 1).first ?? Substring(trimmed))

        if shellCommands.contains(firstWord) {
            if tabMode == .git && firstWord == "git" {
                return .aiRequest
            }
            return .terminalCommand
        }

        if trimmed.contains("| ") || trimmed.hasPrefix("$") {
            return .terminalCommand
        }

        if firstWord.contains("=") {
            return .terminalCommand
        }

        if tabMode == .git || tabMode == .explorer {
            return .aiRequest
        }

        return .aiRequest
    }

    private static func looksLikeGitIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = Set(lower.components(separatedBy: .whitespacesAndNewlines))
        return !words.isDisjoint(with: gitIntentKeywords)
    }

    private static func looksLikeExplorerIntent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = Set(lower.components(separatedBy: .whitespacesAndNewlines))
        return !words.isDisjoint(with: explorerIntentKeywords)
    }
}
