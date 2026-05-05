import Foundation
import SwiftUI

/// Status de um passo no ciclo de vida da execução.
enum ExecutionStepStatus: String, Codable {
    case planned        // Faz parte de um plano (dry-run); ainda não rodou
    case approved       // Usuário aprovou; vai rodar em seguida
    case running        // Em execução
    case completed      // Sucesso
    case failed         // Erro
    case blocked        // Bloqueado por policy
    case cancelled      // Usuário cancelou no dry-run
    case rolledBack     // Foi revertido pelo usuário

    var displayName: String {
        switch self {
        case .planned:     return "Planejado"
        case .approved:    return "Aprovado"
        case .running:     return "Executando"
        case .completed:   return "OK"
        case .failed:      return "Falhou"
        case .blocked:     return "Bloqueado"
        case .cancelled:   return "Cancelado"
        case .rolledBack:  return "Revertido"
        }
    }

    var icon: String {
        switch self {
        case .planned:     return "clock"
        case .approved:    return "checkmark.circle"
        case .running:     return "arrow.triangle.2.circlepath"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "xmark.octagon.fill"
        case .blocked:     return "hand.raised.fill"
        case .cancelled:   return "minus.circle"
        case .rolledBack:  return "arrow.uturn.backward.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .planned:     return .secondary
        case .approved:    return .blue
        case .running:     return .accentColor
        case .completed:   return .green
        case .failed:      return .red
        case .blocked:     return .orange
        case .cancelled:   return .secondary
        case .rolledBack:  return .purple
        }
    }
}

/// Categoria do step — alimenta filtros e ícones na timeline.
enum ExecutionStepKind: String, Codable {
    case fileWrite
    case fileMove
    case fileRename
    case fileDelete
    case fileCreateFolder
    case fileDuplicate
    case fileCompress
    case fileOpen
    case shellCommand
    case gitAction
    case toolCall            // tools nativas (NexTool)
    case mcpToolCall         // tools de servidores MCP
    case skillCreation

    var displayName: String {
        switch self {
        case .fileWrite:        return "Escrever Arquivo"
        case .fileMove:         return "Mover Arquivo"
        case .fileRename:       return "Renomear"
        case .fileDelete:       return "Deletar"
        case .fileCreateFolder: return "Criar Pasta"
        case .fileDuplicate:    return "Duplicar"
        case .fileCompress:     return "Comprimir"
        case .fileOpen:         return "Abrir"
        case .shellCommand:     return "Comando Shell"
        case .gitAction:        return "Git"
        case .toolCall:         return "Tool"
        case .mcpToolCall:      return "MCP"
        case .skillCreation:    return "Skill"
        }
    }

    var icon: String {
        switch self {
        case .fileWrite:        return "doc.badge.plus"
        case .fileMove:         return "arrow.right.doc.on.clipboard"
        case .fileRename:       return "pencil"
        case .fileDelete:       return "trash"
        case .fileCreateFolder: return "folder.badge.plus"
        case .fileDuplicate:    return "doc.on.doc"
        case .fileCompress:     return "doc.zipper"
        case .fileOpen:         return "doc.text"
        case .shellCommand:     return "terminal"
        case .gitAction:        return "arrow.triangle.branch"
        case .toolCall:         return "wrench.and.screwdriver"
        case .mcpToolCall:      return "network"
        case .skillCreation:    return "sparkles"
        }
    }

    /// Indica se uma operação desse tipo, em condições normais, pode ser revertida.
    var supportsRollback: Bool {
        switch self {
        case .fileWrite, .fileMove, .fileRename, .fileDelete,
             .fileCreateFolder, .fileDuplicate:
            return true
        case .fileCompress, .fileOpen, .shellCommand, .gitAction,
             .toolCall, .mcpToolCall, .skillCreation:
            return false
        }
    }
}

/// Operação de rollback armazenada junto com o step.
/// Cada caso descreve EXATAMENTE como reverter, para que possamos executar
/// o rollback sem reinventar nada depois.
enum RollbackOperation: Codable {
    case restoreFromBackup(originalPath: String, backupPath: String)
    case moveBack(currentPath: String, originalPath: String)
    case deleteCreated(path: String)
    case restoreFromTrash(originalPath: String)

    var summary: String {
        switch self {
        case .restoreFromBackup(let p, _):  return "Restaurar conteúdo de \(URL(fileURLWithPath: p).lastPathComponent)"
        case .moveBack(_, let original):    return "Voltar para \(URL(fileURLWithPath: original).lastPathComponent)"
        case .deleteCreated(let p):         return "Apagar \(URL(fileURLWithPath: p).lastPathComponent)"
        case .restoreFromTrash(let p):      return "Restaurar \(URL(fileURLWithPath: p).lastPathComponent) da Lixeira"
        }
    }
}

/// Um step da execução do agente — entidade central da Execution Timeline.
struct ExecutionStep: Identifiable, Codable {
    let id: UUID
    /// Agrupa steps de uma mesma "rodada" do agente (uma chamada do execute()).
    let sessionId: UUID
    /// Para correlacionar com a aba que disparou.
    let tabId: String?
    let timestamp: Date
    let kind: ExecutionStepKind
    /// Resumo curto: "Mover 12 arquivos para Documentos/"
    let title: String
    /// Detalhe longo: comando completo, paths, args, etc.
    let detail: String
    let risk: RiskLevel
    /// True quando o step foi parte de um dry-run (não executou de verdade).
    var dryRun: Bool
    var status: ExecutionStepStatus
    /// Output / mensagem após execução (vazio quando ainda não rodou).
    var output: String
    var errorMessage: String?
    /// Caminhos afetados (usado pra mostrar visualmente no dry-run).
    var affectedPaths: [String]
    /// Operação de rollback se a ação for reversível.
    var rollback: RollbackOperation?
    /// Quando foi revertido (se foi).
    var rolledBackAt: Date?
    /// Prompt original do usuário que gerou esta sessão.
    var userPrompt: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        tabId: String? = nil,
        timestamp: Date = Date(),
        kind: ExecutionStepKind,
        title: String,
        detail: String = "",
        risk: RiskLevel = .low,
        dryRun: Bool = false,
        status: ExecutionStepStatus = .planned,
        output: String = "",
        errorMessage: String? = nil,
        affectedPaths: [String] = [],
        rollback: RollbackOperation? = nil,
        rolledBackAt: Date? = nil,
        userPrompt: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.tabId = tabId
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.risk = risk
        self.dryRun = dryRun
        self.status = status
        self.output = output
        self.errorMessage = errorMessage
        self.affectedPaths = affectedPaths
        self.rollback = rollback
        self.rolledBackAt = rolledBackAt
        self.userPrompt = userPrompt
    }

    var canRollback: Bool {
        guard kind.supportsRollback,
              status == .completed,
              rollback != nil,
              rolledBackAt == nil else { return false }
        return true
    }
}

/// Plano agregado para o dry-run. Mostrado ao usuário antes de qualquer execução.
struct ExecutionPlan: Identifiable {
    let id: UUID
    let sessionId: UUID
    let userPrompt: String
    let steps: [ExecutionStep]
    let createdAt: Date

    init(sessionId: UUID, userPrompt: String, steps: [ExecutionStep]) {
        self.id = UUID()
        self.sessionId = sessionId
        self.userPrompt = userPrompt
        self.steps = steps
        self.createdAt = Date()
    }

    /// Maior nível de risco entre os steps — pode acionar aprovação.
    var maxRisk: RiskLevel {
        steps.map(\.risk).max() ?? .readOnly
    }

    /// Conjunto de paths que serão afetados (deduplicado).
    var allAffectedPaths: [String] {
        Array(Set(steps.flatMap(\.affectedPaths))).sorted()
    }

    /// Steps agrupados por categoria — usado na UI de preview.
    var stepsByKind: [(ExecutionStepKind, [ExecutionStep])] {
        let grouped = Dictionary(grouping: steps) { $0.kind }
        return grouped.sorted { $0.key.displayName < $1.key.displayName }
    }
}

/// Resposta do usuário ao preview do dry-run.
enum DryRunDecision {
    case approve
    case cancel
}
