import Foundation

enum AppConfig {
    static let appName = "NexOperator Terminal"
    static let appVersion = "0.1.0"

    enum Ollama {
        static let defaultBaseURL = "http://localhost:11434"
        static let defaultModel = "qwen2.5-coder:7b"
        static let chatEndpoint = "/api/chat"
    }

    enum OpenAI {
        static let baseURL = "https://api.openai.com/v1"
        static let defaultModel = "gpt-5.5"
        static let chatEndpoint = "/chat/completions"
    }

    enum Gemini {
        static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
        static let defaultModel = "gemini-2.5-pro"
    }

    enum GitHub {
        static let oauthClientId = "Ov23li7DpLMLUkfipKL3"
    }

    enum Defaults {
        static let provider = ProviderType.ollama
        static let approvalMode = ApprovalMode.alwaysAsk
        static let shell = "/bin/zsh"
    }
}
