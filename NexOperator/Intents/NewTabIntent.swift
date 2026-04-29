import AppIntents
import AppKit

enum TabType: String, AppEnum {
    case terminal
    case explorer
    case git

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tab Type")
    static var caseDisplayRepresentations: [TabType: DisplayRepresentation] = [
        .terminal: "Terminal",
        .explorer: "File Explorer",
        .git: "Git"
    ]
}

struct NewTabIntent: AppIntent {
    static var title: LocalizedStringResource = "New Tab"
    static var description = IntentDescription("Creates a new tab in NexifyTerm")

    @Parameter(title: "Tab Type", default: .terminal)
    var tabType: TabType

    @Parameter(title: "Directory Path", description: "Directory for the new tab")
    var directoryPath: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create new \(\.$tabType) tab") {
            \.$directoryPath
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NSApp.activate(ignoringOtherApps: true)

        let path = directoryPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let urlString = "nexifyterm://newTab?type=\(tabType.rawValue)&path=\(encoded)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        return .result(dialog: "Created new \(tabType.rawValue) tab")
    }
}
