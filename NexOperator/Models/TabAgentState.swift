import Foundation

class TabAgentState {
    var isAgentRunning = false
    var agentStatus: String?
    var agentResults: [StepResult] = []
    var agentTask: Task<Void, Never>?

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

    func reset() {
        isAgentRunning = false
        agentStatus = nil
        agentResults = []
        agentTask = nil
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
        isAgentRunning = false
        agentStatus = "Cancelado"
        endTime = Date()
        runningPlan = nil
        runningPlanRound = 0

        if let request = pendingToolInstall {
            isShowingToolInstall = false
            pendingToolInstall = nil
            request.continuation.resume(returning: .skip)
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
