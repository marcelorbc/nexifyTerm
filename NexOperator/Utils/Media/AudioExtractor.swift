import Foundation
import AVFoundation

/// Tipo de mídia inferido pela extensão do arquivo.
/// Mantém paridade com `audio_transcript/backend/config.js` (vídeos vs áudios suportados).
enum MediaKind: Equatable {
    case audio
    case video
    case unsupported

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "webm",
        "m4v", "mpeg", "mpg", "flv", "wmv", "3gp"
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac",
        "ogg", "oga", "opus", "wma", "aiff", "aif"
    ]

    static func of(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return .unsupported
    }
}

struct AudioExtractionResult {
    let url: URL
    let durationSeconds: Double
    let sizeMB: Double
}

/// Extração e chunking de áudio usando AVFoundation, sem dependência de ffmpeg.
/// Espelha o comportamento de `backend/src/audioProcessor.js`, com `.m4a` (AAC) como
/// formato nativo de saída — aceito pela Whisper API.
enum AudioExtractor {

    enum AudioError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "Arquivo não contém faixa de áudio."
            case .exportFailed(let msg):
                return "Falha na exportação de áudio: \(msg)"
            case .unsupported(let msg):
                return msg
            }
        }
    }

    /// Tamanho máximo (MB) por arquivo enviado à Whisper. Limite real é 25MB,
    /// usamos 24 para deixar uma margem de segurança igual ao projeto original.
    static let whisperMaxSizeMB: Double = 24

    /// Duração padrão de cada chunk (segundos). 10 minutos cabem com folga em 24MB
    /// no preset M4A 64kbps mono usado pelo pipeline original.
    static let defaultChunkSeconds: Double = 600

    // MARK: - Extração

    /// Extrai a faixa de áudio de um vídeo para `.m4a` ao lado do arquivo (ou em
    /// `destination` quando informado). Sobrescreve se já existir.
    static func extractAudio(from videoURL: URL, to destination: URL? = nil) async throws -> AudioExtractionResult {
        let dst = destination ?? videoURL.deletingPathExtension().appendingPathExtension("m4a")

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioError.noAudioTrack }

        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed("Não foi possível criar sessão de exportação para \(videoURL.lastPathComponent)")
        }
        session.outputURL = dst
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        await session.export()

        switch session.status {
        case .completed:
            let size = fileSizeMB(dst)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            return AudioExtractionResult(url: dst, durationSeconds: duration, sizeMB: size)
        case .failed:
            throw AudioError.exportFailed(session.error?.localizedDescription ?? "Erro desconhecido")
        case .cancelled:
            throw AudioError.exportFailed("Exportação cancelada")
        default:
            throw AudioError.exportFailed("Status inesperado: \(session.status.rawValue)")
        }
    }

    // MARK: - Chunking

    /// Divide um arquivo de áudio (ou vídeo com trilha de áudio) em pedaços `.m4a`
    /// de aproximadamente `chunkSeconds`. Retorna apenas `[input]` se a duração
    /// couber em um único chunk.
    static func splitIntoChunks(
        audioURL: URL,
        chunkSeconds: Double = defaultChunkSeconds,
        tempDir: URL
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: audioURL)
        let totalDuration = (try? await asset.load(.duration).seconds) ?? 0
        guard totalDuration > 0 else { return [audioURL] }

        let chunkCount = Int(ceil(totalDuration / chunkSeconds))
        if chunkCount <= 1 { return [audioURL] }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let baseName = audioURL.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        outputs.reserveCapacity(chunkCount)

        for i in 0..<chunkCount {
            let start = Double(i) * chunkSeconds
            let length = min(chunkSeconds, totalDuration - start)

            let chunkURL = tempDir.appendingPathComponent(
                String(format: "%@_chunk_%03d.m4a", baseName, i + 1)
            )
            if FileManager.default.fileExists(atPath: chunkURL.path) {
                try FileManager.default.removeItem(at: chunkURL)
            }

            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AudioError.exportFailed("Falha ao criar sessão para chunk \(i + 1)/\(chunkCount)")
            }
            let timescale = CMTimeScale(NSEC_PER_SEC)
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: timescale),
                duration: CMTime(seconds: length, preferredTimescale: timescale)
            )
            session.outputURL = chunkURL
            session.outputFileType = .m4a

            await session.export()

            switch session.status {
            case .completed:
                outputs.append(chunkURL)
            case .failed:
                throw AudioError.exportFailed(session.error?.localizedDescription ?? "Erro no chunk \(i + 1)")
            case .cancelled:
                throw AudioError.exportFailed("Chunk \(i + 1) cancelado")
            default:
                throw AudioError.exportFailed("Status inesperado no chunk \(i + 1)")
            }
        }
        return outputs
    }

    // MARK: - Opus conversion

    /// Converte arquivo OGG-Opus (WhatsApp) para .m4a usando ffmpeg.
    /// AVFoundation não lê OGG/Opus nativamente em macOS, então usamos ffmpeg
    /// como fallback para arquivos grandes que precisam de chunking.
    static func convertOpusToM4A(opusURL: URL, outputDir: URL) async throws -> URL {
        let baseName = opusURL.deletingPathExtension().lastPathComponent
        let outputURL = outputDir.appendingPathComponent(baseName + ".m4a")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let ffmpegPath = findFFmpeg()
        guard let ffmpeg = ffmpegPath else {
            throw AudioError.unsupported(
                "Arquivo .opus maior que 25MB requer ffmpeg para conversão. " +
                "Instale com: brew install ffmpeg"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", opusURL.path,
            "-vn",
            "-acodec", "aac",
            "-b:a", "64k",
            "-ac", "1",
            "-y",
            outputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: outputURL)
                } else {
                    continuation.resume(throwing: AudioError.exportFailed(
                        "ffmpeg finalizou com código \(proc.terminationStatus)"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AudioError.exportFailed(
                    "Falha ao executar ffmpeg: \(error.localizedDescription)"
                ))
            }
        }
    }

    /// Procura ffmpeg no sistema (Homebrew, /usr/local, PATH).
    private static func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffmpeg"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = result, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    // MARK: - Helpers

    static func fileSizeMB(_ url: URL) -> Double {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attrs[.size] as? NSNumber)?.doubleValue ?? 0
        return bytes / 1_048_576
    }
}
