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

    func modelForProvider(_ provider: ProviderType) -> String {
        switch provider {
        case .ollama: return ollamaModel
        case .openAI: return openAIModel
        case .gemini: return geminiModel
        }
    }
}
