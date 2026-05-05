import Foundation
import AppKit

struct FileActionResult {
    let action: FileAction
    let success: Bool
    let message: String
    /// Step gravado no ExecutionLogStore; preenchido quando passamos `recorder`.
    var stepId: UUID?
}

/// Contexto opcional de gravação na Execution Timeline.
/// Quando passado, cada `FileAction` vira um `ExecutionStep` com rollback
/// quando aplicável.
struct FileActionRecorder {
    let sessionId: UUID
    let tabId: String?
    let userPrompt: String?
}

struct FileActionExecutor {

    static func execute(
        actions: [FileAction],
        directory: String,
        recorder: FileActionRecorder? = nil
    ) async -> [FileActionResult] {
        var results: [FileActionResult] = []
        let baseURL = URL(fileURLWithPath: directory)

        for action in actions {
            let result = executeSingle(action, baseURL: baseURL, recorder: recorder)
            results.append(result)

            if !result.success {
                NexLog.ai.warning("File action '\(action.type)' failed: \(result.message)")
            }
        }

        return results
    }

    private static func executeSingle(
        _ action: FileAction,
        baseURL: URL,
        recorder: FileActionRecorder?
    ) -> FileActionResult {
        let params = action.params ?? [:]
        let fm = FileManager.default

        switch action.type.lowercased() {
        case "createfolder":
            guard let name = params["name"], !name.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Nome da pasta não especificado")
            }
            let dest = baseURL.appendingPathComponent(name)
            return runRecorded(
                action: action,
                recorder: recorder,
                kind: .fileCreateFolder,
                title: "Criar pasta: \(name)",
                paths: [dest.path],
                risk: .low
            ) { _ in
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                return ("Pasta criada: \(name)", RollbackStore.shared.rollbackForCreated(path: dest.path))
            }

        case "rename":
            guard let oldName = params["oldName"], let newName = params["newName"] else {
                return FileActionResult(action: action, success: false, message: "Nomes não especificados")
            }
            let source = baseURL.appendingPathComponent(oldName)
            let dest = baseURL.appendingPathComponent(newName)
            return runRecorded(
                action: action,
                recorder: recorder,
                kind: .fileRename,
                title: "Renomear: \(oldName) → \(newName)",
                paths: [source.path, dest.path],
                risk: .medium
            ) { _ in
                try fm.moveItem(at: source, to: dest)
                let rb = RollbackStore.shared.rollbackForMove(from: dest.path, originalPath: source.path)
                return ("Renomeado: \(oldName) → \(newName)", rb)
            }

        case "delete":
            let files = parseFileList(params["files"] ?? "")
            guard !files.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Nenhum arquivo para deletar")
            }
            // Gera um step por arquivo deletado (cada um com seu rollback de "restoreFromTrash").
            var aggregateMessage = ""
            var deleted = 0
            var lastStepId: UUID?
            for file in files {
                let url = baseURL.appendingPathComponent(file)
                let result = runRecorded(
                    action: action,
                    recorder: recorder,
                    kind: .fileDelete,
                    title: "Mover para Lixeira: \(file)",
                    paths: [url.path],
                    risk: .high
                ) { _ in
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    return ("Movido para Lixeira: \(file)",
                            RollbackStore.shared.rollbackForTrashDelete(originalPath: url.path))
                }
                if result.success { deleted += 1 }
                lastStepId = result.stepId
            }
            aggregateMessage = "\(deleted)/\(files.count) arquivo(s) movido(s) para a Lixeira"
            return FileActionResult(action: action, success: deleted > 0, message: aggregateMessage, stepId: lastStepId)

        case "move":
            let files = parseFileList(params["files"] ?? "")
            guard let destPath = params["destination"], !files.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Arquivos ou destino não especificados")
            }
            let destURL = destPath.hasPrefix("/")
                ? URL(fileURLWithPath: destPath)
                : baseURL.appendingPathComponent(destPath)

            if !fm.fileExists(atPath: destURL.path) {
                try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            }

            var moved = 0
            var lastStepId: UUID?
            for file in files {
                let source = baseURL.appendingPathComponent(file)
                let dest = destURL.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
                let result = runRecorded(
                    action: action,
                    recorder: recorder,
                    kind: .fileMove,
                    title: "Mover: \(file) → \(destURL.lastPathComponent)/",
                    paths: [source.path, dest.path],
                    risk: .medium
                ) { _ in
                    try fm.moveItem(at: source, to: dest)
                    let rb = RollbackStore.shared.rollbackForMove(from: dest.path, originalPath: source.path)
                    return ("Movido: \(file)", rb)
                }
                if result.success { moved += 1 }
                lastStepId = result.stepId
            }
            return FileActionResult(action: action, success: moved > 0, message: "\(moved)/\(files.count) arquivo(s) movido(s)", stepId: lastStepId)

        case "duplicate":
            guard let file = params["file"] else {
                return FileActionResult(action: action, success: false, message: "Arquivo não especificado")
            }
            let source = baseURL.appendingPathComponent(file)
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = source.deletingLastPathComponent().appendingPathComponent(copyName)
            return runRecorded(
                action: action,
                recorder: recorder,
                kind: .fileDuplicate,
                title: "Duplicar: \(file)",
                paths: [source.path, dest.path],
                risk: .low
            ) { _ in
                try fm.copyItem(at: source, to: dest)
                return ("Duplicado: \(file) → \(copyName)",
                        RollbackStore.shared.rollbackForCreated(path: dest.path))
            }

        case "openterminal":
            return FileActionResult(action: action, success: true, message: "OPEN_TERMINAL:\(baseURL.path)")

        case "openfile":
            guard let file = params["file"] else {
                return FileActionResult(action: action, success: false, message: "Arquivo não especificado")
            }
            let url = baseURL.appendingPathComponent(file)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
            return FileActionResult(action: action, success: true, message: "Abrindo: \(file)")

        case "openinfinder":
            let file = params["file"]
            let url = file.map { baseURL.appendingPathComponent($0) } ?? baseURL
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return FileActionResult(action: action, success: true, message: "Revelado no Finder")

        case "compress":
            let files = parseFileList(params["files"] ?? "")
            let archiveName = params["name"] ?? "archive.zip"
            guard !files.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Nenhum arquivo para comprimir")
            }
            let dest = baseURL.appendingPathComponent(archiveName)
            let fileArgs = files.map { "\"\($0)\"" }.joined(separator: " ")
            let cmd = "cd \"\(baseURL.path)\" && zip -r \"\(dest.path)\" \(fileArgs)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", cmd]
            process.currentDirectoryURL = baseURL

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return FileActionResult(action: action, success: true, message: "Comprimido em: \(archiveName)")
                } else {
                    return FileActionResult(action: action, success: false, message: "Erro ao comprimir")
                }
            } catch {
                return FileActionResult(action: action, success: false, message: "Erro: \(error.localizedDescription)")
            }

        default:
            return FileActionResult(action: action, success: false, message: "Ação desconhecida: \(action.type)")
        }
    }

    /// Executa `body` envolvendo num step da Execution Timeline (quando há `recorder`).
    /// Cria step .running antes, .completed/.failed depois, com rollback se houver.
    private static func runRecorded(
        action: FileAction,
        recorder: FileActionRecorder?,
        kind: ExecutionStepKind,
        title: String,
        paths: [String],
        risk: RiskLevel,
        body: (UUID) throws -> (message: String, rollback: RollbackOperation?)
    ) -> FileActionResult {
        let stepId = UUID()

        if let recorder {
            let step = ExecutionStep(
                id: stepId,
                sessionId: recorder.sessionId,
                tabId: recorder.tabId,
                kind: kind,
                title: title,
                detail: action.reason ?? "",
                risk: risk,
                dryRun: false,
                status: .running,
                affectedPaths: paths,
                userPrompt: recorder.userPrompt
            )
            ExecutionLogStore.shared.upsert(step)
        }

        do {
            let (message, rollback) = try body(stepId)

            if recorder != nil {
                var updated = ExecutionStep(
                    id: stepId,
                    sessionId: recorder!.sessionId,
                    tabId: recorder!.tabId,
                    kind: kind,
                    title: title,
                    detail: action.reason ?? "",
                    risk: risk,
                    dryRun: false,
                    status: .completed,
                    output: message,
                    affectedPaths: paths,
                    userPrompt: recorder!.userPrompt
                )
                updated.rollback = rollback
                ExecutionLogStore.shared.upsert(updated)
            }

            return FileActionResult(action: action, success: true, message: message, stepId: stepId)
        } catch {
            let errMsg = "Erro: \(error.localizedDescription)"
            if recorder != nil {
                let failed = ExecutionStep(
                    id: stepId,
                    sessionId: recorder!.sessionId,
                    tabId: recorder!.tabId,
                    kind: kind,
                    title: title,
                    detail: action.reason ?? "",
                    risk: risk,
                    dryRun: false,
                    status: .failed,
                    output: "",
                    errorMessage: errMsg,
                    affectedPaths: paths,
                    userPrompt: recorder!.userPrompt
                )
                ExecutionLogStore.shared.upsert(failed)
            }
            return FileActionResult(action: action, success: false, message: errMsg, stepId: stepId)
        }
    }

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
