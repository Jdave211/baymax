import Foundation

final class OpenAIClient: @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = "https://api.openai.com/v1"

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Chat Completion (Vision)

    func chatCompletion(
        systemPrompt: String,
        userContent: [[String: Any]],
        jsonMode: Bool = false
    ) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
            "max_completion_tokens": 4096,
        ]

        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BaymaxError.networkError("Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw BaymaxError.apiError(http.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw BaymaxError.parseError("Could not parse chat response")
        }

        return content
    }

    // MARK: - Text to Speech

    func textToSpeech(text: String, voice: String = "alloy") async throws -> Data {
        let url = URL(string: "\(baseURL)/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "aac",
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.apiError(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                "TTS request failed"
            )
        }

        return data
    }

    // MARK: - Speech To Text

    func transcribeAudio(fileURL: URL, model: String = "gpt-4o-mini-transcribe") async throws -> String {
        do {
            return try await transcribeAudioAttempt(fileURL: fileURL, model: model)
        } catch {
            guard model != "whisper-1", shouldFallbackTranscription(error) else {
                throw error
            }
            print("[Baymax] STT model \(model) failed, retrying with whisper-1: \(error.localizedDescription)")
            return try await transcribeAudioAttempt(fileURL: fileURL, model: "whisper-1")
        }
    }

    private func transcribeAudioAttempt(fileURL: URL, model: String) async throws -> String {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(mimeType(for: fileURL))\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        request.httpBody = body
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "Transcription failed")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String else {
            throw BaymaxError.parseError("Could not parse transcription response")
        }

        return text
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "ogg":
            return "audio/ogg"
        default:
            return "application/octet-stream"
        }
    }

    private func shouldFallbackTranscription(_ error: Error) -> Bool {
        guard let baymaxError = error as? BaymaxError else { return false }
        switch baymaxError {
        case .apiError(let code, let message):
            let lower = message.lowercased()
            return code == 400
                || code == 401
                || code == 404
                || code == 429
                || (500...599).contains(code)
                || lower.contains("model")
                || lower.contains("not found")
                || lower.contains("unsupported")
        case .networkError:
            return true
        case .parseError:
            return true
        default:
            return false
        }
    }
}

// MARK: - Errors

enum BaymaxError: LocalizedError {
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)
    case noDisplay
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .noDisplay: return "No display available for capture"
        case .noApiKey: return "OpenAI API key not set"
        }
    }
}
