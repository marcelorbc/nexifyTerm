import Foundation

enum ApprovalMode: String, CaseIterable, Codable, Identifiable {
    case autoAll
    case riskBased
    case alwaysAsk
    case manualOnly
    case autoReadOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .autoAll: return "Auto ⚡"
        case .manualOnly: return "Manual"
        case .alwaysAsk: return "Perguntar"
        case .riskBased: return "Por Risco"
        case .autoReadOnly: return "Auto Leitura"
        }
    }

    var shortDescription: String {
        switch self {
        case .autoAll: return "Executa tudo automaticamente sem perguntar"
        case .manualOnly: return "IA apenas sugere, nunca executa"
        case .alwaysAsk: return "Sempre mostra plano antes de executar"
        case .riskBased: return "Auto-executa leitura, pergunta o resto"
        case .autoReadOnly: return "Auto-executa apenas comandos de leitura"
        }
    }
}
