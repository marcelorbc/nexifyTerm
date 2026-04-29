import Foundation

enum HistoryEntryType: String, Codable {
    case terminalCommand
    case agentPlan
}

struct HistoryStepOutput: Codable {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let risk: String

    init(command: String, stdout: String, stderr: String, exitCode: Int32, risk: String = "low") {
        self.command = command
        self.stdout = String(stdout.prefix(2000))
        self.stderr = String(stderr.prefix(1000))
        self.exitCode = exitCode
        self.risk = risk
    }

    var succeeded: Bool { exitCode == 0 }

    var truncatedOutput: String {
        var out = stdout
        if !stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + stderr }
        return out
    }
}

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let type: HistoryEntryType
    let userInput: String
    let commands: [String]
    let summary: String?
    let plan: AgentPlan?
    let stepOutputs: [HistoryStepOutput]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: HistoryEntryType,
        userInput: String,
        commands: [String] = [],
        summary: String? = nil,
        plan: AgentPlan? = nil,
        stepOutputs: [HistoryStepOutput]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.userInput = userInput
        self.commands = commands
        self.summary = summary
        self.plan = plan
        self.stepOutputs = stepOutputs
    }

    var timeFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: timestamp)
    }

    var dateFormatted: String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f.string(from: timestamp)
    }

    var isAgent: Bool { type == .agentPlan }
    var hasOutputs: Bool { !(stepOutputs ?? []).isEmpty }
}
