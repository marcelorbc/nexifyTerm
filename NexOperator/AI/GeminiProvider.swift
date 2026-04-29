import Foundation

struct GeminiProvider: LLMProvider {
    let id = "gemini"
    let displayName = "Gemini"

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = AppConfig.Gemini.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    private func buildPayload(messages: [[String: String]]) -> [String: Any] {
        let systemMsg = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let userMsg = messages.first(where: { $0["role"] == "user" })?["content"] ?? ""

        return [
            "system_instruction": [
                "parts": [["text": systemMsg]]
            ],
            "contents": [
                ["role": "user", "parts": [["text": userMsg]]]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "responseMimeType": "application/json"
            ]
        ]
    }

    func sendRaw(messages: [[String: String]]) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let urlString = "\(AppConfig.Gemini.baseURL)/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: buildPayload(messages: messages))

        NexLog.ai.info("Sending request to Gemini with model \(model)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await LLMSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 400 {
                throw LLMError.apiError("Invalid request to Gemini. Check your API key and model name.")
            }
            throw LLMError.apiError("Gemini returned status \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMError.invalidResponse
        }

        return text
    }

    func sendRawStreaming(messages: [[String: String]], onChunk: @escaping StreamCallback) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let urlString = "\(AppConfig.Gemini.baseURL)/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: buildPayload(messages: messages))

        NexLog.ai.info("Sending streaming request to Gemini with model \(model)")

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await LLMSession.shared.bytes(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let body = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 400 {
                throw LLMError.apiError("Invalid request to Gemini. Check your API key and model name.")
            }
            throw LLMError.apiError("Gemini returned status \(httpResponse.statusCode): \(body)")
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            guard let chunkData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { continue }

            accumulated += text
            onChunk(accumulated)
        }

        NexLog.ai.info("Gemini streaming response complete")
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
