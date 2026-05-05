import Foundation
import AppKit

/// Pipeline ponta a ponta: vídeo/áudio → áudio (.m4a) → chunks → Whisper →
/// correção GPT → arquivo `.txt` ao lado do original. Mantém a mesma estrutura
/// de saída do CLI Node (`backend/src/processTranscriptionJob.js`).
enum MediaTranscriptionPipeline {

    enum Step: CustomStringConvertible {
        case extractingAudio
        case preparingChunks(Int)
        case transcribingChunk(Int, Int)
        case correctingText
        case writingFile
        case done(URL)

        var description: String {
            switch self {
            case .extractingAudio:
                return "Extraindo áudio do vídeo..."
            case .preparingChunks(let n):
                return n <= 1
                    ? "Preparando áudio para envio..."
                    : "Dividindo áudio em \(n) partes..."
            case .transcribingChunk(let i, let total):
                return total <= 1
                    ? "Transcrevendo áudio..."
                    : "Transcrevendo parte \(i)/\(total)..."
            case .correctingText:
                return "Corrigindo e melhorando texto..."
            case .writingFile:
                return "Salvando transcrição..."
            case .done(let url):
                return "Transcrição salva: \(url.lastPathComponent)"
            }
        }
    }

    enum PipelineError: LocalizedError {
        case unsupported(String)
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .unsupported(let msg): return msg
            case .missingAPIKey:
                return "Chave da OpenAI não configurada. Defina em Configurações antes de transcrever."
            }
        }
    }

    // MARK: - Extração simples (vídeo → áudio .m4a ao lado do original)

    /// Apenas separa o áudio do vídeo, salva como `<nome>.m4a` ao lado do
    /// original (sobrescreve se já existir).
    @MainActor
    static func extractAudioOnly(
        for videoURL: URL,
        progress: @escaping (Step) -> Void = { _ in }
    ) async throws -> URL {
        guard MediaKind.of(videoURL) == .video else {
            throw PipelineError.unsupported(
                "Não é um vídeo suportado: .\(videoURL.pathExtension)"
            )
        }
        progress(.extractingAudio)
        let dst = videoURL.deletingPathExtension().appendingPathExtension("m4a")
        let result = try await AudioExtractor.extractAudio(from: videoURL, to: dst)
        progress(.done(result.url))
        return result.url
    }

    // MARK: - Pipeline completa (áudio ou vídeo → .txt ao lado)

    /// Roda o fluxo completo. Para vídeos, extrai o áudio numa pasta temporária
    /// (não polui a pasta do usuário com `.m4a`). O `.txt` é salvo ao lado do
    /// arquivo original com o mesmo nome, sobrescrevendo se já existir.
    @MainActor
    static func runFullTranscription(
        for sourceURL: URL,
        progress: @escaping (Step) -> Void = { _ in }
    ) async throws -> URL {
        let kind = MediaKind.of(sourceURL)
        guard kind == .audio || kind == .video else {
            throw PipelineError.unsupported(
                "Tipo de arquivo não suportado: .\(sourceURL.pathExtension)"
            )
        }

        let apiKey = ConfigStore.shared.openAIAPIKey
        guard !apiKey.isEmpty else { throw PipelineError.missingAPIKey }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexify_transcription_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Áudio de trabalho (extrai do vídeo se necessário, em pasta temp)
        //    Para .opus (WhatsApp) converte para .m4a via ffmpeg quando necessário
        //    para chunking, pois AVFoundation não lê OGG/Opus nativamente.
        let workingAudio: URL
        if kind == .video {
            progress(.extractingAudio)
            let tempAudio = tempDir.appendingPathComponent(
                sourceURL.deletingPathExtension().lastPathComponent + ".m4a"
            )
            let extracted = try await AudioExtractor.extractAudio(from: sourceURL, to: tempAudio)
            workingAudio = extracted.url
        } else if sourceURL.pathExtension.lowercased() == "opus" {
            let sizeMB = AudioExtractor.fileSizeMB(sourceURL)
            if sizeMB > AudioExtractor.whisperMaxSizeMB {
                progress(.extractingAudio)
                let converted = try await AudioExtractor.convertOpusToM4A(
                    opusURL: sourceURL,
                    outputDir: tempDir
                )
                workingAudio = converted
            } else {
                workingAudio = sourceURL
            }
        } else {
            workingAudio = sourceURL
        }

        // 2. Chunks (só divide se passar do limite Whisper)
        let sizeMB = AudioExtractor.fileSizeMB(workingAudio)
        let chunks: [URL]
        if sizeMB > AudioExtractor.whisperMaxSizeMB {
            chunks = try await AudioExtractor.splitIntoChunks(
                audioURL: workingAudio,
                chunkSeconds: AudioExtractor.defaultChunkSeconds,
                tempDir: tempDir
            )
            progress(.preparingChunks(chunks.count))
        } else {
            chunks = [workingAudio]
            progress(.preparingChunks(1))
        }

        // 3. Transcrição
        let result = try await WhisperTranscriptionService.transcribeChunks(
            chunks,
            apiKey: apiKey,
            chunkDurationSeconds: AudioExtractor.defaultChunkSeconds,
            progress: { i, total in
                Task { @MainActor in
                    progress(.transcribingChunk(min(i + 1, total), total))
                }
            }
        )

        // 4. Correção (best-effort: nunca falha o pipeline)
        progress(.correctingText)
        let correctedText = await WhisperTranscriptionService.correctText(
            result.text,
            apiKey: apiKey
        )

        // 5. Saída .txt ao lado do original (sobrescreve)
        progress(.writingFile)
        let destURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("txt")

        let txt = formatTxt(
            originalURL: sourceURL,
            result: result,
            correctedText: correctedText
        )
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try txt.write(to: destURL, atomically: true, encoding: .utf8)

        progress(.done(destURL))
        return destURL
    }

    // MARK: - Formatação .txt (paridade com fileManager.js do projeto original)

    private static func formatTxt(
        originalURL: URL,
        result: WhisperResult,
        correctedText: String
    ) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: originalURL.path)) ?? [:]
        let bytes = (attrs[.size] as? NSNumber)?.doubleValue ?? 0
        let sizeMB = bytes / 1_048_576

        let dateStr: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "pt_BR")
            f.dateStyle = .medium
            f.timeStyle = .medium
            return f.string(from: Date())
        }()

        var out = "TRANSCRIÇÃO DE ÁUDIO\n"
        out += "Arquivo original: \(originalURL.lastPathComponent)\n"
        out += "Data de processamento: \(dateStr)\n"
        out += String(format: "Tamanho do arquivo: %.2f MB\n", sizeMB)
        out += "Duração: \(formatTime(result.duration))\n\n"

        out += "=== TRANSCRIÇÃO ORIGINAL ===\n"
        out += result.text + "\n\n"

        if !correctedText.isEmpty, correctedText != result.text {
            out += "=== TRANSCRIÇÃO CORRIGIDA E MELHORADA ===\n"
            out += correctedText + "\n\n"
        }

        if !result.segments.isEmpty {
            out += "=== TIMESTAMPS DETALHADOS ===\n"
            for seg in result.segments {
                out += "[\(formatTime(seg.start)) - \(formatTime(seg.end))] \(seg.text)\n"
            }
        }
        return out
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
