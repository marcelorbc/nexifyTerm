import Foundation

/// Persistent fact / preference about the user, used to personalize ALL future
/// LLM interactions across tabs and sessions (similar to ChatGPT's "saved memories").
struct UserMemory: Codable, Identifiable, Hashable {
    let id: UUID
    var category: MemoryCategory
    var content: String
    var source: MemorySource
    var createdAt: Date
    var updatedAt: Date
    var hitCount: Int
    var pinned: Bool

    init(
        id: UUID = UUID(),
        category: MemoryCategory = .fact,
        content: String,
        source: MemorySource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        hitCount: Int = 0,
        pinned: Bool = false
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hitCount = hitCount
        self.pinned = pinned
    }

    var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MemoryCategory: String, Codable, CaseIterable, Identifiable {
    case identity      // who the user is (name, role, company)
    case preference    // how they like answers (style, tone, format)
    case project       // ongoing projects / context
    case skill         // tech stack, expertise
    case fact          // generic observed fact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .identity:   return "Identidade"
        case .preference: return "Preferência"
        case .project:    return "Projeto"
        case .skill:      return "Stack/Skill"
        case .fact:       return "Fato"
        }
    }

    var icon: String {
        switch self {
        case .identity:   return "person.crop.circle"
        case .preference: return "slider.horizontal.3"
        case .project:    return "folder.badge.gearshape"
        case .skill:      return "hammer"
        case .fact:       return "lightbulb"
        }
    }
}

enum MemorySource: String, Codable {
    case manual    // user added it explicitly via UI
    case explicit  // captured from "lembre que..." style request
    case auto      // LLM auto-detected something worth remembering
}

/// Personality / response style used as part of the system prompt.
/// Inspired by ChatGPT's personality customization.
enum PersonalityStyle: String, Codable, CaseIterable, Identifiable {
    case professional
    case direct
    case friendly
    case technical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .professional: return "Profissional"
        case .direct:       return "Direto / Candid"
        case .friendly:     return "Amigável"
        case .technical:    return "Técnico"
        }
    }

    var description: String {
        switch self {
        case .professional: return "Respostas mais formais, estruturadas e neutras."
        case .direct:       return "Objetividade, riscos e próximos passos. Sem enrolação."
        case .friendly:     return "Tom acolhedor, próximo, com explicações didáticas."
        case .technical:    return "Profundidade técnica, trade-offs e detalhes de engenharia."
        }
    }

    var promptInstruction: String {
        switch self {
        case .professional:
            return "Adote um tom profissional, formal e estruturado nas respostas."
        case .direct:
            return "Seja direto e objetivo. Vá ao ponto, destaque riscos e próximos passos. Sem enrolação."
        case .friendly:
            return "Use tom amigável e acolhedor. Explique de forma didática quando útil, mas sem ser condescendente."
        case .technical:
            return "Adote profundidade técnica. Explique trade-offs, mencione alternativas e detalhes de engenharia relevantes."
        }
    }
}

/// Action emitted by the LLM (inside the JSON plan) to update the user's memory store.
/// Allows the model to "learn" about the user across conversations.
struct MemoryUpdate: Codable {
    enum Action: String, Codable {
        case add
        case update
        case remove
    }

    let action: Action
    let id: String?
    let category: String?
    let content: String?

    var resolvedCategory: MemoryCategory {
        guard let raw = category, let cat = MemoryCategory(rawValue: raw) else { return .fact }
        return cat
    }
}
