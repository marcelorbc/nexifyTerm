import SwiftUI

struct SudoPromptView: View {
    let onResponse: (SudoPasswordResponse) -> Void

    @State private var password = ""
    @State private var savePassword = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Senha sudo necessária")
                        .font(.headline)
                        .foregroundColor(NexTheme.textPrimary)
                    Text("O comando requer privilégios de administrador")
                        .font(.caption)
                        .foregroundColor(NexTheme.textSecondary)
                }

                Spacer()
            }

            SecureField("Digite sua senha do macOS", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitPassword() }

            Toggle("Salvar senha para próximas execuções", isOn: $savePassword)
                .font(.caption)
                .foregroundColor(NexTheme.textSecondary)

            if SudoManager.shared.hasSavedPassword {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text("Senha salva anteriormente")
                        .font(.caption2)
                        .foregroundColor(NexTheme.textSecondary)

                    Spacer()

                    Button {
                        SudoManager.shared.clear()
                    } label: {
                        Text("Limpar senha salva")
                            .font(.caption2)
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 12) {
                Button("Cancelar") {
                    onResponse(SudoPasswordResponse(password: nil, save: false))
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button {
                    submitPassword()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.open.fill")
                            .font(.caption)
                        Text("Autorizar")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.black)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(NexTheme.bg)
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        onResponse(SudoPasswordResponse(password: password, save: savePassword))
        dismiss()
    }
}
