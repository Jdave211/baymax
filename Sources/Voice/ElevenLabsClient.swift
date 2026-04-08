import Foundation

final class ElevenLabsClient: @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = "https://api.elevenlabs.io/v1"

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Converts text to speech using ElevenLabs API. Returns raw MP3 audio data.
    func textToSpeech(
        text: String,
        voiceId: String = "21m00Tcm4TlvDq8ikWAM",
        modelId: String = "eleven_flash_v2_5"
    ) async throws -> Data {
        let url = URL(string: "\(baseURL)/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.4,
                "similarity_boost": 0.8,
                "style": 0.35,
                "use_speaker_boost": true,
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw BaymaxError.apiError(status, "ElevenLabs TTS failed: \(msg)")
        }

        return data
    }
}
