import Foundation
import AppKit

struct FileActionResult {
    let action: FileAction
    let success: Bool
    let message: String
}

struct FileActionExecutor {

    static func execute(actions: [FileAction], directory: String) async -> [FileActionResult] {
        var results: [FileActionResult] = []
        let baseURL = URL(fileURLWithPath: directory)

        for action in actions {
            let result = executeSingle(action, baseURL: baseURL)
            results.append(result)

            if !result.success {
                NexLog.ai.warning("File action '\(action.type)' failed: \(result.message)")
            }
        }

        return results
    }

    private static func executeSingle(_ action: FileAction, baseURL: URL) -> FileActionResult {
        let params = action.params ?? [:]
        let fm = FileManager.default

        switch action.type.lowercased() {
        case "createfolder":
            guard let name = params["name"], !name.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Nome da pasta não especificado")
            }
            let dest = baseURL.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                return FileActionResult(action: action, success: true, message: "Pasta criada: \(name)")
            } catch {
                return FileActionResult(action: action, success: false, message: "Erro ao criar pasta: \(error.localizedDescription)")
            }

        case "rename":
            guard let oldName = params["oldName"], let newName = params["newName"] else {
                return FileActionResult(action: action, success: false, message: "Nomes não especificados")
            }
            let source = baseURL.appendingPathComponent(oldName)
            let dest = baseURL.appendingPathComponent(newName)
            do {
                try fm.moveItem(at: source, to: dest)
                return FileActionResult(action: action, success: true, message: "Renomeado: \(oldName) → \(newName)")
            } catch {
                return FileActionResult(action: action, success: false, message: "Erro ao renomear: \(error.localizedDescription)")
            }

        case "delete":
            let files = parseFileList(params["files"] ?? "")
            guard !files.isEmpty else {
                return FileActionResult(action: action, success: false, message: "Nenhum arquivo para deletar")
            }
            var deleted = 0
            for file in files {
                let url = baseURL.appendingPathComponent(file)
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    deleted += 1
                } catch {
                    NexLog.ai.warning("Failed to trash \(file): \(error.localizedDescription)")
                }
            }
            return FileActionResult(action: action, success: deleted > 0, message: "\(deleted) arquivo(s) movido(s) para a Lixeira")

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
            for file in files {
                let source = baseURL.appendingPathComponent(file)
                let dest = destURL.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
                do {
                    try fm.moveItem(at: source, to: dest)
                    moved += 1
                } catch {
                    NexLog.ai.warning("Failed to move \(file): \(error.localizedDescription)")
                }
            }
            return FileActionResult(action: action, success: moved > 0, message: "\(moved) arquivo(s) movido(s)")

        case "duplicate":
            guard let file = params["file"] else {
                return FileActionResult(action: action, success: false, message: "Arquivo não especificado")
            }
            let source = baseURL.appendingPathComponent(file)
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            let dest = source.deletingLastPathComponent().appendingPathComponent(copyName)
            do {
                try fm.copyItem(at: source, to: dest)
                return FileActionResult(action: action, success: true, message: "Duplicado: \(file) → \(copyName)")
            } catch {
                return FileActionResult(action: action, success: false, message: "Erro ao duplicar: \(error.localizedDescription)")
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
