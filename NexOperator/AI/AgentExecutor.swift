import Foundation

struct StepResult: Identifiable {
    let id = UUID()
    let command: String
    let output: CommandOutput
    let risk: RiskLevel
    let wasBlocked: Bool
    var filePath: String?
}

struct ToolInstallRequest {
    let missingTool: MissingToolInfo
    let continuation: CheckedContinuation<ToolInstallResponse, Never>
}

enum ToolInstallResponse {
    case installTool
    case useAlternative
    case skip
}

struct SudoPasswordRequest {
    let command: String
    let continuation: CheckedContinuation<SudoPasswordResponse, Never>
}

struct SudoPasswordResponse {
    let password: String?
    let save: Bool
}

class AgentExecutor {
    private let router: ModelRouter
    private let guard_ = CommandGuard()
    private let classifier = RiskClassifier()
    private let logger = SessionLogger.shared
    private let maxSteps = 15
    private let maxRounds = 5

    var onThinking: (@MainActor (_ phase: String?, _ details: [String]) -> Void)?
    var onStreaming: (@MainActor (_ partialText: String?) -> Void)?

    init(router: ModelRouter) {
        self.router = router
    }

    var fileAttachments: [FileAttachment] = []
    var contextExtra: String = ""
    var gitViewModel: GitViewModel?
    var fileExplorerDirectory: String?

    func execute(
        userMessage: String,
        tab: TerminalTab,
        session: TerminalSession,
        onStatus: @escaping @MainActor (String) -> Void,
        onStep: @escaping @MainActor (StepResult) -> Void,
        onPlanUpdate: @escaping @MainActor (AgentPlan, Int) -> Void,
        onComplete: @escaping @MainActor (String, RichOutput?) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onToolMissing: @escaping @MainActor (ToolInstallRequest) -> Void,
        onSudoNeeded: @escaping @MainActor (SudoPasswordRequest) -> Void
    ) {
        Task {
            do {
                try await executeInternal(
                    userMessage: userMessage,
                    tab: tab,
                    session: session,
                    onStatus: onStatus,
                    onStep: onStep,
                    onPlanUpdate: onPlanUpdate,
                    onComplete: onComplete,
                    onError: onError,
                    onToolMissing: onToolMissing,
                    onSudoNeeded: onSudoNeeded
                )
            } catch is CancellationError {
                NexLog.ai.info("Agent execution cancelled")
                await MainActor.run { onError("Execução cancelada pelo usuário.") }
            } catch {
                let errorDetail = buildErrorDetail(error)
                NexLog.ai.error("Agent execution failed: \(errorDetail)")
                logger.logError(errorDetail)
                CrashLog.shared.save("AgentExecutor error: \(errorDetail)")
                await MainActor.run { onError(errorDetail) }
            }
        }
    }

    private func executeInternal(
        userMessage: String,
        tab: TerminalTab,
        session: TerminalSession,
        onStatus: @escaping @MainActor (String) -> Void,
        onStep: @escaping @MainActor (StepResult) -> Void,
        onPlanUpdate: @escaping @MainActor (AgentPlan, Int) -> Void,
        onComplete: @escaping @MainActor (String, RichOutput?) -> Void,
        onError: @escaping @MainActor (String) -> Void,
        onToolMissing: @escaping @MainActor (ToolInstallRequest) -> Void,
        onSudoNeeded: @escaping @MainActor (SudoPasswordRequest) -> Void
    ) async throws {
        let logFile = logger.startSession(
            userMessage: userMessage,
            provider: tab.provider.displayName,
            model: tab.model
        )
        NexLog.ai.info("Session log: \(logFile)")

        await MainActor.run {
            onStatus("Coletando contexto...")
            onThinking?("Coletando contexto", ["Lendo terminal..."])
        }

        let learnings = LearningStore.shared.relevantLearnings(for: userMessage)

        let terminalText = await MainActor.run { session.getTerminalText(maxLines: 50) }

        var thinkingCtx: [String] = []
        thinkingCtx.append("📂 Diretório: \(tab.currentDirectory)")
        if !terminalText.isEmpty {
            let lineCount = terminalText.components(separatedBy: "\n").count
            thinkingCtx.append("🖥️ Terminal: \(lineCount) linhas de contexto")
        }
        if !learnings.isEmpty {
            thinkingCtx.append("🧠 \(learnings.count) aprendizados anteriores carregados")
        }
        thinkingCtx.append("🤖 Provider: \(tab.provider.displayName) / \(tab.model)")

        await MainActor.run {
            onThinking?("Montando prompt", thinkingCtx)
        }

        var enrichedMessage = userMessage
        if !learnings.isEmpty {
            let tips = learnings.map { "- \($0.lesson)" }.joined(separator: "\n")
            enrichedMessage += "\n\n[APRENDIZADOS ANTERIORES - evite estes erros]\n\(tips)"
        }

        if !fileAttachments.isEmpty {
            let names = fileAttachments.map { "\($0.fileName) (\($0.displaySize))" }.joined(separator: ", ")
            thinkingCtx.append("📎 Arquivos anexados: \(names)")
        }

        let mcpToolsCtx = await MCPManager.shared.toolsDescription()
        if !mcpToolsCtx.isEmpty {
            thinkingCtx.append("🔧 \(await MCPManager.shared.availableTools.count) MCP tools disponíveis")
        }

        if tab.tabMode == .git {
            thinkingCtx.append("🔀 Modo Git: contexto do repositório injetado")
        } else if tab.tabMode == .explorer {
            thinkingCtx.append("📁 Modo Explorer: contexto de arquivos injetado")
        }

        let input = AgentInput(
            userMessage: enrichedMessage,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            terminalContext: terminalText,
            mcpToolsContext: mcpToolsCtx,
            fileAttachments: fileAttachments,
            tabMode: tab.tabMode,
            contextExtra: contextExtra
        )

        try Task.checkCancellation()

        // Phase 1: Tool Calling (context gathering) - for providers that support it
        let llm = router.provider(for: tab.provider, model: tab.model)
        var toolCallingContext: ToolCallingResult?

        if llm.supportsToolCalling {
            let availableTools = NexToolRegistry.tools(for: tab.model)
            thinkingCtx.append("🔧 \(availableTools.count) NexTools (tool calling)")
            await MainActor.run {
                onStatus("Coletando dados via tools (\(llm.displayName))...")
                onThinking?("Tool Calling + Plan", thinkingCtx + ["⏳ Fase 1: Coletando contexto com \(availableTools.count) ferramentas...", "💬 \"\(userMessage.prefix(80))\""])
            }

            do {
                let result = try await router.executeWithTools(
                    input: input,
                    onToolCall: { @Sendable toolName, args in
                        await MainActor.run {
                            onStatus("🔧 Tool: \(toolName)")
                        }

                        let fileOps: Set<String> = ["write_file", "read_file"]
                        let detectedPath: String? = fileOps.contains(toolName) ? args["path"] : nil

                        let toolStep = StepResult(
                            command: "🔧 \(toolName)",
                            output: CommandOutput(command: toolName, stdout: args.description, stderr: "", exitCode: 0),
                            risk: .readOnly,
                            wasBlocked: false,
                            filePath: detectedPath
                        )
                        await MainActor.run { onStep(toolStep) }
                    },
                    onStatus: { @Sendable status in
                        await MainActor.run { onStatus(status) }
                    }
                )

                if case .unsupported = result {
                    NexLog.ai.info("Tool calling unsupported, proceeding with plan-only mode")
                } else {
                    toolCallingContext = result
                    let toolCount = result.toolResults.count
                    let toolSummary = result.toolResults.map { "  🔧 \($0.toolName): \($0.isError ? "❌" : "✅")" }.joined(separator: "\n")
                    NexLog.ai.info("Tool calling phase completed: \(toolCount) tools executed\n\(toolSummary)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NexLog.ai.warning("Tool calling phase failed, proceeding with plan-only: \(error.localizedDescription)")
                await MainActor.run {
                    onStatus("Tools indisponíveis, gerando plan direto...")
                    onThinking?("Fallback", ["⚠️ Tool calling falhou: \(error.localizedDescription.prefix(80))", "➡️ Continuando sem tools..."])
                }
            }
        }

        // Phase 2: Plan Generation + Execution
        await MainActor.run {
            let phase = toolCallingContext != nil ? "Fase 2: Gerando plan" : "Gerando plan"
            onStatus("\(phase) via \(tab.provider.displayName)...")
            onThinking?("Gerando Plan", thinkingCtx + ["⏳ Enviando prompt para a LLM...", "💬 \"\(userMessage.prefix(80))\""])
        }

        var conversationHistory: [StepResult] = []
        var round = 0
        var lastRichOutput: RichOutput? = nil

        let streamingCb: StreamCallback = { [weak self] partial in
            guard let self else { return }
            Task { @MainActor in
                self.onStreaming?(partial)
            }
        }

        var initialPlan: AgentPlan

        if let tcResult = toolCallingContext {
            switch tcResult {
            case .completed(let content, let toolResults, let rounds):
                NexLog.ai.info("Parsing tool calling response as plan (\(rounds) rounds, \(toolResults.count) tools)")
                let parsed = parseToolCallingAsPlan(content: content)

                let hasSubstantialContent = parsed.richOutput != nil
                    || !parsed.explanation.isEmpty && parsed.explanation.count > 200
                    || !parsed.commands.isEmpty

                if hasSubstantialContent {
                    initialPlan = parsed
                } else if !toolResults.isEmpty {
                    NexLog.ai.warning("Tool calling response lacks data (\(content.count) chars), regenerating plan with \(toolResults.count) tool results")
                    let toolContext = buildToolResultsContext(toolResults)
                    initialPlan = try await generatePlanWithToolContext(
                        toolContext: toolContext,
                        input: input,
                        onChunk: streamingCb
                    )
                } else {
                    initialPlan = parsed
                }

            case .maxRoundsReached(let toolResults):
                NexLog.ai.warning("Tool calling hit max rounds, generating plan with collected context")
                let toolContext = buildToolResultsContext(toolResults)
                initialPlan = try await generatePlanWithToolContext(
                    toolContext: toolContext,
                    input: input,
                    onChunk: streamingCb
                )

            case .unsupported:
                initialPlan = try await router.generatePlanStreaming(input: input, onChunk: streamingCb)
            }
        } else {
            // No tool calling - standard plan generation
            initialPlan = try await router.generatePlanStreaming(input: input, onChunk: streamingCb)
        }

        logger.logPlan(initialPlan)

        await MainActor.run {
            onStreaming?(nil)
            onThinking?(nil, [])
        }

        if initialPlan.hasSkillCreation, let creation = initialPlan.skillCreation {
            let skill = Skill(
                name: creation.name,
                instruction: creation.instruction,
                icon: creation.icon ?? "bolt.fill"
            )
            await MainActor.run {
                SkillStore.shared.add(skill)
            }
            NexLog.ai.info("Skill created via AI: \(creation.name)")
        }

        if initialPlan.hasMCPToolCalls {
            initialPlan = try await handleMCPToolCalls(
                plan: initialPlan,
                originalRequest: userMessage,
                tab: tab,
                session: session,
                onStatus: onStatus,
                onChunk: streamingCb
            )
        }

        await MainActor.run {
            onPlanUpdate(initialPlan, 0)
            onStatus("Plano: \(initialPlan.title)")
        }

        // Execute git actions if present
        if initialPlan.hasGitActions, let gitActions = initialPlan.gitActions {
            try Task.checkCancellation()
            await MainActor.run {
                onStatus("Executando \(gitActions.count) ação(ões) Git...")
            }

            if let vm = gitViewModel {
                let gitResults = await MainActor.run {
                    await GitActionExecutor.execute(actions: gitActions, viewModel: vm)
                }

                for gr in gitResults {
                    let stepResult = StepResult(
                        command: "git:\(gr.action.type)",
                        output: CommandOutput(
                            command: "git:\(gr.action.type)",
                            stdout: gr.message,
                            stderr: gr.success ? "" : gr.message,
                            exitCode: gr.success ? 0 : 1
                        ),
                        risk: .low,
                        wasBlocked: false
                    )
                    conversationHistory.append(stepResult)
                    await MainActor.run { onStep(stepResult) }
                }
            }
        }

        // Execute file actions if present
        if initialPlan.hasFileActions, let fileActions = initialPlan.fileActions {
            try Task.checkCancellation()
            await MainActor.run {
                onStatus("Executando \(fileActions.count) ação(ões) de arquivo...")
            }

            let dir = fileExplorerDirectory ?? tab.currentDirectory
            let fileResults = await FileActionExecutor.execute(actions: fileActions, directory: dir)

            for fr in fileResults {
                let stepResult = StepResult(
                    command: "file:\(fr.action.type)",
                    output: CommandOutput(
                        command: "file:\(fr.action.type)",
                        stdout: fr.message,
                        stderr: fr.success ? "" : fr.message,
                        exitCode: fr.success ? 0 : 1
                    ),
                    risk: .low,
                    wasBlocked: false
                )
                conversationHistory.append(stepResult)
                await MainActor.run { onStep(stepResult) }
            }
        }

        if initialPlan.hasNoWork {
            let summary = initialPlan.explanation + "\n\n" + initialPlan.finalNote
            logger.logCompletion(summary: summary)
            await MainActor.run { onComplete(summary, initialPlan.richOutput) }
            return
        }

        var currentPlan = initialPlan

        while round < maxRounds && conversationHistory.count < maxSteps {
            try Task.checkCancellation()
            round += 1

            for (index, command) in currentPlan.commands.enumerated() {
                try Task.checkCancellation()

                if conversationHistory.count >= maxSteps {
                    break
                }

                let stepResult = await executeStep(
                    command: command,
                    index: index,
                    totalCommands: currentPlan.commands.count,
                    tab: tab,
                    session: session,
                    onStatus: onStatus,
                    onStep: onStep,
                    onToolMissing: onToolMissing,
                    onSudoNeeded: onSudoNeeded,
                    isFollowUp: round > 1
                )
                conversationHistory.append(stepResult)

                if !stepResult.output.succeeded && !stepResult.wasBlocked {
                    LearningStore.shared.learn(
                        command: stepResult.command,
                        error: stepResult.output.stderr,
                        lesson: "Comando '\(stepResult.command.prefix(60))' falhou: \(stepResult.output.stderr.prefix(120))"
                    )
                }
            }

            if conversationHistory.count >= maxSteps {
                let msg = "Limite de \(maxSteps) passos atingido."
                logger.logCompletion(summary: msg)
                await MainActor.run { onComplete(msg, lastRichOutput) }
                return
            }

            try Task.checkCancellation()
            await MainActor.run {
                onStatus("Analisando resultados (round \(round))...")
                let stepSummary = conversationHistory.suffix(3).map { r in
                    let icon = r.output.succeeded ? "✅" : "❌"
                    return "\(icon) \(r.command.prefix(50))"
                }
                onThinking?("Analisando round \(round)", stepSummary + ["⏳ Enviando resultados para a LLM..."])
            }

            var followUpPlan: AgentPlan
            do {
                followUpPlan = try await getFollowUp(
                    originalRequest: userMessage,
                    results: conversationHistory,
                    session: session,
                    tab: tab,
                    onChunk: streamingCb
                )
            } catch {
                let msg = "Erro no follow-up: \(error.localizedDescription)"
                NexLog.ai.error("Follow-up failed: \(error.localizedDescription)")
                let summary = currentPlan.finalNote.isEmpty ? "Execução parcial concluída." : currentPlan.finalNote
                logger.logCompletion(summary: summary)
                await MainActor.run { onComplete(summary, lastRichOutput) }
                return
            }

            await MainActor.run {
                onStreaming?(nil)
                onThinking?(nil, [])
            }

            logger.logFollowUp(followUpPlan)

            if followUpPlan.hasMCPToolCalls {
                followUpPlan = try await handleMCPToolCalls(
                    plan: followUpPlan,
                    originalRequest: userMessage,
                    tab: tab,
                    session: session,
                    onStatus: onStatus,
                    onChunk: streamingCb
                )
            }

            lastRichOutput = followUpPlan.richOutput ?? lastRichOutput

            // Execute follow-up git actions
            if followUpPlan.hasGitActions, let gitActs = followUpPlan.gitActions, let vm = gitViewModel {
                let gitResults = await MainActor.run {
                    await GitActionExecutor.execute(actions: gitActs, viewModel: vm)
                }
                for gr in gitResults {
                    let stepResult = StepResult(
                        command: "git:\(gr.action.type)",
                        output: CommandOutput(command: "git:\(gr.action.type)", stdout: gr.message, stderr: gr.success ? "" : gr.message, exitCode: gr.success ? 0 : 1),
                        risk: .low, wasBlocked: false
                    )
                    conversationHistory.append(stepResult)
                    await MainActor.run { onStep(stepResult) }
                }
            }

            // Execute follow-up file actions
            if followUpPlan.hasFileActions, let fileActs = followUpPlan.fileActions {
                let dir = fileExplorerDirectory ?? tab.currentDirectory
                let fileResults = await FileActionExecutor.execute(actions: fileActs, directory: dir)
                for fr in fileResults {
                    let stepResult = StepResult(
                        command: "file:\(fr.action.type)",
                        output: CommandOutput(command: "file:\(fr.action.type)", stdout: fr.message, stderr: fr.success ? "" : fr.message, exitCode: fr.success ? 0 : 1),
                        risk: .low, wasBlocked: false
                    )
                    conversationHistory.append(stepResult)
                    await MainActor.run { onStep(stepResult) }
                }
            }

            if followUpPlan.hasNoWork {
                let summary = followUpPlan.explanation + "\n\n" + followUpPlan.finalNote
                logger.logCompletion(summary: summary)
                await MainActor.run { onComplete(summary, followUpPlan.richOutput ?? lastRichOutput) }
                return
            }

            currentPlan = followUpPlan
            await MainActor.run {
                onPlanUpdate(followUpPlan, round)
            }
        }

        let msg = "Execução concluída após \(round) rounds e \(conversationHistory.count) passos."
        logger.logCompletion(summary: msg)
        await MainActor.run { onComplete(msg, lastRichOutput) }
    }

    // MARK: - Tool Calling Helpers

    private func parseToolCallingAsPlan(content: String) -> AgentPlan {
        switch JSONPlanParser.parse(content) {
        case .success(let plan):
            return plan
        case .failure(let error):
            NexLog.ai.warning("Tool calling response not valid plan JSON, wrapping as text: \(error.localizedDescription)")
            return AgentPlan.textOnly(
                title: "Resultado da análise",
                explanation: content,
                finalNote: ""
            )
        }
    }

    private func buildToolResultsContext(_ results: [NexToolResult]) -> String {
        guard !results.isEmpty else { return "" }
        var ctx = "\n=== DADOS COLETADOS PELAS TOOLS ===\n"
        for r in results {
            let status = r.isError ? "ERRO" : "OK"
            ctx += "[\(r.toolName)] (\(status)):\n\(r.content.prefix(1500))\n\n"
        }
        ctx += "=== FIM DADOS TOOLS ===\n"
        return ctx
    }

    private func generatePlanWithToolContext(
        toolContext: String,
        input: AgentInput,
        onChunk: @escaping StreamCallback
    ) async throws -> AgentPlan {
        let enrichedInput = AgentInput(
            userMessage: input.userMessage + "\n\n" + toolContext + "\nUse os dados coletados acima para gerar o plan. Se já tiver tudo necessário, retorne commands vazio [].",
            currentDirectory: input.currentDirectory,
            provider: input.provider,
            model: input.model,
            terminalContext: input.terminalContext,
            mcpToolsContext: input.mcpToolsContext,
            fileAttachments: input.fileAttachments
        )
        return try await router.generatePlanStreaming(input: enrichedInput, onChunk: onChunk)
    }

    private func executeStep(
        command: AgentCommand,
        index: Int,
        totalCommands: Int,
        tab: TerminalTab,
        session: TerminalSession,
        onStatus: @escaping @MainActor (String) -> Void,
        onStep: @escaping @MainActor (StepResult) -> Void,
        onToolMissing: @escaping @MainActor (ToolInstallRequest) -> Void,
        onSudoNeeded: @escaping @MainActor (SudoPasswordRequest) -> Void,
        isFollowUp: Bool = false
    ) async -> StepResult {
        let guardResult = guard_.evaluate(
            command: command.command,
            approvalMode: tab.approvalMode
        )

        if guardResult.isBlocked {
            logger.logBlocked(command: command.command, reason: guardResult.blockReason)
            let result = StepResult(
                command: command.command,
                output: CommandOutput(command: command.command, stdout: "", stderr: "BLOQUEADO: \(guardResult.blockReason ?? "Segurança")", exitCode: -1),
                risk: .blocked,
                wasBlocked: true
            )
            await MainActor.run { onStep(result) }
            return result
        }

        logger.logStepStart(index: index, command: command.command, risk: guardResult.classifiedRisk)

        let slowEstimate = SlowCommandClassifier.classify(command.command)
        let prefix = isFollowUp ? "Follow-up" : "Executando"

        if let warning = slowEstimate.warningText {
            await MainActor.run {
                onStatus("\(warning) — \(command.command.prefix(60))")
                onThinking?("Aviso de comando lento", [warning, "Comando: \(command.command.prefix(80))", "Você pode derrubar a qualquer momento."])
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        await MainActor.run {
            let statusText = slowEstimate.isSlow
                ? "\(prefix) [\(index + 1)/\(totalCommands)]: \(command.command) — \(slowEstimate.shortLabel ?? "")"
                : "\(prefix) [\(index + 1)/\(totalCommands)]: \(command.command)"
            onStatus(statusText)
        }

        guard !Task.isCancelled else {
            return StepResult(
                command: command.command,
                output: CommandOutput(command: command.command, stdout: "", stderr: "Cancelado pelo usuário", exitCode: -1),
                risk: .blocked,
                wasBlocked: true
            )
        }

        session.sendCommand(command.command)

        let savedPassword = SudoManager.shared.savedPassword
        var output = await CommandExecutor.run(
            command.command,
            workingDirectory: tab.currentDirectory,
            sudoPassword: CommandExecutor.needsSudo(command.command) ? savedPassword : nil
        )

        guard !Task.isCancelled else {
            return StepResult(
                command: command.command,
                output: CommandOutput(command: command.command, stdout: "", stderr: "Cancelado pelo usuário", exitCode: -1),
                risk: .blocked,
                wasBlocked: true
            )
        }

        if CommandExecutor.isSudoPasswordError(output) {
            let autoAuth = ConfigStore.shared.sudoAutoAuthorize
            let savedPassword = SudoManager.shared.savedPassword

            if autoAuth, let password = savedPassword, !password.isEmpty {
                await MainActor.run {
                    onStatus("🔓 Sudo auto-autorizado: \(command.command.prefix(50))")
                }

                output = await CommandExecutor.run(
                    command.command,
                    workingDirectory: tab.currentDirectory,
                    sudoPassword: password
                )
            } else {
                await MainActor.run {
                    onStatus("🔐 Senha sudo necessária para: \(command.command.prefix(50))")
                }

                let sudoResponse = await withCheckedContinuation { (cont: CheckedContinuation<SudoPasswordResponse, Never>) in
                    let request = SudoPasswordRequest(command: command.command, continuation: cont)
                    Task { @MainActor in onSudoNeeded(request) }
                }

                if let password = sudoResponse.password, !password.isEmpty {
                    if sudoResponse.save {
                        SudoManager.shared.savePassword(password)
                    }

                    await MainActor.run {
                        onStatus("Executando com sudo: \(command.command.prefix(50))")
                    }

                    output = await CommandExecutor.run(
                        command.command,
                        workingDirectory: tab.currentDirectory,
                        sudoPassword: password
                    )
                }
            }
        }

        if let missingTool = ToolAvailabilityChecker.detectMissingTool(from: output) {
            output = await handleMissingTool(
                missingTool: missingTool,
                originalCommand: command.command,
                session: session,
                tab: tab,
                onStatus: onStatus,
                onToolMissing: onToolMissing
            )
        }

        logger.logStepResult(index: index, command: command.command, output: output, risk: guardResult.classifiedRisk)

        let result = StepResult(
            command: command.command,
            output: output,
            risk: guardResult.classifiedRisk,
            wasBlocked: false
        )
        await MainActor.run { onStep(result) }
        return result
    }

    static func parseRichOutput(from content: String) -> (cleanContent: String, richOutput: RichOutput?) {
        let startTag = "<!--RICH_OUTPUT_JSON-->"
        let endTag = "<!--/RICH_OUTPUT_JSON-->"

        if let startRange = content.range(of: startTag),
           let endRange = content.range(of: endTag) {
            let jsonStr = String(content[startRange.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = String(content[content.startIndex..<startRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = jsonStr.data(using: .utf8),
               let rich = try? JSONDecoder().decode(RichOutput.self, from: data) {
                return (clean, rich)
            }
            return (clean, nil)
        }

        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let richJSON = json["richOutput"] {
            let richData = try? JSONSerialization.data(withJSONObject: richJSON)
            let rich = richData.flatMap { try? JSONDecoder().decode(RichOutput.self, from: $0) }
            return (content, rich)
        }

        return (content, nil)
    }

    private func buildErrorDetail(_ error: Error) -> String {
        let base = error.localizedDescription
        let type = String(describing: type(of: error))

        if let urlError = error as? URLError {
            let code = urlError.code.rawValue
            switch urlError.code {
            case .timedOut:
                return "Timeout na conexão com a LLM (código \(code)). Verifique sua internet ou tente um modelo menor.\n\nDetalhes: \(base)"
            case .notConnectedToInternet, .networkConnectionLost:
                return "Sem conexão com a internet (código \(code)).\n\nDetalhes: \(base)"
            case .cannotFindHost, .cannotConnectToHost:
                return "Não foi possível conectar ao servidor da LLM (código \(code)).\n\nDetalhes: \(base)"
            default:
                return "Erro de rede (código \(code)): \(base)"
            }
        }

        if let llmError = error as? LLMError {
            switch llmError {
            case .missingAPIKey:
                return "API Key não configurada. Vá em Configurações e adicione sua chave."
            case .parsingError(let detail):
                return "Erro ao interpretar resposta da LLM: \(detail)"
            case .apiError(let detail):
                return "Erro da API: \(detail)"
            default:
                return "Erro LLM [\(type)]: \(base)"
            }
        }

        return "Erro [\(type)]: \(base)"
    }

    private func handleMissingTool(
        missingTool: MissingToolInfo,
        originalCommand: String,
        session: TerminalSession,
        tab: TerminalTab,
        onStatus: @escaping @MainActor (String) -> Void,
        onToolMissing: @escaping @MainActor (ToolInstallRequest) -> Void
    ) async -> CommandOutput {
        await MainActor.run {
            onStatus("Ferramenta '\(missingTool.toolName)' não encontrada — aguardando decisão...")
        }

        let response = await withCheckedContinuation { (continuation: CheckedContinuation<ToolInstallResponse, Never>) in
            let request = ToolInstallRequest(
                missingTool: missingTool,
                continuation: continuation
            )
            Task { @MainActor in
                onToolMissing(request)
            }
        }

        switch response {
        case .useAlternative:
            guard let alt = missingTool.installSuggestion?.alternativeCommand else {
                return CommandOutput(
                    command: originalCommand,
                    stdout: "",
                    stderr: "Sem alternativa para \(missingTool.toolName)",
                    exitCode: -1
                )
            }
            let fixedCommand = originalCommand.replacingOccurrences(of: missingTool.toolName, with: alt)
            await MainActor.run { onStatus("Tentando com path completo: \(fixedCommand)") }
            session.sendCommand(fixedCommand)
            return await CommandExecutor.run(fixedCommand, workingDirectory: tab.currentDirectory)

        case .installTool:
            guard let suggestion = missingTool.installSuggestion,
                  suggestion.alternativeCommand == nil else {
                if let alt = missingTool.installSuggestion?.alternativeCommand {
                    let fixedCommand = originalCommand.replacingOccurrences(of: missingTool.toolName, with: alt)
                    await MainActor.run { onStatus("Usando path do sistema: \(fixedCommand)") }
                    session.sendCommand(fixedCommand)
                    return await CommandExecutor.run(fixedCommand, workingDirectory: tab.currentDirectory)
                }
                return CommandOutput(
                    command: originalCommand, stdout: "", stderr: "Sem sugestão de instalação para \(missingTool.toolName)", exitCode: -1
                )
            }

            await MainActor.run { onStatus("Instalando \(missingTool.toolName)...") }
            session.sendCommand(suggestion.installCommand)
            let installOutput = await CommandExecutor.run(suggestion.installCommand, workingDirectory: tab.currentDirectory)

            guard installOutput.succeeded else {
                return CommandOutput(
                    command: originalCommand,
                    stdout: installOutput.stdout,
                    stderr: "Falha ao instalar \(missingTool.toolName): \(installOutput.stderr)",
                    exitCode: installOutput.exitCode
                )
            }

            await MainActor.run { onStatus("Retentando: \(originalCommand)") }
            session.sendCommand(originalCommand)
            return await CommandExecutor.run(originalCommand, workingDirectory: tab.currentDirectory)

        case .skip:
            return CommandOutput(
                command: originalCommand, stdout: "", stderr: "Ignorado: \(missingTool.toolName) não instalado (usuário recusou)", exitCode: -1
            )
        }
    }

    private func handleMCPToolCalls(
        plan: AgentPlan,
        originalRequest: String,
        tab: TerminalTab,
        session: TerminalSession,
        onStatus: @escaping @MainActor (String) -> Void,
        onChunk: @escaping StreamCallback
    ) async throws -> AgentPlan {
        guard let calls = plan.mcpToolCalls, !calls.isEmpty else { return plan }

        await MainActor.run {
            onStatus("Executando \(calls.count) MCP tool(s)...")
            onThinking?("Chamando MCP Tools", calls.map { "🔧 \($0.server).\($0.tool)" })
        }

        let results = await MCPManager.shared.executeMCPToolCalls(calls)

        let mcpContext = PromptBuilder.buildMCPResultsContext(results: results)

        await MainActor.run {
            onStatus("Processando resultados MCP...")
            onThinking?("Analisando resultados MCP", results.map { r in
                let icon = r.isError ? "❌" : "✅"
                return "\(icon) \(r.server).\(r.tool): \(r.content.prefix(60))"
            })
        }

        let terminalText = await MainActor.run { session.getTerminalText(maxLines: 30) }

        let enrichedMessage = """
        O usuário pediu: "\(originalRequest)"

        Seu plano inicial:
        - Título: \(plan.title)
        - Explicação: \(plan.explanation)

        \(mcpContext)

        Agora, com base nos resultados das tools MCP acima, gere o plano final.
        Se os dados MCP já são suficientes para responder, retorne commands vazio [] e use richOutput.
        Se ainda precisa executar comandos no terminal, inclua-os normalmente.

        Responda no mesmo formato JSON, em Português Brasileiro.
        """

        let input = AgentInput(
            userMessage: enrichedMessage,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            terminalContext: terminalText,
            tabMode: tab.tabMode,
            contextExtra: contextExtra
        )

        try Task.checkCancellation()
        return try await router.generatePlanStreaming(input: input, onChunk: onChunk)
    }

    private func getFollowUp(
        originalRequest: String,
        results: [StepResult],
        session: TerminalSession,
        tab: TerminalTab,
        onChunk: @escaping StreamCallback
    ) async throws -> AgentPlan {
        try Task.checkCancellation()

        let followUpMessage = PromptBuilder.buildFollowUpMessage(
            originalRequest: originalRequest,
            results: results
        )

        let terminalText = await MainActor.run { session.getTerminalText(maxLines: 30) }

        let input = AgentInput(
            userMessage: followUpMessage,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            terminalContext: terminalText,
            tabMode: tab.tabMode,
            contextExtra: contextExtra
        )

        try Task.checkCancellation()
        return try await router.generatePlanStreaming(input: input, onChunk: onChunk)
    }
}
