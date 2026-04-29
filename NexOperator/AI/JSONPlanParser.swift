import Foundation

struct JSONBrowserPlanParser {
    static func parse(_ rawResponse: String) -> Result<BrowserPlan, LLMError> {
        var lastError: Error?

        switch tryParse(rawResponse) {
        case .success(let plan): return .success(plan)
        case .failure(let err): lastError = err
        }

        if let extracted = JSONPlanParser.extractJSONBlock(from: rawResponse) {
            switch tryParse(extracted) {
            case .success(let plan): return .success(plan)
            case .failure(let err): lastError = err
            }
        }

        if let extracted = JSONPlanParser.extractFirstJSONObject(from: rawResponse) {
            switch tryParse(extracted) {
            case .success(let plan): return .success(plan)
            case .failure(let err): lastError = err
            }
        }

        let detail = JSONPlanParser.describeDecodingError(lastError)
        NexLog.ai.error("Failed to parse browser plan. Detail: \(detail). Raw (500 chars): \(rawResponse.prefix(500))")
        return .failure(.parsingError("Could not extract a valid browser plan. \(detail)"))
    }

    private static func tryParse(_ json: String) -> Result<BrowserPlan, Error> {
        guard let data = json.data(using: .utf8) else {
            return .failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8")))
        }
        do {
            let plan = try JSONDecoder().decode(BrowserPlan.self, from: data)
            return .success(plan)
        } catch {
            return .failure(error)
        }
    }
}

struct JSONPlanParser {

    static func parse(_ rawResponse: String) -> Result<AgentPlan, LLMError> {
        var lastError: Error?

        switch tryParse(rawResponse) {
        case .success(let plan): return .success(plan)
        case .failure(let err): lastError = err
        }

        if let extracted = extractJSONBlock(from: rawResponse) {
            switch tryParse(extracted) {
            case .success(let plan): return .success(plan)
            case .failure(let err): lastError = err
            }
        }

        if let extracted = extractFirstJSONObject(from: rawResponse) {
            switch tryParse(extracted) {
            case .success(let plan): return .success(plan)
            case .failure(let err): lastError = err
            }
        }

        let detail = Self.describeDecodingError(lastError)
        NexLog.ai.error("Failed to parse LLM response. Detail: \(detail). Raw (500 chars): \(rawResponse.prefix(500))")
        return .failure(.parsingError("Could not extract a valid plan. \(detail)"))
    }

    private static func tryParse(_ json: String) -> Result<AgentPlan, Error> {
        guard let data = json.data(using: .utf8) else {
            return .failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid UTF-8")))
        }
        do {
            let plan = try JSONDecoder().decode(AgentPlan.self, from: data)
            return .success(plan)
        } catch {
            return .failure(error)
        }
    }

    static func describeDecodingError(_ error: Error?) -> String {
        guard let error else { return "No JSON found in the response." }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, _):
                return "Missing required field: '\(key.stringValue)'"
            case .typeMismatch(let type, let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                return "Wrong type for '\(path)': expected \(type)"
            case .valueNotFound(let type, let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                return "Null value for '\(path)': expected \(type)"
            case .dataCorrupted(let ctx):
                return "Malformed JSON: \(ctx.debugDescription)"
            @unknown default:
                return "Decoding error: \(decodingError.localizedDescription)"
            }
        }
        return "Parse error: \(error.localizedDescription)"
    }

    static func extractJSONBlock(from text: String) -> String? {
        let pattern = "```(?:json)?\\s*\\n?([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?

        for index in text[start...].indices {
            let char = text[index]

            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }

            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
        }

        guard let endIndex = end else { return nil }
        return String(text[start...endIndex])
    }
}
