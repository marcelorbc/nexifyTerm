import Foundation

typealias StreamCallback = @Sendable (String) -> Void

protocol LLMProvider {
    var id: String { get }
    var displayName: String { get }
    func generatePlan(input: AgentInput) async throws -> AgentPlan
    func sendRaw(messages: [[String: String]]) async throws -> String
    func sendRawStreaming(messages: [[String: String]], onChunk: @escaping StreamCallback) async throws -> String

    var supportsToolCalling: Bool { get }
    func sendWithTools(messages: [[String: Any]], tools: [[String: Any]]) async throws -> LLMToolResponse
}

extension LLMProvider {
    func sendRawStreaming(messages: [[String: String]], onChunk: @escaping StreamCallback) async throws -> String {
        return try await sendRaw(messages: messages)
    }

    var supportsToolCalling: Bool { false }

    func sendWithTools(messages: [[String: Any]], tools: [[String: Any]]) async throws -> LLMToolResponse {
        throw LLMError.apiError("Tool calling not supported by \(displayName)")
    }
}

enum LLMSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
}

enum LLMError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case parsingError(String)
    case apiError(String)
    case missingAPIKey
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL configuration. Check your provider settings."
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .invalidResponse:
            return "Received an invalid response from the AI provider."
        case .parsingError(let msg):
            return "Failed to parse AI response: \(msg)"
        case .apiError(let msg):
            return "API error: \(msg)"
        case .missingAPIKey:
            return "API key not configured. Open Settings to add your key."
        case .providerUnavailable(let name):
            return "\(name) is not available. Check if it's running and configured correctly."
        }
    }
}
