import SwiftUI

// MARK: - Commit

struct GitCommit: Identifiable, Equatable {
    let id: String // full SHA
    let shortHash: String
    let parentHashes: [String]
    let authorName: String
    let authorEmail: String
    let date: Date
    let subject: String
    var branches: [String]
    var tags: [String]
    var isHead: Bool

    var lane: Int = 0
    var isMerge: Bool { parentHashes.count > 1 }
}

// MARK: - Commit Detail

struct GitCommitDetail {
    let hash: String
    let shortHash: String
    let authorName: String
    let authorEmail: String
    let date: Date
    let subject: String
    let body: String
    let parentHashes: [String]
    let branches: [String]
    let tags: [String]
    let changedFiles: [GitFileStatus]
    let additions: Int
    let deletions: Int
}

// MARK: - Branch

struct GitBranch: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let trackingBranch: String?
    let commitHash: String?

    var displayName: String {
        if isRemote, name.hasPrefix("origin/") {
            return String(name.dropFirst(7))
        }
        return name
    }
}

// MARK: - Tag

struct GitTag: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    let commitHash: String
    let message: String?
}

// MARK: - Stash

struct GitStash: Identifiable, Equatable {
    let id: Int
    let message: String
    let branchName: String?
}

// MARK: - File Status

enum GitFileStatusKind: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case unmerged = "U"

    var icon: String {
        switch self {
        case .modified:  return "pencil"
        case .added:     return "plus"
        case .deleted:   return "minus"
        case .renamed:   return "arrow.right"
        case .copied:    return "doc.on.doc"
        case .untracked: return "questionmark"
        case .unmerged:  return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .modified:  return .orange
        case .added:     return .green
        case .deleted:   return .red
        case .renamed:   return .blue
        case .copied:    return .blue
        case .untracked: return .gray
        case .unmerged:  return .red
        }
    }
}

struct GitFileStatus: Identifiable, Equatable, Hashable {
    var id: String { path }
    let path: String
    let status: GitFileStatusKind
    let oldPath: String?

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Graph Layout

struct GitGraphLine: Identifiable {
    let id = UUID()
    let fromLane: Int
    let toLane: Int
    let fromRow: Int
    let toRow: Int
    let color: Color
    let isMerge: Bool

    static let laneColors: [Color] = [
        Color(red: 0.2, green: 0.78, blue: 0.87),   // cyan (main)
        Color(red: 0.36, green: 0.82, blue: 0.35),   // green
        Color(red: 0.68, green: 0.42, blue: 0.92),   // purple
        Color(red: 0.95, green: 0.62, blue: 0.22),   // orange
        Color(red: 0.92, green: 0.35, blue: 0.52),   // pink
        Color(red: 0.32, green: 0.55, blue: 0.95),   // blue
        Color(red: 0.95, green: 0.82, blue: 0.22),   // yellow
        Color(red: 0.88, green: 0.34, blue: 0.34),   // red
    ]

    static func color(for lane: Int) -> Color {
        laneColors[lane % laneColors.count]
    }
}

struct GitLane {
    var activeLanes: [String?]

    init() {
        activeLanes = []
    }

    mutating func assign(_ commitHash: String) -> Int {
        if let idx = activeLanes.firstIndex(of: commitHash) {
            return idx
        }
        if let idx = activeLanes.firstIndex(of: nil) {
            activeLanes[idx] = commitHash
            return idx
        }
        activeLanes.append(commitHash)
        return activeLanes.count - 1
    }

    mutating func free(_ lane: Int) {
        guard lane < activeLanes.count else { return }
        activeLanes[lane] = nil
    }

    var maxLane: Int { activeLanes.count }
}

// MARK: - Diff

struct GitDiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [GitDiffLine]
}

struct GitDiffLine: Identifiable {
    let id = UUID()
    let content: String
    let type: LineType

    enum LineType {
        case context
        case addition
        case deletion
        case header
    }

    var color: Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .header:   return .secondary
        case .context:  return .primary
        }
    }

    var backgroundColor: Color {
        switch type {
        case .addition: return Color.green.opacity(0.1)
        case .deletion: return Color.red.opacity(0.1)
        default:        return .clear
        }
    }
}

struct GitFileDiff: Identifiable {
    let id = UUID()
    let filePath: String
    let hunks: [GitDiffHunk]
}
