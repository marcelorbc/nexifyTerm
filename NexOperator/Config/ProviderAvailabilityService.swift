import Foundation
import Combine

@MainActor
final class ProviderAvailabilityService: ObservableObject {
    static let shared = ProviderAvailabilityService()

    @Published private(set) var ollamaAvailable = false
    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var openAIAvailable = false
    @Published private(set) var geminiAvailable = false
    @Published private(set) var hasChecked = false

    var availableProviders: [ProviderType] {
        var providers: [ProviderType] = []
        if ollamaAvailable { providers.append(.ollama) }
        if openAIAvailable { providers.append(.openAI) }
        if geminiAvailable { providers.append(.gemini) }
        return providers
    }

    var hasAnyProvider: Bool { !availableProviders.isEmpty }

    func availableModels(for provider: ProviderType) -> [String] {
        switch provider {
        case .ollama:
            return ollamaModels.isEmpty ? provider.availableModels : ollamaModels
        case .openAI:
            return openAIAvailable ? provider.availableModels : []
        case .gemini:
            return geminiAvailable ? provider.availableModels : []
        }
    }

    func bestAvailableProvider() -> ProviderType? {
        let config = ConfigStore.shared
        let preferred = config.defaultProvider
        if availableProviders.contains(preferred) { return preferred }
        return availableProviders.first
    }

    func refresh() async {
        let config = ConfigStore.shared

        openAIAvailable = !config.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        geminiAvailable = !config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let (running, models) = await checkOllama(baseURL: config.ollamaBaseURL)
        ollamaAvailable = running
        ollamaModels = models.map { name in
            name.replacingOccurrences(of: ":latest", with: "")
        }

        hasChecked = true
    }

    // MARK: - Ollama check

    private func checkOllama(baseURL: String) async -> (running: Bool, models: [String]) {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return (false, []) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return (false, []) }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                return (true, names)
            }
            return (true, [])
        } catch {
            return (false, [])
        }
    }
}
