import SwiftUI

struct OllamaSetupView: View {
    @StateObject private var service = OllamaSetupService.shared
    @State private var selectedModel: String = "qwen2.5-coder:7b"
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusBanner

            switch service.step {
            case .checking:
                ProgressView("Verificando instalação do Ollama...")
                    .frame(maxWidth: .infinity, alignment: .center)

            case .notInstalled:
                notInstalledView

            case .installingOllama:
                installingView

            case .ollamaInstalled:
                ollamaInstalledView

            case .ollamaRunning:
                modelSelectionView

            case .pullingModel(let name):
                pullingModelView(name)

            case .ready:
                readyView

            case .error(let msg):
                errorView(msg)
            }
        }
        .task { await service.checkStatus() }
    }

    // MARK: - Status Banner

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Button {
                Task { await service.checkStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Verificar novamente")
        }
    }

    private var statusColor: Color {
        switch service.step {
        case .ready: return .green
        case .ollamaRunning, .ollamaInstalled: return .orange
        case .error: return .red
        case .pullingModel, .installingOllama, .checking: return .blue
        case .notInstalled: return .red
        }
    }

    private var statusText: String {
        switch service.step {
        case .checking: return "Verificando..."
        case .notInstalled: return "Ollama não instalado"
        case .installingOllama: return "Instalando Ollama..."
        case .ollamaInstalled: return "Ollama instalado (parado)"
        case .ollamaRunning: return "Ollama rodando — nenhum modelo instalado"
        case .pullingModel(let m): return "Baixando \(m)..."
        case .ready: return "Ollama pronto — \(service.installedModels.count) modelo(s)"
        case .error: return "Erro"
        }
    }

    // MARK: - Not Installed

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("O Ollama permite rodar modelos de IA localmente, sem custo e com total privacidade.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                installMethodCard(
                    icon: "mug",
                    title: "Via Homebrew",
                    subtitle: "brew install ollama",
                    recommended: true
                ) {
                    Task { await service.installOllama() }
                }

                installMethodCard(
                    icon: "arrow.down.circle",
                    title: "Instalador Oficial",
                    subtitle: "ollama.com/download",
                    recommended: false
                ) {
                    if let url = URL(string: "https://ollama.com/download/mac") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Text("Requisitos: macOS 13+, ~8 GB RAM livre para modelos 7B")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func installMethodCard(icon: String, title: String, subtitle: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(recommended ? .blue : .secondary)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                if recommended {
                    Text("Recomendado")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.blue))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(recommended ? Color.blue.opacity(0.4) : NexTheme.border, lineWidth: recommended ? 1.5 : 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Installing

    private var installingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Instalando Ollama...")
                    .font(.system(size: 12, weight: .medium))
            }

            if !service.installLog.isEmpty {
                logPanel(service.installLog)
            }
        }
    }

    // MARK: - Installed but not running

    private var ollamaInstalledView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ollama está instalado mas não está rodando.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button {
                Task { await service.startOllama() }
            } label: {
                Label("Iniciar Ollama", systemImage: "play.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Text("Ou rode no terminal: ollama serve")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Model Selection

    private var modelSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Escolha um modelo para usar com o NexifyTerm:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(OllamaSetupService.recommendedModels) { model in
                modelRow(model)
            }

            Button {
                Task { await service.pullModel(selectedModel) }
            } label: {
                Label("Instalar Modelo Selecionado", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func modelRow(_ model: OllamaModelInfo) -> some View {
        let isSelected = selectedModel == model.id
        let isInstalled = service.installedModels.contains(where: { $0.hasPrefix(model.id.replacingOccurrences(of: ":latest", with: "")) })

        return Button {
            selectedModel = model.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 12, weight: .medium))

                        Text(model.size)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if model.recommended {
                            Text("Recomendado")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.blue))
                        }

                        if isInstalled {
                            Text("Instalado")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.green))
                        }
                    }

                    Text(model.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pulling Model

    private func pullingModelView(_ modelName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Baixando \(modelName)...")
                    .font(.system(size: 12, weight: .medium))
            }

            Text(service.pullProgress)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Isso pode levar alguns minutos dependendo da sua conexão.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 16))
                Text("Ollama configurado e pronto!")
                    .font(.system(size: 12, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Modelos instalados:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(service.installedModels, id: \.self) { model in
                    HStack(spacing: 6) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                        Text(model)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }

            Divider()

            DisclosureGroup("Instalar mais modelos") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OllamaSetupService.recommendedModels) { model in
                        let isInstalled = service.installedModels.contains(where: { $0.hasPrefix(model.id.components(separatedBy: ":").first ?? model.id) })
                        if !isInstalled {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(model.size)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Instalar") {
                                    Task { await service.pullModel(model.id) }
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await service.checkStatus() }
                } label: {
                    Label("Tentar novamente", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)

                Button {
                    if let url = URL(string: "https://ollama.com/download/mac") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Baixar manualmente", systemImage: "safari")
                }
                .controlSize(.small)
            }

            if !service.installLog.isEmpty {
                logPanel(service.installLog)
            }
        }
    }

    // MARK: - Shared

    private func logPanel(_ text: String) -> some View {
        DisclosureGroup("Log de instalação", isExpanded: $showLog) {
            ScrollView {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
        }
        .font(.system(size: 11))
    }
}
