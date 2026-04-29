import Foundation

enum ShellEscaping {
    static func escape(_ input: String) -> String {
        var result = "'"
        for char in input {
            if char == "'" {
                result += "'\\''"
            } else {
                result.append(char)
            }
        }
        result += "'"
        return result
    }

    static func extractBaseCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: " ", maxSplits: 1)
        guard let first = components.first else { return trimmed }

        let cmd = String(first)
        if cmd.contains("/") {
            return String(cmd.split(separator: "/").last ?? Substring(cmd))
        }
        return cmd
    }
}
