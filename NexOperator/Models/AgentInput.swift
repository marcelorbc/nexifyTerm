import Foundation

struct AgentInput {
    let userMessage: String
    let operatingSystem: String
    let shell: String
    let currentDirectory: String
    let provider: ProviderType
    let model: String
    let terminalContext: String
    let isBrowserMode: Bool
    let browserPageInfo: String
    let mcpToolsContext: String
    let fileAttachments: [FileAttachment]
    let tabMode: TabMode
    let contextExtra: String

    var hasAttachment: Bool { !fileAttachments.isEmpty }
    var isGitMode: Bool { tabMode == .git }
    var isExplorerMode: Bool { tabMode == .explorer }

    init(
        userMessage: String,
        currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        provider: ProviderType = .ollama,
        model: String = ProviderType.ollama.defaultModel,
        terminalContext: String = "",
        isBrowserMode: Bool = false,
        browserPageInfo: String = "",
        mcpToolsContext: String = "",
        fileAttachments: [FileAttachment] = [],
        tabMode: TabMode = .terminal,
        contextExtra: String = ""
    ) {
        self.userMessage = userMessage
        self.operatingSystem = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        self.shell = "/bin/zsh"
        self.currentDirectory = currentDirectory
        self.provider = provider
        self.model = model
        self.terminalContext = terminalContext
        self.isBrowserMode = isBrowserMode
        self.browserPageInfo = browserPageInfo
        self.mcpToolsContext = mcpToolsContext
        self.fileAttachments = fileAttachments
        self.tabMode = tabMode
        self.contextExtra = contextExtra
    }
}
