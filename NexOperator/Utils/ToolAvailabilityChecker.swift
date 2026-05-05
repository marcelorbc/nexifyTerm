import Foundation

struct MissingToolInfo {
    let toolName: String
    let failedCommand: String
    let installSuggestion: ToolInstallSuggestion?
    /// Quando true, a alternativa pode ser aplicada sem perguntar ao usuário
    /// (ex: builtin do bash chamado em zsh, ou ferramenta de sistema com path absoluto).
    let canAutoApply: Bool
}

enum MissingToolKind {
    case bashBuiltin
    case systemTool
    case brewFormula
    case unknown
}

struct ToolInstallSuggestion {
    let installCommand: String
    let description: String
    let risk: RiskLevel
    let alternativeCommand: String?
    let kind: MissingToolKind
}

struct ToolAvailabilityChecker {

    private static let notFoundPatterns: [NSRegularExpression] = {
        let patterns = [
            "command not found:\\s*(\\S+)",
            "(\\S+):\\s*command not found",
            "zsh:\\s*command not found:\\s*(\\S+)",
            "bash:\\s*(\\S+):\\s*command not found",
            "sh:\\s*(\\S+):\\s*not found",
            "No such file or directory.*/(\\S+)"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    static func detectMissingTool(from output: CommandOutput) -> MissingToolInfo? {
        guard !output.succeeded else { return nil }

        let text = output.combinedOutput
        guard !text.isEmpty else { return nil }

        for regex in notFoundPatterns {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let toolRange = Range(match.range(at: 1), in: text) {
                let toolName = String(text[toolRange])
                    .trimmingCharacters(in: .punctuationCharacters)

                guard !toolName.isEmpty, toolName.count < 40 else { continue }

                let suggestion = suggestInstall(for: toolName, originalCommand: output.command)
                let autoApply: Bool = {
                    guard let s = suggestion else { return false }
                    switch s.kind {
                    case .bashBuiltin: return true
                    case .systemTool: return s.alternativeCommand != nil
                    default: return false
                    }
                }()

                return MissingToolInfo(
                    toolName: toolName,
                    failedCommand: output.command,
                    installSuggestion: suggestion,
                    canAutoApply: autoApply
                )
            }
        }

        return nil
    }

    static func suggestInstall(for tool: String, originalCommand: String = "") -> ToolInstallSuggestion? {
        if bashBuiltins.contains(tool) {
            let zshEquivalent = zshEquivalentFor(bashBuiltin: tool, originalCommand: originalCommand)
            let alt = "bash -c \(shellQuote(originalCommand.isEmpty ? tool : originalCommand))"
            let desc: String = {
                if let zsh = zshEquivalent {
                    return "'\(tool)' é builtin do bash. No zsh use: \(zsh). Ou rode via `bash -c`."
                }
                return "'\(tool)' é builtin do bash (não existe no zsh). Posso re-executar via `bash -c`."
            }()
            return ToolInstallSuggestion(
                installCommand: alt,
                description: desc,
                risk: .readOnly,
                alternativeCommand: alt,
                kind: .bashBuiltin
            )
        }

        if let fullPath = systemToolPaths[tool] {
            return ToolInstallSuggestion(
                installCommand: fullPath,
                description: "\(tool) é uma ferramenta de sistema do macOS em \(fullPath).",
                risk: .readOnly,
                alternativeCommand: fullPath,
                kind: .systemTool
            )
        }

        if let brewFormula = brewFormulas[tool] {
            return ToolInstallSuggestion(
                installCommand: "brew install \(brewFormula)",
                description: "Instalar \(tool) via Homebrew.",
                risk: .low,
                alternativeCommand: nil,
                kind: .brewFormula
            )
        }

        return ToolInstallSuggestion(
            installCommand: "brew install \(tool)",
            description: "Tentar instalar \(tool) via Homebrew (não verificado).",
            risk: .low,
            alternativeCommand: nil,
            kind: .unknown
        )
    }

    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Builtins do bash que NÃO existem no zsh (ou comportam-se diferente).
    /// Para estes não faz sentido `brew install`; a saída correta é
    /// re-executar o comando via `bash -c "..."` ou usar o equivalente zsh.
    private static let bashBuiltins: Set<String> = [
        "shopt",
        "declare",
        "local",
        "compgen",
        "complete",
        "compopt",
        "bind",
        "caller",
        "enable",
        "mapfile",
        "readarray",
        "help",
        "logout",
        "dirs",
        "popd",
        "pushd",
        "let"
    ]

    /// Mapeamento de builtins bash -> equivalente zsh quando trivial.
    private static func zshEquivalentFor(bashBuiltin: String, originalCommand: String) -> String? {
        switch bashBuiltin {
        case "shopt":
            return "setopt / unsetopt"
        case "declare":
            return "typeset"
        case "local":
            return "typeset (dentro de função)"
        default:
            return nil
        }
    }

    private static let systemToolPaths: [String: String] = [
        "scutil": "/usr/sbin/scutil",
        "networksetup": "/usr/sbin/networksetup",
        "dscl": "/usr/bin/dscl",
        "dscacheutil": "/usr/bin/dscacheutil",
        "diskutil": "/usr/sbin/diskutil",
        "pmset": "/usr/bin/pmset",
        "systemsetup": "/usr/sbin/systemsetup",
        "system_profiler": "/usr/sbin/system_profiler",
        "sw_vers": "/usr/bin/sw_vers",
        "spctl": "/usr/sbin/spctl",
        "csrutil": "/usr/sbin/csrutil",
        "fdesetup": "/usr/sbin/fdesetup",
        "nvram": "/usr/sbin/nvram",
        "ioreg": "/usr/sbin/ioreg",
        "kextstat": "/usr/sbin/kextstat",
        "launchctl": "/bin/launchctl",
        "sysctl": "/usr/sbin/sysctl",
        "mdutil": "/usr/bin/mdutil",
        "tmutil": "/usr/bin/tmutil",
        "installer": "/usr/sbin/installer",
        "hdiutil": "/usr/bin/hdiutil",
        "codesign": "/usr/bin/codesign",
        "security": "/usr/bin/security",
        "xcode-select": "/usr/bin/xcode-select",
        "xcodebuild": "/usr/bin/xcodebuild",
        "instruments": "/usr/bin/instruments",
        "plutil": "/usr/bin/plutil",
        "defaults": "/usr/bin/defaults"
    ]

    private static let brewFormulas: [String: String] = [
        "htop": "htop",
        "tree": "tree",
        "wget": "wget",
        "jq": "jq",
        "bat": "bat",
        "fd": "fd",
        "rg": "ripgrep",
        "ripgrep": "ripgrep",
        "fzf": "fzf",
        "tldr": "tldr",
        "neovim": "neovim",
        "nvim": "neovim",
        "tmux": "tmux",
        "gh": "gh",
        "nmap": "nmap",
        "ffmpeg": "ffmpeg",
        "imagemagick": "imagemagick",
        "starship": "starship",
        "pyenv": "pyenv",
        "rbenv": "rbenv",
        "nvm": "nvm",
        "cmake": "cmake",
        "ninja": "ninja",
        "go": "go",
        "rustup": "rustup-init",
        "kotlin": "kotlin",
        "mas": "mas",
        "watch": "watch",
        "lsd": "lsd",
        "exa": "exa",
        "eza": "eza",
        "neofetch": "neofetch",
        "fastfetch": "fastfetch"
    ]
}
