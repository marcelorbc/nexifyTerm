import SwiftUI

struct DiskSunburstView: View {
    let node: DiskNode
    let onNavigate: (DiskNode) -> Void
    let maxDepth: Int = 4

    @State private var hoveredId: UUID?

    var body: some View {
        GeometryReader { geo in
            sunburstContent(in: geo.size)
        }
    }

    @ViewBuilder
    private func sunburstContent(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 10
        let ringWidth = maxRadius / CGFloat(maxDepth + 1)
        let innerBase = ringWidth * 0.6
        let arcs = flattenArcs(node: node, center: center, startAngle: .zero, sweep: .degrees(360), depth: 0, ringWidth: ringWidth, innerBase: innerBase)

        ZStack {
            sunburstCanvas(arcs: arcs, center: center)
            sunburstHitOverlay(arcs: arcs, center: center)
            sunburstCenterLabel(innerBase: innerBase, center: center)
        }
    }

    private func sunburstCanvas(arcs: [ArcItem], center: CGPoint) -> some View {
        Canvas { context, _ in
            for arc in arcs {
                let isHovered = arc.node.id == hoveredId
                let color = TreemapColorMapper.color(for: arc.node)
                let opacity = isHovered ? 0.95 : 0.75
                let path = makeArcPath(
                    center: center,
                    innerRadius: arc.innerRadius,
                    outerRadius: arc.outerRadius,
                    startAngle: arc.startAngle,
                    endAngle: arc.endAngle
                )
                context.fill(path, with: .color(color.opacity(opacity)))
                context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.8)), lineWidth: 0.5)
            }
        }
    }

    private func sunburstHitOverlay(arcs: [ArcItem], center: CGPoint) -> some View {
        ForEach(arcs, id: \.node.id) { arc in
            arcHitTarget(arc: arc, center: center)
        }
    }

    private func arcHitTarget(arc: ArcItem, center: CGPoint) -> some View {
        let path = makeArcPath(
            center: center,
            innerRadius: arc.innerRadius,
            outerRadius: arc.outerRadius,
            startAngle: arc.startAngle,
            endAngle: arc.endAngle
        )
        return path
            .fill(Color.clear)
            .contentShape(path)
            .onHover { h in hoveredId = h ? arc.node.id : nil }
            .onTapGesture {
                if arc.node.isDirectory && !arc.node.children.isEmpty {
                    onNavigate(arc.node)
                }
            }
    }

    private func sunburstCenterLabel(innerBase: CGFloat, center: CGPoint) -> some View {
        VStack(spacing: 2) {
            Text(node.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(node.formattedSize)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.secondary)
        }
        .frame(width: innerBase * 1.6)
        .position(center)
        .allowsHitTesting(false)
    }

    // MARK: - Flatten arcs

    private struct ArcItem: Identifiable {
        var id: UUID { node.id }
        let node: DiskNode
        let innerRadius: CGFloat
        let outerRadius: CGFloat
        let startAngle: Angle
        let endAngle: Angle
    }

    private func flattenArcs(
        node: DiskNode,
        center: CGPoint,
        startAngle: Angle,
        sweep: Angle,
        depth: Int,
        ringWidth: CGFloat,
        innerBase: CGFloat
    ) -> [ArcItem] {
        guard depth < maxDepth else { return [] }
        let children = node.sortedChildren()
        guard !children.isEmpty, node.size > 0 else { return [] }

        let ir = innerBase + CGFloat(depth) * ringWidth
        let or = ir + ringWidth
        var result: [ArcItem] = []
        var currentAngle = startAngle

        for child in children {
            let fraction = Double(child.size) / Double(node.size)
            let childSweep = Angle.degrees(sweep.degrees * fraction)

            guard childSweep.degrees > 0.3 else {
                currentAngle = currentAngle + childSweep
                continue
            }

            result.append(ArcItem(
                node: child,
                innerRadius: ir,
                outerRadius: or,
                startAngle: currentAngle,
                endAngle: currentAngle + childSweep
            ))

            if child.isDirectory {
                result += flattenArcs(
                    node: child,
                    center: center,
                    startAngle: currentAngle,
                    sweep: childSweep,
                    depth: depth + 1,
                    ringWidth: ringWidth,
                    innerBase: innerBase
                )
            }
            currentAngle = currentAngle + childSweep
        }
        return result
    }

    // MARK: - Arc path

    private func makeArcPath(
        center: CGPoint,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        startAngle: Angle,
        endAngle: Angle
    ) -> Path {
        var path = Path()
        let adjustedStart = startAngle - .degrees(90)
        let adjustedEnd = endAngle - .degrees(90)

        path.addArc(center: center, radius: outerRadius,
                     startAngle: adjustedStart, endAngle: adjustedEnd, clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                     startAngle: adjustedEnd, endAngle: adjustedStart, clockwise: true)
        path.closeSubpath()
        return path
    }
}
