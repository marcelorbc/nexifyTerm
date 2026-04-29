import AppIntents
import AppKit

struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask AI Agent"
    static var description = IntentDescription("Sends a prompt to the NexifyTerm AI agent")

    @Parameter(title: "Prompt", description: "What you want the AI agent to do")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask agent: \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $prompt.needsValueError("Prompt cannot be empty")
        }

        NSApp.activate(ignoringOtherApps: true)

        let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prompt
        let urlString = "nexifyterm://agent?prompt=\(encoded)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        let preview = String(prompt.prefix(60))
        return .result(dialog: "Sent to agent: \(preview)")
    }
}
