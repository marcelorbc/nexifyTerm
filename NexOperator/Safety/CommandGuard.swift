import Foundation

struct CommandGuard {
    private let classifier = RiskClassifier()
    private let policy = ApprovalPolicy()

    struct GuardResult {
        let command: String
        let classifiedRisk: RiskLevel
        let requiresApproval: Bool
        let isBlocked: Bool
        let blockReason: String?
    }

    func evaluate(command: String, approvalMode: ApprovalMode) -> GuardResult {
        let risk = classifier.classify(command)

        if risk == .blocked {
            return GuardResult(
                command: command,
                classifiedRisk: risk,
                requiresApproval: true,
                isBlocked: true,
                blockReason: "This command is blocked for safety. It could cause irreversible damage to your system."
            )
        }

        let needsApproval = policy.requiresApproval(mode: approvalMode, riskLevel: risk)

        return GuardResult(
            command: command,
            classifiedRisk: risk,
            requiresApproval: needsApproval,
            isBlocked: false,
            blockReason: nil
        )
    }

    func evaluatePlan(_ plan: AgentPlan, approvalMode: ApprovalMode) -> [GuardResult] {
        plan.commands.map { evaluate(command: $0.command, approvalMode: approvalMode) }
    }
}
