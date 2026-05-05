import Foundation

/// A single repo the architect tracks in the multi-repo Cockpit. Persisted in
/// `~/Library/Application Support/NexOperator/workspace.json`.
struct WorkspaceProject: Codable, Identifiable, Equatable, Hashable {
    /// Stable id so the UI can keep selection across renames/path moves.
    let id: UUID

    /// Absolute path to the working tree root.
    var path: String

    /// Display name. Defaults to the last path component.
    var name: String

    /// Free-form group key (e.g. "Backend", "Frontend", "Mobile"). The Cockpit
    /// groups projects by this string. Empty string == "Sem grupo".
    var group: String

    /// Optional ordered tags. Used by the "filter by tag" chip row.
    var tags: [String]

    /// User-defined sort order inside the group.
    var order: Int

    /// True when the user starred the project — pinned to the top of its
    /// group in the Cockpit list.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        group: String = "",
        tags: [String] = [],
        order: Int = 0,
        isPinned: Bool = false
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.group = group
        self.tags = tags
        self.order = order
        self.isPinned = isPinned
    }

    var displayGroup: String {
        group.isEmpty ? "Sem grupo" : group
    }
}

/// Snapshot returned by `WorkspaceSnapshotService.snapshot(at:)`. Not Codable —
/// it is pure runtime state that re-derives every refresh.
struct RepoSnapshot: Equatable {
    enum State: Equatable {
        /// Path is not a git repo (or unreadable).
        case notARepo
        /// Healthy snapshot; everything below is meaningful.
        case ok
        /// `git` ran but returned an unexpected error (permission, corrupted
        /// repo, detached HEAD edge cases).
        case error(String)
    }

    let path: String
    let state: State
    let branch: String
    /// `nil` when there is no upstream configured for the current branch.
    let aheadBehind: (ahead: Int, behind: Int)?
    let hasUpstream: Bool
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let lastCommitSubject: String
    let lastCommitAuthor: String
    let lastCommitRelative: String
    /// Wall-clock time the snapshot was captured. Drives the "atualizado há
    /// 12s" indicator and the "stale" filter.
    let measuredAt: Date

    var isDirty: Bool {
        stagedCount + unstagedCount + untrackedCount > 0
    }

    var totalChanges: Int {
        stagedCount + unstagedCount + untrackedCount
    }

    var needsAttention: Bool {
        switch state {
        case .ok:
            if isDirty { return true }
            if let ab = aheadBehind, ab.ahead > 0 || ab.behind > 0 { return true }
            return false
        case .notARepo, .error:
            return true
        }
    }

    static func placeholder(path: String) -> RepoSnapshot {
        RepoSnapshot(
            path: path,
            state: .ok,
            branch: "",
            aheadBehind: nil,
            hasUpstream: false,
            stagedCount: 0,
            unstagedCount: 0,
            untrackedCount: 0,
            lastCommitSubject: "",
            lastCommitAuthor: "",
            lastCommitRelative: "",
            measuredAt: .distantPast
        )
    }

    // Equatable can't synthesize for tuple — implement manually so SwiftUI
    // diffing works correctly.
    static func == (lhs: RepoSnapshot, rhs: RepoSnapshot) -> Bool {
        lhs.path == rhs.path
            && lhs.state == rhs.state
            && lhs.branch == rhs.branch
            && lhs.aheadBehind?.ahead == rhs.aheadBehind?.ahead
            && lhs.aheadBehind?.behind == rhs.aheadBehind?.behind
            && lhs.hasUpstream == rhs.hasUpstream
            && lhs.stagedCount == rhs.stagedCount
            && lhs.unstagedCount == rhs.unstagedCount
            && lhs.untrackedCount == rhs.untrackedCount
            && lhs.lastCommitSubject == rhs.lastCommitSubject
            && lhs.lastCommitAuthor == rhs.lastCommitAuthor
            && lhs.lastCommitRelative == rhs.lastCommitRelative
            && lhs.measuredAt == rhs.measuredAt
    }
}
