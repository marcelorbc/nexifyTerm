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
    let resolver: ToolInstallResolver
}

enum ToolInstallResponse {
    case installTool
    case useAlternative
    case skip
}

/// Garante que a `CheckedContinuation` seja retomada exatamente UMA vez,
/// mesmo que cheguem múltiplas resoluções concorrentes (clique do usuário + timeout).
final class ToolInstallResolver {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolInstallResponse, Never>?
    /// Callback invocado após o resume bem-sucedido (uma única vez).
    /// Usado para limpar a UI quando o timeout dispara antes do clique.
    var onResolved: (@Sendable () -> Void)?

    init(continuation: CheckedContinuation<ToolInstallResponse, Never>) {
        self.continuation = continuation
    }

    func resolve(_ response: ToolInstallResponse) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let cb = onResolved
        onResolved = nil
        lock.unlock()
        guard let cont else { return }
        cont.resume(returning: response)
        cb?()
    }
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
    /// Callback opcional para mostrar o dry-run preview ao usuário e bloquear
    /// até a decisão. Quando nil, o dry-run é pulado.
    var onDryRunRequest: (@MainActor (ExecutionPlan) async -> DryRunDecision)?

    init(router: ModelRouter) {
        self.router = router
    }

    var fileAttachments: [FileAttachment] = []
    var contextExtra: String = ""
    var gitViewModel: GitViewModel?
    var fileExplorerDirectory: String?
    /// Prior turns from the same tab, oldest first. Injected into the prompt so the LLM
    /// has continuity across user messages (no more "starting from scratch every turn").
    var priorTurns: [ConversationTurn] = []
    /// ID único desta rodada de execução (uma por chamada de `execute()`).
    /// Usado pra correlacionar todos os steps gravados na Execution Timeline.
    private(set) var currentSessionId: UUID = UUID()
    /// Prompt original do usuário desta rodada (para gravar com cada step).
    private var currentUserPrompt: String = ""

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
        currentSessionId = UUID()
        currentUserPrompt = userMessage
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
            contextExtra: contextExtra,
            conversationTurns: priorTurns
        )

        if !priorTurns.isEmpty {
            thinkingCtx.append("💬 \(priorTurns.count) turno(s) de conversa prévia desta aba")
        }

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
        let hasToolContext = toolCallingContext != nil
        let capturedThinkingCtx = thinkingCtx
        await MainActor.run {
            let phase = hasToolContext ? "Fase 2: Gerando plan" : "Gerando plan"
            onStatus("\(phase) via \(tab.provider.displayName)...")
            onThinking?("Gerando Plan", capturedThinkingCtx + ["⏳ Enviando prompt para a LLM...", "💬 \"\(userMessage.prefix(80))\""])
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

        applyMemoryUpdatesIfNeeded(plan: initialPlan, onStatus: onStatus)

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

        let capturedInitialPlan = initialPlan
        await MainActor.run {
            onPlanUpdate(capturedInitialPlan, 0)
            onStatus("Plano: \(capturedInitialPlan.title)")
        }

        // ── Dry-run preview (Phase 1 · Trust) ──────────────────────────────
        // O plan preview existente já cobre `.alwaysAsk` e `.manualOnly`.
        // Aqui aplicamos o dry-run RICO (cards visuais com paths e risk) para
        // os modos de auto-execução quando há ações de risco médio+.
        if let onDryRunRequest, shouldRequestDryRun(plan: initialPlan, mode: tab.approvalMode) {
            let dryRunPlan = DryRunPlanner.buildPlan(
                from: initialPlan,
                sessionId: currentSessionId,
                tabId: tab.id.uuidString,
                userPrompt: userMessage,
                baseDirectory: fileExplorerDirectory ?? tab.currentDirectory
            )

            let decision = await onDryRunRequest(dryRunPlan)
            if decision == .cancel {
                NexLog.ai.info("Execution cancelled by user via dry-run preview")
                await MainActor.run {
                    onComplete("Execução cancelada pelo usuário (dry-run).", nil)
                }
                return
            }
        }

        // Execute git actions if present
        if initialPlan.hasGitActions, let gitActions = initialPlan.gitActions {
            try Task.checkCancellation()
            await MainActor.run {
                onStatus("Executando \(gitActions.count) ação(ões) Git...")
            }

            if let vm = gitViewModel {
                let gitResults = await GitActionExecutor.execute(actions: gitActions, viewModel: vm)

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
            let recorder = FileActionRecorder(
                sessionId: currentSessionId,
                tabId: tab.id.uuidString,
                userPrompt: userMessage
            )
            let fileResults = await FileActionExecutor.execute(actions: fileActions, directory: dir, recorder: recorder)

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
            // Defense against the "promise mode" / "fake completion" anti-patterns.
            // We retry up to twice (3 LLM calls total) before giving up — some
            // models will repeat the same promise on the first nudge but yield
            // on the second.
            let maxPromiseRetries = 2
            var attempt = 0
            while attempt < maxPromiseRetries, Self.shouldForceExecution(initialPlan) {
                attempt += 1
                let kind = Self.isPromiseExplanation(initialPlan.explanation + " " + initialPlan.finalNote)
                    ? "promessa futura"
                    : "fake completion (passado sem execução)"
                NexLog.ai.warning("Plan flagged as \(kind) — forcing executable follow-up (attempt \(attempt)/\(maxPromiseRetries))")
                await MainActor.run {
                    onStatus("Modelo \(kind) — pedindo plano real (\(attempt)/\(maxPromiseRetries))...")
                    onThinking?("Anti-promessa ativada", [
                        "⚠️ Detecção: \(kind)",
                        "➡️ Tentativa \(attempt)/\(maxPromiseRetries) — exigindo comandos ou resultado completo."
                    ])
                }
                do {
                    initialPlan = try await regenerateAfterPromise(
                        originalRequest: userMessage,
                        promiseText: initialPlan.explanation + "\n" + initialPlan.finalNote,
                        session: session,
                        tab: tab,
                        onChunk: streamingCb
                    )
                    await MainActor.run {
                        onStreaming?(nil)
                        onThinking?(nil, [])
                        onPlanUpdate(initialPlan, 0)
                    }
                } catch {
                    NexLog.ai.warning("Promise recovery failed (attempt \(attempt)): \(error.localizedDescription)")
                    break
                }
            }

            if initialPlan.hasNoWork {
                let summary = initialPlan.explanation + "\n\n" + initialPlan.finalNote
                logger.logCompletion(summary: summary)
                let richOut = initialPlan.richOutput
                await MainActor.run { onComplete(summary, richOut) }
                return
            }
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
                let capturedRich = lastRichOutput
                await MainActor.run { onComplete(msg, capturedRich) }
                return
            }

            try Task.checkCancellation()
            let capturedRound = round
            let capturedHistory = conversationHistory
            await MainActor.run {
                onStatus("Analisando resultados (round \(capturedRound))...")
                let stepSummary = capturedHistory.suffix(3).map { r in
                    let icon = r.output.succeeded ? "✅" : "❌"
                    return "\(icon) \(r.command.prefix(50))"
                }
                onThinking?("Analisando round \(capturedRound)", stepSummary + ["⏳ Enviando resultados para a LLM..."])
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
                let capturedRichErr = lastRichOutput
                await MainActor.run { onComplete(summary, capturedRichErr) }
                return
            }

            await MainActor.run {
                onStreaming?(nil)
                onThinking?(nil, [])
            }

            logger.logFollowUp(followUpPlan)

            applyMemoryUpdatesIfNeeded(plan: followUpPlan, onStatus: onStatus)

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
                let gitResults = await GitActionExecutor.execute(actions: gitActs, viewModel: vm)
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
                let recorder = FileActionRecorder(
                    sessionId: currentSessionId,
                    tabId: tab.id.uuidString,
                    userPrompt: userMessage
                )
                let fileResults = await FileActionExecutor.execute(actions: fileActs, directory: dir, recorder: recorder)
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
                let capturedRichDone = followUpPlan.richOutput ?? lastRichOutput
                await MainActor.run { onComplete(summary, capturedRichDone) }
                return
            }

            currentPlan = followUpPlan
            let capturedFollowUp = followUpPlan
            let capturedRoundUp = round
            await MainActor.run {
                onPlanUpdate(capturedFollowUp, capturedRoundUp)
            }
        }

        let msg = "Execução concluída após \(round) rounds e \(conversationHistory.count) passos."
        logger.logCompletion(summary: msg)
        let capturedRichFinal = lastRichOutput
        await MainActor.run { onComplete(msg, capturedRichFinal) }
    }

    // MARK: - Promise & fake-completion detection

    /// Future-tense / wait-for-me promises. The presence of any one of these
    /// in `explanation`+`finalNote` (when no commands ran) flags the response
    /// as a promise instead of an execution.
    private static let promisePatterns: [String] = [
        // verb "vou X" - core list
        "vou fazer", "vou extrair", "vou analisar", "vou listar",
        "vou processar", "vou gerar", "vou montar", "vou criar",
        "vou rodar", "vou executar", "vou checar", "vou verificar",
        "vou consultar", "vou abrir", "vou ler",
        "vou te entregar", "vou te mostrar", "vou te enviar",
        "vou retornar", "vou trazer", "vou continuar",
        // verbs that previously slipped through (turnos 1, 4 e 5 do bug report)
        "vou inspecionar", "vou agrupar", "vou identificar",
        "vou separar", "vou organizar", "vou mapear",
        "vou classificar", "vou categorizar", "vou aprofundar",
        "vou mostrar", "vou exibir", "vou apresentar",
        "vou detalhar", "vou explorar", "vou consolidar",
        "vou compilar", "vou cruzar", "vou comparar",
        "vou levantar", "vou puxar", "vou buscar",
        "vou coletar", "vou enumerar", "vou descrever",
        // generic future markers
        "farei", "em seguida", "assim que terminar",
        "assim que a extração terminar", "aguarde enquanto",
        "em breve", "em instantes", "quando terminar",
        // fake follow-ups: "Se quiser, posso..." / "no próximo passo eu..."
        "se quiser, posso", "se você quiser, posso",
        "se quiser eu posso", "se quiser eu aprofundo",
        "no próximo passo eu", "no próximo passo, eu",
        "no próximo passo posso", "no próximo passo, posso",
        "quer que eu", "deseja que eu",
        "posso aprofundar", "posso abrir", "posso detalhar",
        "posso resumir", "posso listar", "posso mostrar",
    ]

    /// Past-tense verbs the LLM uses to fake completion.
    private static let fakeCompletionVerbs: [String] = [
        "organizei", "agrupei", "listei", "identifiquei",
        "mapeei", "classifiquei", "categorizei", "consolidei",
        "elenquei", "separei", "analisei", "inspecionei",
        "verifiquei", "compilei", "extraí",
    ]

    /// Markers that betray the response is *inferred from names* rather than
    /// from real data. When the LLM uses these alongside a past-tense verb
    /// without any command output, it's almost always a fake completion.
    private static let inferenceMarkers: [String] = [
        "inferida", "inferência",
        "com base nos nomes", "pelo nome das pastas",
        "pelo nome dos diretórios", "pelo contexto dos nomes",
        "ainda não abrimos", "ainda não inspecionamos",
        "ainda não rodamos", "ainda não executamos",
        "como ainda não",
    ]

    /// Heuristic: returns true when the plan's explanation/finalNote sounds
    /// like a future-tense promise. Used together with `hasNoWork` to force
    /// a retry.
    static func isPromiseExplanation(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20, trimmed.count < 4000 else { return false }
        for pattern in promisePatterns where lowered.contains(pattern) {
            return true
        }
        return false
    }

    /// Heuristic: detects the **fake completion** anti-pattern — the LLM
    /// pretends it already did the work ("Organizei...", "Identifiquei...")
    /// while admitting it inferred from names only and producing no
    /// commands and no `richOutput`. This was Turno 3 of the bug report.
    static func isFakeCompletion(_ plan: AgentPlan) -> Bool {
        // Real work shipped? Not fake.
        guard plan.hasNoWork else { return false }
        if hasMaterialRichOutput(plan.richOutput) { return false }

        let text = (plan.explanation + " " + plan.finalNote).lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return false }

        let claimsPast = fakeCompletionVerbs.contains { text.contains($0) }
        let admitsInference = inferenceMarkers.contains { text.contains($0) }

        // Strong signal: claims completion in past tense AND admits it's only inferred.
        return claimsPast && admitsInference
    }

    /// Combined check — drives the retry loop in the executor.
    static func shouldForceExecution(_ plan: AgentPlan) -> Bool {
        if !plan.hasNoWork { return false }
        if isPromiseExplanation(plan.explanation + " " + plan.finalNote) { return true }
        if isFakeCompletion(plan) { return true }
        return false
    }

    /// A `RichOutput` only counts as "real evidence" if it actually carries
    /// data — empty metrics/empty rows shouldn't excuse a fake completion.
    private static func hasMaterialRichOutput(_ rich: RichOutput?) -> Bool {
        guard let rich else { return false }
        if let metrics = rich.metrics, !metrics.isEmpty { return true }
        if let table = rich.table, !table.rows.isEmpty { return true }
        if let chart = rich.chart, !chart.items.isEmpty { return true }
        if let html = rich.html, !html.isEmpty { return true }
        if let url = rich.openUrl, !url.isEmpty { return true }
        return false
    }

    private func regenerateAfterPromise(
        originalRequest: String,
        promiseText: String,
        session: TerminalSession,
        tab: TerminalTab,
        onChunk: @escaping StreamCallback
    ) async throws -> AgentPlan {
        try Task.checkCancellation()

        let nudge = """
        Sua resposta anterior foi REJEITADA pelo guarda anti-promessa. Você escreveu:
        ---
        \(promiseText.prefix(800))
        ---

        Por que foi rejeitada (escolha o caso que se aplica):
        1) **Promessa futura**: você usou "vou X", "farei", "em seguida", "se quiser, posso", \
           "no próximo passo", "posso aprofundar", etc. — sem nenhum comando em `commands`.
        2) **Fake completion**: você escreveu no PASSADO ("organizei", "agrupei", \
           "identifiquei", "mapeei", "consolidei") afirmando que fez algo, mas admitiu \
           que era "inferido pelo nome", "com base nos nomes", "ainda não abrimos", \
           "ainda não inspecionamos", e não rodou comando algum. Isso é mentira: você \
           NÃO fez o trabalho. PROIBIDO.

        Você AGORA tem exatamente DUAS opções, escolha UMA:

        OPÇÃO A — EXECUTE: retorne `commands` (ou `gitActions`/`fileActions`) com os \
        comandos reais para resolver: "\(originalRequest)". Sem futuro, sem promessas, \
        sem fake follow-ups. Apenas o comando.

        OPÇÃO B — RESULTADO COMPLETO AGORA: se você já tem dados reais (vindos de \
        comandos anteriores neste chat ou do contexto), retorne `commands` vazio E \
        coloque o RESULTADO COMPLETO em `explanation` (texto final) e/ou `richOutput` \
        (tabela/métricas/gráfico com os dados reais — NÃO inferidos por nome).

        REGRAS IMPÓSTAS:
        - NÃO repita "vou fazer", "vou inspecionar", "vou agrupar", "vou identificar", \
          "se quiser, posso", "no próximo passo".
        - NÃO use passado fingindo conclusão sem dados ("organizei", "agrupei", "identifiquei") \
          se não rodou comando E não tem dados reais no histórico.
        - Se a tarefa exige listar arquivos, agrupar projetos por tecnologia, identificar \
          stack — você PRECISA rodar `find`, `ls`, `cat package.json`, `head Cargo.toml`, \
          `find . -name "*.gemspec"`, `stat`, etc. para ter dados reais.

        Pedido original do usuário: "\(originalRequest)"
        """

        let terminalText = await MainActor.run { session.getTerminalText(maxLines: 30) }

        let input = AgentInput(
            userMessage: nudge,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            terminalContext: terminalText,
            tabMode: tab.tabMode,
            contextExtra: contextExtra,
            conversationTurns: priorTurns
        )

        return try await router.generatePlanStreaming(input: input, onChunk: onChunk)
    }

    // MARK: - Memory auto-capture

    /// If the plan came back with `memoryUpdates` and the user has auto-capture
    /// enabled, persist them to `MemoryStore`. Notifies the UI via `onStatus`.
    private func applyMemoryUpdatesIfNeeded(
        plan: AgentPlan,
        onStatus: @escaping @MainActor (String) -> Void
    ) {
        guard plan.hasMemoryUpdates,
              let updates = plan.memoryUpdates,
              ConfigStore.shared.memoryAutoCapture,
              ConfigStore.shared.memoryEnabled
        else { return }

        let changes = MemoryStore.shared.applyUpdates(updates)
        guard changes > 0 else { return }

        NexLog.ai.info("Memory auto-capture: \(changes) update(s) applied")
        Task { @MainActor in
            onStatus("🧠 \(changes) memória(s) atualizada(s)")
        }
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
            fileAttachments: input.fileAttachments,
            tabMode: input.tabMode,
            contextExtra: input.contextExtra,
            conversationTurns: input.conversationTurns
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

        // Visual echo only — the actual execution happens via CommandExecutor below.
        // Sending to the PTY too would execute the command twice (one in the visible
        // shell, one in the parallel Process), duplicating side effects (mkdir, npm
        // install, etc.).
        session.echoAgentCommand(command.command)

        let savedPassword = SudoManager.shared.savedPassword
        var output = await CommandExecutor.run(
            command.command,
            workingDirectory: tab.currentDirectory,
            sudoPassword: CommandExecutor.needsSudo(command.command) ? savedPassword : nil
        )
        session.echoAgentOutput(output.truncatedOutput, exitCode: output.exitCode)

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

        let timelineStep = ExecutionStep(
            sessionId: currentSessionId,
            tabId: tab.id.uuidString,
            kind: .shellCommand,
            title: command.command,
            detail: command.reason,
            risk: guardResult.classifiedRisk,
            dryRun: false,
            status: output.exitCode == 0 ? .completed : .failed,
            output: output.truncatedOutput,
            errorMessage: output.exitCode == 0 ? nil : output.stderr,
            userPrompt: currentUserPrompt
        )
        ExecutionLogStore.shared.upsert(timelineStep)

        await MainActor.run { onStep(result) }
        return result
    }

    /// Decide se devemos mostrar o dry-run preview rico para este plano.
    /// Retorna `false` para modos onde o PlanPreview existente já cuida disso.
    private func shouldRequestDryRun(plan: AgentPlan, mode: ApprovalMode) -> Bool {
        // Se NÃO tem nada que altere estado, não tem o que prever.
        guard plan.hasFileActions || plan.hasGitActions || !plan.commands.isEmpty else {
            return false
        }
        switch mode {
        case .alwaysAsk, .manualOnly:
            // Já tem PlanPreview existente — evita dupla aprovação.
            return false
        case .autoAll:
            // No auto, mostramos só quando há risco médio+ (proteção mínima).
            return plan.maxRiskLevel >= .medium || plan.hasFileActions
        case .riskBased:
            return plan.maxRiskLevel >= .medium || plan.hasFileActions
        case .autoReadOnly:
            return plan.maxRiskLevel > .readOnly
        }
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
        // Auto-aplicar alternativa quando seguro (builtin do bash ou path absoluto do sistema).
        // Evita travar a UI esperando clique para casos óbvios como `shopt` em zsh.
        if missingTool.canAutoApply,
           let alt = missingTool.installSuggestion?.alternativeCommand {
            await MainActor.run {
                onStatus("Aplicando alternativa automaticamente: \(alt)")
            }
            session.echoAgentCommand(alt)
            let altOut = await CommandExecutor.run(alt, workingDirectory: tab.currentDirectory)
            session.echoAgentOutput(altOut.truncatedOutput, exitCode: altOut.exitCode)
            return altOut
        }

        await MainActor.run {
            onStatus("Ferramenta '\(missingTool.toolName)' não encontrada — aguardando decisão (timeout 30s)...")
        }

        // Timeout de 30s: se o usuário não responder, faz skip automático.
        // Implementação segura: 1 única continuation, resolvida por quem chegar primeiro
        // (resposta do usuário OU timer). Guarda atômica garante resume único.
        let response: ToolInstallResponse = await withCheckedContinuation { (continuation: CheckedContinuation<ToolInstallResponse, Never>) in
            let resolver = ToolInstallResolver(continuation: continuation)
            let request = ToolInstallRequest(
                missingTool: missingTool,
                resolver: resolver
            )
            Task { @MainActor in
                onToolMissing(request)
            }
            Task {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                resolver.resolve(.skip)
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
            session.echoAgentCommand(fixedCommand)
            let altOut = await CommandExecutor.run(fixedCommand, workingDirectory: tab.currentDirectory)
            session.echoAgentOutput(altOut.truncatedOutput, exitCode: altOut.exitCode)
            return altOut

        case .installTool:
            guard let suggestion = missingTool.installSuggestion,
                  suggestion.alternativeCommand == nil else {
                if let alt = missingTool.installSuggestion?.alternativeCommand {
                    let fixedCommand = originalCommand.replacingOccurrences(of: missingTool.toolName, with: alt)
                    await MainActor.run { onStatus("Usando path do sistema: \(fixedCommand)") }
                    session.echoAgentCommand(fixedCommand)
                    let altOut = await CommandExecutor.run(fixedCommand, workingDirectory: tab.currentDirectory)
                    session.echoAgentOutput(altOut.truncatedOutput, exitCode: altOut.exitCode)
                    return altOut
                }
                return CommandOutput(
                    command: originalCommand, stdout: "", stderr: "Sem sugestão de instalação para \(missingTool.toolName)", exitCode: -1
                )
            }

            await MainActor.run { onStatus("Instalando \(missingTool.toolName)...") }
            session.echoAgentCommand(suggestion.installCommand)
            let installOutput = await CommandExecutor.run(suggestion.installCommand, workingDirectory: tab.currentDirectory)
            session.echoAgentOutput(installOutput.truncatedOutput, exitCode: installOutput.exitCode)

            guard installOutput.succeeded else {
                return CommandOutput(
                    command: originalCommand,
                    stdout: installOutput.stdout,
                    stderr: "Falha ao instalar \(missingTool.toolName): \(installOutput.stderr)",
                    exitCode: installOutput.exitCode
                )
            }

            await MainActor.run { onStatus("Retentando: \(originalCommand)") }
            session.echoAgentCommand(originalCommand)
            let retryOut = await CommandExecutor.run(originalCommand, workingDirectory: tab.currentDirectory)
            session.echoAgentOutput(retryOut.truncatedOutput, exitCode: retryOut.exitCode)
            return retryOut

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
            contextExtra: contextExtra,
            conversationTurns: priorTurns
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
            contextExtra: contextExtra,
            conversationTurns: priorTurns
        )

        try Task.checkCancellation()
        return try await router.generatePlanStreaming(input: input, onChunk: onChunk)
    }
}
