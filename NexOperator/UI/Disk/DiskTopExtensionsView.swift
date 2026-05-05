import SwiftUI

struct DiskTopExtensionsView: View {
    let node: DiskNode
    let limit: Int = 15

    private var aggregates: [ExtensionAggregate] {
        Array(node.aggregateByExtension().prefix(limit))
    }

    var body: some View {
        let items = aggregates
        let maxSize = items.first?.totalSize ?? 1

        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Text(".\(item.ext)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(.primary)

                        GeometryReader { geo in
                            let fraction = CGFloat(item.totalSize) / CGFloat(max(maxSize, 1))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(colorForExtension(item.ext).opacity(0.65))
                                    .frame(width: geo.size.width * min(fraction, 1.0))
                            }
                        }
                        .frame(height: 16)

                        VStack(alignment: .trailing, spacing: 0) {
                            Text(item.formattedSize)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Text("\(item.count) arquivo\(item.count == 1 ? "" : "s")")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func colorForExtension(_ ext: String) -> Color {
        let hash = abs(ext.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.7)
    }
}
