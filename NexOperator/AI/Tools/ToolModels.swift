import Foundation

// MARK: - Tool Definition

struct NexToolParam {
    let name: String
    let type: String
    let description: String
    let required: Bool
    let enumValues: [String]?

    init(_ name: String, type: String = "string", description: String, required: Bool = true, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

struct NexToolDefinition {
    let name: String
    let description: String
    let parameters: [NexToolParam]
    let category: ToolCategory

    enum ToolCategory: String {
        case system = "Sistema"
        case files = "Arquivos"
        case terminal = "Terminal"
        case packages = "Pacotes"
        case macos = "macOS"
        case automation = "Automação"
        case development = "Desenvolvimento"
    }

    func toOpenAISchema() -> [String: Any] {
        var properties: [String: Any] = [:]
        var requiredFields: [String] = []

        for param in parameters {
            var prop: [String: Any] = [
                "type": param.type,
                "description": param.description
            ]
            if let enums = param.enumValues {
                prop["enum"] = enums
            }
            properties[param.name] = prop
            if param.required {
                requiredFields.append(param.name)
            }
        }

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": requiredFields
                ] as [String: Any]
            ] as [String: Any]
        ]
    }
}

// MARK: - Tool Call / Result

struct NexToolCall: Codable {
    let id: String
    let name: String
    let arguments: [String: String]

    init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let function = dict["function"] as? [String: Any],
              let name = function["name"] as? String,
              let argsString = function["arguments"] as? String else {
            return nil
        }

        self.id = id
        self.name = name

        if let data = argsString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var stringArgs: [String: String] = [:]
            for (key, value) in parsed {
                stringArgs[key] = "\(value)"
            }
            self.arguments = stringArgs
        } else {
            self.arguments = [:]
        }
    }
}

struct NexToolResult {
    let callId: String
    let toolName: String
    let content: String
    let isError: Bool

    func toOpenAIMessage() -> [String: Any] {
        return [
            "role": "tool",
            "tool_call_id": callId,
            "content": content
        ]
    }
}

// MARK: - Tool Response from LLM

enum LLMToolResponse {
    case toolCalls([NexToolCall])
    case finalContent(String)
}
