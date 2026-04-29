import Foundation

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var enabled: Bool

    init(name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }
}

struct MCPTool: Codable, Identifiable {
    var id: String { "\(serverName).\(name)" }
    let serverName: String
    let name: String
    let description: String
    let inputSchema: MCPToolSchema?
}

struct MCPToolSchema: Codable {
    let type: String?
    let properties: [String: MCPPropertySchema]?
    let required: [String]?
}

final class MCPPropertySchema: Codable {
    let type: String?
    let description: String?
    let items: MCPPropertySchema?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, items
        case enumValues = "enum"
    }
}

struct MCPToolCall: Codable {
    let server: String
    let tool: String
    let arguments: [String: AnyCodable]
}

struct MCPToolResult {
    let server: String
    let tool: String
    let content: String
    let isError: Bool
}

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let arr as [Any]: try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        case is NSNull: try container.encodeNil()
        default: try container.encode(String(describing: value))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func toJSON() -> Any { value }
}
