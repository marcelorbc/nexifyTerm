import Foundation
import Combine

struct OllamaModelInfo: Identifiable {
    let id: String
    let name: String
    let size: String
    let description: String
    let recommended: Bool
}

enum OllamaSetupStep: Equatable {
    case checking
    case notInstalled
    case installingOllama
    case ollamaInstalled
    case ollamaRunning
    case pullingModel(String)
    case ready
    case error(String)

    static func == (lhs: OllamaSetupStep, rhs: OllamaSetupStep) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking),
             (.notInstalled, .notInstalled),
             (.installingOllama, .installingOllama),
             (.ollamaInstalled, .ollamaInstalled),
             (.ollamaRunning, .ollamaRunning),
             (.ready, .ready):
            return true
        case (.pullingModel(let a), .pullingModel(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
final class OllamaSetupService: ObservableObject {
    static let shared = OllamaSetupService()

    @Published var step: OllamaSetupStep = .checking
    @Published var isOllamaInstalled = false
    @Published var isOllamaRunning = false
    @Published var installedModels: [String] = []
    @Published var pullProgress: String = ""
    @Published var installLog: String = ""

    static let recommendedModels: [OllamaModelInfo] = [
        OllamaModelInfo(
            id: "qwen2.5-coder:7b",
            name: "Qwen 2.5 Coder 7B",
            size: "~4.7 GB",
            description: "Especialista em código e comandos de terminal. Melhor custo-benefício para dev.",
            recommended: true
        ),
        OllamaModelInfo(
            id: "llama3.1:8b",
            name: "Llama 3.1 8B",
            size: "~4.7 GB",
            description: "Modelo geral da Meta. Bom em instruções e raciocínio.",
            recommended: false
        ),
        OllamaModelInfo(
            id: "deepseek-coder-v2:16b",
            name: "DeepSeek Coder V2 16B",
            size: "~8.9 GB",
            description: "Excelente em código mas requer mais RAM (~16 GB).",
            recommended: false
        ),
        OllamaModelInfo(
            id: "codellama:7b",
            name: "Code Llama 7B",
            size: "~3.8 GB",
            description: "Modelo da Meta focado em código. Leve e rápido.",
            recommended: false
        ),
        OllamaModelInfo(
            id: "mistral:7b",
            name: "Mistral 7B",
            size: "~4.1 GB",
            description: "Modelo europeu eficiente. Bom equilíbrio geral.",
            recommended: false
        )
    ]

    func checkStatus() async {
        step = .checking
        isOllamaInstalled = await checkInstalled()
        if isOllamaInstalled {
            isOllamaRunning = await checkRunning()
            if isOllamaRunning {
                installedModels = await fetchInstalledModels()
                step = installedModels.isEmpty ? .ollamaRunning : .ready
            } else {
                step = .ollamaInstalled
            }
        } else {
            step = .notInstalled
        }
    }

    func installOllama() async {
        step = .installingOllama
        installLog = ""

        let brewInstalled = await checkBrewInstalled()
        if brewInstalled {
            appendLog("Homebrew detectado. Instalando Ollama via brew...")
            let success = await runShell("brew install ollama")
            if success {
                appendLog("Ollama instalado com sucesso via Homebrew.")
                isOllamaInstalled = true
                step = .ollamaInstalled
                return
            }
            appendLog("Falha no brew install. Tentando instalador oficial...")
        }

        appendLog("Baixando instalador oficial do Ollama...")
        let curlSuccess = await runShell("curl -fsSL https://ollama.com/install.sh | sh")
        if curlSuccess {
            appendLog("Ollama instalado com sucesso.")
            isOllamaInstalled = true
            step = .ollamaInstalled
        } else {
            step = .error("Não foi possível instalar o Ollama. Tente manualmente: https://ollama.com/download")
        }
    }

    func startOllama() async {
        appendLog("Iniciando Ollama em background...")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", "ollama serve &"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()

        try? await Task.sleep(for: .seconds(2))

        isOllamaRunning = await checkRunning()
        if isOllamaRunning {
            appendLog("Ollama está rodando.")
            installedModels = await fetchInstalledModels()
            step = installedModels.isEmpty ? .ollamaRunning : .ready
        } else {
            appendLog("Ollama não iniciou. Tente rodar 'ollama serve' no terminal.")
            step = .error("Não foi possível iniciar o Ollama. Rode 'ollama serve' manualmente.")
        }
    }

    func pullModel(_ modelId: String) async {
        step = .pullingModel(modelId)
        pullProgress = "Iniciando download de \(modelId)..."

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "ollama pull \(modelId) 2>&1"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            step = .error("Falha ao executar ollama pull: \(error.localizedDescription)")
            return
        }

        let handle = pipe.fileHandleForReading
        let stream = Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if let line = String(data: chunk, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        await MainActor.run {
                            self?.pullProgress = trimmed
                        }
                    }
                }
            }
        }

        task.waitUntilExit()
        stream.cancel()

        if task.terminationStatus == 0 {
            pullProgress = "\(modelId) instalado com sucesso!"
            installedModels = await fetchInstalledModels()
            step = .ready
        } else {
            step = .error("Falha ao baixar \(modelId). Verifique sua conexão.")
        }
    }

    // MARK: - Private

    private func checkInstalled() async -> Bool {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.ollama/bin/ollama"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return true }
        }
        return await shellSucceeds("which ollama")
    }

    private func checkRunning() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func fetchInstalledModels() async -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.compactMap { $0["name"] as? String }
            }
        } catch {}
        return []
    }

    private func checkBrewInstalled() async -> Bool {
        await shellSucceeds("which brew")
    }

    private func shellSucceeds(_ command: String) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    private func runShell(_ command: String) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            appendLog("Erro: \(error.localizedDescription)")
            return false
        }

        let handle = pipe.fileHandleForReading
        let readTask = Task.detached { [weak self] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let line = String(data: data, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        await MainActor.run { self?.appendLog(trimmed) }
                    }
                }
            }
        }

        proc.waitUntilExit()
        readTask.cancel()
        return proc.terminationStatus == 0
    }

    private func appendLog(_ text: String) {
        if !installLog.isEmpty { installLog += "\n" }
        installLog += text
    }
}
