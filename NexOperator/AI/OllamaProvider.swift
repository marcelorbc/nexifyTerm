import Foundation

struct OllamaProvider: LLMProvider {
    let id = "ollama"
    let displayName = "Ollama"

    let baseURL: String
    let model: String

    init(baseURL: String = AppConfig.Ollama.defaultBaseURL, model: String = AppConfig.Ollama.defaultModel) {
        self.baseURL = baseURL
        self.model = model
    }

    private func buildRequest(messages: [[String: String]], stream: Bool) throws -> URLRequest {
        let urlString = baseURL + AppConfig.Ollama.chatEndpoint
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL }

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "format": "json"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    func sendRaw(messages: [[String: String]]) async throws -> String {
        let request = try buildRequest(messages: messages, stream: false)
        NexLog.ai.info("Sending request to Ollama: \(baseURL) with model \(model)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await LLMSession.shared.data(for: request)
        } catch {
            throw LLMError.providerUnavailable("Ollama at \(baseURL). Make sure Ollama is running.")
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError("Ollama returned status \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        NexLog.ai.info("Ollama response received")
        return content
    }

    func sendRawStreaming(messages: [[String: String]], onChunk: @escaping StreamCallback) async throws -> String {
        let request = try buildRequest(messages: messages, stream: true)
        NexLog.ai.info("Sending streaming request to Ollama: \(baseURL) with model \(model)")

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await LLMSession.shared.bytes(for: request)
        } catch {
            throw LLMError.providerUnavailable("Ollama at \(baseURL). Make sure Ollama is running.")
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError("Ollama returned status \(httpResponse.statusCode): \(body)")
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let done = json["done"] as? Bool, done { break }

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                accumulated += content
                onChunk(accumulated)
            }
        }

        NexLog.ai.info("Ollama streaming response complete")
        return accumulated
    }

    func generatePlan(input: AgentInput) async throws -> AgentPlan {
        let messages = PromptBuilder.buildMessages(from: input)
        let content = try await sendRaw(messages: messages)

        switch JSONPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let firstError):
            NexLog.ai.warning("First parse failed, retrying with repair prompt...")
            let retryMessages = PromptBuilder.buildRepairPrompt(rawResponse: content)
            let retryContent = try await sendRaw(messages: retryMessages)
            switch JSONPlanParser.parse(retryContent) {
            case .success(let plan): return plan
            case .failure: throw firstError
            }
        }
    }
}
