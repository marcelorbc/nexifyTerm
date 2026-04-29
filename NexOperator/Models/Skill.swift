import Foundation

struct Skill: Codable, Identifiable {
    let id: UUID
    var name: String
    var instruction: String
    var parameters: [String]
    var icon: String
    var createdAt: Date
    var updatedAt: Date

    init(name: String, instruction: String, icon: String = "bolt.fill") {
        self.id = UUID()
        self.name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.instruction = instruction
        self.parameters = Skill.extractParameters(from: instruction)
        self.icon = icon
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    static func extractParameters(from instruction: String) -> [String] {
        let pattern = "\\{\\{\\s*(\\w+)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(instruction.startIndex..., in: instruction)
        let matches = regex.matches(in: instruction, range: range)
        var params: [String] = []
        for match in matches {
            if let paramRange = Range(match.range(at: 1), in: instruction) {
                let param = String(instruction[paramRange])
                if !params.contains(param) {
                    params.append(param)
                }
            }
        }
        return params
    }
}
