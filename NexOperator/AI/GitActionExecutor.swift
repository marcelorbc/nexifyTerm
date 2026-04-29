import Foundation

struct GitActionResult {
    let action: GitAction
    let success: Bool
    let message: String
}

@MainActor
struct GitActionExecutor {

    static func execute(actions: [GitAction], viewModel: GitViewModel) async -> [GitActionResult] {
        var results: [GitActionResult] = []

        for action in actions {
            let result = await executeSingle(action, viewModel: viewModel)
            results.append(result)

            if !result.success {
                NexLog.ai.warning("Git action '\(action.type)' failed: \(result.message)")
            }
        }

        return results
    }

    private static func executeSingle(_ action: GitAction, viewModel: GitViewModel) async -> GitActionResult {
        let params = action.params ?? [:]

        switch action.type.lowercased() {
        case "stage":
            if params["all"] == "true" {
                await viewModel.stageAll()
                return GitActionResult(action: action, success: true, message: "Todos os arquivos staged")
            } else if let filesStr = params["files"] {
                let files = parseFileList(filesStr)
                await viewModel.stagePaths(files)
                return GitActionResult(action: action, success: true, message: "Staged: \(files.joined(separator: ", "))")
            }
            return GitActionResult(action: action, success: false, message: "Parâmetros inválidos para stage")

        case "unstage":
            if params["all"] == "true" {
                await viewModel.unstageAll()
                return GitActionResult(action: action, success: true, message: "Todos os arquivos unstaged")
            } else if let filesStr = params["files"] {
                let files = parseFileList(filesStr)
                await viewModel.unstagePaths(files)
                return GitActionResult(action: action, success: true, message: "Unstaged: \(files.joined(separator: ", "))")
            }
            return GitActionResult(action: action, success: false, message: "Parâmetros inválidos para unstage")

        case "commit":
            guard let message = params["message"], !message.isEmpty else {
                return GitActionResult(action: action, success: false, message: "Mensagem de commit vazia")
            }
            viewModel.commitMessage = message
            await viewModel.commitChanges()
            let hasError = viewModel.toastIsError
            return GitActionResult(
                action: action,
                success: !hasError,
                message: hasError ? "Falha no commit" : "Commit: \(message.prefix(60))"
            )

        case "push":
            await viewModel.push()
            return GitActionResult(action: action, success: true, message: "Push realizado")

        case "pull":
            await viewModel.pull()
            return GitActionResult(action: action, success: true, message: "Pull realizado")

        case "checkout":
            guard let branch = params["branch"] else {
                return GitActionResult(action: action, success: false, message: "Branch não especificada")
            }
            await viewModel.checkoutBranch(branch)
            return GitActionResult(action: action, success: true, message: "Checkout: \(branch)")

        case "createbranch":
            guard let name = params["name"] else {
                return GitActionResult(action: action, success: false, message: "Nome da branch não especificado")
            }
            await viewModel.createBranch(name)
            return GitActionResult(action: action, success: true, message: "Branch criada: \(name)")

        case "deletebranch":
            guard let name = params["name"] else {
                return GitActionResult(action: action, success: false, message: "Nome da branch não especificado")
            }
            let force = params["force"] == "true"
            await viewModel.deleteBranch(name, force: force)
            return GitActionResult(action: action, success: true, message: "Branch deletada: \(name)")

        case "merge":
            guard let branch = params["branch"] else {
                return GitActionResult(action: action, success: false, message: "Branch não especificada")
            }
            await viewModel.mergeBranch(branch)
            return GitActionResult(action: action, success: true, message: "Merge de \(branch)")

        case "rebase":
            guard let branch = params["branch"] else {
                return GitActionResult(action: action, success: false, message: "Branch não especificada")
            }
            await viewModel.rebaseBranch(branch)
            return GitActionResult(action: action, success: true, message: "Rebase em \(branch)")

        case "stashsave":
            let message = params["message"]
            await viewModel.stashSave(message)
            return GitActionResult(action: action, success: true, message: "Stash salvo")

        case "stashpop":
            let index = Int(params["index"] ?? "0") ?? 0
            await viewModel.stashPop(index)
            return GitActionResult(action: action, success: true, message: "Stash aplicado")

        case "stashdrop":
            let index = Int(params["index"] ?? "0") ?? 0
            await viewModel.stashDrop(index)
            return GitActionResult(action: action, success: true, message: "Stash removido")

        case "revert":
            guard let hash = params["hash"] else {
                return GitActionResult(action: action, success: false, message: "Hash do commit não especificado")
            }
            await viewModel.revertCommit(hash)
            return GitActionResult(action: action, success: true, message: "Revert de \(hash.prefix(7))")

        case "cherrypick":
            guard let hash = params["hash"] else {
                return GitActionResult(action: action, success: false, message: "Hash do commit não especificado")
            }
            await viewModel.cherryPick(hash)
            return GitActionResult(action: action, success: true, message: "Cherry-pick de \(hash.prefix(7))")

        case "tag":
            guard let name = params["name"] else {
                return GitActionResult(action: action, success: false, message: "Nome da tag não especificado")
            }
            await viewModel.createTag(name, message: params["message"])
            return GitActionResult(action: action, success: true, message: "Tag criada: \(name)")

        case "resetsoft":
            guard let hash = params["hash"] else {
                return GitActionResult(action: action, success: false, message: "Hash não especificado")
            }
            await viewModel.resetSoft(to: hash)
            return GitActionResult(action: action, success: true, message: "Soft reset para \(hash.prefix(7))")

        case "resetmixed":
            guard let hash = params["hash"] else {
                return GitActionResult(action: action, success: false, message: "Hash não especificado")
            }
            await viewModel.resetMixed(to: hash)
            return GitActionResult(action: action, success: true, message: "Reset para \(hash.prefix(7))")

        default:
            return GitActionResult(action: action, success: false, message: "Ação Git desconhecida: \(action.type)")
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
        return [str]
    }
}
