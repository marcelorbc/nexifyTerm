import Foundation
import AppKit

enum ExternalEditor: String {
    case vscode = "code"
    case cursor = "cursor"

    var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        }
    }

    var cliCommand: String { rawValue }

    var appBundleIds: [String] {
        switch self {
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        }
    }
}

struct OpenWithApp: Identifiable {
    let id: String
    let name: String
    let icon: String
    let bundleId: String

    func open(url: URL) {
        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: appURL, configuration: config)
        }
    }
}

enum ExternalEditorLauncher {
    static func open(path: String, editor: ExternalEditor) {
        if openViaCLI(path: path, editor: editor) { return }
        openViaBundle(path: path, editor: editor)
    }

    static func suggestedApps(for fileExtension: String) -> [OpenWithApp] {
        var apps: [OpenWithApp] = []
        let ext = fileExtension.lowercased()
        let workspace = NSWorkspace.shared

        let suggestions: [(extensions: Set<String>, bundleId: String, name: String, icon: String)] = [
            // Text editors
            (["txt", "md", "rtf", "log", "csv", "json", "yaml", "yml", "xml", "toml", "plist",
              "swift", "py", "js", "ts", "rb", "go", "rs", "java", "c", "cpp", "h", "m", "cs",
              "html", "css", "scss", "sh", "bash", "zsh", "fish", "env", "gitignore", "dockerfile",
              "makefile", "sql", "graphql", "r", "php", "lua", "kt", "dart", "jsx", "tsx", "vue",
              "svelte"],
             "com.apple.TextEdit", "TextEdit", "doc.plaintext"),

            // PDF
            (["pdf"],
             "com.apple.Preview", "Preview", "doc.richtext"),

            // Images
            (["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "svg"],
             "com.apple.Preview", "Preview", "photo"),

            // Video
            (["mp4", "mov", "avi", "mkv", "m4v", "webm"],
             "com.apple.QuickTimePlayerX", "QuickTime", "film"),

            // Audio
            (["mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff"],
             "com.apple.Music", "Music", "waveform"),

            // Spreadsheets / office
            (["xls", "xlsx", "numbers"],
             "com.apple.iWork.Numbers", "Numbers", "tablecells"),
            (["doc", "docx", "pages"],
             "com.apple.iWork.Pages", "Pages", "doc.text"),
            (["ppt", "pptx", "key"],
             "com.apple.iWork.Keynote", "Keynote", "play.rectangle"),

            // Archives
            (["zip", "tar", "gz", "rar", "7z", "bz2", "xz"],
             "com.apple.archiveutility", "Archive Utility", "doc.zipper"),

            // Database
            (["db", "sqlite", "sqlite3"],
             "com.tinyapp.TablePlus", "TablePlus", "cylinder.split.1x2"),
        ]

        for suggestion in suggestions {
            if suggestion.extensions.contains(ext) {
                if workspace.urlForApplication(withBundleIdentifier: suggestion.bundleId) != nil {
                    apps.append(OpenWithApp(
                        id: suggestion.bundleId,
                        name: suggestion.name,
                        icon: suggestion.icon,
                        bundleId: suggestion.bundleId
                    ))
                }
            }
        }

        return apps
    }

    static func installedAppsForFile(url: URL) -> [OpenWithApp] {
        guard let appURLs = LSCopyApplicationURLsForURL(url as CFURL, .all)?.takeRetainedValue() as? [URL] else {
            return []
        }

        var seen = Set<String>()
        var apps: [OpenWithApp] = []

        let skipBundles: Set<String> = [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.todesktop.230313mzl4w4u92",
        ]

        for appURL in appURLs.prefix(8) {
            guard let bundle = Bundle(url: appURL),
                  let bundleId = bundle.bundleIdentifier,
                  !skipBundles.contains(bundleId),
                  !seen.contains(bundleId) else { continue }
            seen.insert(bundleId)

            let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent

            apps.append(OpenWithApp(
                id: bundleId,
                name: name,
                icon: "app",
                bundleId: bundleId
            ))
        }

        return apps
    }

    private static func openViaCLI(path: String, editor: ExternalEditor) -> Bool {
        let cli = editor.cliCommand
        let searchPaths = [
            "/usr/local/bin/\(cli)",
            "/opt/homebrew/bin/\(cli)",
            "/usr/bin/\(cli)",
            NSString(string: "~/.local/bin/\(cli)").expandingTildeInPath,
        ]

        guard let binary = searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func openViaBundle(path: String, editor: ExternalEditor) {
        let workspace = NSWorkspace.shared
        let fileURL = URL(fileURLWithPath: path)

        for bundleId in editor.appBundleIds {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                workspace.open([fileURL], withApplicationAt: appURL, configuration: config)
                return
            }
        }

        NexLog.general.warning("Editor \(editor.displayName) não encontrado no sistema.")
    }
}
