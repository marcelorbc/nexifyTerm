import Foundation
import PDFKit

struct FileAttachment: Equatable {
    let fileName: String
    let fileType: AttachmentType
    let textContent: String
    let originalPath: String
    let fileSize: Int64

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var truncatedContent: String {
        let maxChars = 15_000
        if textContent.count <= maxChars { return textContent }
        return String(textContent.prefix(maxChars)) + "\n\n[... conteúdo truncado — \(textContent.count) caracteres total ...]"
    }

    enum AttachmentType: String {
        case pdf
        case text
        case markdown
        case json
        case yaml
        case code
        case unknown

        var icon: String {
            switch self {
            case .pdf:      return "doc.richtext"
            case .text:     return "doc.text"
            case .markdown: return "doc.text"
            case .json:     return "curlybraces"
            case .yaml:     return "list.bullet.indent"
            case .code:     return "chevron.left.forwardslash.chevron.right"
            case .unknown:  return "doc"
            }
        }
    }
}

enum FileAttachmentExtractor {

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "xml", "csv", "tsv",
        "log", "conf", "cfg", "ini", "toml", "env", "sh", "bash", "zsh",
        "swift", "py", "js", "ts", "go", "rs", "java", "kt", "rb", "php",
        "html", "css", "sql", "r", "m", "h", "c", "cpp", "makefile",
        "dockerfile", "gitignore", "editorconfig"
    ]

    static func extract(from url: URL) -> FileAttachment? {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }

        let maxSize: Int64 = 10_000_000
        guard size <= maxSize else {
            NexLog.ai.warning("File too large to attach: \(fileName) (\(size) bytes)")
            return nil
        }

        if ext == "pdf" {
            return extractPDF(url: url, fileName: fileName, size: size)
        }

        if textExtensions.contains(ext) || ext.isEmpty {
            return extractText(url: url, fileName: fileName, ext: ext, size: size)
        }

        return extractText(url: url, fileName: fileName, ext: ext, size: size)
    }

    private static func extractPDF(url: URL, fileName: String, size: Int64) -> FileAttachment? {
        guard let document = PDFDocument(url: url) else {
            NexLog.ai.error("Failed to open PDF: \(fileName)")
            return nil
        }

        var fullText = ""
        let pageCount = document.pageCount
        let maxPages = 50

        for i in 0..<min(pageCount, maxPages) {
            guard let page = document.page(at: i) else { continue }
            if let pageText = page.string {
                fullText += "--- Página \(i + 1) ---\n"
                fullText += pageText + "\n\n"
            }
        }

        if pageCount > maxPages {
            fullText += "\n[... documento tem \(pageCount) páginas, mostrando as primeiras \(maxPages) ...]"
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NexLog.ai.warning("PDF has no extractable text (might be image-based): \(fileName)")
            return FileAttachment(
                fileName: fileName, fileType: .pdf,
                textContent: "[PDF sem texto extraível — possivelmente baseado em imagens. \(pageCount) página(s)]",
                originalPath: url.path, fileSize: size
            )
        }

        NexLog.ai.info("Extracted \(fullText.count) chars from PDF \(fileName) (\(pageCount) pages)")

        return FileAttachment(
            fileName: fileName, fileType: .pdf,
            textContent: fullText,
            originalPath: url.path, fileSize: size
        )
    }

    private static func extractText(url: URL, fileName: String, ext: String, size: Int64) -> FileAttachment? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            if let data = try? Data(contentsOf: url),
               let latin1 = String(data: data, encoding: .isoLatin1) {
                let type = fileType(for: ext)
                return FileAttachment(
                    fileName: fileName, fileType: type,
                    textContent: latin1,
                    originalPath: url.path, fileSize: size
                )
            }
            NexLog.ai.warning("Could not read text from: \(fileName)")
            return nil
        }

        let type = fileType(for: ext)
        return FileAttachment(
            fileName: fileName, fileType: type,
            textContent: content,
            originalPath: url.path, fileSize: size
        )
    }

    private static func fileType(for ext: String) -> FileAttachment.AttachmentType {
        switch ext {
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "txt", "log", "csv", "tsv": return .text
        default: return .code
        }
    }
}
