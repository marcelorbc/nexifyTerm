import Foundation

/// Operações git que podem causar perda de dados ou afetar branches
/// protegidas. Usadas por `GitViewModel` para pausar antes de executar e
/// pedir confirmação explícita do usuário (`GitDestructiveConfirmSheet`).
///
/// Cada caso carrega o payload mínimo necessário para executar a ação sem
/// reexecutar o pipeline de validação — o sheet de confirmação só decide
/// se confirma ou cancela.
enum GitDestructiveAction: Equatable {
    /// `git reset --hard <commitHash>` — apaga mudanças locais não
    /// commitadas no working tree.
    case resetHard(commitHash: String, hasDirtyTree: Bool)

    /// `git branch -D <name>` — remove branch local sem checar se foi
    /// mergeada.
    case forceDeleteBranch(name: String)

    /// `git push --force` — sobrescreve história remota; só permitido em
    /// branches não protegidas (caso contrário é `pushToProtected`).
    case forcePush(branch: String)

    /// `git push` em branch protegida (main, master, develop, production…).
    /// Pede confirmação mesmo que seja push normal.
    case pushToProtected(branch: String)

    /// `git stash drop` de TODOS os stashes (operação em lote).
    case dropAllStashes(count: Int)

    var title: String {
        switch self {
        case .resetHard:
            return "Reset --hard descarta mudanças locais"
        case .forceDeleteBranch(let name):
            return "Forçar delete da branch '\(name)'"
        case .forcePush(let branch):
            return "Force-push em '\(branch)' reescreve história remota"
        case .pushToProtected(let branch):
            return "Push direto em branch protegida '\(branch)'"
        case .dropAllStashes(let n):
            return "Apagar todos os \(n) stashes"
        }
    }

    var explanation: String {
        switch self {
        case .resetHard(let hash, let dirty):
            let head = "HEAD vai para \(hash.prefix(7))."
            if dirty {
                return "\(head)\n\n⚠️ Você tem mudanças não commitadas — elas serão perdidas e não há undo. Considere `git stash` antes."
            }
            return "\(head) Commits após esse hash deixarão de ser alcançáveis pelo branch atual (recuperáveis via `git reflog` por ~90 dias)."
        case .forceDeleteBranch(let name):
            return "A branch '\(name)' pode conter commits que não estão em nenhuma outra branch. Esses commits ficam órfãos e são limpos pelo `git gc` em ~30 dias."
        case .forcePush(let branch):
            return "Force-push reescreve a história remota de '\(branch)'. Quem já tinha pull dessa branch verá conflitos no próximo pull. Use somente em branches pessoais."
        case .pushToProtected(let branch):
            return "'\(branch)' é uma branch protegida (main, master, develop, production, prod, release). Em times maduros isso geralmente exige um Pull Request, não push direto."
        case .dropAllStashes(let n):
            return "\(n) stash(es) serão removidos permanentemente. Não há undo."
        }
    }

    /// Botão de confirmação. Texto deliberadamente direto para o usuário
    /// não confirmar no automático.
    var confirmLabel: String {
        switch self {
        case .resetHard:           return "Sim, descartar mudanças"
        case .forceDeleteBranch:   return "Sim, apagar branch"
        case .forcePush:           return "Sim, force-push"
        case .pushToProtected:     return "Sim, push direto"
        case .dropAllStashes:      return "Sim, apagar tudo"
        }
    }

    var icon: String {
        switch self {
        case .resetHard:           return "arrow.uturn.backward.circle.fill"
        case .forceDeleteBranch:   return "trash.fill"
        case .forcePush:           return "arrow.up.forward.circle.fill"
        case .pushToProtected:     return "lock.shield.fill"
        case .dropAllStashes:      return "tray.full.fill"
        }
    }

    /// Risco associado. Drives o nível de friction (cor, checkbox obrigatório).
    enum Severity { case high, critical }
    var severity: Severity {
        switch self {
        case .resetHard(_, let dirty):
            return dirty ? .critical : .high
        case .forcePush, .dropAllStashes, .forceDeleteBranch:
            return .critical
        case .pushToProtected:
            return .high
        }
    }
}

/// Lista canônica de branches consideradas "protegidas" para fins de
/// confirmação no client. Não substitui rules do GitHub/GitLab — é uma
/// camada local para evitar acidente.
enum GitProtectedBranches {
    static let names: Set<String> = [
        "main", "master", "develop", "production", "prod",
        "release", "stable", "default"
    ]

    static func isProtected(_ branch: String) -> Bool {
        names.contains(branch.lowercased())
    }
}
