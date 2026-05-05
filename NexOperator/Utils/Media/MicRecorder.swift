import Foundation
import AVFoundation
import Accelerate

/// Grava o microfone escolhido pelo usuário em um arquivo `.m4a` (AAC).
/// Usa `AVCaptureSession` + `AVAssetWriter` para suportar qualquer microfone
/// (built-in, USB, AirPods, agregado) — `AVAudioEngine` puro só usa o default
/// do sistema.
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    enum RecorderError: LocalizedError {
        case permissionDenied
        case deviceNotFound
        case configurationFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Permissão de microfone negada. Permita em Ajustes do Sistema → Privacidade → Microfone."
            case .deviceNotFound:
                return "Microfone selecionado não encontrado."
            case .configurationFailed(let msg):
                return "Falha ao configurar microfone: \(msg)"
            case .writerFailed(let msg):
                return "Falha ao salvar áudio do microfone: \(msg)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.nexia.recorder.mic")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstSampleTime: CMTime?
    private var didStartSession = false

    private(set) var outputURL: URL?

    /// Nível de áudio (0..1), atualizado em tempo real pelo callback de samples.
    /// Lê/escreve via lock para acesso seguro a partir do queue interno.
    private var _level: Float = 0
    private let levelLock = NSLock()
    var currentLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _level
    }

    // MARK: - Permissions

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Lifecycle

    /// Inicia a captura. `outputURL` deve apontar para um `.m4a`. Sobrescreve se já existir.
    func start(deviceID: String?, outputURL: URL) async throws {
        guard await Self.requestPermission() else { throw RecorderError.permissionDenied }

        guard let device = AudioInputDevices.resolve(preferredID: deviceID) else {
            throw RecorderError.deviceNotFound
        }

        try await Task.detached(priority: .userInitiated) { [self] in
            try configureSession(with: device)
            try configureWriter(at: outputURL)
            self.outputURL = outputURL
            session.startRunning()
        }.value
    }

    /// Para a captura e finaliza o arquivo. Retorna a URL final ou nil se nunca capturou.
    func stop() async -> URL? {
        guard session.isRunning else { return outputURL }

        await Task.detached(priority: .userInitiated) { [self] in
            session.stopRunning()
        }.value

        guard let writer, let input else { return outputURL }

        await Task.detached { [input, writer] in
            input.markAsFinished()
            await writer.finishWriting()
        }.value

        let url = outputURL
        cleanupAfterStop()
        return url
    }

    /// Aborta sem finalizar (apaga arquivo parcial).
    func cancel() async {
        if session.isRunning {
            await Task.detached(priority: .userInitiated) { [self] in
                session.stopRunning()
            }.value
        }
        if let writer = writer, writer.status == .writing {
            input?.markAsFinished()
            writer.cancelWriting()
        }
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupAfterStop()
    }

    private func cleanupAfterStop() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        writer = nil
        input = nil
        firstSampleTime = nil
        didStartSession = false
    }

    // MARK: - Setup helpers

    private func configureSession(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let captureInput: AVCaptureDeviceInput
        do {
            captureInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecorderError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(captureInput) else {
            throw RecorderError.configurationFailed("Não foi possível adicionar input do microfone")
        }
        session.addInput(captureInput)

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw RecorderError.configurationFailed("Não foi possível adicionar output de áudio")
        }
        session.addOutput(output)
    }

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
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

        guard assetWriter.canAdd(writerInput) else {
            throw RecorderError.writerFailed("Writer recusou input de áudio")
        }
        assetWriter.add(writerInput)

        guard assetWriter.startWriting() else {
            throw RecorderError.writerFailed(assetWriter.error?.localizedDescription ?? "startWriting falhou")
        }

        self.writer = assetWriter
        self.input = writerInput
    }

    // MARK: - Sample capture (delegate)

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer, let input else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !didStartSession {
            firstSampleTime = pts
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
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return }

        // Trabalhamos com o formato de saída do AVCaptureAudioDataOutput (Int16 PCM).
        let sampleCount = totalLength / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        var rms: Float = 0
        dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { ptr in
            var sum: Float = 0
            for i in 0..<sampleCount {
                let normalized = Float(ptr[i]) / Float(Int16.max)
                sum += normalized * normalized
            }
            rms = sqrt(sum / Float(sampleCount))
        }

        levelLock.lock()
        // Suavização exponencial para o medidor não pular feio.
        _level = max(rms, _level * 0.85)
        levelLock.unlock()
    }
}
