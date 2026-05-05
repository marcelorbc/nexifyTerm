import Foundation

/// Converte um `AgentPlan` em `ExecutionPlan` (lista de `ExecutionStep` com
/// status `.planned`) para mostrar ao usuário antes de executar.
///
/// Não modifica nada — só descreve. A execução real lê o mesmo `AgentPlan`
/// e materializa os steps via `ExecutionLogStore` quando rodar.
enum DryRunPlanner {

    /// Constrói um plano de preview (todos os steps com `dryRun = true`).
    static func buildPlan(
        from agentPlan: AgentPlan,
        sessionId: UUID,
        tabId: String,
        userPrompt: String,
        baseDirectory: String
    ) -> ExecutionPlan {
        var steps: [ExecutionStep] = []
        let now = Date()

        // 1. File actions
        for action in agentPlan.fileActions ?? [] {
            steps.append(stepForFileAction(
                action,
                sessionId: sessionId,
                tabId: tabId,
                userPrompt: userPrompt,
                baseDirectory: baseDirectory,
                timestamp: now
            ))
        }

        // 2. Git actions
        for action in agentPlan.gitActions ?? [] {
            steps.append(stepForGitAction(
                action,
                sessionId: sessionId,
                tabId: tabId,
                userPrompt: userPrompt,
                timestamp: now
            ))
        }

        // 3. Shell commands
        for command in agentPlan.commands {
            steps.append(stepForCommand(
                command,
                sessionId: sessionId,
                tabId: tabId,
                userPrompt: userPrompt,
                timestamp: now
            ))
        }

        return ExecutionPlan(
            sessionId: sessionId,
            userPrompt: userPrompt,
            steps: steps
        )
    }

    // MARK: - File action mapping

    private static func stepForFileAction(
        _ action: FileAction,
        sessionId: UUID,
        tabId: String,
        userPrompt: String,
        baseDirectory: String,
        timestamp: Date
    ) -> ExecutionStep {
        let params = action.params ?? [:]
        let baseURL = URL(fileURLWithPath: baseDirectory)

        let kind: ExecutionStepKind
        let title: String
        let detail: String
        let risk: RiskLevel
        let paths: [String]

        switch action.type.lowercased() {
        case "createfolder":
            kind = .fileCreateFolder
            let name = params["name"] ?? "?"
            title = "Criar pasta: \(name)"
            paths = [baseURL.appendingPathComponent(name).path]
            detail = "Cria uma nova pasta dentro de \(baseDirectory)."
            risk = .low

        case "rename":
            kind = .fileRename
            let oldName = params["oldName"] ?? "?"
            let newName = params["newName"] ?? "?"
            title = "Renomear: \(oldName) → \(newName)"
            paths = [
                baseURL.appendingPathComponent(oldName).path,
                baseURL.appendingPathComponent(newName).path
            ]
            detail = "Renomeia o arquivo/pasta no diretório."
            risk = .medium

        case "delete":
            kind = .fileDelete
            let files = parseFileList(params["files"] ?? "")
            title = files.count == 1
                ? "Mover para Lixeira: \(files[0])"
                : "Mover \(files.count) item(ns) para a Lixeira"
            paths = files.map { baseURL.appendingPathComponent($0).path }
            detail = "Itens vão para a Lixeira (recuperáveis manualmente):\n" + files.joined(separator: "\n")
            risk = .high

        case "move":
            kind = .fileMove
            let files = parseFileList(params["files"] ?? "")
            let destination = params["destination"] ?? "?"
            title = "Mover \(files.count) item(ns) → \(destination)"
            let destURL = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : baseURL.appendingPathComponent(destination)
            paths = files.map { baseURL.appendingPathComponent($0).path } + [destURL.path]
            detail = "Move:\n" + files.joined(separator: "\n") + "\nPara: \(destURL.path)"
            risk = .medium

        case "duplicate":
            kind = .fileDuplicate
            let file = params["file"] ?? "?"
            title = "Duplicar: \(file)"
            paths = [baseURL.appendingPathComponent(file).path]
            detail = "Cria uma cópia ao lado do original."
            risk = .low

        case "compress":
            kind = .fileCompress
            let files = parseFileList(params["files"] ?? "")
            let archive = params["name"] ?? "archive.zip"
            title = "Comprimir \(files.count) item(ns) → \(archive)"
            paths = files.map { baseURL.appendingPathComponent($0).path }
            detail = "Gera \(archive)."
            risk = .low

        case "openterminal":
            kind = .fileOpen
            title = "Abrir terminal em \(baseDirectory)"
            paths = [baseDirectory]
            detail = ""
            risk = .readOnly

        case "openfile":
            kind = .fileOpen
            let file = params["file"] ?? "?"
            title = "Abrir arquivo: \(file)"
            paths = [baseURL.appendingPathComponent(file).path]
            detail = "Abre com o app default do macOS."
            risk = .readOnly

        case "openinfinder":
            kind = .fileOpen
            let file = params["file"] ?? ""
            title = file.isEmpty ? "Mostrar pasta no Finder" : "Mostrar \(file) no Finder"
            paths = file.isEmpty ? [baseDirectory] : [baseURL.appendingPathComponent(file).path]
            detail = ""
            risk = .readOnly

        default:
            kind = .toolCall
            title = "Ação: \(action.type)"
            paths = []
            detail = "Parâmetros: \(params)"
            risk = .medium
        }

        return ExecutionStep(
            sessionId: sessionId,
            tabId: tabId,
            timestamp: timestamp,
            kind: kind,
            title: title,
            detail: detail,
            risk: risk,
            dryRun: true,
            status: .planned,
            affectedPaths: paths,
            userPrompt: userPrompt
        )
    }

    // MARK: - Git action mapping

    private static func stepForGitAction(
        _ action: GitAction,
        sessionId: UUID,
        tabId: String,
        userPrompt: String,
        timestamp: Date
    ) -> ExecutionStep {
        let params = action.params ?? [:]
        let title: String
        let risk: RiskLevel

        switch action.type.lowercased() {
        case "stage", "stageall", "add":
            title = "Git: stage de arquivos"
            risk = .low
        case "commit":
            title = "Git: commit \(params["message"].map { "\"\($0.prefix(40))…\"" } ?? "")"
            risk = .low
        case "push":
            title = "Git: push"
            risk = .medium
        case "pull":
            title = "Git: pull"
            risk = .medium
        case "checkout":
            title = "Git: checkout \(params["branch"] ?? "?")"
            risk = .medium
        case "branch":
            title = "Git: criar branch \(params["name"] ?? "?")"
            risk = .low
        case "merge":
            title = "Git: merge \(params["branch"] ?? "?")"
            risk = .high
        case "reset":
            title = "Git: reset \(params["mode"] ?? "soft")"
            risk = .high
        case "stash":
            title = "Git: stash"
            risk = .low
        default:
            title = "Git: \(action.type)"
            risk = .medium
        }

        return ExecutionStep(
            sessionId: sessionId,
            tabId: tabId,
            timestamp: timestamp,
            kind: .gitAction,
            title: title,
            detail: action.reason ?? "",
            risk: risk,
            dryRun: true,
            status: .planned,
            userPrompt: userPrompt
        )
    }

    // MARK: - Shell command mapping

    private static func stepForCommand(
        _ command: AgentCommand,
        sessionId: UUID,
        tabId: String,
        userPrompt: String,
        timestamp: Date
    ) -> ExecutionStep {
        ExecutionStep(
            sessionId: sessionId,
            tabId: tabId,
            timestamp: timestamp,
            kind: .shellCommand,
            title: command.command,
            detail: command.reason,
            risk: command.riskLevel,
            dryRun: true,
            status: .planned,
            userPrompt: userPrompt
        )
    }

    // MARK: - Helpers

    private static func parseFileList(_ str: String) -> [String] {
        if str.hasPrefix("[") {
            return str
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { !$0.isEmpty }
        }
        if str.isEmpty { return [] }
        return [str]
    }
}
