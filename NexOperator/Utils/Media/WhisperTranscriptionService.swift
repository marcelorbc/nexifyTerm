import Foundation

struct WhisperSegment {
    let start: Double
    let end: Double
    let text: String
}

struct WhisperResult {
    let text: String
    let duration: Double
    let segments: [WhisperSegment]
}

/// Cliente para a API `audio/transcriptions` da OpenAI (Whisper) + correção
/// de texto via Chat Completions. Reusa `LLMSession.shared` da app.
///
/// Pareia com `backend/src/transcriptionService.js` do projeto `audio_transcript`.
enum WhisperTranscriptionService {

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case requestFailed(Int, String)
        case invalidResponse
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Chave da OpenAI não configurada. Defina em Configurações."
            case .requestFailed(let code, let body):
                return "Whisper falhou (HTTP \(code)): \(body)"
            case .invalidResponse:
                return "Resposta inválida da API Whisper."
            case .readFailed(let path):
                return "Falha ao ler arquivo de áudio: \(path)"
            }
        }
    }

    static let defaultTranscribeModel = "whisper-1"
    static let defaultLanguage = "pt"

    // MARK: - Transcrição

    /// Transcreve um único arquivo de áudio (deve estar abaixo de 25MB).
    static func transcribeFile(
        _ url: URL,
        apiKey: String,
        model: String = defaultTranscribeModel,
        language: String = defaultLanguage
    ) async throws -> WhisperResult {
        guard !apiKey.isEmpty else { throw ServiceError.missingAPIKey }

        let endpoint = AppConfig.OpenAI.baseURL + "/audio/transcriptions"
        guard let endpointURL = URL(string: endpoint) else {
            throw ServiceError.invalidResponse
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            throw ServiceError.readFailed(url.path)
        }

        let boundary = "----NexifyTermBoundary\(UUID().uuidString)"
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.appendField(name: "model", value: model, boundary: boundary)
        body.appendField(name: "language", value: language, boundary: boundary)
        body.appendField(name: "response_format", value: "verbose_json", boundary: boundary)
        if model == "whisper-1" {
            body.appendField(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
        }
        body.appendFile(
            name: "file",
            filename: uploadFilename(for: url),
            mimeType: mimeType(for: url),
            data: fileData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        let (data, response) = try await LLMSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 { throw ServiceError.missingAPIKey }
            throw ServiceError.requestFailed(http.statusCode, String(bodyText.prefix(2000)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.invalidResponse
        }

        let text = (json["text"] as? String) ?? ""
        let duration = (json["duration"] as? Double) ?? 0

        let segments: [WhisperSegment]
        if let raw = json["segments"] as? [[String: Any]] {
            segments = raw.compactMap { seg in
                guard let start = seg["start"] as? Double,
                      let end = seg["end"] as? Double,
                      let text = seg["text"] as? String else { return nil }
                return WhisperSegment(
                    start: start,
                    end: end,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } else {
            segments = []
        }

        return WhisperResult(text: text, duration: duration, segments: segments)
    }

    /// Transcreve múltiplos chunks aplicando offsets de tempo (mesma lógica do
    /// `transcribeChunks` do CLI original).
    static func transcribeChunks(
        _ urls: [URL],
        apiKey: String,
        model: String = defaultTranscribeModel,
        language: String = defaultLanguage,
        chunkDurationSeconds: Double = AudioExtractor.defaultChunkSeconds,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> WhisperResult {
        guard !urls.isEmpty else {
            return WhisperResult(text: "", duration: 0, segments: [])
        }

        var fullText = ""
        var allSegments: [WhisperSegment] = []
        var totalDuration: Double = 0

        for (i, chunkURL) in urls.enumerated() {
            progress?(i, urls.count)
            let r = try await transcribeFile(
                chunkURL,
                apiKey: apiKey,
                model: model,
                language: language
            )
            let offset = Double(i) * chunkDurationSeconds
            fullText += (fullText.isEmpty ? "" : " ") + r.text

            for seg in r.segments {
                allSegments.append(
                    WhisperSegment(start: seg.start + offset, end: seg.end + offset, text: seg.text)
                )
            }
            totalDuration = offset + (r.duration > 0 ? r.duration : 0)
        }
        progress?(urls.count, urls.count)

        return WhisperResult(text: fullText, duration: totalDuration, segments: allSegments)
    }

    // MARK: - Correção via GPT

    /// Pede ao modelo configurado para corrigir/melhorar a transcrição. Em caso
    /// de erro, devolve o texto original — espelhando a tolerância a falha do CLI.
    static func correctText(
        _ text: String,
        apiKey: String,
        model: String? = nil
    ) async -> String {
        guard !text.isEmpty, !apiKey.isEmpty else { return text }
        let chatModel = model ?? AppConfig.OpenAI.defaultModel
        let maxChunkSize = 12_000

        do {
            if text.count <= maxChunkSize {
                return try await correctSingle(text, apiKey: apiKey, model: chatModel)
            }
            let chunks = splitTextForCorrection(text, maxSize: maxChunkSize)
            var parts: [String] = []
            parts.reserveCapacity(chunks.count)
            for chunk in chunks {
                parts.append(try await correctSingle(chunk, apiKey: apiKey, model: chatModel))
            }
            return parts.joined(separator: "\n\n")
        } catch {
            NexLog.ai.warning("Correção da transcrição falhou: \(error.localizedDescription)")
            return text
        }
    }

    private static func correctSingle(
        _ text: String,
        apiKey: String,
        model: String
    ) async throws -> String {
        let endpoint = AppConfig.OpenAI.baseURL + AppConfig.OpenAI.chatEndpoint
        guard let url = URL(string: endpoint) else { throw ServiceError.invalidResponse }

        let systemPrompt = "Você é um especialista em correção de texto em português brasileiro. " +
            "Corrija e melhore transcrições de áudio mantendo o sentido original."

        let userPrompt = """
        Você é um especialista em correção de texto em português brasileiro.
        Sua tarefa é corrigir e melhorar a transcrição de áudio fornecida, mantendo o sentido original.

        INSTRUÇÕES:
        1. Corrija erros de transcrição, gramática e ortografia
        2. Melhore a fluidez e clareza do texto
        3. Mantenha o tom e estilo original
        4. Preserve informações importantes e detalhes técnicos
        5. Organize o texto em parágrafos quando apropriado
        6. Mantenha o texto em português brasileiro

        TEXTO PARA CORRIGIR:
        \(text)

        TEXTO CORRIGIDO:
        """

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]

        // Modelos de raciocínio (gpt-5.x) preferem reasoning_effort em vez de temperature.
        let caps = ProviderType.capabilities(for: model)
        if caps.supportsReasoning {
            payload["reasoning_effort"] = "low"
            payload.removeValue(forKey: "temperature")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await LLMSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 { throw ServiceError.missingAPIKey }
            throw ServiceError.requestFailed(http.statusCode, String(body.prefix(2000)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ServiceError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitTextForCorrection(_ text: String, maxSize: Int) -> [String] {
        // Split por sentenças (.!?) seguindo a heurística do CLI Node.
        let pattern = #"(?<=[.!?])\s+"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        var sentences: [String] = []
        var lastEnd = 0
        if let regex {
            let matches = regex.matches(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
            )
            for match in matches {
                let part = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                sentences.append(part)
                lastEnd = match.range.location + match.range.length
            }
            if lastEnd < nsText.length {
                sentences.append(nsText.substring(from: lastEnd))
            }
        } else {
            sentences = [text]
        }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count > maxSize, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = sentence
            } else {
                current = candidate
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks.isEmpty ? [text] : chunks
    }

    // MARK: - Helpers

    /// Whisper API rejects `.opus` extension. WhatsApp opus files are OGG-Opus
    /// containers, so renaming to `.ogg` makes the API accept them as-is.
    private static func uploadFilename(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "opus" {
            return url.deletingPathExtension().lastPathComponent + ".ogg"
        }
        return url.lastPathComponent
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "mpga", "mpeg": return "audio/m4a"
        case "mp3":                          return "audio/mpeg"
        case "wav":                          return "audio/wav"
        case "ogg", "oga", "opus":           return "audio/ogg"
        case "flac":                         return "audio/flac"
        case "aac":                          return "audio/aac"
        case "webm":                         return "audio/webm"
        case "aiff", "aif":                  return "audio/aiff"
        default:                             return "application/octet-stream"
        }
    }
}

// MARK: - multipart helpers

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }

    mutating func appendField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
