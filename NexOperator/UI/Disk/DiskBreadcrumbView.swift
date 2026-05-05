import SwiftUI

struct DiskBreadcrumbView: View {
    let breadcrumb: [DiskNode]
    let onNavigate: (DiskNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(breadcrumb.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.5))
                    }

                    let isLast = index == breadcrumb.count - 1
                    Button {
                        onNavigate(node)
                    } label: {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10))
                            }
                            Text(node.name)
                                .font(.system(size: 11, weight: isLast ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .foregroundColor(isLast ? .primary : .accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isLast ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}
