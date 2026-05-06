import Foundation
import AVFoundation
import Combine
import AppKit
import CoreGraphics

/// Estado observável da gravação. Direcionado pela UI (`RecorderPanel`).
enum RecorderState: Equatable {
    case idle
    case preparing
    case recording
    case finalizing
    case finished(URL)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing: return true
        default: return false
        }
    }
}

/// Orquestra os recorders individuais (mic, sistema, tela) e produz um único
/// arquivo final. Combinações que usam múltiplas fontes têm seus arquivos
/// temporários mesclados via `AVMutableComposition` ao parar.
@MainActor
final class MediaRecorderController: ObservableObject {

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levelMic: Float = 0
    @Published private(set) var levelSystem: Float = 0

    private(set) var mode: RecordingMode = .audioMic
    private(set) var outputURL: URL?

    private var micRecorder: MicRecorder?
    private var systemRecorder: AnyObject? // SystemAudioRecorder (gated by availability)
    private var screenRecorder: AnyObject?  // ScreenRecorder
    private var tempDir: URL?
    private var startedAt: Date?
    private var levelTimer: Timer?

    // MARK: - Public API

    /// Detecta combinações de configuração que historicamente sabotam a
    /// gravação no macOS — em particular: usar mic Bluetooth com captura de
    /// áudio do sistema (AirPods força A2DP→HFP, que bypassa o mixer interno
    /// e o ScreenCaptureKit não recebe samples). Retorna texto pronto para
    /// mostrar como banner/alert; `nil` quando não há risco aparente.
    static func preflightAdvisory(mode: RecordingMode, micID: String?) -> String? {
        guard mode.needsSystemAudio else { return nil }

        // Caso 1: o mic escolhido pelo usuário é um dispositivo Bluetooth.
        if mode.needsMic, let id = micID, let device = AudioInputDevices.device(withID: id),
           AudioRouteInspector.isBluetoothMic(device) {
            return "O microfone \"\(device.localizedName)\" é Bluetooth. Ativá-lo durante a gravação força o macOS a trocar o áudio para modo HFP/SCO, o que costuma BLOQUEAR a captura do áudio do sistema (você gravaria só o microfone). Recomendado: usar o microfone interno do Mac."
        }

        // Caso 2: o output ativo do sistema é Bluetooth/AirPlay (que pode
        // bypassar o mixer interno mesmo sem mic Bluetooth).
        if let route = AudioRouteInspector.currentRoute() {
            if route.outputIsBluetooth {
                return "O output de áudio ativo é \"\(route.outputDeviceName)\" (Bluetooth). Em alguns drivers/OS, o áudio do sistema não chega ao gravador. Se o resultado vier sem áudio do sistema, troque temporariamente o output para os alto-falantes internos."
            }
            if route.outputTransport == .airplay {
                return "O output de áudio ativo é \"\(route.outputDeviceName)\" (AirPlay). AirPlay roteia fora do mixer interno e geralmente impede a captura do áudio do sistema. Troque para um output local."
            }
        }
        return nil
    }

    /// Inicia a gravação. Lança erro se a configuração for inválida ou alguma
    /// permissão for negada.
    func start(
        mode: RecordingMode,
        micID: String?,
        displayID: CGDirectDisplayID?,
        outputDirectory: URL,
        baseName: String
    ) async throws {
        guard !state.isActive else { return }

        state = .preparing
        elapsed = 0
        levelMic = 0
        levelSystem = 0
        self.mode = mode

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexify_recorder_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        self.tempDir = temp

        let finalExtension: String = mode.isVideo ? "mov" : "m4a"
        let safeBase = sanitizeFileName(baseName)
        let finalURL = uniqueDestination(
            outputDirectory.appendingPathComponent("\(safeBase).\(finalExtension)")
        )
        self.outputURL = finalURL

        do {
            try await launchPipelines(
                mode: mode,
                micID: micID,
                displayID: displayID,
                tempDir: temp
            )
        } catch {
            await rollback()
            state = .failed(error.localizedDescription)
            throw error
        }

        startedAt = Date()
        startMonitoring()
        state = .recording

        // Persistir preferências para a próxima gravação.
        let prefs = RecordingPreferences.shared
        prefs.lastMode = mode
        if let micID, mode.needsMic { prefs.lastMicID = micID }
        prefs.lastOutputDirectory = outputDirectory
    }

    /// Para tudo, mescla as faixas se necessário e devolve a URL do arquivo final.
    @discardableResult
    func stop() async -> URL? {
        guard state == .recording else { return nil }
        state = .finalizing
        stopMonitoring()

        let micFile: URL?
        if let rec = micRecorder {
            micFile = await rec.stop()
        } else {
            micFile = nil
        }

        var systemFile: URL?
        if #available(macOS 13.0, *), let rec = systemRecorder as? SystemAudioRecorder {
            systemFile = await rec.stop()
        }

        var screenFile: URL?
        if #available(macOS 13.0, *), let rec = screenRecorder as? ScreenRecorder {
            screenFile = await rec.stop()
        }

        guard let finalURL = outputURL else {
            state = .failed("URL final não definida")
            return nil
        }

        do {
            try await mergeIntoFinalFile(
                mode: mode,
                micFile: micFile,
                systemFile: systemFile,
                screenFile: screenFile,
                destination: finalURL
            )
        } catch {
            state = .failed(error.localizedDescription)
            cleanupTemp()
            return nil
        }

        cleanupTemp()
        state = .finished(finalURL)
        return finalURL
    }

    /// Aborta tudo e descarta arquivos temporários (sem produzir saída).
    func cancel() async {
        stopMonitoring()
        if let rec = micRecorder { await rec.cancel() }
        if #available(macOS 13.0, *) {
            if let rec = systemRecorder as? SystemAudioRecorder { await rec.cancel() }
            if let rec = screenRecorder as? ScreenRecorder { await rec.cancel() }
        }
        if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupTemp()
        state = .idle
    }

    /// Reset suave para reabrir o painel após uma gravação concluída ou um erro.
    func reset() {
        guard !state.isActive else { return }
        state = .idle
        elapsed = 0
        levelMic = 0
        levelSystem = 0
        outputURL = nil
    }

    // MARK: - Pipelines

    private func launchPipelines(
        mode: RecordingMode,
        micID: String?,
        displayID: CGDirectDisplayID?,
        tempDir: URL
    ) async throws {
        if mode.isVideo {
            guard #available(macOS 13.0, *) else {
                throw NSError(domain: "MediaRecorder", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Gravação de tela requer macOS 13 ou superior."
                ])
            }
            let screen = ScreenRecorder()
            self.screenRecorder = screen
            let videoTemp = tempDir.appendingPathComponent("video.mov")
            try await screen.start(
                displayID: displayID,
                captureSystemAudio: mode.needsSystemAudio,
                outputURL: videoTemp
            )

            if mode.needsMic {
                let mic = MicRecorder()
                self.micRecorder = mic
                try await mic.start(
                    deviceID: micID,
                    outputURL: tempDir.appendingPathComponent("mic.m4a")
                )
            }
        } else {
            // Áudio puro
            if mode.needsMic {
                let mic = MicRecorder()
                self.micRecorder = mic
                try await mic.start(
                    deviceID: micID,
                    outputURL: tempDir.appendingPathComponent("mic.m4a")
                )
            }
            if mode.needsSystemAudio {
                guard #available(macOS 13.0, *) else {
                    throw NSError(domain: "MediaRecorder", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Captura de áudio do sistema requer macOS 13 ou superior."
                    ])
                }
                let sys = SystemAudioRecorder()
                self.systemRecorder = sys
                try await sys.start(
                    outputURL: tempDir.appendingPathComponent("system.m4a")
                )
            }
        }
    }

    // MARK: - Merge final

    private func mergeIntoFinalFile(
        mode: RecordingMode,
        micFile: URL?,
        systemFile: URL?,
        screenFile: URL?,
        destination: URL
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if mode.isVideo {
            guard let video = screenFile else {
                throw NSError(domain: "MediaRecorder", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Vídeo não foi capturado."
                ])
            }
            // Sem mic → vídeo já tem (ou não) o áudio do sistema, basta mover.
            if micFile == nil {
                try FileManager.default.moveItem(at: video, to: destination)
                return
            }
            try await composeVideoWithMic(videoURL: video, micURL: micFile!, destination: destination)
        } else {
            // Áudio puro
            switch (micFile, systemFile) {
            case let (mic?, nil):
                try FileManager.default.moveItem(at: mic, to: destination)
            case let (nil, sys?):
                try FileManager.default.moveItem(at: sys, to: destination)
            case let (mic?, sys?):
                try await mixAudio(tracks: [mic, sys], destination: destination)
            default:
                throw NSError(domain: "MediaRecorder", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "Nenhuma fonte de áudio capturada."
                ])
            }
        }
    }

    private func mixAudio(tracks: [URL], destination: URL) async throws {
        let composition = AVMutableComposition()

        var emptyTracks: [URL] = []
        for url in tracks {
            let asset = AVURLAsset(url: url)
            let assetTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let assetTrack = assetTracks.first else {
                // Antes silenciávamos isso e o usuário recebia o output sem
                // o áudio do sistema (típico AirPods em HFP). Agora coletamos
                // pra propagar como erro/warning depois do loop.
                emptyTracks.append(url)
                continue
            }
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let duration = try await asset.load(.duration)
            try compTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetTrack,
                at: .zero
            )
        }

        if composition.tracks(withMediaType: .audio).isEmpty {
            throw NSError(domain: "MediaRecorder", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Nenhuma fonte de áudio capturou samples. Verifique permissões e roteamento de áudio."
            ])
        }
        if !emptyTracks.isEmpty {
            let names = emptyTracks.map { $0.lastPathComponent }.joined(separator: ", ")
            NexLog.general.warning("MediaRecorder: faixa(s) de áudio sem samples: \(names)")
        }

        try await export(composition: composition, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, to: destination)
    }

    private func composeVideoWithMic(videoURL: URL, micURL: URL, destination: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)

        // Vídeo
        if let videoAssetTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
           let compVideo = composition.addMutableTrack(
               withMediaType: .video,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await videoAsset.load(.duration)
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoAssetTrack,
                at: .zero
            )
            // Preserva orientação da fonte (geralmente identidade).
            if let preferred = try? await videoAssetTrack.load(.preferredTransform) {
                compVideo.preferredTransform = preferred
            }
        }

        // Áudio do sistema, se já estiver no .mov
        if let sysAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
           let compSysAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await videoAsset.load(.duration)
            try compSysAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sysAudioTrack,
                at: .zero
            )
        }

        // Microfone (faixa de áudio adicional)
        let micAsset = AVURLAsset(url: micURL)
        if let micTrack = try await micAsset.loadTracks(withMediaType: .audio).first,
           let compMic = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let duration = try await micAsset.load(.duration)
            try compMic.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: micTrack,
                at: .zero
            )
        }

        try await export(composition: composition, fileType: .mov, preset: AVAssetExportPresetPassthrough, to: destination)
    }

    private func export(
        composition: AVComposition,
        fileType: AVFileType,
        preset: String,
        to destination: URL
    ) async throws {
        // PassThrough é mais rápido e preserva qualidade. Cai para HighestQuality
        // quando o preset incompatível com o destino (raro nas combinações que usamos).
        guard let session = AVAssetExportSession(asset: composition, presetName: preset)
                ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "MediaRecorder", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Não foi possível criar a sessão de exportação."
            ])
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false

        await session.export()

        switch session.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw session.error ?? NSError(domain: "MediaRecorder", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Exportação falhou."
            ])
        default:
            throw NSError(domain: "MediaRecorder", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Status inesperado da exportação: \(session.status.rawValue)"
            ])
        }
    }

    // MARK: - Helpers

    private func startMonitoring() {
        stopMonitoring()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshMonitorValues()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func refreshMonitorValues() {
        if let started = startedAt {
            elapsed = Date().timeIntervalSince(started)
        }
        levelMic = micRecorder?.currentLevel ?? 0
        if #available(macOS 13.0, *), let rec = systemRecorder as? SystemAudioRecorder {
            levelSystem = rec.currentLevel
        } else {
            levelSystem = 0
        }
    }

    private func rollback() async {
        if let rec = micRecorder { await rec.cancel() }
        if #available(macOS 13.0, *) {
            if let rec = systemRecorder as? SystemAudioRecorder { await rec.cancel() }
            if let rec = screenRecorder as? ScreenRecorder { await rec.cancel() }
        }
        cleanupTemp()
    }

    private func cleanupTemp() {
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        micRecorder = nil
        systemRecorder = nil
        screenRecorder = nil
        startedAt = nil
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultBaseName() : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return base.components(separatedBy: invalid).joined(separator: "_")
    }

    private func defaultBaseName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "recording-\(f.string(from: Date()))"
    }

    private func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for i in 2...100 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
