import Foundation

struct OpenAIProvider: LLMProvider {
    let id = "openai"
    let displayName = "OpenAI"
    var supportsToolCalling: Bool { capabilities.canUseToolCalling }

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = AppConfig.OpenAI.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    private var capabilities: ModelCapabilities {
        ProviderType.capabilities(for: model)
    }

    private var isReasoningModel: Bool {
        capabilities.supportsReasoning
    }

    private func buildRequest(messages: [[String: String]], stream: Bool) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let urlString = AppConfig.OpenAI.baseURL + AppConfig.OpenAI.chatEndpoint
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "response_format": ["type": "json_object"]
        ]

        if isReasoningModel {
            payload["reasoning_effort"] = stream ? "low" : "medium"
        }

        if stream {
            payload["stream"] = true
            payload["stream_options"] = ["include_usage": true]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = stream && isReasoningModel ? 600 : 300
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func buildToolRequest(messages: [[String: Any]], tools: [[String: Any]]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }

        let urlString = AppConfig.OpenAI.baseURL + AppConfig.OpenAI.chatEndpoint
        guard let url = URL(string: urlString) else { throw LLMError.invalidURL }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools
        ]
        if !tools.isEmpty {
            payload["tool_choice"] = "auto"
        }
        if capabilities.supportsReasoningWithTools {
            payload["reasoning_effort"] = "low"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = isReasoningModel ? 600 : 300
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    func sendRaw(messages: [[String: String]]) async throws -> String {
        let request = try buildRequest(messages: messages, stream: false)
        NexLog.ai.info("Sending request to OpenAI with model \(model)")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await LLMSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 { throw LLMError.missingAPIKey }
            throw LLMError.apiError("OpenAI returned status \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }

    func sendRawStreaming(messages: [[String: String]], onChunk: @escaping StreamCallback) async throws -> String {
        let request = try buildRequest(messages: messages, stream: true)
        NexLog.ai.info("Sending streaming request to OpenAI with model \(model) (reasoning=\(isReasoningModel))")

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
            if httpResponse.statusCode == 401 { throw LLMError.missingAPIKey }
            throw LLMError.apiError("OpenAI returned status \(httpResponse.statusCode): \(body)")
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let chunkData = payload.data(using: .utf8),
                  let chunkJSON = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                  let choices = chunkJSON["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                accumulated += content
                onChunk(accumulated)
            } else if let refusal = delta["refusal"] as? String, !refusal.isEmpty {
                NexLog.ai.warning("OpenAI stream refusal: \(refusal)")
                throw LLMError.apiError("Model refused request: \(refusal)")
            }

            if let finishReason = first["finish_reason"] as? String, finishReason == "stop" {
                break
            }
        }

        if accumulated.isEmpty {
            NexLog.ai.warning("Streaming returned empty content for model \(model)")
            throw LLMError.invalidResponse
        }

        return accumulated
    }

    // MARK: - Tool Calling

    func sendWithTools(messages: [[String: Any]], tools: [[String: Any]]) async throws -> LLMToolResponse {
        guard capabilities.canUseToolCalling else {
            NexLog.ai.warning("Model \(model) cannot use tools on /v1/chat/completions (reasoning model without tool support)")
            throw LLMError.apiError("Modelo \(model) não suporta tools no endpoint chat/completions. Use um modelo compatível ou desative tool calling.")
        }

        let request = try buildToolRequest(messages: messages, tools: tools)
        NexLog.ai.info("Sending tool-aware request to OpenAI with model \(model), \(tools.count) tools")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await LLMSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 { throw LLMError.missingAPIKey }
            throw LLMError.apiError("OpenAI returned status \(httpResponse.statusCode): \(body)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        let finishReason = first["finish_reason"] as? String ?? ""

        if finishReason == "tool_calls",
           let toolCallsRaw = message["tool_calls"] as? [[String: Any]] {
            let calls = toolCallsRaw.compactMap { NexToolCall(from: $0) }
            if !calls.isEmpty {
                NexLog.ai.info("OpenAI requested \(calls.count) tool call(s): \(calls.map(\.name).joined(separator: ", "))")
                return .toolCalls(calls)
            }
        }

        if let content = message["content"] as? String {
            return .finalContent(content)
        }

        throw LLMError.invalidResponse
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
