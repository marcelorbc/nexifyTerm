import Foundation

enum TabMode: String {
    case terminal
    case explorer
    case mosaic
    case git
    case diskAnalyzer
}

struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var currentDirectory: String
    var provider: ProviderType
    var model: String
    var approvalMode: ApprovalMode
    var tabMode: TabMode
    var mosaicLayout: MosaicNode?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        provider: ProviderType = .ollama,
        model: String = ProviderType.ollama.defaultModel,
        approvalMode: ApprovalMode = .alwaysAsk,
        tabMode: TabMode = .terminal,
        mosaicLayout: MosaicNode? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.currentDirectory = currentDirectory
        self.provider = provider
        self.model = model
        self.approvalMode = approvalMode
        self.tabMode = tabMode
        self.mosaicLayout = mosaicLayout
        self.isPinned = isPinned
    }

    var isExplorer: Bool { tabMode == .explorer }
    var isTerminal: Bool { tabMode == .terminal }
    var isMosaic: Bool { tabMode == .mosaic }
    var isGit: Bool { tabMode == .git }
    var isDiskAnalyzer: Bool { tabMode == .diskAnalyzer }

    var tabIcon: String {
        switch tabMode {
        case .terminal: return "terminal.fill"
        case .explorer: return "folder.fill"
        case .mosaic: return "rectangle.split.2x2.fill"
        case .git: return "arrow.triangle.branch"
        case .diskAnalyzer: return "chart.pie.fill"
        }
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id
    }
}
