import Foundation

/// Modos de gravação suportados. Combinações comuns de fontes (mic/sistema/tela).
enum RecordingMode: String, CaseIterable, Identifiable, Codable {
    case audioMic
    case audioSystem
    case audioMicAndSystem
    case videoScreen
    case videoScreenWithMic
    case videoScreenWithMicAndSystem

    var id: String { rawValue }

    var isVideo: Bool {
        switch self {
        case .videoScreen, .videoScreenWithMic, .videoScreenWithMicAndSystem:
            return true
        default:
            return false
        }
    }

    var needsMic: Bool {
        switch self {
        case .audioMic, .audioMicAndSystem, .videoScreenWithMic, .videoScreenWithMicAndSystem:
            return true
        default:
            return false
        }
    }

    var needsSystemAudio: Bool {
        switch self {
        case .audioSystem, .audioMicAndSystem, .videoScreenWithMicAndSystem:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .audioMic:                   return "Áudio · Microfone"
        case .audioSystem:                return "Áudio · Saída do Sistema"
        case .audioMicAndSystem:          return "Áudio · Microfone + Sistema"
        case .videoScreen:                return "Vídeo · Tela (sem áudio)"
        case .videoScreenWithMic:         return "Vídeo · Tela + Microfone"
        case .videoScreenWithMicAndSystem: return "Vídeo · Tela + Mic + Sistema"
        }
    }

    var icon: String {
        switch self {
        case .audioMic:                    return "mic.fill"
        case .audioSystem:                 return "hifispeaker.fill"
        case .audioMicAndSystem:           return "mic.and.signal.meter.fill"
        case .videoScreen:                 return "rectangle.dashed.badge.record"
        case .videoScreenWithMic:          return "video.bubble"
        case .videoScreenWithMicAndSystem: return "video.fill.badge.plus"
        }
    }
}

/// Persiste a última configuração escolhida pelo usuário (modo, microfone, pasta).
final class RecordingPreferences {
    static let shared = RecordingPreferences()
    private let store = NexPersistence.shared

    private enum Keys {
        static let mode = "recording.lastMode"
        static let micID = "recording.lastMicID"
        static let outputDir = "recording.lastOutputDir"
    }

    var lastMode: RecordingMode {
        get {
            guard let raw = store.getConfig(Keys.mode),
                  let mode = RecordingMode(rawValue: raw) else { return .audioMic }
            return mode
        }
        set { store.setConfig(Keys.mode, value: newValue.rawValue) }
    }

    var lastMicID: String? {
        get { store.getConfig(Keys.micID) }
        set {
            if let v = newValue, !v.isEmpty {
                store.setConfig(Keys.micID, value: v)
            }
        }
    }

    /// Caminho da última pasta de saída usada (para cair de volta nela quando o usuário
    /// disparar o gravador de fora de uma aba de explorer).
    var lastOutputDirectory: URL? {
        get {
            guard let path = store.getConfig(Keys.outputDir) else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set {
            if let url = newValue {
                store.setConfig(Keys.outputDir, value: url.path)
            }
        }
    }
}
