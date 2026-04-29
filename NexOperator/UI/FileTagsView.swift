import SwiftUI

struct FileTagDots: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 2) {
                ForEach(tags.prefix(4), id: \.self) { tag in
                    Circle()
                        .fill(MacOSTag.color(for: tag))
                        .frame(width: 8, height: 8)
                }
                if tags.count > 4 {
                    Text("+\(tags.count - 4)")
                        .font(.system(size: 8))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }
        }
    }
}

struct FileTagEditor: View {
    let currentTags: [String]
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tags")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            ForEach(MacOSTag.allTags) { tag in
                Button {
                    onToggle(tag.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 10, height: 10)
                        Text(tag.name)
                            .font(.system(size: 12))
                            .foregroundColor(NexTheme.textPrimary)
                        Spacer()
                        if currentTags.contains(tag.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 160)
        .glassCard(cornerRadius: 8)
    }
}
