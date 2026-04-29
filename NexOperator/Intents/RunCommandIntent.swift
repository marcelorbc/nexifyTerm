import AppIntents
import AppKit

struct RunCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Terminal Command"
    static var description = IntentDescription("Executes a command in the active NexifyTerm terminal")

    @Parameter(title: "Command", description: "The shell command to execute")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in terminal")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $command.needsValueError("Command cannot be empty")
        }

        NSApp.activate(ignoringOtherApps: true)

        let encoded = command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? command
        let urlString = "nexifyterm://run?command=\(encoded)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        let preview = String(command.prefix(50))
        return .result(dialog: "Running: \(preview)")
    }
}
