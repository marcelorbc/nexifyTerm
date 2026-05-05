import Foundation

class TabAgentState {
    var isAgentRunning = false
    var agentStatus: String?
    var agentResults: [StepResult] = []
    var agentTask: Task<Void, Never>?
    /// Wave 2 · C6: tracks the in-flight `submitPromptInline` task so it can be
    /// cancelled when the tab is closed or the user cancels the operation.
    /// Without this, closing a tab during inline prompt generation left the task
    /// alive, eventually publishing into a state nobody owned.
    var inlineTask: Task<Void, Never>?

    var errorMessage: String?

    var pendingAgentMessage: String?
    var previewPlan: AgentPlan?
    var isShowingPlanPreview = false
    var previewGuardResults: [CommandGuard.GuardResult] = []

    var currentPlan: AgentPlan?
    var isShowingApproval = false
    var guardResults: [CommandGuard.GuardResult] = []

    var pendingToolInstall: ToolInstallRequest?
    var isShowingToolInstall = false

    var pendingSudoRequest: SudoPasswordRequest?
    var isShowingSudoPrompt = false

    var lastRichOutput: RichOutput?
    var browserURL: URL?
    var startTime: Date?
    var endTime: Date?

    var runningPlan: AgentPlan?
    var runningPlanRound: Int = 0

    var thinkingPhase: String?
    var thinkingDetails: [String] = []
    var streamingText: String?
    var fileAttachments: [FileAttachment] = []

    /// Conversation memory for THIS tab. Survives between user messages so the LLM
    /// has continuity. Cleared explicitly via `clearConversation()` or when the tab closes.
    var conversationTurns: [ConversationTurn] = []

    /// Caps how many past turns are passed back to the LLM. Bigger = more context but more tokens.
    private let maxTurnsForPrompt = 6

    /// Returns the most recent turns (oldest first) up to the configured cap, for prompt injection.
    var recentTurnsForPrompt: [ConversationTurn] {
        Array(conversationTurns.suffix(maxTurnsForPrompt))
    }

    func appendTurn(_ turn: ConversationTurn) {
        conversationTurns.append(turn)
        // Hard cap to avoid unbounded memory growth even before prompt-trimming.
        let hardCap = 50
        if conversationTurns.count > hardCap {
            conversationTurns.removeFirst(conversationTurns.count - hardCap)
        }
    }

    func clearConversation() {
        conversationTurns.removeAll()
    }

    func reset() {
        isAgentRunning = false
        agentStatus = nil
        agentResults = []
        agentTask = nil
        inlineTask = nil
        errorMessage = nil
        pendingAgentMessage = nil
        previewPlan = nil
        isShowingPlanPreview = false
        previewGuardResults = []
        currentPlan = nil
        isShowingApproval = false
        guardResults = []
        pendingToolInstall = nil
        isShowingToolInstall = false
        browserURL = nil
        startTime = nil
        endTime = nil
        runningPlan = nil
        runningPlanRound = 0
        thinkingPhase = nil
        thinkingDetails = []
        streamingText = nil
        fileAttachments = []
    }

    func cancel() {
        agentTask?.cancel()
        agentTask = nil
        inlineTask?.cancel()
        inlineTask = nil
        isAgentRunning = false
        agentStatus = "Cancelado"
        endTime = Date()
        runningPlan = nil
        runningPlanRound = 0

        if let request = pendingToolInstall {
            isShowingToolInstall = false
            pendingToolInstall = nil
            request.resolver.resolve(.skip)
        }

        if let request = pendingSudoRequest {
            isShowingSudoPrompt = false
            pendingSudoRequest = nil
            request.continuation.resume(returning: SudoPasswordResponse(password: nil, save: false))
        }
    }

    func dismissPlan() {
        isShowingApproval = false
        currentPlan = nil
        guardResults = []
    }

    func dismissPlanPreview() {
        isShowingPlanPreview = false
        previewPlan = nil
        previewGuardResults = []
        pendingAgentMessage = nil
    }
}
