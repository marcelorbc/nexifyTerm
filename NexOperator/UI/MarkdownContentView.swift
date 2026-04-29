import SwiftUI

private enum MarkdownBlock {
    case text(String)
    case table(headers: [String], rows: [[String]])
    case heading(level: Int, text: String)
    case codeBlock(language: String?, code: String)
}

struct MarkdownContentView: View {
    let content: String
    var fontSize: CGFloat = 12
    var maxTableRows: Int = 30

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    headingView(level: level, text: text)

                case .table(let headers, let rows):
                    tableView(headers: headers, rows: rows)

                case .codeBlock(_, let code):
                    codeBlockView(code: code)

                case .text(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textView(text)
                    }
                }
            }
        }
    }

    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = level == 1 ? fontSize + 4 : (level == 2 ? fontSize + 2 : fontSize + 1)
        return Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundColor(NexTheme.textPrimary)
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.system(size: fontSize))
                .foregroundColor(NexTheme.textPrimary)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(NexTheme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func codeBlockView(code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundColor(NexTheme.accent.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NexTheme.bg.opacity(0.8))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let displayRows = Array(rows.prefix(maxTableRows))
        let columnWidths = computeColumnWidths(headers: headers, rows: displayRows)

        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                            Text(header)
                                .font(.system(size: fontSize - 1, weight: .semibold))
                                .foregroundColor(NexTheme.accent)
                                .lineLimit(1)
                                .frame(width: columnWidths[safe: idx] ?? 100, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                    .background(NexTheme.accentDim)

                    ForEach(Array(displayRows.enumerated()), id: \.offset) { rowIdx, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                                Text(cell)
                                    .font(.system(size: fontSize - 1, design: .monospaced))
                                    .foregroundColor(NexTheme.textPrimary)
                                    .lineLimit(2)
                                    .frame(width: columnWidths[safe: colIdx] ?? 100, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                        }
                        .background(rowIdx % 2 == 0 ? Color.clear : NexTheme.surface)
                    }

                    if rows.count > maxTableRows {
                        HStack {
                            Spacer()
                            Text("... e mais \(rows.count - maxTableRows) linhas")
                                .font(.system(size: fontSize - 2))
                                .foregroundColor(NexTheme.textSecondary)
                                .padding(.vertical, 4)
                            Spacer()
                        }
                        .background(NexTheme.surface)
                    }
                }
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private func computeColumnWidths(headers: [String], rows: [[String]]) -> [CGFloat] {
        let minWidth: CGFloat = 60
        let maxWidth: CGFloat = 250
        let charWidth: CGFloat = 7.5

        return headers.enumerated().map { idx, header in
            var maxLen = header.count
            for row in rows {
                if idx < row.count {
                    maxLen = max(maxLen, row[idx].count)
                }
            }
            let computed = CGFloat(maxLen) * charWidth + 20
            return min(max(computed, minWidth), maxWidth)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Parser

private enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        var textBuffer: [String] = []

        func flushText() {
            let joined = textBuffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(joined))
            }
            textBuffer = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushText()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let headingLevel = parseHeading(trimmed) {
                flushText()
                let text = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                blocks.append(.heading(level: headingLevel, text: text))
                i += 1
                continue
            }

            if isTableRow(trimmed), i + 1 < lines.count, isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushText()
                let headers = parseTableRow(trimmed)
                i += 2 // skip header + separator
                var rows: [[String]] = []
                while i < lines.count && isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(parseTableRow(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                if !headers.isEmpty {
                    blocks.append(.table(headers: headers, rows: rows))
                }
                continue
            }

            textBuffer.append(line)
            i += 1
        }

        flushText()
        return blocks
    }

    private static func parseHeading(_ line: String) -> Int? {
        if line.hasPrefix("### ") { return 3 }
        if line.hasPrefix("## ") { return 2 }
        if line.hasPrefix("# ") { return 1 }
        return nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && !isTableSeparator(line)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cleaned = line.replacingOccurrences(of: " ", with: "")
        guard cleaned.contains("-"), cleaned.contains("|") else { return false }
        let stripped = cleaned.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        return stripped.isEmpty
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }

        return cells
    }
}
