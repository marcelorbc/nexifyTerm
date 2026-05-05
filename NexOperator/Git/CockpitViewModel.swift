import SwiftUI
import Combine

/// Drives the multi-repo Cockpit. Reads project list from `WorkspaceStore`,
/// fans out snapshots through `WorkspaceSnapshotService`, and exposes
/// derived collections for the table (filters, search, bulk selection).
@MainActor
final class CockpitViewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos"
        case attention = "Precisam de mim"
        case dirty = "Com mudanças"
        case behind = "Atrás do remoto"
        case ahead = "Não pushadas"
        case noUpstream = "Sem upstream"
        case errors = "Com erro"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .all:        return "list.bullet"
            case .attention:  return "exclamationmark.bubble"
            case .dirty:      return "pencil.tip"
            case .behind:     return "arrow.down"
            case .ahead:      return "arrow.up"
            case .noUpstream: return "questionmark.circle"
            case .errors:     return "xmark.octagon"
            }
        }
    }

    @Published var snapshots: [String: RepoSnapshot] = [:]
    @Published var inFlightPaths: Set<String> = []
    @Published var bulkResults: [WorkspaceSnapshotService.BulkResult] = []
    @Published var isBulkRunning = false
    @Published var lastBulkAction: WorkspaceSnapshotService.BulkAction?

    @Published var searchQuery: String = ""
    @Published var filter: Filter = .all
    @Published var selectedTag: String? = nil
    @Published var selection: Set<UUID> = []

    @Published var isShowingAddSheet = false
    @Published var addPathInput: String = ""
    @Published var addNameInput: String = ""
    @Published var addGroupInput: String = ""

    let store: WorkspaceStore
    private let service = WorkspaceSnapshotService.shared
    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(store: WorkspaceStore = .shared) {
        self.store = store
        store.$projects
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func onAppear() {
        Task { await refreshAll() }
        startAutoRefresh()
    }

    func onDisappear() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
    }

    // MARK: - Snapshot orchestration

    func refreshAll() async {
        let paths = store.projects.map(\.path)
        guard !paths.isEmpty else {
            snapshots = [:]
            return
        }
        for p in paths { inFlightPaths.insert(p) }

        let results = await service.snapshotAll(paths: paths)

        var dict: [String: RepoSnapshot] = [:]
        for snap in results { dict[snap.path] = snap }
        snapshots = dict
        inFlightPaths.removeAll()
    }

    func refresh(project: WorkspaceProject) async {
        inFlightPaths.insert(project.path)
        defer { inFlightPaths.remove(project.path) }
        let snap = await service.snapshot(at: project.path)
        snapshots[project.path] = snap
    }

    // MARK: - Bulk actions

    /// Runs `action` on every selected project (or all, when selection is
    /// empty). Stores per-repo results and refreshes snapshots after.
    func runBulk(_ action: WorkspaceSnapshotService.BulkAction) async {
        let targets = bulkTargetProjects()
        guard !targets.isEmpty else { return }

        isBulkRunning = true
        lastBulkAction = action
        bulkResults = []
        defer { isBulkRunning = false }

        for p in targets { inFlightPaths.insert(p.path) }
        let results = await service.bulk(action: action, paths: targets.map(\.path))
        bulkResults = results
        await refreshAll()
        for p in targets { inFlightPaths.remove(p.path) }
    }

    private func bulkTargetProjects() -> [WorkspaceProject] {
        if selection.isEmpty { return store.projects }
        return store.projects.filter { selection.contains($0.id) }
    }

    // MARK: - Project mutation

    func addCurrentInput() {
        let path = addPathInput.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        let name = addNameInput.trimmingCharacters(in: .whitespaces)
        let group = addGroupInput.trimmingCharacters(in: .whitespaces)

        if let added = store.add(
            path: path,
            name: name.isEmpty ? nil : name,
            group: group
        ) {
            addPathInput = ""
            addNameInput = ""
            addGroupInput = ""
            isShowingAddSheet = false
            Task {
                let snap = await service.snapshot(at: added.path)
                snapshots[added.path] = snap
            }
        }
    }

    func addPathFromDrop(_ path: String) {
        guard let added = store.add(path: path) else { return }
        Task {
            let snap = await service.snapshot(at: added.path)
            snapshots[added.path] = snap
        }
    }

    func remove(_ project: WorkspaceProject) {
        store.remove(project.id)
        snapshots.removeValue(forKey: project.path)
        selection.remove(project.id)
    }

    func togglePin(_ project: WorkspaceProject) {
        store.togglePin(project.id)
    }

    func toggleSelection(_ project: WorkspaceProject) {
        if selection.contains(project.id) {
            selection.remove(project.id)
        } else {
            selection.insert(project.id)
        }
    }

    func selectAll() {
        selection = Set(filteredProjects.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - Derived collections

    /// All projects after filter + search + tag chips have been applied.
    var filteredProjects: [WorkspaceProject] {
        let q = searchQuery.lowercased()

        return store.orderedProjects.filter { project in
            // Tag chip
            if let selectedTag, !project.tags.contains(selectedTag) {
                return false
            }
            // Search box
            if !q.isEmpty {
                let hay = "\(project.name) \(project.path) \(project.group) \(project.tags.joined(separator: " "))".lowercased()
                if !hay.contains(q) { return false }
            }
            // Status filter
            let snap = snapshots[project.path]
            switch filter {
            case .all:
                return true
            case .attention:
                return snap?.needsAttention ?? false
            case .dirty:
                return snap?.isDirty ?? false
            case .behind:
                return (snap?.aheadBehind?.behind ?? 0) > 0
            case .ahead:
                return (snap?.aheadBehind?.ahead ?? 0) > 0
            case .noUpstream:
                return snap.map { $0.state == .ok && !$0.hasUpstream } ?? false
            case .errors:
                if case .error = snap?.state { return true }
                if snap?.state == .notARepo { return true }
                return false
            }
        }
    }

    /// Projects grouped by `displayGroup`, in stable group order.
    var groupedFiltered: [(group: String, projects: [WorkspaceProject])] {
        var groups: [String] = []
        var byGroup: [String: [WorkspaceProject]] = [:]
        for p in filteredProjects {
            if byGroup[p.displayGroup] == nil {
                groups.append(p.displayGroup)
                byGroup[p.displayGroup] = []
            }
            byGroup[p.displayGroup]?.append(p)
        }
        return groups.map { ($0, byGroup[$0] ?? []) }
    }

    /// Aggregate counters used by the header KPIs.
    struct Stats {
        var total: Int = 0
        var dirty: Int = 0
        var behind: Int = 0
        var ahead: Int = 0
        var errors: Int = 0
        var attention: Int = 0
    }

    var stats: Stats {
        var s = Stats()
        s.total = store.projects.count
        for p in store.projects {
            guard let snap = snapshots[p.path] else { continue }
            if snap.isDirty { s.dirty += 1 }
            if (snap.aheadBehind?.behind ?? 0) > 0 { s.behind += 1 }
            if (snap.aheadBehind?.ahead ?? 0) > 0 { s.ahead += 1 }
            if case .error = snap.state { s.errors += 1 }
            if snap.state == .notARepo { s.errors += 1 }
            if snap.needsAttention { s.attention += 1 }
        }
        return s
    }

    var allTags: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for p in store.projects {
            for t in p.tags where !seen.contains(t) {
                seen.insert(t)
                ordered.append(t)
            }
        }
        return ordered.sorted()
    }
}
