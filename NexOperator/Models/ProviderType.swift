import Foundation

// MARK: - Model Tier

enum ModelTier: String, Comparable {
    case pro
    case standard
    case lite
    case local

    var displayName: String {
        switch self {
        case .pro:      return "Pro"
        case .standard: return "Standard"
        case .lite:     return "Lite"
        case .local:    return "Local"
        }
    }

    var icon: String {
        switch self {
        case .pro:      return "bolt.fill"
        case .standard: return "sparkle"
        case .lite:     return "hare"
        case .local:    return "desktopcomputer"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .pro: return 3
        case .standard: return 2
        case .lite: return 1
        case .local: return 0
        }
    }

    static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Model Capabilities

struct ModelCapabilities {
    let tier: ModelTier
    let supportsToolCalling: Bool
    let supportsFileAccess: Bool
    let supportsReasoning: Bool
    let supportsReasoningWithTools: Bool
    let supportsStreaming: Bool
    let supportsJsonMode: Bool
    let maxToolCount: Int
    let contextWindow: Int
    let description: String

    var canUseToolCalling: Bool {
        supportsToolCalling && (!supportsReasoning || supportsReasoningWithTools)
    }

    var canReadFiles: Bool { canUseToolCalling && supportsFileAccess }
    var canWriteFiles: Bool { canUseToolCalling && supportsFileAccess }
    var canExecuteCommands: Bool { canUseToolCalling }
}

// MARK: - Provider Type

enum ProviderType: String, CaseIterable, Codable, Identifiable {
    case ollama
    case openAI
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return "llama3.1"
        case .openAI: return "gpt-5.5"
        case .gemini: return "gemini-2.5-pro"
        }
    }

    var availableModels: [String] {
        switch self {
        case .ollama: return ["llama3.1", "llama3", "mistral", "codellama", "gemma2"]
        case .openAI: return [
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-pro",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4.1"
        ]
        case .gemini: return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
        }
    }

    // MARK: - Capability Registry

    private static let capabilityMap: [String: ModelCapabilities] = [
        // OpenAI Pro tier — full tool calling, file access, reasoning with tools
        "gpt-5.5": ModelCapabilities(
            tier: .pro, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: true, supportsReasoningWithTools: true,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Modelo flagship com raciocínio avançado e acesso completo a ferramentas"
        ),
        "gpt-5.5-pro": ModelCapabilities(
            tier: .pro, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: true, supportsReasoningWithTools: true,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Versão Pro com raciocínio estendido e acesso completo"
        ),
        "gpt-5.4": ModelCapabilities(
            tier: .pro, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: true, supportsReasoningWithTools: true,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Alta capacidade com raciocínio e ferramentas completas"
        ),
        "gpt-5.4-pro": ModelCapabilities(
            tier: .pro, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: true, supportsReasoningWithTools: true,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Versão Pro com raciocínio estendido e acesso completo"
        ),

        // OpenAI Standard tier — tool calling, file read only, reasoning (no reasoning with tools)
        "gpt-5.4-mini": ModelCapabilities(
            tier: .standard, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: true, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 64, contextWindow: 128_000,
            description: "Modelo eficiente com ferramentas, sem reasoning_effort em tool calls"
        ),
        "gpt-4o": ModelCapabilities(
            tier: .standard, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Modelo multimodal rápido com ferramentas completas"
        ),
        "gpt-4.1": ModelCapabilities(
            tier: .standard, supportsToolCalling: true, supportsFileAccess: true,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 128, contextWindow: 128_000,
            description: "Modelo otimizado para código e instruções longas"
        ),

        // OpenAI Lite tier — tool calling limitado, sem file write, sem reasoning with tools
        "gpt-5.4-nano": ModelCapabilities(
            tier: .lite, supportsToolCalling: true, supportsFileAccess: false,
            supportsReasoning: true, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 16, contextWindow: 128_000,
            description: "Ultra-rápido para tarefas simples, ferramentas limitadas"
        ),
        "gpt-4o-mini": ModelCapabilities(
            tier: .lite, supportsToolCalling: true, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 16, contextWindow: 128_000,
            description: "Rápido e econômico, sem acesso a arquivos"
        ),

        // Gemini models
        "gemini-2.5-pro": ModelCapabilities(
            tier: .pro, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 1_000_000,
            description: "Contexto massivo, ideal para análise de grandes volumes"
        ),
        "gemini-2.5-flash": ModelCapabilities(
            tier: .standard, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 1_000_000,
            description: "Rápido com grande contexto"
        ),
        "gemini-2.0-flash": ModelCapabilities(
            tier: .lite, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 1_000_000,
            description: "Ultra-rápido para tarefas simples"
        ),

        // Local (Ollama) models
        "llama3.1": ModelCapabilities(
            tier: .local, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 128_000,
            description: "Modelo local versátil"
        ),
        "llama3": ModelCapabilities(
            tier: .local, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 8_000,
            description: "Modelo local rápido"
        ),
        "mistral": ModelCapabilities(
            tier: .local, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 32_000,
            description: "Modelo local eficiente"
        ),
        "codellama": ModelCapabilities(
            tier: .local, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 16_000,
            description: "Especializado em código"
        ),
        "gemma2": ModelCapabilities(
            tier: .local, supportsToolCalling: false, supportsFileAccess: false,
            supportsReasoning: false, supportsReasoningWithTools: false,
            supportsStreaming: true, supportsJsonMode: true,
            maxToolCount: 0, contextWindow: 8_000,
            description: "Modelo leve do Google"
        ),
    ]

    private static let defaultCapabilities = ModelCapabilities(
        tier: .standard, supportsToolCalling: false, supportsFileAccess: false,
        supportsReasoning: false, supportsReasoningWithTools: false,
        supportsStreaming: true, supportsJsonMode: false,
        maxToolCount: 0, contextWindow: 8_000,
        description: "Modelo desconhecido — modo conservador"
    )

    static func capabilities(for model: String) -> ModelCapabilities {
        capabilityMap[model] ?? defaultCapabilities
    }

    // MARK: - Legacy compatibility

    static func isReasoningModel(_ model: String) -> Bool {
        capabilities(for: model).supportsReasoning
    }

    static func supportsToolReasoning(_ model: String) -> Bool {
        capabilities(for: model).supportsReasoningWithTools
    }
}
