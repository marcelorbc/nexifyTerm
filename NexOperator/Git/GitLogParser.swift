import Foundation

enum GitLogParser {
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ output: String) -> [GitCommit] {
        output.components(separatedBy: "\n").compactMap { line -> GitCommit? in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 6 else { return nil }

            let hash = parts[0]
            let parents = parts[1].isEmpty ? [] : parts[1].components(separatedBy: " ")
            let authorName = parts[2]
            let authorEmail = parts[3]
            let dateStr = parts[4]
            let subject = parts[5]
            let decorations = parts.count > 6 ? parts[6] : ""

            let date = dateFormatter.date(from: dateStr)
                ?? fallbackFormatter.date(from: dateStr)
                ?? Date()

            var branches: [String] = []
            var tags: [String] = []
            var isHead = false

            if !decorations.isEmpty {
                let refs = decorations.components(separatedBy: ", ")
                for ref in refs {
                    let trimmed = ref.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("tag: ") {
                        tags.append(String(trimmed.dropFirst(5)))
                    } else if trimmed == "HEAD" || trimmed.hasPrefix("HEAD -> ") {
                        isHead = true
                        if trimmed.hasPrefix("HEAD -> ") {
                            branches.append(String(trimmed.dropFirst(8)))
                        }
                    } else {
                        branches.append(trimmed)
                    }
                }
            }

            return GitCommit(
                id: hash,
                shortHash: String(hash.prefix(7)),
                parentHashes: parents,
                authorName: authorName,
                authorEmail: authorEmail,
                date: date,
                subject: subject,
                branches: branches,
                tags: tags,
                isHead: isHead
            )
        }
    }
}

// MARK: - Diff Parser

enum GitDiffParser {
    static func parse(_ raw: String, filePath: String) -> GitFileDiff {
        guard !raw.isEmpty else {
            return GitFileDiff(filePath: filePath, hunks: [])
        }

        var hunks: [GitDiffHunk] = []
        var currentHeader = ""
        var currentLines: [GitDiffLine] = []

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                if !currentLines.isEmpty || !currentHeader.isEmpty {
                    hunks.append(GitDiffHunk(header: currentHeader, lines: currentLines))
                }
                currentHeader = line
                currentLines = [GitDiffLine(content: line, type: .header)]
            } else if line.hasPrefix("+") {
                currentLines.append(GitDiffLine(content: line, type: .addition))
            } else if line.hasPrefix("-") {
                currentLines.append(GitDiffLine(content: line, type: .deletion))
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                continue
            } else {
                currentLines.append(GitDiffLine(content: line, type: .context))
            }
        }

        if !currentLines.isEmpty {
            hunks.append(GitDiffHunk(header: currentHeader, lines: currentLines))
        }

        return GitFileDiff(filePath: filePath, hunks: hunks)
    }
}
