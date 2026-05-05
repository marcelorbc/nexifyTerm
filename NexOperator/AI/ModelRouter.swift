import Foundation

struct ModelRouter {
    let configStore: ConfigStore

    func provider(for type: ProviderType, model: String? = nil) -> any LLMProvider {
        switch type {
        case .ollama:
            return OllamaProvider(
                baseURL: configStore.ollamaBaseURL,
                model: model ?? configStore.ollamaModel
            )
        case .openAI:
            return OpenAIProvider(
                apiKey: configStore.openAIAPIKey,
                model: model ?? configStore.openAIModel
            )
        case .gemini:
            return GeminiProvider(
                apiKey: configStore.geminiAPIKey,
                model: model ?? configStore.geminiModel
            )
        }
    }

    func generatePlan(input: AgentInput) async throws -> AgentPlan {
        let llm = provider(for: input.provider, model: input.model)
        NexLog.ai.info("Routing to \(llm.displayName) (\(input.model))")
        return try await llm.generatePlan(input: input)
    }

    func generatePlanStreaming(input: AgentInput, onChunk: @escaping StreamCallback) async throws -> AgentPlan {
        let llm = provider(for: input.provider, model: input.model)
        NexLog.ai.info("Routing streaming to \(llm.displayName) (\(input.model)) [mode: \(input.tabMode.rawValue)]")

        let messages = PromptBuilder.buildMessages(from: input, tabMode: input.tabMode, contextExtra: input.contextExtra)
        let content = try await llm.sendRawStreaming(messages: messages, onChunk: onChunk)

        switch JSONPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let firstError):
            NexLog.ai.warning("Streaming parse failed, retrying with repair prompt...")
            let retryMessages = PromptBuilder.buildRepairPrompt(rawResponse: content)
            let retryContent = try await llm.sendRaw(messages: retryMessages)
            switch JSONPlanParser.parse(retryContent) {
            case .success(let plan): return plan
            case .failure: throw firstError
            }
        }
    }

    func generateFollowUpStreaming(messages: [[String: String]], providerType: ProviderType, model: String, onChunk: @escaping StreamCallback) async throws -> AgentPlan {
        let llm = provider(for: providerType, model: model)
        let content = try await llm.sendRawStreaming(messages: messages, onChunk: onChunk)

        switch JSONPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let firstError):
            let retryMessages = PromptBuilder.buildRepairPrompt(rawResponse: content)
            let retryContent = try await llm.sendRaw(messages: retryMessages)
            switch JSONPlanParser.parse(retryContent) {
            case .success(let plan): return plan
            case .failure: throw firstError
            }
        }
    }

    // MARK: - Tool Calling Flow

    func executeWithTools(
        input: AgentInput,
        onToolCall: @escaping @Sendable (String, [String: String]) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> ToolCallingResult {
        let llm = provider(for: input.provider, model: input.model)

        guard llm.supportsToolCalling else {
            NexLog.ai.info("Provider \(llm.displayName) does not support tool calling, falling back to plan mode")
            return .unsupported
        }

        NexLog.ai.info("Starting tool calling flow with \(llm.displayName) (\(input.model))")

        let tools = NexToolRegistry.openAITools(for: input.model)
        let systemPrompt = PromptBuilder.buildToolCallingSystemPrompt()
        let userPrompt = PromptBuilder.buildToolCallingUserPrompt(from: input)
        let toolExecutor = NexToolExecutor(workingDirectory: input.currentDirectory)

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        var allToolResults: [NexToolResult] = []
        let maxRounds = 10

        for round in 1...maxRounds {
            try Task.checkCancellation()

            await onStatus("Enviando para \(llm.displayName) (round \(round))...")

            let response = try await llm.sendWithTools(messages: messages, tools: tools)

            switch response {
            case .toolCalls(let calls):
                NexLog.ai.info("Round \(round): LLM requested \(calls.count) tool(s)")

                var assistantToolCalls: [[String: Any]] = []
                for call in calls {
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data()
                    let argsString = String(data: argsJSON, encoding: .utf8) ?? "{}"
                    assistantToolCalls.append([
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": argsString
                        ] as [String: Any]
                    ])
                }

                messages.append([
                    "role": "assistant",
                    "tool_calls": assistantToolCalls
                ])

                for call in calls {
                    await onToolCall(call.name, call.arguments)
                    let result = await toolExecutor.execute(call: call)
                    allToolResults.append(result)

                    messages.append(result.toOpenAIMessage())

                    NexLog.ai.info("Tool \(call.name) result: \(result.isError ? "ERROR" : "OK") (\(result.content.count) chars)")
                }

            case .finalContent(let content):
                NexLog.ai.info("Round \(round): LLM returned final content (\(content.count) chars)")
                return .completed(
                    content: content,
                    toolResults: allToolResults,
                    rounds: round
                )
            }
        }

        NexLog.ai.warning("Tool calling reached max rounds (\(maxRounds))")
        return .maxRoundsReached(toolResults: allToolResults)
    }

    func generateBrowserPlan(input: AgentInput) async throws -> BrowserPlan {
        let llm = provider(for: input.provider, model: input.model)
        NexLog.ai.info("Routing browser plan to \(llm.displayName) (\(input.model))")
        let messages = PromptBuilder.buildMessages(from: input)
        let content = try await llm.sendRaw(messages: messages)

        switch JSONBrowserPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let error):
            throw error
        }
    }

    func sendBrowserFollowUp(messages: [[String: String]], providerType: ProviderType, model: String) async throws -> BrowserPlan {
        let llm = provider(for: providerType, model: model)
        let content = try await llm.sendRaw(messages: messages)

        switch JSONBrowserPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Tool Calling Result

enum ToolCallingResult {
    case completed(content: String, toolResults: [NexToolResult], rounds: Int)
    case maxRoundsReached(toolResults: [NexToolResult])
    case unsupported

    var toolResults: [NexToolResult] {
        switch self {
        case .completed(_, let results, _): return results
        case .maxRoundsReached(let results): return results
        case .unsupported: return []
        }
    }
}
