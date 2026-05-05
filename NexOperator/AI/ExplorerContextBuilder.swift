import Foundation

struct ExplorerContext {
    let currentDirectory: String
    let directoryName: String
    let files: [(name: String, type: String, size: String, ext: String)]
    let selectedFiles: [String]
    let totalCount: Int
    let folderCount: Int
    let fileCount: Int
    let dominantExtensions: [(ext: String, count: Int)]
    let isGitRepo: Bool

    var hasSelection: Bool { !selectedFiles.isEmpty }
}

struct ExplorerContextBuilder {

    /// Wave 5 · B1: convenience entry-point used by `AppState.buildContextExtra`
    /// when the explorer's live `[FileItem]` array isn't reachable from the call
    /// site. Lists the directory directly so the LLM still gets a real snapshot
    /// (file names, types, dominant extensions, git flag) instead of an empty
    /// string.
    @MainActor
    static func build(directory: String, showHidden: Bool = false) -> ExplorerContext {
        let url = URL(fileURLWithPath: directory)
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                .isHiddenKey, .tagNamesKey, .isSymbolicLinkKey, .isApplicationKey
            ],
            options: opts
        )) ?? []
        let items = urls.map { FileItem(url: $0) }
        return build(directory: directory, items: items)
    }

    @MainActor
    static func build(
        directory: String,
        items: [FileItem],
        selectedIds: Set<String> = []
    ) -> ExplorerContext {
        let url = URL(fileURLWithPath: directory)

        let fileEntries = items.prefix(100).map { item -> (String, String, String, String) in
            let typeStr: String
            switch item.fileType {
            case .folder: typeStr = "pasta"
            case .app: typeStr = "app"
            case .symlink: typeStr = "link"
            case .file: typeStr = item.fileExtension.isEmpty ? "arquivo" : item.fileExtension
            }
            return (item.name, typeStr, item.formattedSize, item.fileExtension)
        }

        let selected = items
            .filter { selectedIds.contains($0.id) }
            .map(\.name)

        let folderCount = items.filter { $0.fileType == .folder }.count
        let fileCount = items.count - folderCount

        var extCounts: [String: Int] = [:]
        for item in items where item.fileType == .file && !item.fileExtension.isEmpty {
            extCounts[item.fileExtension, default: 0] += 1
        }
        let dominant = extCounts.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }

        let isGit = FileManager.default.fileExists(
            atPath: url.appendingPathComponent(".git").path
        )

        return ExplorerContext(
            currentDirectory: directory,
            directoryName: url.lastPathComponent,
            files: fileEntries,
            selectedFiles: selected,
            totalCount: items.count,
            folderCount: folderCount,
            fileCount: fileCount,
            dominantExtensions: dominant,
            isGitRepo: isGit
        )
    }

    static func formatForPrompt(_ ctx: ExplorerContext) -> String {
        var prompt = """
        === CONTEXTO EXPLORER ===
        Diretório: \(ctx.currentDirectory)
        Total: \(ctx.totalCount) itens (\(ctx.folderCount) pastas, \(ctx.fileCount) arquivos)
        """

        if ctx.isGitRepo {
            prompt += "\nÉ um repositório Git"
        }

        if !ctx.dominantExtensions.isEmpty {
            let exts = ctx.dominantExtensions.map { ".\($0.ext)(\($0.count))" }.joined(separator: ", ")
            prompt += "\nExtensões predominantes: \(exts)"
        }

        if !ctx.selectedFiles.isEmpty {
            prompt += "\n\nArquivos selecionados (\(ctx.selectedFiles.count)):"
            for f in ctx.selectedFiles.prefix(20) {
                prompt += "\n  → \(f)"
            }
            if ctx.selectedFiles.count > 20 {
                prompt += "\n  ... +\(ctx.selectedFiles.count - 20) mais"
            }
        }

        prompt += "\n\nConteúdo do diretório:"
        if ctx.files.isEmpty {
            prompt += "\n  (pasta vazia)"
        } else {
            for f in ctx.files {
                let sizeStr = f.size == "--" ? "" : " (\(f.size))"
                prompt += "\n  [\(f.type)] \(f.name)\(sizeStr)"
            }
            if ctx.totalCount > 100 {
                prompt += "\n  ... +\(ctx.totalCount - 100) itens não listados"
            }
        }

        prompt += "\n=== FIM CONTEXTO EXPLORER ==="
        return prompt
    }
}
