import Foundation
import CoreGraphics

final class AIService: @unchecked Sendable {
    private let provider: LLMProvider
    private let apiKey: String

    static let openAIModel      = "gpt-4o-mini"
    static let anthropicModel   = "claude-3-5-sonnet-20241022"
    static let geminiModel      = "gemini-1.5-flash"

    init(provider: LLMProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    // MARK: - Conversational Chat (with history)

    func chat(messages history: [[String: Any]], systemPrompt: String) async throws -> String {
        switch provider {
        case .openai:
            return try await openAIChat(system: systemPrompt, messages: history)
        case .anthropic:
            return try await anthropicChat(system: systemPrompt, messages: history)
        case .gemini:
            return try await geminiChat(system: systemPrompt, messages: history)
        case .deepseek:
            return try await openAIChat(system: systemPrompt, messages: history, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }
    }

    // MARK: - Vision (screen analysis)

    func analyzeScreen(screenshot: CGImage, question: String, screenSize: CGSize) async throws -> TeachingPlan {
        let base64 = screenshot.jpegBase64(quality: 0.5)

        let systemPrompt = """
        You are Baymax — a warm, casual on-screen teaching buddy for macOS. \
        You talk to the user like a friend showing them how to do something on their computer. \
        You can see their screen and you'll guide them step-by-step.

        TASK: Look at this screenshot and help the user with their question. \
        Create a step-by-step plan with precise screen coordinates.

        Screenshot is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin (0,0 = top-left).

        Respond ONLY with valid JSON (no markdown block, just raw JSON) in this schema:
        {
          "app_name": "Name of the app on screen",
          "greeting": "A casual 1-sentence spoken greeting",
          "steps": [
            {
              "instruction": "What you SAY aloud — conversational, 1-2 sentences.",
              "label": "Short 2-4 word on-screen label (e.g. 'over here!', 'this one!')",
              "target_x": 500,
              "target_y": 300,
              "action": "click",
              "highlight_x": 450,
              "highlight_y": 260,
              "highlight_width": 120,
              "highlight_height": 80
            }
          ]
        }
        """

        let userContent: [[String: Any]] = [
            ["type": "text", "text": question],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "auto"]]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent)
        case .anthropic:
            jsonString = try await anthropicVision(system: systemPrompt, question: question, base64: base64)
        case .gemini:
            jsonString = try await geminiVision(system: systemPrompt, question: question, base64: base64)
        case .deepseek:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }

        let cleanJSON = jsonString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid string data")
        }

        return try JSONDecoder().decode(TeachingPlan.self, from: data)
    }

    // MARK: - OpenAI Chat

    private func openAIChat(system: String, messages: [[String: Any]], baseURL: String = "https://api.openai.com/v1", model: String = openAIModel) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var allMessages: [[String: Any]] = [["role": "system", "content": system]]
        allMessages.append(contentsOf: messages)

        let body: [String: Any] = [
            "model": model,
            "messages": allMessages,
            "max_tokens": 512
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.networkError("API Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return content
    }

    // MARK: - OpenAI Vision

    private func openAIVision(system: String, userContent: [[String: Any]], baseURL: String = "https://api.openai.com/v1", model: String = openAIModel) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 2048,
            "response_format": ["type": "json_object"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.networkError("API Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return content
    }

    // MARK: - Anthropic

    private func anthropicChat(system: String, messages: [[String: Any]]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": Self.anthropicModel,
            "system": system,
            "max_tokens": 512,
            "messages": messages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.networkError("Anthropic Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let contentArr = json?["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return text
    }

    private func anthropicVision(system: String, question: String, base64: String) async throws -> String {
        let messages: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                ["type": "text", "text": question]
            ]]
        ]
        return try await anthropicChat(system: system, messages: messages)
    }

    // MARK: - Gemini

    private func geminiChat(system: String, messages: [[String: Any]]) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Convert OpenAI-style messages to Gemini format
        let contents: [[String: Any]] = messages.map { msg in
            let role = (msg["role"] as? String) == "assistant" ? "model" : "user"
            return ["role": role, "parts": [["text": msg["content"] as? String ?? ""]]]
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.networkError("Gemini Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return text
    }

    private func geminiVision(system: String, question: String, base64: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [
                ["parts": [
                    ["text": question],
                    ["inline_data": ["mime_type": "image/jpeg", "data": base64]]
                ]]
            ],
            "generationConfig": ["responseMimeType": "application/json"]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BaymaxError.networkError("Gemini Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return text
    }
}
