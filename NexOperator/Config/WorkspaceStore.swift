import Foundation
import Combine

/// Persisted list of repos the user tracks in the multi-repo Cockpit.
/// Mirrors `FavoritesStore`'s pattern (singleton, JSON in Application Support,
/// `@Published` array). Lives at
/// `~/Library/Application Support/NexOperator/workspace.json`.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var projects: [WorkspaceProject] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexOperator")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("workspace.json")
        load()
    }

    // MARK: - Disk I/O

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WorkspaceProject].self, from: data)
        else { return }
        projects = decoded.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.order < rhs.order
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - CRUD

    /// Adds a project. Idempotent on `path` — re-adding an existing path is a
    /// no-op so the user can drag-and-drop the same folder twice without
    /// duplicate rows.
    @discardableResult
    func add(
        path: String,
        name: String? = nil,
        group: String = "",
        tags: [String] = []
    ) -> WorkspaceProject? {
        let normalized = (path as NSString).standardizingPath
        if let existing = projects.first(where: { $0.path == normalized }) {
            return existing
        }
        guard FileManager.default.fileExists(atPath: normalized) else { return nil }

        let nextOrder = (projects.filter { $0.group == group }.map(\.order).max() ?? -1) + 1
        let project = WorkspaceProject(
            path: normalized,
            name: name,
            group: group,
            tags: tags,
            order: nextOrder
        )
        projects.append(project)
        save()
        return project
    }

    func remove(_ id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to newName: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[idx].name = trimmed
        save()
    }

    func setGroup(_ id: UUID, group: String) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].group = group
        save()
    }

    func setTags(_ id: UUID, tags: [String]) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].tags = tags
        save()
    }

    func togglePin(_ id: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].isPinned.toggle()
        save()
    }

    /// Reorders projects within a group. The caller passes the group key and
    /// the new ordered list of ids that belong to it.
    func reorder(group: String, orderedIds: [UUID]) {
        for (i, id) in orderedIds.enumerated() {
            if let idx = projects.firstIndex(where: { $0.id == id && $0.group == group }) {
                projects[idx].order = i
            }
        }
        save()
    }

    // MARK: - Queries

    func project(at path: String) -> WorkspaceProject? {
        let normalized = (path as NSString).standardizingPath
        return projects.first { $0.path == normalized }
    }

    var groups: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for p in projects where !seen.contains(p.group) {
            seen.insert(p.group)
            ordered.append(p.group)
        }
        return ordered
    }

    /// Returns projects in stable, user-friendly order: pinned first, then by
    /// `order`. Caller filters by group when needed.
    var orderedProjects: [WorkspaceProject] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.order < rhs.order
        }
    }
}
