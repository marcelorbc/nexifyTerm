import SwiftUI

struct DiskTreemapView: View {
    let node: DiskNode
    let onNavigate: (DiskNode) -> Void

    @State private var hoveredId: UUID?
    @State private var tooltipText: String = ""
    @State private var tooltipPosition: CGPoint = .zero
    @State private var showTooltip = false

    var body: some View {
        GeometryReader { geo in
            let rects = TreemapLayout.squarify(
                children: node.sortedChildren(),
                parentSize: node.size,
                bounds: CGRect(origin: .zero, size: geo.size)
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for item in rects {
                        let r = item.rect.insetBy(dx: 1, dy: 1)
                        guard r.width > 0 && r.height > 0 else { continue }

                        let isHovered = item.node.id == hoveredId
                        let color = TreemapColorMapper.color(for: item.node)
                        let fillColor = isHovered ? color.opacity(0.9) : color.opacity(0.7)
                        let path = Path(roundedRect: r, cornerRadius: 2)
                        context.fill(path, with: .color(fillColor))
                        context.stroke(path, with: .color(.black.opacity(0.15)), lineWidth: 0.5)

                        if r.width > 50 && r.height > 24 {
                            let nameText = Text(item.node.name)
                                .font(.system(size: max(9, min(12, r.width / 12)), weight: .medium))
                                .foregroundColor(.white)
                            context.draw(
                                context.resolve(nameText),
                                at: CGPoint(x: r.midX, y: r.midY - 6),
                                anchor: .center
                            )

                            let sizeText = Text(item.node.formattedSize)
                                .font(.system(size: max(8, min(10, r.width / 14)), design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                            context.draw(
                                context.resolve(sizeText),
                                at: CGPoint(x: r.midX, y: r.midY + 8),
                                anchor: .center
                            )
                        } else if r.width > 30 && r.height > 14 {
                            let shortText = Text(item.node.name.prefix(8) + (item.node.name.count > 8 ? "..." : ""))
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.9))
                            context.draw(
                                context.resolve(shortText),
                                at: CGPoint(x: r.midX, y: r.midY),
                                anchor: .center
                            )
                        }
                    }
                }

                ForEach(rects, id: \.node.id) { item in
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .position(x: item.rect.midX, y: item.rect.midY)
                        .onHover { hovering in
                            if hovering {
                                hoveredId = item.node.id
                                let pct = String(format: "%.1f%%", item.node.percentageOfParent)
                                tooltipText = "\(item.node.name)\n\(item.node.formattedSize) (\(pct))"
                                tooltipPosition = CGPoint(x: item.rect.midX, y: item.rect.minY - 4)
                                showTooltip = true
                            } else if hoveredId == item.node.id {
                                hoveredId = nil
                                showTooltip = false
                            }
                        }
                        .onTapGesture {
                            if item.node.isDirectory && !item.node.children.isEmpty {
                                onNavigate(item.node)
                            }
                        }
                        .cursorOnHover(item.node.isDirectory ? .pointingHand : .arrow)
                }

                if showTooltip {
                    Text(tooltipText)
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        )
                        .position(x: min(max(tooltipPosition.x, 60), geo.size.width - 60),
                                  y: max(tooltipPosition.y, 20))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Layout

struct TreemapRect {
    let node: DiskNode
    let rect: CGRect
}

enum TreemapLayout {
    static func squarify(children: [DiskNode], parentSize: Int64, bounds: CGRect) -> [TreemapRect] {
        guard !children.isEmpty, parentSize > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let sorted = children.sorted { $0.size > $1.size }
        let totalArea = Double(bounds.width * bounds.height)
        let scaleFactor = totalArea / Double(parentSize)

        let areas = sorted.map { max(Double($0.size) * scaleFactor, 0) }

        var result: [TreemapRect] = []
        var remaining = CGRect(origin: bounds.origin, size: bounds.size)
        var i = 0

        while i < sorted.count {
            let isWide = remaining.width >= remaining.height
            let sideLength = isWide ? remaining.height : remaining.width

            guard sideLength > 0 else { break }

            var row: [(index: Int, area: Double)] = []
            var rowArea: Double = 0
            var bestAspect = Double.infinity

            while i < sorted.count {
                let candidate = areas[i]
                let testArea = rowArea + candidate
                let testRow = row + [(i, candidate)]
                let aspect = worstAspect(row: testRow.map(\.area), sideLength: Double(sideLength), totalRowArea: testArea)

                if aspect <= bestAspect || row.isEmpty {
                    row = testRow
                    rowArea = testArea
                    bestAspect = aspect
                    i += 1
                } else {
                    break
                }
            }

            let rowLength = rowArea / Double(sideLength)
            var offset: CGFloat = 0

            for (idx, area) in row {
                let itemLength = area / rowLength
                let rect: CGRect
                if isWide {
                    rect = CGRect(
                        x: remaining.minX,
                        y: remaining.minY + offset,
                        width: CGFloat(rowLength),
                        height: CGFloat(itemLength)
                    )
                } else {
                    rect = CGRect(
                        x: remaining.minX + offset,
                        y: remaining.minY,
                        width: CGFloat(itemLength),
                        height: CGFloat(rowLength)
                    )
                }
                result.append(TreemapRect(node: sorted[idx], rect: rect))
                offset += CGFloat(itemLength)
            }

            if isWide {
                remaining = CGRect(
                    x: remaining.minX + CGFloat(rowLength),
                    y: remaining.minY,
                    width: remaining.width - CGFloat(rowLength),
                    height: remaining.height
                )
            } else {
                remaining = CGRect(
                    x: remaining.minX,
                    y: remaining.minY + CGFloat(rowLength),
                    width: remaining.width,
                    height: remaining.height - CGFloat(rowLength)
                )
            }
        }

        return result
    }

    private static func worstAspect(row: [Double], sideLength: Double, totalRowArea: Double) -> Double {
        guard sideLength > 0, totalRowArea > 0 else { return .infinity }
        let rowWidth = totalRowArea / sideLength
        guard rowWidth > 0 else { return .infinity }

        var worst: Double = 0
        for area in row {
            let h = area / rowWidth
            guard h > 0 else { continue }
            let aspect = max(rowWidth / h, h / rowWidth)
            worst = max(worst, aspect)
        }
        return worst
    }
}

// MARK: - Color Mapping

enum TreemapColorMapper {
    private static let directoryColor = Color.blue
    private static let extensionColors: [String: Color] = [
        "swift": .orange,
        "js": .yellow,
        "ts": .blue,
        "py": .green,
        "json": .purple,
        "xml": .pink,
        "html": .red,
        "css": .cyan,
        "md": .gray,
        "txt": .gray,
        "png": .mint,
        "jpg": .mint,
        "jpeg": .mint,
        "gif": .mint,
        "mp4": .indigo,
        "mov": .indigo,
        "mp3": .teal,
        "zip": .brown,
        "tar": .brown,
        "gz": .brown,
        "pdf": .red,
        "log": .secondary,
        "env": .secondary
    ]

    static func color(for node: DiskNode) -> Color {
        if node.isDirectory { return directoryColor }
        if let c = extensionColors[node.extensionKey] { return c }
        let hash = abs(node.extensionKey.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.7)
    }
}
