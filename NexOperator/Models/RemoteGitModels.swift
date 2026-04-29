import SwiftUI

// MARK: - Provider Type

enum RemoteProviderType: String, Codable, CaseIterable, Identifiable {
    case github
    case azureDevOps

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .azureDevOps: return "Azure DevOps"
        }
    }

    var icon: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .azureDevOps: return "triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .github: return .white
        case .azureDevOps: return .blue
        }
    }
}

// MARK: - Account

struct RemoteAccount: Identifiable, Codable, Equatable {
    let id: UUID
    var provider: RemoteProviderType
    var displayName: String
    var username: String
    var organization: String?
    var isAuthenticated: Bool

    var keychainTokenKey: String {
        "remote_token_\(id.uuidString)"
    }
}

// MARK: - Repository

struct RemoteRepository: Identifiable, Equatable {
    let id: String
    let name: String
    let fullName: String
    let description: String?
    let language: String?
    let stars: Int
    let forks: Int
    let defaultBranch: String
    let cloneURL: String
    let htmlURL: String
    let isPrivate: Bool
    let updatedAt: Date
    let provider: RemoteProviderType

    var languageColor: Color {
        switch language?.lowercased() {
        case "swift": return .orange
        case "python": return .blue
        case "javascript", "typescript": return .yellow
        case "go": return .cyan
        case "rust": return .red
        case "java", "kotlin": return .purple
        case "c#", "c++", "c": return .green
        case "ruby": return .red
        case "php": return .indigo
        default: return .gray
        }
    }
}

// MARK: - File Tree

enum RemoteFileNodeType: String {
    case file
    case directory
}

struct RemoteFileNode: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let type: RemoteFileNodeType
    let size: Int?

    var icon: String {
        switch type {
        case .directory: return "folder.fill"
        case .file:
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "swift": return "swift"
            case "py": return "doc.text"
            case "js", "ts", "jsx", "tsx": return "doc.text"
            case "json": return "curlybraces"
            case "md", "txt": return "doc.plaintext"
            case "yml", "yaml": return "doc.text"
            case "png", "jpg", "jpeg", "gif", "svg": return "photo"
            case "sh", "bash", "zsh": return "terminal"
            default: return "doc"
            }
        }
    }

    var iconColor: Color {
        switch type {
        case .directory: return .blue
        case .file:
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "swift": return .orange
            case "py": return .blue
            case "js", "ts": return .yellow
            case "json": return .green
            case "md": return .gray
            default: return .secondary
            }
        }
    }
}

// MARK: - Pull Request

enum PRStatus: String {
    case open
    case closed
    case merged

    var icon: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .closed: return "xmark.circle"
        case .merged: return "arrow.triangle.merge"
        }
    }

    var color: Color {
        switch self {
        case .open: return .green
        case .closed: return .red
        case .merged: return .purple
        }
    }
}

struct RemotePullRequest: Identifiable, Equatable {
    let id: String
    let number: Int
    let title: String
    let author: String
    let status: PRStatus
    let createdAt: Date
    let sourceBranch: String
    let targetBranch: String
    let url: String
}

// MARK: - Issue

enum IssueState: String {
    case open
    case closed

    var icon: String {
        switch self {
        case .open: return "circle.fill"
        case .closed: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .open: return .green
        case .closed: return .purple
        }
    }
}

struct RemoteIssue: Identifiable, Equatable {
    let id: String
    let number: Int
    let title: String
    let author: String
    let state: IssueState
    let labels: [String]
    let createdAt: Date
    let url: String
}

// MARK: - Clone Request

struct CloneRequest: Identifiable {
    let id = UUID()
    let repository: RemoteRepository
    var destinationPath: String
    var progress: Double = 0
    var status: CloneStatus = .pending

    enum CloneStatus: Equatable {
        case pending
        case cloning
        case completed
        case failed(String)
    }
}
