import Foundation
import AVFoundation
import ScreenCaptureKit

/// Captura **a saída de áudio do sistema** (qualquer som que tocaria nos
/// alto-falantes) usando ScreenCaptureKit, gravando em `.m4a` (AAC).
///
/// Disponível desde macOS 13. Em macOS 14+ usamos a API moderna `SCStream` com
/// `capturesAudio = true`, com um output dummy de vídeo (1×1) para satisfazer
/// a API mesmo quando só queremos o áudio.
@available(macOS 13.0, *)
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    enum RecorderError: LocalizedError {
        case permissionDenied
        case noContent
        case configurationFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Permissão de Gravação de Tela negada. Permita em Ajustes do Sistema → Privacidade → Gravação de Tela."
            case .noContent:
                return "Nenhum display disponível para captura de áudio do sistema."
            case .configurationFailed(let msg):
                return "Falha ao configurar áudio do sistema: \(msg)"
            case .writerFailed(let msg):
                return "Falha ao salvar áudio do sistema: \(msg)"
            }
        }
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.nexia.recorder.system-audio")
    private var didStartSession = false

    private(set) var outputURL: URL?

    private var _level: Float = 0
    private let levelLock = NSLock()
    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _level
    }

    // MARK: - Lifecycle

    func start(outputURL: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied
        }

        guard let display = content.displays.first else { throw RecorderError.noContent }

        // Filtro: incluir o display, mas excluir nossa própria app para evitar feedback
        // se a UI emitir áudio durante a gravação.
        let bundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Mesmo só querendo áudio, ScreenCaptureKit exige output de vídeo válido.
        // Mantemos uma resolução minúscula e baixa taxa para custo desprezível.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        try configureWriter(at: outputURL)
        self.outputURL = outputURL

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // Adiciona output de vídeo dummy só para a API ficar feliz.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw RecorderError.configurationFailed(error.localizedDescription)
        }
        self.stream = stream
    }

    func stop() async -> URL? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        guard let writer, let input else { return outputURL }
        input.markAsFinished()
        await writer.finishWriting()
        let url = outputURL
        cleanupAfterStop()
        return url
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        if let writer, writer.status == .writing {
            input?.markAsFinished()
            writer.cancelWriting()
        }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupAfterStop()
    }

    private func cleanupAfterStop() {
        writer = nil
        input = nil
        didStartSession = false
    }

    // MARK: - Writer

    private func configureWriter(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

        guard assetWriter.canAdd(writerInput) else {
            throw RecorderError.writerFailed("Writer recusou input de áudio do sistema")
        }
        assetWriter.add(writerInput)

        guard assetWriter.startWriting() else {
            throw RecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "startWriting falhou")
        }

        self.writer = assetWriter
        self.input = writerInput
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer, let input else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartSession {
            writer.startSession(atSourceTime: pts)
            didStartSession = true
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }

        updateLevel(from: sampleBuffer)
    }

    private func updateLevel(from sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return }

        // ScreenCaptureKit entrega Float32 PCM nesse caminho.
        let sampleCount = totalLength / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }

        var rms: Float = 0
        dataPointer.withMemoryRebound(to: Float32.self, capacity: sampleCount) { ptr in
            var sum: Float = 0
            for i in 0..<sampleCount {
                let v = ptr[i]
                sum += v * v
            }
            rms = sqrt(sum / Float(sampleCount))
        }

        levelLock.lock()
        _level = max(rms, _level * 0.85)
        levelLock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NexLog.general.error("SystemAudioRecorder stream stopped: \(error.localizedDescription)")
    }
}
