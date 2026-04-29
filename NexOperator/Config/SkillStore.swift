import Foundation

class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [Skill] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexOperator")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("skills.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Skill].self, from: data) else {
            return
        }
        skills = decoded.sorted { $0.name < $1.name }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skills) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ skill: Skill) {
        if let idx = skills.firstIndex(where: { $0.name == skill.name }) {
            skills[idx] = skill
        } else {
            skills.append(skill)
        }
        skills.sort { $0.name < $1.name }
        save()
        NexLog.ai.info("Skill saved: \(skill.name)")
    }

    func update(_ skill: Skill) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        var updated = skill
        updated.updatedAt = Date()
        updated.parameters = Skill.extractParameters(from: skill.instruction)
        skills[idx] = updated
        save()
    }

    func delete(_ id: UUID) {
        skills.removeAll { $0.id == id }
        save()
    }

    func duplicate(_ skill: Skill) {
        var copy = Skill(name: skill.name + "-copy", instruction: skill.instruction, icon: skill.icon)
        copy.parameters = skill.parameters
        add(copy)
    }

    func find(name: String) -> Skill? {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return skills.first { $0.name == normalized }
    }

    func search(query: String) -> [Skill] {
        let q = query.lowercased()
        if q.isEmpty { return skills }
        return skills.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}
