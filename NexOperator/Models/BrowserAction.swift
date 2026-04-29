import Foundation

struct BrowserAction: Codable {
    let action: String   // "getPageInfo", "click", "fill", "extract", "screenshot", "runJS", "navigate", "scroll", "downloadImages"
    let selector: String?
    let value: String?
    let reason: String
}

struct BrowserPlan: Codable {
    let title: String
    let explanation: String
    let browserActions: [BrowserAction]
    let finalNote: String
    let richOutput: RichOutput?

    enum CodingKeys: String, CodingKey {
        case title, explanation, browserActions, finalNote, richOutput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? "Browser Action"
        explanation = try container.decode(String.self, forKey: .explanation)
        browserActions = (try? container.decode([BrowserAction].self, forKey: .browserActions)) ?? []
        finalNote = (try? container.decode(String.self, forKey: .finalNote)) ?? ""
        richOutput = try? container.decodeIfPresent(RichOutput.self, forKey: .richOutput)
    }
}

struct BrowserActionResult {
    let action: BrowserAction
    let output: String
    let success: Bool
}
