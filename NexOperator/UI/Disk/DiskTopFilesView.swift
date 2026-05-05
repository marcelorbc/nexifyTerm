import SwiftUI

struct DiskTopFilesView: View {
    let node: DiskNode
    let limit: Int = 50

    @State private var hoveredId: UUID?

    private var largestFiles: [DiskNode] {
        node.collectLargestFiles(limit: limit)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(largestFiles.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, rank: index + 1)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fileRow(_ file: DiskNode, rank: Int) -> some View {
        let isHovered = hoveredId == file.id
        let parentPath = file.url.deletingLastPathComponent().lastPathComponent

        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            Image(systemName: iconFor(file.extensionKey))
                .font(.system(size: 11))
                .foregroundColor(TreemapColorMapper.color(for: file))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(parentPath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(file.formattedSize)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)

            Menu {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                } label: {
                    Label("Mostrar no Finder", systemImage: "magnifyingglass")
                }
                Button(role: .destructive) {
                    trashFile(file)
                } label: {
                    Label("Mover para Lixeira", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isHovered ? Color.accentColor.opacity(0.06) : Color.clear)
        .onHover { hoveredId = $0 ? file.id : nil }
    }

    private func trashFile(_ file: DiskNode) {
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
    }

    private func iconFor(_ ext: String) -> String {
        switch ext {
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "xml", "plist":
            return "doc.text.fill"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo.fill"
        case "mp4", "mov", "avi", "mkv":
            return "film.fill"
        case "mp3", "wav", "aac", "flac":
            return "waveform"
        case "zip", "tar", "gz", "rar":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "dmg", "iso":
            return "opticaldisc.fill"
        default:
            return "doc.fill"
        }
    }
}
