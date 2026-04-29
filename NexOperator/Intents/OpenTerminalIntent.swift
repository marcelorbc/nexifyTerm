import AppIntents
import AppKit

struct OpenTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Terminal"
    static var description = IntentDescription("Opens NexifyTerm in a specific directory")

    @Parameter(title: "Directory Path", description: "The directory to open. Defaults to home.")
    var directoryPath: String?

    @Parameter(title: "New Tab", description: "Open in a new tab", default: true)
    var newTab: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Open terminal at \(\.$directoryPath)") {
            \.$newTab
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let path = directoryPath ?? FileManager.default.homeDirectoryForCurrentUser.path

        guard FileManager.default.fileExists(atPath: path) else {
            throw $directoryPath.needsValueError("Directory not found: \(path)")
        }

        NSApp.activate(ignoringOtherApps: true)

        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let urlString = "nexifyterm://open?path=\(encoded)&newTab=\(newTab)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        let dirName = URL(fileURLWithPath: path).lastPathComponent
        return .result(dialog: "Opened terminal at \(dirName)")
    }
}
