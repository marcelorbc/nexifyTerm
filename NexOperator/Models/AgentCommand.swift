import Foundation

struct AgentCommand: Codable, Identifiable {
    let command: String
    let reason: String
    let expectedRisk: String

    var id: String { command }

    var riskLevel: RiskLevel {
        RiskLevel(rawValue: expectedRisk) ?? .high
    }

    enum CodingKeys: String, CodingKey {
        case command, reason, expectedRisk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        reason = (try? container.decode(String.self, forKey: .reason)) ?? ""

        if let risk = try? container.decode(String.self, forKey: .expectedRisk) {
            expectedRisk = Self.normalizeRisk(risk)
        } else {
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
            let fallbackKeys = ["risk", "expected_risk", "riskLevel", "risk_level"]
            var found: String?
            for key in fallbackKeys {
                if let k = DynamicCodingKey(stringValue: key),
                   let val = try? dynamic.decode(String.self, forKey: k) {
                    found = val
                    break
                }
            }
            expectedRisk = Self.normalizeRisk(found ?? "medium")
        }
    }

    private static func normalizeRisk(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let mapping: [String: String] = [
            "readonly": "readOnly", "read_only": "readOnly", "read-only": "readOnly", "safe": "readOnly",
            "low": "low", "baixo": "low",
            "medium": "medium", "medio": "medium", "médio": "medium", "moderate": "medium",
            "high": "high", "alto": "high",
            "blocked": "blocked", "bloqueado": "blocked", "dangerous": "blocked"
        ]
        return mapping[lower] ?? raw
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}
