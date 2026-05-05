import SwiftUI

/// Sheet shown before executing a `GitDestructiveAction`. Critical actions
/// require checking an "Entendo o risco" checkbox before the confirm button
/// becomes active — same pattern used by GitHub/Bitbucket destructive flows.
struct GitDestructiveConfirmSheet: View {
    let action: GitDestructiveAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledged: Bool = false

    private var requiresAck: Bool {
        action.severity == .critical
    }

    private var canConfirm: Bool {
        !requiresAck || acknowledged
    }

    private var accentColor: Color {
        switch action.severity {
        case .critical: return .red
        case .high:     return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: 22))
                    .foregroundColor(accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NexTheme.textPrimary)
                    Text(action.severity == .critical ? "Operação irreversível" : "Operação sensível")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accentColor)
                        .textCase(.uppercase)
                }
                Spacer()
            }

            Text(action.explanation)
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accentColor.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentColor.opacity(0.35), lineWidth: 0.5)
                )

            if requiresAck {
                Toggle(isOn: $acknowledged) {
                    Text("Entendo o risco e quero prosseguir mesmo assim")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textPrimary)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancelar") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    Text(action.confirmLabel)
                        .fontWeight(.semibold)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
