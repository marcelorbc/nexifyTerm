import Foundation
import Combine

/// Cross-session persistent store of `UserMemory`. Lives in
/// `~/Library/Application Support/NexOperator/memories.json`.
///
/// Conceptually equivalent to ChatGPT's "saved memories": facts, preferences and
/// recurring context the agent should know about the user — across all tabs.
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var memories: [UserMemory] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nexia.memorystore", qos: .utility)
    private let maxEntries = 200
    private let maxContentLength = 600

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.fileURL = baseDir.appendingPathComponent("memories.json")
        load()
    }

    // MARK: - Public API

    /// Most recently updated memories first.
    func all() -> [UserMemory] {
        memories.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Adds a new memory. Returns the stored entry.
    @discardableResult
    func add(
        content: String,
        category: MemoryCategory = .fact,
        source: MemorySource = .manual,
        pinned: Bool = false
    ) -> UserMemory? {
        let trimmed = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxContentLength))
        guard !trimmed.isEmpty else { return nil }

        if let idx = memories.firstIndex(where: { $0.trimmedContent.lowercased() == trimmed.lowercased() }) {
            memories[idx].hitCount += 1
            memories[idx].updatedAt = Date()
            persist()
            return memories[idx]
        }

        let memory = UserMemory(
            category: category,
            content: trimmed,
            source: source,
            pinned: pinned
        )
        memories.append(memory)
        enforceCap()
        persist()
        NexLog.ai.info("Memory added: [\(category.rawValue)] \(trimmed.prefix(80))")
        return memory
    }

    func update(_ memory: UserMemory) {
        guard let idx = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        var updated = memory
        updated.updatedAt = Date()
        updated.content = String(memory.content.prefix(maxContentLength))
        memories[idx] = updated
        persist()
    }

    func updateContent(id: UUID, content: String, category: MemoryCategory? = nil) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].content = String(
            content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxContentLength)
        )
        if let category {
            memories[idx].category = category
        }
        memories[idx].updatedAt = Date()
        persist()
    }

    func togglePinned(id: UUID) {
        guard let idx = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[idx].pinned.toggle()
        memories[idx].updatedAt = Date()
        persist()
    }

    func remove(id: UUID) {
        memories.removeAll { $0.id == id }
        persist()
    }

    func remove(matching content: String) -> Int {
        let lowered = content.lowercased()
        let before = memories.count
        memories.removeAll {
            $0.content.lowercased().contains(lowered) ||
            lowered.contains($0.content.lowercased())
        }
        let removed = before - memories.count
        if removed > 0 { persist() }
        return removed
    }

    func clearAll() {
        memories = []
        persist()
    }

    /// Bumps `hitCount` for the memories that were actually used in a prompt,
    /// so we can rank by usefulness when capping storage.
    func touch(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        for idx in memories.indices where set.contains(memories[idx].id) {
            memories[idx].hitCount += 1
        }
        persist()
    }

    /// Applies a batch of `MemoryUpdate` actions emitted by the LLM. Returns the
    /// number of effective changes (used for status messages).
    @discardableResult
    func applyUpdates(_ updates: [MemoryUpdate]) -> Int {
        var changes = 0
        for upd in updates {
            switch upd.action {
            case .add:
                guard let raw = upd.content,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                if add(content: raw, category: upd.resolvedCategory, source: .auto) != nil {
                    changes += 1
                }
            case .update:
                guard let idStr = upd.id, let uuid = UUID(uuidString: idStr) else { continue }
                if let content = upd.content, !content.isEmpty {
                    updateContent(id: uuid, content: content, category: MemoryCategory(rawValue: upd.category ?? ""))
                    changes += 1
                }
            case .remove:
                if let idStr = upd.id, let uuid = UUID(uuidString: idStr) {
                    if memories.contains(where: { $0.id == uuid }) {
                        remove(id: uuid)
                        changes += 1
                    }
                } else if let content = upd.content {
                    let removed = remove(matching: content)
                    changes += removed
                }
            }
        }
        return changes
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            memories = try JSONDecoder().decode([UserMemory].self, from: data)
        } catch {
            NexLog.config.error("Failed to load memories.json: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshot = memories
        queue.async { [fileURL] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NexLog.config.error("Failed to save memories.json: \(error.localizedDescription)")
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func enforceCap() {
        guard memories.count > maxEntries else { return }
        let sorted = memories.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            let lhsScore = lhs.hitCount * 2 + (lhs.source == .manual ? 5 : 0)
            let rhsScore = rhs.hitCount * 2 + (rhs.source == .manual ? 5 : 0)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.updatedAt > rhs.updatedAt
        }
        memories = Array(sorted.prefix(maxEntries))
    }
}
