import Foundation
import AppKit
import PDFKit

/// Operações em lote para múltiplos arquivos selecionados no File Explorer.
/// Cobre os cenários mais pedidos: juntar imagens em PDF, combinar imagens
/// em uma única (vertical/horizontal/grid) e detectar grupos compatíveis.
enum BatchFileActions {

    enum BatchError: LocalizedError {
        case noImages
        case imageDecodeFailed(URL)
        case pdfCreationFailed
        case writeFailed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noImages: return "Nenhuma imagem válida selecionada."
            case .imageDecodeFailed(let url): return "Falha ao ler imagem: \(url.lastPathComponent)"
            case .pdfCreationFailed: return "Falha ao gerar o PDF."
            case .writeFailed(let msg): return "Falha ao salvar arquivo: \(msg)"
            case .unsupported(let msg): return msg
            }
        }
    }

    enum CombineLayout {
        case vertical, horizontal, grid
    }

    static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp",
        "heic", "heif", "webp"
    ]

    static func isImage(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    static func filterImages(_ urls: [URL]) -> [URL] {
        urls.filter { isImage($0) || isPDF($0) }
    }

    // MARK: - Merge to PDF

    /// Junta imagens (e PDFs já existentes) em um único PDF.
    /// Cada imagem vira uma página com tamanho proporcional (max 2000pt no lado maior).
    @discardableResult
    static func mergeToPDF(urls: [URL], outputDirectory: URL, baseName: String = "merged") throws -> URL {
        let validURLs = filterImages(urls)
        guard !validURLs.isEmpty else { throw BatchError.noImages }

        let pdfDocument = PDFDocument()
        var pageIndex = 0

        for url in validURLs {
            if isPDF(url) {
                guard let existing = PDFDocument(url: url) else { continue }
                for i in 0..<existing.pageCount {
                    if let page = existing.page(at: i) {
                        pdfDocument.insert(page, at: pageIndex)
                        pageIndex += 1
                    }
                }
            } else {
                guard let image = NSImage(contentsOf: url) else {
                    throw BatchError.imageDecodeFailed(url)
                }
                let normalized = normalizedImage(from: image, maxDimension: 2000)
                guard let page = PDFPage(image: normalized) else {
                    throw BatchError.imageDecodeFailed(url)
                }
                pdfDocument.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }

        guard pdfDocument.pageCount > 0 else { throw BatchError.pdfCreationFailed }

        let outputURL = uniqueDestination(
            outputDirectory.appendingPathComponent("\(baseName).pdf")
        )
        guard pdfDocument.write(to: outputURL) else {
            throw BatchError.writeFailed(outputURL.path)
        }
        return outputURL
    }

    // MARK: - Combine Images

    /// Combina múltiplas imagens em uma única, conforme layout escolhido.
    @discardableResult
    static func combineImages(
        urls: [URL],
        layout: CombineLayout,
        outputDirectory: URL,
        baseName: String = "combined"
    ) throws -> URL {
        let imageURLs = urls.filter { isImage($0) }
        guard !imageURLs.isEmpty else { throw BatchError.noImages }

        let images: [NSImage] = try imageURLs.map { url in
            guard let img = NSImage(contentsOf: url) else { throw BatchError.imageDecodeFailed(url) }
            return img
        }

        let canvas: NSImage
        switch layout {
        case .vertical:   canvas = stackVertically(images)
        case .horizontal: canvas = stackHorizontally(images)
        case .grid:       canvas = arrangeAsGrid(images)
        }

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BatchError.writeFailed("Falha ao converter para PNG")
        }

        let outputURL = uniqueDestination(
            outputDirectory.appendingPathComponent("\(baseName).png")
        )
        try png.write(to: outputURL)
        return outputURL
    }

    // MARK: - Compose Helpers

    private static func normalizedImage(from image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return image }
        let scale = maxDimension / largest
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private static func stackVertically(_ images: [NSImage]) -> NSImage {
        let width = images.map { $0.size.width }.max() ?? 0
        let height = images.reduce(0) { $0 + $1.size.height }
        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        var y: CGFloat = height
        for image in images {
            y -= image.size.height
            let x = (width - image.size.width) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
        }
        canvas.unlockFocus()
        return canvas
    }

    private static func stackHorizontally(_ images: [NSImage]) -> NSImage {
        let height = images.map { $0.size.height }.max() ?? 0
        let width = images.reduce(0) { $0 + $1.size.width }
        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        var x: CGFloat = 0
        for image in images {
            let y = (height - image.size.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
            x += image.size.width
        }
        canvas.unlockFocus()
        return canvas
    }

    private static func arrangeAsGrid(_ images: [NSImage]) -> NSImage {
        let count = images.count
        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))

        let cellW = images.map { $0.size.width }.max() ?? 0
        let cellH = images.map { $0.size.height }.max() ?? 0
        let canvas = NSImage(size: NSSize(width: cellW * CGFloat(cols),
                                          height: cellH * CGFloat(rows)))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        for (i, image) in images.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = CGFloat(col) * cellW + (cellW - image.size.width) / 2
            let y = CGFloat(rows - 1 - row) * cellH + (cellH - image.size.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
        }
        canvas.unlockFocus()
        return canvas
    }

    // MARK: - Compress to ZIP

    /// Comprime os arquivos em um zip usando o utilitário do sistema.
    @discardableResult
    static func compressToZip(urls: [URL], outputDirectory: URL, baseName: String = "archive") throws -> URL {
        guard !urls.isEmpty else { throw BatchError.unsupported("Nada para comprimir.") }
        let outputURL = uniqueDestination(outputDirectory.appendingPathComponent("\(baseName).zip"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        var args = ["-rq", outputURL.path]
        args.append(contentsOf: urls.map { $0.lastPathComponent })
        process.arguments = args
        process.currentDirectoryURL = outputDirectory

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw BatchError.writeFailed(msg)
        }
        return outputURL
    }

    // MARK: - Helpers

    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for i in 2...100 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
