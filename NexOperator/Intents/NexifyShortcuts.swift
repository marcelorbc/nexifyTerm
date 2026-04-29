import AppIntents

struct NexifyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTerminalIntent(),
            phrases: [
                "Open terminal in \(.applicationName)",
                "Open \(.applicationName)",
                "Launch \(.applicationName) terminal"
            ],
            shortTitle: "Open Terminal",
            systemImageName: "terminal.fill"
        )

        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run command in \(.applicationName)",
                "Execute in \(.applicationName)"
            ],
            shortTitle: "Run Command",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: NewTabIntent(),
            phrases: [
                "New tab in \(.applicationName)",
                "Create tab in \(.applicationName)"
            ],
            shortTitle: "New Tab",
            systemImageName: "plus.rectangle"
        )

        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Ask \(.applicationName) agent",
                "Ask AI in \(.applicationName)"
            ],
            shortTitle: "Ask AI Agent",
            systemImageName: "sparkles"
        )
    }
}
