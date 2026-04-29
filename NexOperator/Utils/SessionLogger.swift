import Foundation

class SessionLogger {
    static let shared = SessionLogger()

    private let logDirectory: URL
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var currentSessionFile: URL?
    private let queue = DispatchQueue(label: "com.nexia.nexoperator.logger", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDirectory = appSupport.appendingPathComponent("NexOperator/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    var logsPath: String { logDirectory.path }

    func startSession(userMessage: String, provider: String, model: String) -> String {
        let sessionId = dateFormatter.string(from: Date())
        let fileName = "session_\(sessionId).md"
        currentSessionFile = logDirectory.appendingPathComponent(fileName)

        let header = """
        # NexOperator Session Log
        **Date:** \(sessionId)
        **Provider:** \(provider)
        **Model:** \(model)
        **User Request:** \(userMessage)

        ---

        """
        write(header)
        return fileName
    }

    func logPlan(_ plan: AgentPlan) {
        let entry = """

        ## Plan: \(plan.title)
        **Explanation:** \(plan.explanation)
        **Max Risk:** \(plan.maxRiskLevel.displayName)
        **Commands:** \(plan.commands.count)

        | # | Command | Risk | Reason |
        |---|---------|------|--------|
        \(plan.commands.enumerated().map { i, cmd in
            "| \(i + 1) | `\(cmd.command)` | \(cmd.expectedRisk) | \(cmd.reason) |"
        }.joined(separator: "\n"))

        **Final Note:** \(plan.finalNote)

        ---

        """
        write(entry)
    }

    func logStepStart(index: Int, command: String, risk: RiskLevel) {
        let ts = timestampFormatter.string(from: Date())
        let entry = """

        ### Step \(index + 1) — `\(command)`
        **Time:** \(ts)
        **Risk:** \(risk.displayName)

        """
        write(entry)
    }

    func logStepResult(index: Int, command: String, output: CommandOutput, risk: RiskLevel) {
        let ts = timestampFormatter.string(from: Date())
        let status = output.succeeded ? "SUCCESS" : "FAILED (exit \(output.exitCode))"
        let entry = """
        **Result:** \(status)
        **Time:** \(ts)

        <details>
        <summary>stdout (\(output.stdout.count) chars)</summary>

        ```
        \(output.stdout.prefix(5000))
        ```
        </details>

        \(output.stderr.isEmpty ? "" : """
        <details>
        <summary>stderr</summary>

        ```
        \(output.stderr.prefix(2000))
        ```
        </details>
        """)

        ---

        """
        write(entry)
    }

    func logBlocked(command: String, reason: String?) {
        let ts = timestampFormatter.string(from: Date())
        let entry = """

        ### BLOCKED — `\(command)`
        **Time:** \(ts)
        **Reason:** \(reason ?? "Safety policy")

        ---

        """
        write(entry)
    }

    func logFollowUp(_ plan: AgentPlan) {
        let entry = """

        ## Follow-up Plan: \(plan.title)
        **Explanation:** \(plan.explanation)
        **Commands:** \(plan.commands.count)
        \(plan.commands.isEmpty ? "**Status:** Objective met — no more commands needed.\n" : plan.commands.enumerated().map { i, cmd in
            "- [\(i + 1)] `\(cmd.command)` (\(cmd.expectedRisk)) — \(cmd.reason)"
        }.joined(separator: "\n"))

        **Final Note:** \(plan.finalNote)

        ---

        """
        write(entry)
    }

    func logCompletion(summary: String) {
        let ts = timestampFormatter.string(from: Date())
        let entry = """

        ## Session Complete
        **Time:** \(ts)

        ### Summary
        \(summary)

        ---
        *End of session log*

        """
        write(entry)
    }

    func logError(_ error: String) {
        let ts = timestampFormatter.string(from: Date())
        let entry = """

        ## ERROR
        **Time:** \(ts)
        **Error:** \(error)

        ---

        """
        write(entry)
    }

    func logTerminalCommand(_ command: String) {
        let ts = timestampFormatter.string(from: Date())
        let entry = """

        > **[\(ts)] Terminal:** `\(command)`

        """
        write(entry)
    }

    private func write(_ text: String) {
        guard let file = currentSessionFile else { return }
        queue.async {
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: file.path) {
                    if let handle = try? FileHandle(forWritingTo: file) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: file)
                }
            }
        }
    }
}
