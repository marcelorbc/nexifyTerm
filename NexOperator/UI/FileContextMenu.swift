import SwiftUI
import QuickLookUI

struct FileContextMenu: View {
    @EnvironmentObject var appState: AppState
    let item: FileItem
    let provider: FileItemProvider
    let onRename: () -> Void
    let onAttach: () -> Void
    var onDelete: (() -> Void)?
    var onPermanentDelete: (() -> Void)?

    private func mergeApps(suggested: [OpenWithApp], system: [OpenWithApp]) -> [OpenWithApp] {
        var seen = Set<String>()
        var result: [OpenWithApp] = []
        for app in suggested + system {
            guard !seen.contains(app.id) else { continue }
            seen.insert(app.id)
            result.append(app)
        }
        return result
    }

    private var targetDirectory: String {
        item.isDirectory ? item.url.path : item.url.deletingLastPathComponent().path
    }

    var body: some View {
        Group {
            Button("Abrir") {
                if item.isDirectory {
                    provider.navigate(to: item.url)
                } else {
                    FileItemProvider.openFile(item.url)
                }
            }

            Button("Abrir no Finder") {
                FileItemProvider.openInFinder(item.url)
            }

            if item.isPreviewable {
                Button("Quick Look") {
                    showQuickLook(url: item.url)
                }
                .keyboardShortcut(" ", modifiers: [])
            }

            Divider()

            Menu("Abrir com...") {
                Button("VS Code") {
                    ExternalEditorLauncher.open(path: item.url.path, editor: .vscode)
                }
                Button("Cursor") {
                    ExternalEditorLauncher.open(path: item.url.path, editor: .cursor)
                }

                let suggested = item.isDirectory ? [] : ExternalEditorLauncher.suggestedApps(for: item.fileExtension)
                let systemApps = ExternalEditorLauncher.installedAppsForFile(url: item.url)
                let allApps = mergeApps(suggested: suggested, system: systemApps)

                if !allApps.isEmpty {
                    Divider()
                    ForEach(allApps) { app in
                        Button {
                            app.open(url: item.url)
                        } label: {
                            Label(app.name, systemImage: app.icon)
                        }
                    }
                }
            }

            if item.isDirectory {
                Button { appState.createTab(directory: item.url.path) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addExplorerTab(directory: item.url.path) } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
                Button { appState.addGitTab(directory: item.url.path) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
            } else {
                Button { appState.createTab(directory: targetDirectory) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addGitTab(directory: targetDirectory) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
            }

            Divider()

            Button("Copiar Path") {
                FileItemProvider.copyPath(item.url)
            }

            Button("Copiar") {
                FileItemProvider.copyFilesToClipboard([item.url], operation: .copy)
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Recortar") {
                FileItemProvider.copyFilesToClipboard([item.url], operation: .cut)
            }
            .keyboardShortcut("x", modifiers: .command)

            if FileItemProvider.hasClipboardFiles {
                Button("Colar Aqui") {
                    let dest = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
                    try? provider.pasteFiles(to: dest)
                }
                .keyboardShortcut("v", modifiers: .command)
            }

            Button("Anexar ao Prompt") {
                onAttach()
            }

            Divider()

            Button("Renomear") {
                onRename()
            }

            Button("Duplicar") {
                try? provider.duplicateItem(item)
            }

            Divider()

            Menu("Tags") {
                ForEach(MacOSTag.allTags) { tag in
                    let currentTags = item.tags
                    let hasTag = currentTags.contains(tag.id)
                    Button {
                        var newTags = currentTags
                        if hasTag {
                            newTags.removeAll { $0 == tag.id }
                        } else {
                            newTags.append(tag.id)
                        }
                        try? provider.setTags(for: item, tags: newTags)
                    } label: {
                        HStack {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                            if hasTag {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if !item.tags.isEmpty {
                    Divider()
                    Button("Remover Todas") {
                        try? provider.setTags(for: item, tags: [])
                    }
                }
            }

            let isFav = FavoritesStore.shared.isFavorite(path: item.url.path)
            Button(isFav ? "Remover dos Favoritos" : "Adicionar aos Favoritos") {
                FavoritesStore.shared.toggleFavorite(path: item.url.path, name: item.name, icon: item.sfSymbol)
            }

            Divider()

            Button {
                if let onDelete {
                    onDelete()
                } else {
                    try? provider.deleteItems([item])
                }
            } label: {
                Label("Mover para Lixeira", systemImage: "trash")
            }

            Button(role: .destructive) {
                if let onPermanentDelete {
                    onPermanentDelete()
                } else {
                    try? provider.permanentDeleteItems([item])
                }
            } label: {
                Label("Excluir Permanentemente", systemImage: "trash.slash")
            }
        }
    }

    private func showQuickLook(url: URL) {
        guard let window = NSApp.keyWindow else { return }
        let panel = QLPreviewPanel.shared()!
        let delegate = QuickLookCoordinator(url: url)
        objc_setAssociatedObject(panel, "qlCoordinator", delegate, .OBJC_ASSOCIATION_RETAIN)
        panel.dataSource = delegate
        panel.delegate = delegate
        panel.makeKeyAndOrderFront(nil)
        panel.center()
    }
}

// MARK: - Preview support on FileItem

extension FileItem {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "heic", "heif",
        "tiff", "tif", "bmp", "raw", "cr2", "nef", "arw"
    ]

    private static let previewableExtensions: Set<String> = imageExtensions.union([
        "pdf", "mp4", "mov", "avi", "mkv", "mp3", "wav", "aac", "flac", "m4a"
    ])

    var isImage: Bool {
        Self.imageExtensions.contains(fileExtension)
    }

    var isPreviewable: Bool {
        !isDirectory && Self.previewableExtensions.contains(fileExtension)
    }
}

// MARK: - Quick Look Coordinator

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL
    }
}

// MARK: - File Preview View (used for context menu preview)

struct FilePreviewView: View {
    let url: URL
    let fileExtension: String

    var body: some View {
        Group {
            if isImageFile {
                imagePreview
            } else if fileExtension == "pdf" {
                pdfPreview
            } else {
                iconPreview
            }
        }
    }

    private var isImageFile: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"].contains(fileExtension)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let nsImage = NSImage(contentsOf: url) {
            VStack(spacing: 8) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 240)
                    .cornerRadius(6)

                fileInfo(nsImage: nsImage)
            }
            .padding(12)
        } else {
            iconPreview
        }
    }

    @ViewBuilder
    private var pdfPreview: some View {
        if let pdfDoc = PDFThumbnailGenerator.thumbnail(for: url) {
            VStack(spacing: 8) {
                Image(nsImage: pdfDoc)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 320)
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

                Text(url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(12)
        } else {
            iconPreview
        }
    }

    private var iconPreview: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(12)
    }

    private func fileInfo(nsImage: NSImage) -> some View {
        VStack(spacing: 2) {
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            let w = Int(nsImage.representations.first?.pixelsWide ?? Int(nsImage.size.width))
            let h = Int(nsImage.representations.first?.pixelsHigh ?? Int(nsImage.size.height))
            let sizeStr = ByteCountFormatter.string(
                fromByteCount: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                countStyle: .file
            )
            Text("\(w) x \(h) — \(sizeStr)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - PDF Thumbnail Helper

enum PDFThumbnailGenerator {
    static func thumbnail(for url: URL) -> NSImage? {
        guard let pdf = CGPDFDocument(url as CFURL),
              let page = pdf.page(at: 1) else { return nil }

        let rect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = min(240 / rect.width, 320 / rect.height, 2.0)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        image.unlockFocus()
        return image
    }
}
