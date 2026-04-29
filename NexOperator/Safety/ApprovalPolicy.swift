import Foundation

struct ApprovalPolicy {

    func requiresApproval(mode: ApprovalMode, riskLevel: RiskLevel) -> Bool {
        switch mode {
        case .autoAll:
            return false
        case .manualOnly:
            return true
        case .alwaysAsk:
            return true
        case .riskBased:
            return riskLevel > .readOnly
        case .autoReadOnly:
            return riskLevel > .readOnly
        }
    }

    func canExecute(mode: ApprovalMode, riskLevel: RiskLevel) -> Bool {
        if riskLevel == .blocked { return false }

        switch mode {
        case .manualOnly:
            return false
        case .autoAll, .alwaysAsk, .riskBased, .autoReadOnly:
            return true
        }
    }
}
