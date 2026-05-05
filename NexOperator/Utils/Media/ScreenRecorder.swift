import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// Grava a tela em `.mov`, opcionalmente capturando o áudio do sistema na mesma
/// faixa. Microfone é gravado em paralelo pelo `MicRecorder` e mesclado depois
/// pelo `MediaRecorderController` (a API `captureMicrophone` da SCStream só
/// existe a partir do macOS 15).
@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

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
                return "Nenhum display disponível para gravação."
            case .configurationFailed(let msg):
                return "Falha ao configurar gravação de tela: \(msg)"
            case .writerFailed(let msg):
                return "Falha ao salvar vídeo: \(msg)"
            }
        }
    }

    struct DisplayChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let width: Int
        let height: Int
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let videoQueue = DispatchQueue(label: "com.nexia.recorder.screen.video")
    private let audioQueue = DispatchQueue(label: "com.nexia.recorder.screen.audio")
    private var didStartSession = false
    private var captureSystemAudio = false

    private(set) var outputURL: URL?

    /// Lista displays disponíveis. Pode lançar erro se a permissão for negada.
    static func listDisplays() async throws -> [DisplayChoice] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied
        }
        return content.displays.map {
            DisplayChoice(
                id: $0.displayID,
                name: "Display \($0.displayID) (\($0.width) × \($0.height))",
                width: $0.width,
                height: $0.height
            )
        }
    }

    // MARK: - Lifecycle

    func start(
        displayID: CGDirectDisplayID?,
        captureSystemAudio: Bool,
        outputURL: URL
    ) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied
        }

        let display: SCDisplay
        if let id = displayID, let match = content.displays.first(where: { $0.displayID == id }) {
            display = match
        } else if let first = content.displays.first {
            display = first
        } else {
            throw RecorderError.noContent
        }

        let bundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Vídeo: respeita Retina e roda em 30fps com keyframes saudáveis.
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.showsCursor = true

        if captureSystemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        self.captureSystemAudio = captureSystemAudio

        try configureWriter(at: outputURL, width: config.width, height: config.height, includeAudio: captureSystemAudio)
        self.outputURL = outputURL

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
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

        guard let writer else { return outputURL }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
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
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.cancelWriting()
        }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupAfterStop()
    }

    private func cleanupAfterStop() {
        writer = nil
        videoInput = nil
        audioInput = nil
        didStartSession = false
    }

    // MARK: - Writer

    private func configureWriter(
        at url: URL,
        width: Int,
        height: Int,
        includeAudio: Bool
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let assetWriter: AVAssetWriter
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, (width * height) / 2),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(videoInput) else {
            throw RecorderError.writerFailed("Writer recusou input de vídeo")
        }
        assetWriter.add(videoInput)
        self.videoInput = videoInput

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
                self.audioInput = audioInput
            }
        }

        guard assetWriter.startWriting() else {
            throw RecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "startWriting falhou")
        }

        self.writer = assetWriter
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if type == .screen {
            // Filtra frames que ScreenCaptureKit marca como inválidos (display com 0 frames).
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first,
                  let statusRaw = info[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else {
                return
            }

            if !didStartSession {
                writer.startSession(atSourceTime: pts)
                didStartSession = true
            }

            if writer.status == .writing, videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        } else if type == .audio, captureSystemAudio {
            if !didStartSession {
                writer.startSession(atSourceTime: pts)
                didStartSession = true
            }
            if writer.status == .writing, audioInput?.isReadyForMoreMediaData == true {
                audioInput?.append(sampleBuffer)
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NexLog.general.error("ScreenRecorder stream stopped: \(error.localizedDescription)")
    }
}
