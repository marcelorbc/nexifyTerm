import SwiftUI

struct SkillAutocompleteView: View {
    let query: String
    let onSelect: (Skill) -> Void
    @StateObject private var store = SkillStore.shared
    @State private var selectedIndex = 0

    private var filtered: [Skill] {
        store.search(query: query)
    }

    var body: some View {
        if !filtered.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, skill in
                    Button {
                        onSelect(skill)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: skill.icon)
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                                .frame(width: 22, height: 22)
                                .background(NexTheme.accentDim)
                                .cornerRadius(5)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("/\(skill.name)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(NexTheme.textPrimary)
                                Text(skill.instruction.prefix(60) + (skill.instruction.count > 60 ? "..." : ""))
                                    .font(.system(size: 10))
                                    .foregroundColor(NexTheme.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if !skill.parameters.isEmpty {
                                Text("\(skill.parameters.count) param")
                                    .font(.system(size: 9))
                                    .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(index == selectedIndex ? NexTheme.surfaceHover : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 400)
            .glassCard(cornerRadius: 8)
            .shadow(color: .black.opacity(0.12), radius: 6, y: -2)
            .onChange(of: query) { _, _ in
                selectedIndex = 0
            }
        }
    }
}
