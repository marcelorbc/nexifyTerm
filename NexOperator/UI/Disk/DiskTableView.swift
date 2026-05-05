import SwiftUI

enum DiskTableSortField: String, CaseIterable {
    case name, size, percentage, items
}

struct DiskTableView: View {
    let node: DiskNode
    let onNavigate: (DiskNode) -> Void

    @State private var sortField: DiskTableSortField = .size
    @State private var ascending = false
    @State private var hoveredId: UUID?

    private var sortedChildren: [DiskNode] {
        let children = node.children
        return children.sorted { a, b in
            let result: Bool
            switch sortField {
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size:
                result = a.size < b.size
            case .percentage:
                result = a.size < b.size
            case .items:
                let aCount = a.isDirectory ? a.fileCount + a.folderCount : 0
                let bCount = b.isDirectory ? b.fileCount + b.folderCount : 0
                result = aCount < bCount
            }
            return ascending ? result : !result
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedChildren, id: \.id) { child in
                        childRow(child)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader("Nome", field: .name, minWidth: 180)
            sortableHeader("Tamanho", field: .size, minWidth: 100)
            sortableHeader("%", field: .percentage, minWidth: 140)
            sortableHeader("Itens", field: .items, minWidth: 70)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .font(.system(size: 11, weight: .medium))
    }

    private func sortableHeader(_ title: String, field: DiskTableSortField, minWidth: CGFloat) -> some View {
        Button {
            if sortField == field {
                ascending.toggle()
            } else {
                sortField = field
                ascending = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundColor(.secondary)
                if sortField == field {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(minWidth: minWidth, maxWidth: field == .name ? .infinity : minWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func childRow(_ child: DiskNode) -> some View {
        let isHovered = hoveredId == child.id
        let pct = child.percentageOfParent

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: child.isDirectory ? "folder.fill" : iconForExtension(child.extensionKey))
                    .font(.system(size: 11))
                    .foregroundColor(child.isDirectory ? .accentColor : .secondary)
                    .frame(width: 16)
                Text(child.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 180, maxWidth: .infinity)

            Text(child.formattedSize)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .frame(minWidth: 100, maxWidth: 100, alignment: .trailing)
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TreemapColorMapper.color(for: child).opacity(0.6))
                            .frame(width: geo.size.width * CGFloat(min(pct / 100.0, 1.0)))
                    }
                }
                .frame(height: 8)

                Text(String(format: "%.1f%%", pct))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(minWidth: 140, maxWidth: 140)
            .padding(.horizontal, 8)

            Text(child.isDirectory ? "\(child.fileCount + child.folderCount)" : "-")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 70, maxWidth: 70, alignment: .trailing)
                .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(isHovered ? Color.accentColor.opacity(0.06) : Color.clear)
        .onHover { hoveredId = $0 ? child.id : nil }
        .onTapGesture(count: 2) {
            if child.isDirectory && !child.children.isEmpty {
                onNavigate(child)
            }
        }
        .onTapGesture(count: 1) {}
        .contextMenu {
            if child.isDirectory {
                Button("Navegar para \(child.name)") {
                    onNavigate(child)
                }
            }
            Button("Mostrar no Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([child.url])
            }
        }
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext {
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "xml", "plist":
            return "doc.text.fill"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo.fill"
        case "mp4", "mov", "avi":
            return "film.fill"
        case "zip", "tar", "gz":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }
}
