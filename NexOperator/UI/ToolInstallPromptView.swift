import SwiftUI

struct ToolInstallPromptView: View {
    @EnvironmentObject var appState: AppState
    let request: ToolInstallRequest

    @State private var secondsRemaining: Int = 30
    @State private var timer: Timer?

    private var tool: MissingToolInfo { request.missingTool }
    private var suggestion: ToolInstallSuggestion? { tool.installSuggestion }
    private var hasAlternative: Bool { suggestion?.alternativeCommand != nil }
    private var canInstall: Bool {
        guard let s = suggestion else { return false }
        return s.kind == .brewFormula || s.kind == .unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Comando que falhou:", systemImage: "xmark.circle")
                    .font(.caption.bold())
                    .foregroundColor(.red)

                Text(tool.failedCommand)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06))
                    .cornerRadius(4)
            }

            if let suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Label(suggestion.description, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let alt = suggestion.alternativeCommand {
                        Label("Alternativa: \(alt)", systemImage: "arrow.right.circle")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                            .lineLimit(2)
                    }

                    if canInstall {
                        Label("Instalar: \(suggestion.installCommand)", systemImage: "arrow.down.circle")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                            .lineLimit(2)
                    }
                }
            }

            Divider()

            actionButtons

            countdownLabel
        }
        .padding(12)
        .background(NexTheme.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .onAppear { startCountdown() }
        .onDisappear { stopCountdown() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ferramenta não encontrada: \(tool.toolName)")
                    .font(.headline)

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var headerSubtitle: String {
        switch suggestion?.kind {
        case .bashBuiltin: return "Builtin do bash — posso re-executar via bash"
        case .systemTool:  return "Ferramenta de sistema — posso usar o path completo"
        case .brewFormula: return "Disponível via Homebrew"
        case .unknown:     return "Origem desconhecida — instalação não verificada"
        case .none:        return "Necessária para concluir a tarefa"
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if hasAlternative {
                Button {
                    appState.respondToToolInstall(.useAlternative)
                } label: {
                    Label("Usar alternativa", systemImage: "arrow.right.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .help("Aplicar a sugestão sem instalar nada")
            }

            if canInstall {
                Button {
                    appState.respondToToolInstall(.installTool)
                } label: {
                    Label("Instalar", systemImage: "arrow.down.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help(suggestion?.installCommand ?? "")
            }

            Button {
                appState.respondToToolInstall(.skip)
            } label: {
                Label("Pular", systemImage: "forward.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private var countdownLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text("Auto-pular em \(secondsRemaining)s se não houver resposta")
                .font(.caption2)
        }
        .foregroundColor(.secondary)
    }

    private func startCountdown() {
        stopCountdown()
        secondsRemaining = 30
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            DispatchQueue.main.async {
                if secondsRemaining > 0 {
                    secondsRemaining -= 1
                } else {
                    t.invalidate()
                }
            }
        }
    }

    private func stopCountdown() {
        timer?.invalidate()
        timer = nil
    }
}
