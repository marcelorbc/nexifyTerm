import Foundation
import Combine
import AppKit

class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private let store = NexPersistence.shared

    static let defaultTerminalFontSize: CGFloat = 13
    static let minTerminalFontSize: CGFloat = 8
    static let maxTerminalFontSize: CGFloat = 36
    static let fontSizeStep: CGFloat = 1

    private enum Keys {
        static let defaultProvider = "defaultProvider"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let openAIModel = "openAIModel"
        static let geminiModel = "geminiModel"
        static let defaultApprovalMode = "defaultApprovalMode"
        static let openAIAPIKey = "openAIAPIKey"
        static let geminiAPIKey = "geminiAPIKey"
        static let defaultDirectory = "defaultDirectory"
        static let askDirectoryOnNewTab = "askDirectoryOnNewTab"
        static let mcpServers = "mcpServers"
        static let terminalFontSize = "terminalFontSize"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyHideOnFocusLost = "hotKeyHideOnFocusLost"
        static let sudoAutoAuthorize = "sudoAutoAuthorize"
        static let diskAnalyzerSkipDevDirs = "diskAnalyzerSkipDevDirs"
        static let customInstructions = "customInstructions"
        static let personalityStyle = "personalityStyle"
        static let memoryEnabled = "memoryEnabled"
        static let memoryAutoCapture = "memoryAutoCapture"
        static let referenceChatHistory = "referenceChatHistory"
        static let systemProfileEnabled = "systemProfileEnabled"
    }

    var defaultProvider: ProviderType {
        get {
            guard let raw = store.getConfig(Keys.defaultProvider),
                  let provider = ProviderType(rawValue: raw) else {
                return AppConfig.Defaults.provider
            }
            return provider
        }
        set {
            store.setConfig(Keys.defaultProvider, value: newValue.rawValue)
            objectWillChange.send()
        }
    }

    var defaultApprovalMode: ApprovalMode {
        get {
            guard let raw = store.getConfig(Keys.defaultApprovalMode),
                  let mode = ApprovalMode(rawValue: raw) else {
                return AppConfig.Defaults.approvalMode
            }
            return mode
        }
        set {
            store.setConfig(Keys.defaultApprovalMode, value: newValue.rawValue)
            objectWillChange.send()
        }
    }

    var ollamaBaseURL: String {
        get { store.getConfig(Keys.ollamaBaseURL) ?? AppConfig.Ollama.defaultBaseURL }
        set {
            store.setConfig(Keys.ollamaBaseURL, value: newValue)
            objectWillChange.send()
        }
    }

    var ollamaModel: String {
        get { store.getConfig(Keys.ollamaModel) ?? AppConfig.Ollama.defaultModel }
        set {
            store.setConfig(Keys.ollamaModel, value: newValue)
            objectWillChange.send()
        }
    }

    var openAIModel: String {
        get { store.getConfig(Keys.openAIModel) ?? AppConfig.OpenAI.defaultModel }
        set {
            store.setConfig(Keys.openAIModel, value: newValue)
            objectWillChange.send()
        }
    }

    var geminiModel: String {
        get { store.getConfig(Keys.geminiModel) ?? AppConfig.Gemini.defaultModel }
        set {
            store.setConfig(Keys.geminiModel, value: newValue)
            objectWillChange.send()
        }
    }

    var openAIAPIKey: String {
        get { store.getSecret(Keys.openAIAPIKey) ?? "" }
        set { store.setSecret(Keys.openAIAPIKey, value: newValue) }
    }

    var geminiAPIKey: String {
        get { store.getSecret(Keys.geminiAPIKey) ?? "" }
        set { store.setSecret(Keys.geminiAPIKey, value: newValue) }
    }

    var defaultDirectory: String {
        get { store.getConfig(Keys.defaultDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path }
        set {
            store.setConfig(Keys.defaultDirectory, value: newValue)
            objectWillChange.send()
        }
    }

    var askDirectoryOnNewTab: Bool {
        get { store.getConfig(Keys.askDirectoryOnNewTab) == "true" }
        set {
            store.setConfig(Keys.askDirectoryOnNewTab, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    var mcpServers: [MCPServerConfig] {
        get {
            guard let raw = store.getConfig(Keys.mcpServers),
                  let data = raw.data(using: .utf8),
                  let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
                return []
            }
            return configs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                store.setConfig(Keys.mcpServers, value: str)
            }
            objectWillChange.send()
        }
    }

    var terminalFontSize: CGFloat {
        get {
            guard let raw = store.getConfig(Keys.terminalFontSize),
                  let size = Double(raw) else {
                return Self.defaultTerminalFontSize
            }
            return CGFloat(size)
        }
        set {
            let clamped = min(Self.maxTerminalFontSize, max(Self.minTerminalFontSize, newValue))
            store.setConfig(Keys.terminalFontSize, value: String(format: "%.0f", clamped))
            objectWillChange.send()
            NotificationCenter.default.post(name: .terminalFontSizeChanged, object: clamped)
        }
    }

    func increaseFontSize() {
        terminalFontSize = terminalFontSize + Self.fontSizeStep
    }

    func decreaseFontSize() {
        terminalFontSize = terminalFontSize - Self.fontSizeStep
    }

    func resetFontSize() {
        terminalFontSize = Self.defaultTerminalFontSize
    }

    // MARK: - Global Hotkey

    var hotKeyEnabled: Bool {
        get { store.getConfig(Keys.hotKeyEnabled) == "true" }
        set {
            store.setConfig(Keys.hotKeyEnabled, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    /// Default: backtick (keyCode 50)
    var hotKeyCode: Int {
        get {
            guard let raw = store.getConfig(Keys.hotKeyCode), let val = Int(raw) else { return 50 }
            return val
        }
        set {
            store.setConfig(Keys.hotKeyCode, value: String(newValue))
            objectWillChange.send()
        }
    }

    /// Default: Control key
    var hotKeyModifiers: Int {
        get {
            guard let raw = store.getConfig(Keys.hotKeyModifiers), let val = Int(raw) else {
                return Int(NSEvent.ModifierFlags.control.rawValue)
            }
            return val
        }
        set {
            store.setConfig(Keys.hotKeyModifiers, value: String(newValue))
            objectWillChange.send()
        }
    }

    var hotKeyHideOnFocusLost: Bool {
        get { store.getConfig(Keys.hotKeyHideOnFocusLost) != "false" }
        set {
            store.setConfig(Keys.hotKeyHideOnFocusLost, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    // MARK: - Sudo

    var sudoAutoAuthorize: Bool {
        get { store.getConfig(Keys.sudoAutoAuthorize) == "true" }
        set {
            store.setConfig(Keys.sudoAutoAuthorize, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    // MARK: - Disk Analyzer

    /// Quando `true` (default), pula `node_modules`, `.git`, `Pods`, build dirs etc
    /// durante a análise de disco. Drasticamente acelera workspaces de dev.
    var diskAnalyzerSkipDevDirs: Bool {
        get { store.getConfig(Keys.diskAnalyzerSkipDevDirs) != "false" }
        set {
            store.setConfig(Keys.diskAnalyzerSkipDevDirs, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    // MARK: - Personalization (memory + custom instructions + style)

    /// Free-form instructions the user wants the agent to consider on EVERY interaction.
    /// Equivalent to ChatGPT's "Custom Instructions".
    var customInstructions: String {
        get { store.getConfig(Keys.customInstructions) ?? "" }
        set {
            store.setConfig(Keys.customInstructions, value: newValue)
            objectWillChange.send()
        }
    }

    /// Tone / style baseline. Combined with memories and custom instructions.
    var personalityStyle: PersonalityStyle {
        get {
            guard let raw = store.getConfig(Keys.personalityStyle),
                  let style = PersonalityStyle(rawValue: raw) else {
                return .direct
            }
            return style
        }
        set {
            store.setConfig(Keys.personalityStyle, value: newValue.rawValue)
            objectWillChange.send()
        }
    }

    /// Master toggle: when off, no memory is injected into prompts.
    var memoryEnabled: Bool {
        get { store.getConfig(Keys.memoryEnabled) != "false" }
        set {
            store.setConfig(Keys.memoryEnabled, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    /// Whether the LLM is allowed to auto-capture new memories from conversation.
    /// User can disable to keep memories purely manual.
    var memoryAutoCapture: Bool {
        get { store.getConfig(Keys.memoryAutoCapture) != "false" }
        set {
            store.setConfig(Keys.memoryAutoCapture, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    /// Whether to surface tab conversation history (recent turns) to the LLM.
    /// Equivalent to ChatGPT's "Reference chat history" toggle.
    var referenceChatHistory: Bool {
        get { store.getConfig(Keys.referenceChatHistory) != "false" }
        set {
            store.setConfig(Keys.referenceChatHistory, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    /// Whether the agent prompt receives the cached `SystemProfile` (hardware,
    /// OS, installed tools). When off, the LLM will discover availability via
    /// commands at runtime instead.
    var systemProfileEnabled: Bool {
        get { store.getConfig(Keys.systemProfileEnabled) != "false" }
        set {
            store.setConfig(Keys.systemProfileEnabled, value: newValue ? "true" : "false")
            objectWillChange.send()
        }
    }

    func modelForProvider(_ provider: ProviderType) -> String {
        switch provider {
        case .ollama: return ollamaModel
        case .openAI: return openAIModel
        case .gemini: return geminiModel
        }
    }
}
