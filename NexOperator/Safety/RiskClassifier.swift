import Foundation

struct RiskClassifier {

    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "whoami", "df", "du", "ps", "top", "vm_stat",
        "uptime", "ping", "traceroute", "lsof", "ifconfig", "netstat",
        "sw_vers", "system_profiler", "cat", "head", "tail", "wc",
        "file", "which", "where", "echo", "date", "cal", "hostname",
        "uname", "sysctl", "pmset", "ioreg", "mount", "dig", "nslookup",
        "mdfind", "mdls", "dscacheutil", "id", "groups", "env", "printenv",
        "security", "spctl", "csrutil", "xcode-select", "xcrun",
        "defaults read", "diskutil list", "launchctl list",
        "softwareupdate --list"
    ]

    private static let lowCommands: Set<String> = [
        "mkdir", "touch", "open", "pbcopy", "pbpaste", "say",
        "afplay", "screencapture", "defaults read", "tee", "sort",
        "grep", "awk", "sed", "tr", "cut", "uniq", "jq",
        "brew search", "brew list", "brew info", "pip list",
        "npm list", "gem list", "cargo search"
    ]

    private static let mediumCommands: Set<String> = [
        "kill", "defaults write", "launchctl unload",
        "brew", "pip", "pip3", "npm", "yarn", "gem", "cargo",
        "brew services stop", "brew install", "brew uninstall",
        "brew services start", "cp", "ln", "zip", "unzip",
        "tar", "xattr", "ditto", "curl", "wget",
        "softwareupdate", "mas", "git"
    ]

    private static let highCommands: Set<String> = [
        "rm", "mv", "chmod", "chown", "kill -9",
        "launchctl remove", "docker system prune",
        "networksetup", "scutil", "hdiutil", "sudo",
        "osascript", "csrutil"
    ]

    private static let blockedPatterns: [String] = [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf /*",
        "rm -rf ~/",
        "diskutil erase",
        "diskutil eraseDisk",
        "mkfs",
        "dd if=",
        ":(){ :|:& };:",
        "> /dev/sda",
        "mv / ",
        "chmod -R 777 /",
        "yes | rm",
        "sudo rm -rf"
    ]

    private static let blockedSudoPatterns: [String] = [
        "sudo rm -rf",
        "sudo dd",
        "sudo mkfs",
        "sudo diskutil erase",
        "sudo mv /",
        "sudo chmod -R 777"
    ]

    func classify(_ command: String) -> RiskLevel {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        for pattern in Self.blockedPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .blocked
            }
        }

        if lowered.hasPrefix("sudo") {
            for pattern in Self.blockedSudoPatterns {
                if lowered.contains(pattern.lowercased()) {
                    return .blocked
                }
            }
            return .high
        }

        if lowered.contains("curl") && lowered.contains("| bash") {
            return .blocked
        }
        if lowered.contains("wget") && lowered.contains("| bash") {
            return .blocked
        }

        let baseCommand = ShellEscaping.extractBaseCommand(trimmed)

        if Self.readOnlyCommands.contains(baseCommand) {
            return .readOnly
        }

        if Self.lowCommands.contains(baseCommand) {
            return .low
        }

        if Self.mediumCommands.contains(baseCommand) {
            return .medium
        }

        if Self.highCommands.contains(baseCommand) {
            return .high
        }

        if lowered.contains("|") {
            return .medium
        }

        return .medium
    }
}
