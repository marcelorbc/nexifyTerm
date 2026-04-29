import Foundation

struct SkillCreation: Codable {
    let name: String
    let instruction: String
    let icon: String?
}

struct GitAction: Codable, Identifiable {
    let type: String
    let params: [String: String]?
    let reason: String?

    var id: String { "\(type)-\(params?.description ?? "")" }

    enum CodingKeys: String, CodingKey {
        case type, params, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)

        if let dict = try? container.decodeIfPresent([String: String].self, forKey: .params) {
            params = dict
        } else if let anyDict = try? container.decodeIfPresent([String: AnyCodableValue].self, forKey: .params) {
            params = anyDict.mapValues { $0.stringValue }
        } else {
            params = nil
        }
    }

    init(type: String, params: [String: String]? = nil, reason: String? = nil) {
        self.type = type
        self.params = params
        self.reason = reason
    }
}

struct FileAction: Codable, Identifiable {
    let type: String
    let params: [String: String]?
    let reason: String?

    var id: String { "\(type)-\(params?.description ?? "")" }

    enum CodingKeys: String, CodingKey {
        case type, params, reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        reason = try? container.decodeIfPresent(String.self, forKey: .reason)

        if let dict = try? container.decodeIfPresent([String: String].self, forKey: .params) {
            params = dict
        } else if let anyDict = try? container.decodeIfPresent([String: AnyCodableValue].self, forKey: .params) {
            params = anyDict.mapValues { $0.stringValue }
        } else {
            params = nil
        }
    }

    init(type: String, params: [String: String]? = nil, reason: String? = nil) {
        self.type = type
        self.params = params
        self.reason = reason
    }
}

enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .bool(let b): return "\(b)"
        case .double(let d): return "\(d)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        self = .string("")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .bool(let b): try container.encode(b)
        case .double(let d): try container.encode(d)
        }
    }
}

struct AgentPlan: Codable {
    let title: String
    let explanation: String
    let commands: [AgentCommand]
    let finalNote: String
    let richOutput: RichOutput?
    let mcpToolCalls: [MCPToolCall]?
    let skillCreation: SkillCreation?
    let gitActions: [GitAction]?
    let fileActions: [FileAction]?

    enum CodingKeys: String, CodingKey {
        case title, explanation, commands, finalNote, richOutput, mcpToolCalls, skillCreation
        case gitActions, fileActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? "Plano"
        explanation = try container.decode(String.self, forKey: .explanation)
        commands = (try? container.decode([AgentCommand].self, forKey: .commands)) ?? []
        finalNote = (try? container.decode(String.self, forKey: .finalNote)) ?? ""
        richOutput = try? container.decodeIfPresent(RichOutput.self, forKey: .richOutput)
        mcpToolCalls = try? container.decodeIfPresent([MCPToolCall].self, forKey: .mcpToolCalls)
        skillCreation = try? container.decodeIfPresent(SkillCreation.self, forKey: .skillCreation)
        gitActions = try? container.decodeIfPresent([GitAction].self, forKey: .gitActions)
        fileActions = try? container.decodeIfPresent([FileAction].self, forKey: .fileActions)
    }

    var maxRiskLevel: RiskLevel {
        commands.map(\.riskLevel).max() ?? .readOnly
    }

    var hasBlockedCommands: Bool {
        commands.contains { $0.riskLevel == .blocked }
    }

    var hasMCPToolCalls: Bool {
        guard let calls = mcpToolCalls else { return false }
        return !calls.isEmpty
    }

    var hasSkillCreation: Bool {
        skillCreation != nil
    }

    var hasGitActions: Bool {
        guard let actions = gitActions else { return false }
        return !actions.isEmpty
    }

    var hasFileActions: Bool {
        guard let actions = fileActions else { return false }
        return !actions.isEmpty
    }

    var hasNoWork: Bool {
        commands.isEmpty && !hasGitActions && !hasFileActions
    }

    static func textOnly(title: String, explanation: String, finalNote: String, richOutput: RichOutput? = nil) -> AgentPlan {
        return AgentPlan(
            title: title,
            explanation: explanation,
            commands: [],
            finalNote: finalNote,
            richOutput: richOutput
        )
    }

    init(title: String, explanation: String, commands: [AgentCommand] = [], finalNote: String = "", richOutput: RichOutput? = nil, mcpToolCalls: [MCPToolCall]? = nil, skillCreation: SkillCreation? = nil, gitActions: [GitAction]? = nil, fileActions: [FileAction]? = nil) {
        self.title = title
        self.explanation = explanation
        self.commands = commands
        self.finalNote = finalNote
        self.richOutput = richOutput
        self.mcpToolCalls = mcpToolCalls
        self.skillCreation = skillCreation
        self.gitActions = gitActions
        self.fileActions = fileActions
    }
}
