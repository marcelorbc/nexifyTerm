import Foundation

struct MissingToolInfo {
    let toolName: String
    let failedCommand: String
    let installSuggestion: ToolInstallSuggestion?
}

struct ToolInstallSuggestion {
    let installCommand: String
    let description: String
    let risk: RiskLevel
    let alternativeCommand: String?
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

                return MissingToolInfo(
                    toolName: toolName,
                    failedCommand: output.command,
                    installSuggestion: suggestInstall(for: toolName)
                )
            }
        }

        return nil
    }

    static func suggestInstall(for tool: String) -> ToolInstallSuggestion? {
        if let fullPath = systemToolPaths[tool] {
            return ToolInstallSuggestion(
                installCommand: fullPath,
                description: "\(tool) is a macOS system tool available at \(fullPath)",
                risk: .readOnly,
                alternativeCommand: fullPath
            )
        }

        if let brewFormula = brewFormulas[tool] {
            return ToolInstallSuggestion(
                installCommand: "brew install \(brewFormula)",
                description: "Install \(tool) via Homebrew",
                risk: .low,
                alternativeCommand: nil
            )
        }

        return ToolInstallSuggestion(
            installCommand: "brew install \(tool)",
            description: "Try installing \(tool) via Homebrew",
            risk: .low,
            alternativeCommand: nil
        )
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
