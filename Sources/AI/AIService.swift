import Foundation
import CoreGraphics

final class AIService: @unchecked Sendable {
    private let provider: LLMProvider
    private let apiKey: String

    static let openAIRealtimeModel = "gpt-realtime-1.5"
    static let openAIChatModel  = "gpt-4o-mini"
    static let openAIInferenceModel = "gpt-5.4-mini"
    static let openAISearchModel = openAIInferenceModel
    static let openAIStructuredModel = openAIInferenceModel
    static let anthropicModel   = "claude-3-5-sonnet-20241022"
    static let geminiModel      = "gemini-1.5-flash"
    private let analysisMaxDimension: CGFloat = 1280

    init(provider: LLMProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    // MARK: - Conversational Chat (with history)

    func chat(messages history: [[String: Any]], systemPrompt: String) async throws -> String {
        switch provider {
        case .openai:
            return try await openAIChat(system: systemPrompt, messages: history, model: Self.openAIChatModel)
        case .anthropic:
            return try await anthropicChat(system: systemPrompt, messages: history)
        case .gemini:
            return try await geminiChat(system: systemPrompt, messages: history)
        case .deepseek:
            return try await openAIChat(system: systemPrompt, messages: history, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }
    }

    // MARK: - One-Shot Tutorial Planning

    func planTutorialSession(
        screenshot: CGImage,
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil
    ) async throws -> TutorialPlan {
        let preparedImage = preparedAnalysisImage(from: screenshot)
        let base64 = try encodeVisionImageBase64(preparedImage.image, quality: 0.35)
        logScreenshotPayload(route: "planTutorialSession", base64Length: base64.count, screenSize: screenSize)
        let systemPrompt = tutorialPlanSystemPrompt(
            screenSize: screenSize,
            additionalContext: preparedImage.additionalContext,
            conversationContext: conversationContext
        )
        let contextBlock = conversationContextBlock(conversationContext)

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": [question, contextBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "low"]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIStructuredVisionJSON(
                instructions: systemPrompt,
                userContent: userContent,
                schemaName: "tutorial_plan",
                schema: Self.tutorialPlanSchema(),
                maxOutputTokens: 1024,
            )
        case .anthropic:
            jsonString = try await anthropicVision(system: systemPrompt, userText: [question, contextBlock].filter { !$0.isEmpty }.joined(separator: "\n\n"), base64: base64)
        case .gemini:
            jsonString = try await geminiVision(system: systemPrompt, userText: [question, contextBlock].filter { !$0.isEmpty }.joined(separator: "\n\n"), base64: base64)
        case .deepseek:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }

        let cleanJSON = normalizeJSONText(jsonString)

        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid tutorial plan JSON data")
        }

        return try JSONDecoder().decode(TutorialPlan.self, from: data)
    }

    func planTutorialSessionTextOnly(
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil
    ) async throws -> TutorialPlan {
        let systemPrompt = textOnlyTutorialPlanSystemPrompt(
            screenSize: screenSize,
            conversationContext: conversationContext
        )
        let contextBlock = conversationContextBlock(conversationContext)
        let userText = [question, contextBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": userText]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIResponsesJSON(
                instructions: systemPrompt,
                userContent: userContent,
                schemaName: "tutorial_plan_text_only",
                schema: Self.tutorialPlanSchema(),
                maxOutputTokens: 1024,
                model: Self.openAIStructuredModel
            )
        case .anthropic:
            jsonString = try await anthropicChat(
                system: systemPrompt,
                messages: [["role": "user", "content": userText]]
            )
        case .gemini:
            jsonString = try await geminiChat(
                system: systemPrompt,
                messages: [["role": "user", "content": userText]]
            )
        case .deepseek:
            jsonString = try await openAIChat(
                system: systemPrompt,
                messages: [["role": "user", "content": userText]],
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat"
            )
        }

        let cleanJSON = normalizeJSONText(jsonString)
        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid text-only tutorial plan JSON data")
        }
        return try JSONDecoder().decode(TutorialPlan.self, from: data)
    }

    // MARK: - Vision (screen analysis)

    func analyzeScreen(
        screenshot: CGImage,
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil,
        researchContext: String? = nil
    ) async throws -> TeachingPlan {
        let preparedImage = preparedAnalysisImage(from: screenshot)
        let base64 = try encodeVisionImageBase64(preparedImage.image, quality: 0.35)
        logScreenshotPayload(route: "analyzeScreen", base64Length: base64.count, screenSize: screenSize)
        let systemPrompt = teachingPlanSystemPrompt(
            screenSize: screenSize,
            additionalContext: preparedImage.additionalContext,
            conversationContext: conversationContext,
            researchContext: researchContext
        )
        let contextBlock = conversationContextBlock(conversationContext)
        let researchBlock = researchContextBlock(researchContext)

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": [question, contextBlock, researchBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "low"]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIStructuredVisionJSON(
                instructions: systemPrompt,
                userContent: userContent,
                schemaName: "teaching_plan",
                schema: Self.teachingPlanSchema(),
                maxOutputTokens: 2048,
            )
        case .anthropic:
            jsonString = try await anthropicVision(system: systemPrompt, userText: question, base64: base64)
        case .gemini:
            jsonString = try await geminiVision(system: systemPrompt, userText: question, base64: base64)
        case .deepseek:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }

        let cleanJSON = normalizeJSONText(jsonString)

        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid string data")
        }

        return try JSONDecoder().decode(TeachingPlan.self, from: data)
    }

    func answerWithScreenshot(
        screenshot: CGImage,
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil
    ) async throws -> String {
        let preparedImage = preparedAnalysisImage(from: screenshot)
        let base64 = try encodeVisionImageBase64(preparedImage.image, quality: 0.35)
        logScreenshotPayload(route: "answerWithScreenshot", base64Length: base64.count, screenSize: screenSize)
        let contextBlock = conversationContextBlock(conversationContext)

        let systemPrompt = """
        You are Baymax — a concise macOS assistant.
        The screenshot is attached. Answer the user in 1-3 natural, direct sentences.
        If a specific control is visible, mention it clearly.
        If the screenshot does not show enough detail, say exactly what is missing.
        """

        let userText = [
            "User question:\n\(question)",
            contextBlock,
            "Screenshot size: \(Int(screenSize.width))×\(Int(screenSize.height))"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": userText],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "low"]
        ]

        switch provider {
        case .openai:
            return try await openAIVision(
                system: systemPrompt,
                userContent: userContent,
                model: Self.openAIInferenceModel
            )
        case .anthropic:
            return try await anthropicVision(system: systemPrompt, userText: userText, base64: base64)
        case .gemini:
            return try await geminiVision(system: systemPrompt, userText: userText, base64: base64)
        case .deepseek:
            return try await openAIVision(
                system: systemPrompt,
                userContent: userContent,
                baseURL: "https://api.deepseek.com/v1",
                model: "deepseek-chat"
            )
        }
    }

    func planTeachingSession(
        screenshot: CGImage,
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil,
        researchContext: String? = nil
    ) async throws -> PlannedTeachingSession {
        guard provider == .openai else {
            let plan = try await analyzeScreen(
                screenshot: screenshot,
                question: question,
                screenSize: screenSize,
                conversationContext: conversationContext,
                researchContext: researchContext
            )
            return PlannedTeachingSession(
                outline: Self.syntheticOutline(from: plan, taskSummary: question),
                plan: plan,
                needsResearch: false,
                researchHint: nil
            )
        }

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            print("[Baymax] Planning pass 1/1: rough outline...")
            let outline = try await draftTeachingOutline(
                screenshot: screenshot,
                question: question,
                screenSize: screenSize,
                conversationContext: conversationContext
            )
            print("[Baymax] ⏱ Outline: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
            print("[Baymax] Outline app: \(outline.appName) | needsResearch: \(outline.needsResearch) | steps: \(outline.steps.count)")
            if let hint = outline.researchHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                print("[Baymax] Outline research hint: \(hint)")
            }
            if outline.appName.lowercased().contains("xcode") {
                print("[Baymax] Xcode detected in outline — keeping extra attention on run/build/toolbar targets.")
            }

            let roughPlan = TeachingPlan(
                appName: outline.appName,
                greeting: outline.greeting,
                steps: outline.steps.map { $0.roughTeachingStep }
            )

            print("[Baymax] ⏱ Planning total: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
            print("[Baymax] Rough plan ready: \(roughPlan.steps.count) steps")

            return PlannedTeachingSession(
                outline: outline,
                plan: roughPlan,
                needsResearch: outline.needsResearch,
                researchHint: outline.researchHint
            )
        } catch {
            print("[Baymax] Rough planning failed: \(error.localizedDescription) — falling back to single-pass planning")
            let plan = try await analyzeScreen(
                screenshot: screenshot,
                question: question,
                screenSize: screenSize,
                conversationContext: conversationContext,
                researchContext: researchContext
            )
            return PlannedTeachingSession(
                outline: Self.syntheticOutline(from: plan, taskSummary: question),
                plan: plan,
                needsResearch: false,
                researchHint: nil
            )
        }
    }

    func validateStepProgress(
        screenshot: CGImage,
        question: String,
        plan: TeachingPlan,
        currentStepIndex: Int,
        screenSize: CGSize,
        conversationContext: String? = nil,
        researchContext: String? = nil
    ) async throws -> StepValidationResult {
        guard currentStepIndex < plan.steps.count else {
            throw BaymaxError.parseError("Current step index out of range")
        }

        let preparedImage = preparedAnalysisImage(from: screenshot)
        let base64 = try encodeVisionImageBase64(preparedImage.image, quality: 0.35)
        logScreenshotPayload(route: "validateStepProgress", base64Length: base64.count, screenSize: screenSize)
        let currentStepJSON = try stepJSONString(plan.steps[currentStepIndex])
        let nextStep = currentStepIndex + 1 < plan.steps.count ? plan.steps[currentStepIndex + 1] : nil
        let contextBlock = conversationContextBlock(conversationContext)
        let researchBlock = researchContextBlock(researchContext)

        let systemPrompt = """
        You are validating whether the user completed the current step in a Baymax guided macOS tutoring flow.
        Use the conversation context if it helps resolve pronouns, follow-up intent, or a task that was discussed earlier.
        Use the web research context if it helps resolve app-specific UI terms or the expected action.

        Return only raw JSON in this schema:
        {
          "decision": "next|done|replan",
          "message": "short casual spoken response",
          "next_step_index": 1
        }

        Rules:
        - Use next only when the current step is clearly complete and the existing plan should continue.
        - Use done when the task is fully finished or there are no meaningful steps left.
        - Use replan if the screenshot shows a different state, the action missed, or the current plan no longer fits.
        - If the current step is not clearly complete, choose replan.
        - If this is the last step in the plan, prefer done when the screen looks finished; only use replan if the task clearly failed or landed in a different state.
        - Keep the message short and conversational.
        - If decision is next, next_step_index should usually be \(currentStepIndex + 1).
        - The screenshot is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin.
        """

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": """
            User question:
            \(question)

            Conversation context:
            \(contextBlock)

            Web research context:
            \(researchBlock)

            Current step JSON:
            \(currentStepJSON)

            Next step label:
            \(nextStep?.label ?? "none")

            Current step index:
            \(currentStepIndex)

            Is current step the last step?
            \(currentStepIndex >= plan.steps.count - 1)
            """],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "low"]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIStructuredVisionJSON(
                instructions: systemPrompt,
                userContent: userContent,
                schemaName: "step_validation_result",
                schema: Self.stepValidationSchema(),
                maxOutputTokens: 768,
            )
        case .anthropic:
            jsonString = try await anthropicVision(system: systemPrompt, userText: """
            User question:
            \(question)

            \(contextBlock)

            Current step JSON:
            \(currentStepJSON)

            Next step label:
            \(nextStep?.label ?? "none")

            Current step index:
            \(currentStepIndex)

            Is current step the last step?
            \(currentStepIndex >= plan.steps.count - 1)
            """, base64: base64)
        case .gemini:
            jsonString = try await geminiVision(system: systemPrompt, userText: """
            User question:
            \(question)

            \(contextBlock)

            Current step JSON:
            \(currentStepJSON)

            Next step label:
            \(nextStep?.label ?? "none")

            Current step index:
            \(currentStepIndex)

            Is current step the last step?
            \(currentStepIndex >= plan.steps.count - 1)
            """, base64: base64)
        case .deepseek:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }

        let cleanJSON = normalizeJSONText(jsonString)

        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid validation JSON data")
        }

        return try JSONDecoder().decode(StepValidationResult.self, from: data)
    }

    func quickResearchContext(
        question: String,
        taskSummary: String? = nil,
        appName: String? = nil,
        researchHint: String? = nil
    ) async throws -> String {
        guard provider == .openai else { return "" }

        let systemPrompt = """
        You are Baymax's web research assistant.
        Give Baymax a compact context note that helps it understand the likely app, UI path, and exact labels to look for.
        If this seems generic enough that extra lookup would not help, say so briefly.
        Be concrete about app names, menu items, button labels, and exact UI terms the user is likely to see.
        Prefer the shortest reliable path.
        If the task is ambiguous, identify the most likely app or workflow and say so briefly.
        Output format:
        - likely app/context
        - likely UI path or control names
        - exact terms to look for on screen
        - warnings or uncertainty
        Do not include screen coordinates.
        Keep it under 120 words.
        """ 

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": """
            User task: \(question)

            First screenshot inference:
            \([
                appName.map { "Likely app/context: \($0)" },
                taskSummary.map { "Task summary: \($0)" },
                researchHint.map { "Research hint: \($0)" }
            ].compactMap { $0 }.joined(separator: "\n"))
            """]
        ]

        let text = try await openAIResponsesText(
            instructions: systemPrompt,
            userContent: userContent,
            maxOutputTokens: 512,
            model: Self.openAISearchModel
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func draftTeachingOutline(
        screenshot: CGImage,
        question: String,
        screenSize: CGSize,
        conversationContext: String? = nil
    ) async throws -> TeachingOutline {
        let preparedImage = preparedAnalysisImage(from: screenshot)
        let base64 = try encodeVisionImageBase64(preparedImage.image, quality: 0.33)
        logScreenshotPayload(route: "draftTeachingOutline", base64Length: base64.count, screenSize: screenSize)
        let systemPrompt = outlineSystemPrompt(
            screenSize: screenSize,
            additionalContext: preparedImage.additionalContext,
            conversationContext: conversationContext
        )
        let contextBlock = conversationContextBlock(conversationContext)

        let userContent: [[String: Any]] = [
            ["type": "input_text", "text": [question, contextBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)", "detail": "low"]
        ]

        let jsonString: String
        switch provider {
        case .openai:
            jsonString = try await openAIStructuredVisionJSON(
                instructions: systemPrompt,
                userContent: userContent,
                schemaName: "teaching_outline",
                schema: Self.teachingOutlineSchema(),
                maxOutputTokens: 1536,
            )
        case .anthropic:
            jsonString = try await anthropicVision(system: systemPrompt, userText: question, base64: base64)
        case .gemini:
            jsonString = try await geminiVision(system: systemPrompt, userText: question, base64: base64)
        case .deepseek:
            jsonString = try await openAIVision(system: systemPrompt, userContent: userContent, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        }

        let cleanJSON = normalizeJSONText(jsonString)

        guard let data = cleanJSON.data(using: .utf8) else {
            throw BaymaxError.parseError("Invalid outline JSON data")
        }

        return try JSONDecoder().decode(TeachingOutline.self, from: data)
    }

    // MARK: - OpenAI Chat

    private func openAIChat(system: String, messages: [[String: Any]], baseURL: String = "https://api.openai.com/v1", model: String = openAIChatModel) async throws -> String {
        do {
            return try await openAIChatAttempt(system: system, messages: messages, baseURL: baseURL, model: model)
        } catch {
            let isOfficialOpenAIAPI = baseURL.contains("api.openai.com")
            guard isOfficialOpenAIAPI, model != Self.openAIChatModel, shouldFallbackForOpenAI(error) else { throw error }
            print("[Baymax] OpenAI chat model \(model) failed, falling back to \(Self.openAIChatModel): \(error.localizedDescription)")
            return try await openAIChatAttempt(system: system, messages: messages, baseURL: baseURL, model: Self.openAIChatModel)
        }
    }

    private func openAIChatAttempt(system: String, messages: [[String: Any]], baseURL: String, model: String) async throws -> String {
        logModelUsage(provider: "openai-chat", model: model, route: "\(baseURL)/chat/completions")
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
        let responseModel = json?["model"] as? String
        logModelAck(provider: "openai-chat", requestedModel: model, acknowledgedModel: responseModel)
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return content
    }

    private func openAIVision(
        system: String,
        userContent: [[String: Any]],
        baseURL: String = "https://api.openai.com/v1",
        model: String = openAIChatModel
    ) async throws -> String {
        logModelUsage(provider: "openai-vision", model: model, route: "\(baseURL)/chat/completions")
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": chatCompletionVisionContent(from: userContent)]
            ],
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BaymaxError.networkError("Invalid response")
        }

        guard http.statusCode == 200 else {
            throw BaymaxError.networkError("API Error: \(String(data: data, encoding: .utf8) ?? "")")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let responseModel = json?["model"] as? String
        logModelAck(provider: "openai-vision", requestedModel: model, acknowledgedModel: responseModel)
        guard let choices = json?["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw BaymaxError.parseError("Invalid response format")
        }
        return content
    }

    private func chatCompletionVisionContent(from userContent: [[String: Any]]) -> [[String: Any]] {
        userContent.compactMap { item in
            guard let type = item["type"] as? String else { return item }

            switch type {
            case "input_text":
                let text = (item["text"] as? String) ?? ""
                return ["type": "text", "text": text]
            case "input_image":
                if let rawURL = item["image_url"] as? String {
                    let detail = (item["detail"] as? String) ?? "auto"
                    return [
                        "type": "image_url",
                        "image_url": [
                            "url": rawURL,
                            "detail": detail
                        ]
                    ]
                }
                if let imageURL = item["image_url"] as? [String: Any] {
                    return [
                        "type": "image_url",
                        "image_url": imageURL
                    ]
                }
                return nil
            default:
                return item
            }
        }
    }

    // MARK: - OpenAI Responses

    private func openAIResponsesText(
        instructions: String,
        userContent: [[String: Any]],
        tools: [[String: Any]] = [],
        maxOutputTokens: Int = 2048,
        model: String = openAIRealtimeModel
    ) async throws -> String {
        do {
            return try await openAIResponsesTextAttempt(
                instructions: instructions,
                userContent: userContent,
                tools: tools,
                maxOutputTokens: maxOutputTokens,
                model: model
            )
        } catch {
            guard model != Self.openAIChatModel, shouldFallbackForOpenAI(error) else { throw error }
            print("[Baymax] OpenAI text model \(model) failed, falling back to \(Self.openAIChatModel): \(error.localizedDescription)")
            return try await openAIResponsesTextAttempt(
                instructions: instructions,
                userContent: userContent,
                tools: tools,
                maxOutputTokens: maxOutputTokens,
                model: Self.openAIChatModel
            )
        }
    }

    private func openAIResponsesJSON(
        instructions: String,
        userContent: [[String: Any]],
        schemaName: String,
        schema: [String: Any],
        maxOutputTokens: Int = 2048,
        model: String = openAIRealtimeModel
    ) async throws -> String {
        do {
            return try await openAIResponsesJSONAttempt(
                instructions: instructions,
                userContent: userContent,
                schemaName: schemaName,
                schema: schema,
                maxOutputTokens: maxOutputTokens,
                model: model
            )
        } catch {
            guard model != Self.openAIChatModel, shouldFallbackForOpenAI(error) else { throw error }
            print("[Baymax] OpenAI structured model \(model) failed, falling back to \(Self.openAIChatModel): \(error.localizedDescription)")
            return try await openAIResponsesJSONAttempt(
                instructions: instructions,
                userContent: userContent,
                schemaName: schemaName,
                schema: schema,
                maxOutputTokens: maxOutputTokens,
                model: Self.openAIChatModel
            )
        }
    }

    private func openAIStructuredVisionJSON(
        instructions: String,
        userContent: [[String: Any]],
        schemaName: String,
        schema: [String: Any],
        maxOutputTokens: Int
    ) async throws -> String {
        do {
            return try await openAIResponsesJSON(
                instructions: instructions,
                userContent: userContent,
                schemaName: schemaName,
                schema: schema,
                maxOutputTokens: maxOutputTokens,
                model: Self.openAIStructuredModel
            )
        } catch {
            print("[Baymax] Responses structured vision failed (\(schemaName)); retrying with chat/completions vision: \(error.localizedDescription)")
            let fallbackInstructions = """
            \(instructions)

            Return ONLY raw JSON matching the required schema.
            """
            return try await openAIVision(
                system: fallbackInstructions,
                userContent: userContent,
                model: Self.openAIInferenceModel
            )
        }
    }

    private func openAIResponsesTextAttempt(
        instructions: String,
        userContent: [[String: Any]],
        tools: [[String: Any]],
        maxOutputTokens: Int,
        model: String
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                ["role": "user", "content": userContent]
            ],
            "max_output_tokens": maxOutputTokens,
            "text": ["verbosity": "low"]
        ]

        if model != Self.openAIRealtimeModel {
            body["reasoning"] = ["effort": "low"]
        }

        if !tools.isEmpty {
            body["tools"] = tools
        }

        let data = try await openAIResponsesBody(body)
        try ensureResponseCompleted(data)
        return try extractResponseText(from: data)
    }

    private func openAIResponsesJSONAttempt(
        instructions: String,
        userContent: [[String: Any]],
        schemaName: String,
        schema: [String: Any],
        maxOutputTokens: Int,
        model: String
    ) async throws -> String {
        if model == Self.openAIRealtimeModel {
            let body: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "input": [
                    ["role": "user", "content": userContent]
                ],
                "max_output_tokens": maxOutputTokens,
                "text": ["verbosity": "low"]
            ]

            let data = try await openAIResponsesBody(body)
            try ensureResponseCompleted(data)
            return try extractResponseText(from: data)
        }

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                ["role": "user", "content": userContent]
            ],
            "max_output_tokens": maxOutputTokens,
            "reasoning": ["effort": "low"],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]

        let data = try await openAIResponsesBody(body)
        try ensureResponseCompleted(data)
        return try extractResponseText(from: data)
    }

    private func openAIResponsesBody(_ body: [String: Any]) async throws -> Data {
        let model = (body["model"] as? String) ?? "unknown"
        logModelUsage(provider: "openai-responses", model: model, route: "https://api.openai.com/v1/responses")
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BaymaxError.networkError("Invalid response")
        }

        guard http.statusCode == 200 else {
            throw BaymaxError.networkError("API Error (\(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "")")
        }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let acknowledged = (root["model"] as? String) ?? (root["model_name"] as? String)
            logModelAck(provider: "openai-responses", requestedModel: model, acknowledgedModel: acknowledged)
        }

        return data
    }

    private func shouldFallbackForOpenAI(_ error: Error) -> Bool {
        guard let baymaxError = error as? BaymaxError else { return false }
        switch baymaxError {
        case .networkError(let msg):
            let lower = msg.lowercased()
            return lower.contains("api error")
                || lower.contains("insufficient_quota")
                || lower.contains("billing")
                || lower.contains("rate limit")
                || lower.contains("invalid_api_key")
                || lower.contains("unauthorized")
                || lower.contains("model_not_found")
                || lower.contains("does not exist")
                || lower.contains("not found")
        case .apiError(let code, _):
            return (400...599).contains(code)
        case .parseError:
            return true
        default:
            return false
        }
    }

    private func extractResponseText(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data)
        if let root = json as? [String: Any] {
            if let text = root["output_text"] as? String {
                return text
            }
            if let parsed = root["output_parsed"] {
                return stringifyJSONValue(parsed)
            }
        }

        let texts = collectResponseText(from: json)
        guard !texts.isEmpty else {
            throw BaymaxError.parseError("Could not parse response text")
        }
        return texts.joined(separator: "\n")
    }

    private func normalizeJSONText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.first == "{", trimmed.last == "}" {
            return trimmed
        }

        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        if let start = trimmed.firstIndex(of: "["),
           let end = trimmed.lastIndex(of: "]") {
            return String(trimmed[start...end])
        }

        return trimmed
    }

    private func collectResponseText(from object: Any) -> [String] {
        if let string = object as? String {
            return [string]
        }

        if let dict = object as? [String: Any] {
            if let outputText = dict["output_text"] as? String {
                return [outputText]
            }

            if let type = dict["type"] as? String {
                if type == "output_text", let text = dict["text"] as? String {
                    return [text]
                }

                if type == "output_json", let json = dict["json"] {
                    return [stringifyJSONValue(json)]
                }

                if type == "message" {
                    if let content = dict["content"] {
                        return collectResponseText(from: content)
                    }
                    return []
                }
            }

            if let text = dict["text"] as? String {
                return [text]
            }

            var texts: [String] = []
            for key in ["output", "items", "messages", "content", "output_parsed", "json", "arguments"] {
                if let value = dict[key] {
                    texts.append(contentsOf: collectResponseText(from: value))
                }
            }
            return texts
        }

        if let array = object as? [Any] {
            return array.flatMap { collectResponseText(from: $0) }
        }

        return []
    }

    private func stringifyJSONValue(_ value: Any) -> String {
        if let text = value as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let data = try? JSONSerialization.data(withJSONObject: ["value": value], options: []),
           let wrapped = String(data: data, encoding: .utf8),
           let start = wrapped.firstIndex(of: ":"),
           let end = wrapped.lastIndex(of: "}") {
            return wrapped[wrapped.index(after: start)..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
        }

        return "\(value)"
    }

    private func encodeVisionImageBase64(_ image: CGImage, quality: CGFloat) throws -> String {
        let base64 = image.jpegBase64(quality: quality)
        guard !base64.isEmpty else {
            throw BaymaxError.parseError("Screenshot encoding failed before AI request")
        }
        return base64
    }

    private func ensureResponseCompleted(_ data: Data) throws {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = root["status"] as? String,
            status != "completed"
        else {
            return
        }

        let reason = (root["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown"
        throw BaymaxError.apiError(200, "Responses API returned status '\(status)' (\(reason))")
    }

    private func outlineSystemPrompt(
        screenSize: CGSize,
        additionalContext: String? = nil,
        conversationContext: String? = nil
    ) -> String {
        let contextNote = conversationContextBlock(conversationContext)

        return """
        You are Baymax — pass 1 of 3.
        Look at the screenshot and conversation context to figure out what the user needs to do.
        Produce a rough task outline, not final coordinates.
        Also decide whether web research is needed at all for this task. If the screenshot and user request already give enough context, set needs_research to false.
        If the task depends on app-specific UI, recent docs, or changing menu/button labels, set needs_research to true and add a short research_hint.
        Keep each step focused on one likely actionable control.
        Use rough_target_x / rough_target_y as an approximate center of the control when you can estimate it.
        If you cannot estimate exact pixels, give your best rough region and keep it honest.
        Do not invent controls that are not visibly present.
        For close/dismiss tasks, identify the likely close affordance in the chrome or tab bar.
        For build/run tasks, identify the likely run/build control or relevant menu item.

        Screenshot is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin.
        \(contextNote.isEmpty ? "" : "\n\(contextNote)\n")
        \(additionalContext.map { "\n\($0)\n" } ?? "")

        Return only valid JSON in this schema:
        {
          "app_name": "Name of the app on screen",
          "greeting": "A casual 1-sentence spoken greeting",
          "task_summary": "Short summary of the task",
          "needs_research": true,
          "research_hint": "optional note about what to search for",
          "steps": [
            {
              "instruction": "What you SAY aloud — conversational, 1-2 sentences.",
              "label": "Short 2-4 word label",
              "action": "click",
              "control_hint": "What control or menu item this probably is",
              "rough_target_x": 500,
              "rough_target_y": 300,
              "rough_highlight_x": 450,
              "rough_highlight_y": 260,
              "rough_highlight_width": 120,
              "rough_highlight_height": 80,
              "text": "optional exact text to type",
              "keys": ["command", "k"],
              "scroll_amount": 480
            }
          ]
        }
        """
    }

    private func teachingPlanSystemPrompt(
        screenSize: CGSize,
        additionalContext: String? = nil,
        conversationContext: String? = nil,
        researchContext: String? = nil
    ) -> String {
        let contextNote = conversationContextBlock(conversationContext)
        let researchNote = researchContextBlock(researchContext)

        return """
        You are Baymax — a warm, casual on-screen teaching buddy for macOS. \
        You talk to the user like a friend showing them how to do something on their computer. \
        You can see their screen and you'll guide them step-by-step.
        Use the conversation context to resolve follow-up requests and pronouns, not just the current screenshot.

        TASK: Look at this screenshot and help the user with their question. \
        Create a step-by-step plan with precise screen coordinates.
        Always return at least one step.
        Map the task out as a full plan from start to finish, not just a single gesture, unless the task truly is one step.
        Make each step tightly focused on one actionable control.
        For click/double_click/right_click/hover, keep highlight boxes compact (usually 18-120 px in width/height) and centered on the actual control.
        For type, bound the exact input field (usually <= 360 px wide unless clearly larger).
        For scroll, highlight the smallest region the user should scroll in.
        Use target_x / target_y as the center of the actionable control whenever possible.
        Keep highlight_x / highlight_y / width / height tight around the actionable element with only a small margin.
        Avoid large decorative regions or coordinates far away from the actual control.
        Do not invent controls that are not visibly present in the screenshot.
        When the task is to close a page/tab/window, target the actual close affordance in the chrome or tab bar, not the editor/content area, tab strip center, or a generic container.
        If there are multiple close affordances, prefer the active tab or window control that would actually dismiss the current page.
        If the task is about building or running something, prefer the visible run/build control or menu item that matches the current state of the app.

        Step actions must be explicit and normalized:
        - click
        - double_click
        - right_click
        - scroll
        - type
        - press_key
        - hover

        If action is type, include "text" with the exact text to type.
        If action is press_key, include "keys" as an array of key names, for example ["command", "k"].
        If action is scroll, include "scroll_amount" as a positive or negative number.

        Screenshot is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin (0,0 = top-left).
        \(contextNote.isEmpty ? "" : "\n\(contextNote)\n")
        \(researchNote.isEmpty ? "" : "\n\(researchNote)\n")
        \(additionalContext.map { "\n\($0)\n" } ?? "")

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
              "highlight_height": 80,
              "text": "optional exact text to type",
              "keys": ["command", "k"],
              "scroll_amount": 480
            }
          ]
        }
        """
    }

    private func conversationContextBlock(_ context: String?) -> String {
        let trimmed = context?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        guard let trimmed, !trimmed.isEmpty else { return "" }
        return """
        Conversation context from earlier turns:
        \(trimmed)
        """
    }

    private func tutorialPlanSystemPrompt(
        screenSize: CGSize,
        additionalContext: String? = nil,
        conversationContext: String? = nil
    ) -> String {
        let contextNote = conversationContextBlock(conversationContext)

        return """
        You are Baymax — a fast one-shot macOS tutorial planner.
        Look at the screenshot and the user request exactly once, then return the full solution plan as JSON.
        Always return at least one step.
        Do not do web search. Do not validate. Do not re-anchor later.
        Keep the plan short and direct. Prefer 1 step when the task can be finished in one action.
        Each step must describe one clear action area and return the box around the exact target the user should click, type into, or scroll over.
        The action box should tightly wrap the actionable control or region. Do not return a huge container if a smaller box exists.
        For click/double_click/right_click/hover actions, action_box_width and action_box_height should usually be between 18 and 120 pixels.
        For type actions, prefer the exact input field bounds and keep width under 360 unless the field is visibly larger.
        For scroll actions, use the smallest visibly scrollable region that still makes sense (avoid full-window boxes unless necessary).
        If the task is to close something, box the actual close affordance.
        If the task is to type, box the input field.
        If the task is to scroll, box the scrollable region.
        If the task is to press a shortcut, box the main visible surface or control the user should focus on.
        Use top-left screen coordinates in pixels.
        The box fields must be absolute coordinates for the full screenshot, not normalized values.

        Screenshot is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin.
        \(contextNote.isEmpty ? "" : "\n\(contextNote)\n")
        \(additionalContext.map { "\n\($0)\n" } ?? "")

        Return only valid JSON in this schema:
        {
          "app_name": "Name of the app on screen",
          "greeting": "A short casual spoken greeting",
          "steps": [
            {
              "instruction": "What you SAY aloud — conversational, 1-2 sentences.",
              "label": "Short 2-4 word label",
              "action": "click",
              "action_box_x": 500,
              "action_box_y": 300,
              "action_box_width": 120,
              "action_box_height": 80,
              "text": "optional exact text to type",
              "keys": ["command", "k"],
              "scroll_amount": 480
            }
          ]
        }
        """
    }

    private func textOnlyTutorialPlanSystemPrompt(
        screenSize: CGSize,
        conversationContext: String?
    ) -> String {
        let contextNote = conversationContextBlock(conversationContext)

        return """
        You are Baymax — a macOS step planner without screenshot access.
        Build a practical step-by-step plan from user intent + prior conversation context.
        Always return at least ONE step.
        Prefer 1-2 steps for simple tasks and 3-6 for multi-step tasks.
        Every step must still include action_box coordinates.
        Since there is no screenshot, use conservative, likely UI locations and tight boxes:
        - click/double_click/right_click/hover boxes: usually 18-120 px
        - type boxes: usually 120-360 px wide, 24-64 px tall
        - scroll boxes: focus the likely scrollable pane, not the entire screen
        Keep coordinates within the screen bounds and avoid random far-off placements.

        Screen is \(Int(screenSize.width))×\(Int(screenSize.height)) pixels, top-left origin.
        \(contextNote.isEmpty ? "" : "\n\(contextNote)\n")

        Return only valid JSON in this schema:
        {
          "app_name": "Likely app name",
          "greeting": "A short casual spoken greeting",
          "steps": [
            {
              "instruction": "What Baymax says aloud",
              "label": "Short 2-4 word label",
              "action": "click",
              "action_box_x": 500,
              "action_box_y": 300,
              "action_box_width": 120,
              "action_box_height": 80,
              "text": "optional exact text to type",
              "keys": ["command", "k"],
              "scroll_amount": 480
            }
          ]
        }
        """
    }

    private func researchContextBlock(_ context: String?) -> String {
        let trimmed = context?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        guard let trimmed, !trimmed.isEmpty else { return "" }
        return """
        Web research context:
        \(trimmed)
        """
    }

    private static func tutorialPlanSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["app_name", "greeting", "steps"],
            "properties": [
                "app_name": ["type": "string"],
                "greeting": ["type": "string"],
                "steps": [
                    "type": "array",
                    "items": tutorialStepSchema()
                ]
            ]
        ]
    }

    private static func tutorialStepSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "instruction", "label", "action",
                "action_box_x", "action_box_y", "action_box_width", "action_box_height",
                "text", "keys", "scroll_amount"
            ],
            "properties": [
                "instruction": ["type": "string"],
                "label": ["type": "string"],
                "action": ["type": "string"],
                "action_box_x": ["type": "number"],
                "action_box_y": ["type": "number"],
                "action_box_width": ["type": "number"],
                "action_box_height": ["type": "number"],
                "text": ["type": ["string", "null"]],
                "keys": [
                    "type": ["array", "null"],
                    "items": ["type": "string"]
                ],
                "scroll_amount": ["type": ["number", "null"]]
            ]
        ]
    }

    private static func teachingPlanSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["app_name", "greeting", "steps"],
            "properties": [
                "app_name": ["type": "string"],
                "greeting": ["type": "string"],
                "steps": [
                    "type": "array",
                    "items": teachingStepSchema()
                ]
            ]
        ]
    }

    private static func teachingOutlineSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["app_name", "greeting", "task_summary", "needs_research", "research_hint", "steps"],
            "properties": [
                "app_name": ["type": "string"],
                "greeting": ["type": "string"],
                "task_summary": ["type": "string"],
                "needs_research": ["type": "boolean"],
                "research_hint": ["type": ["string", "null"]],
                "steps": [
                    "type": "array",
                    "items": teachingOutlineStepSchema()
                ]
            ]
        ]
    }

    private static func teachingOutlineStepSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "instruction", "label", "action", "control_hint",
                "rough_target_x", "rough_target_y",
                "rough_highlight_x", "rough_highlight_y",
                "rough_highlight_width", "rough_highlight_height",
                "text", "keys", "scroll_amount"
            ],
            "properties": [
                "instruction": ["type": "string"],
                "label": ["type": "string"],
                "action": ["type": "string"],
                "control_hint": ["type": "string"],
                "rough_target_x": ["type": ["number", "null"]],
                "rough_target_y": ["type": ["number", "null"]],
                "rough_highlight_x": ["type": ["number", "null"]],
                "rough_highlight_y": ["type": ["number", "null"]],
                "rough_highlight_width": ["type": ["number", "null"]],
                "rough_highlight_height": ["type": ["number", "null"]],
                "text": ["type": ["string", "null"]],
                "keys": [
                    "type": ["array", "null"],
                    "items": ["type": "string"]
                ],
                "scroll_amount": ["type": ["number", "null"]]
            ]
        ]
    }

    private static func teachingStepSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "instruction", "label", "target_x", "target_y", "action",
                "highlight_x", "highlight_y", "highlight_width", "highlight_height",
                "text", "keys", "scroll_amount"
            ],
            "properties": [
                "instruction": ["type": "string"],
                "label": ["type": "string"],
                "target_x": ["type": "number"],
                "target_y": ["type": "number"],
                "action": ["type": "string"],
                "highlight_x": ["type": ["number", "null"]],
                "highlight_y": ["type": ["number", "null"]],
                "highlight_width": ["type": ["number", "null"]],
                "highlight_height": ["type": ["number", "null"]],
                "text": ["type": ["string", "null"]],
                "keys": [
                    "type": ["array", "null"],
                    "items": ["type": "string"]
                ],
                "scroll_amount": ["type": ["number", "null"]]
            ]
        ]
    }

    private static func stepValidationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["decision", "message", "next_step_index"],
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["next", "done", "replan"]
                ],
                "message": ["type": "string"],
                "next_step_index": ["type": ["integer", "null"]]
            ]
        ]
    }

    private func stepJSONData(_ step: TeachingStep) throws -> Data {
        var payload: [String: Any] = [
            "instruction": step.instruction,
            "label": step.label,
            "target_x": step.targetX,
            "target_y": step.targetY,
            "action": step.action,
        ]

        if let highlightX = step.highlightX { payload["highlight_x"] = highlightX }
        if let highlightY = step.highlightY { payload["highlight_y"] = highlightY }
        if let highlightWidth = step.highlightWidth { payload["highlight_width"] = highlightWidth }
        if let highlightHeight = step.highlightHeight { payload["highlight_height"] = highlightHeight }
        if let text = step.text { payload["text"] = text }
        if let keys = step.keys { payload["keys"] = keys }
        if let scrollAmount = step.scrollAmount { payload["scroll_amount"] = scrollAmount }

        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private func stepJSONString(_ step: TeachingStep) throws -> String {
        let data = try stepJSONData(step)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func syntheticOutline(from plan: TeachingPlan, taskSummary: String) -> TeachingOutline {
        TeachingOutline(
            appName: plan.appName,
            greeting: plan.greeting,
            taskSummary: taskSummary,
            needsResearch: false,
            researchHint: nil,
            steps: plan.steps.map { step in
                TeachingOutlineStep(
                    instruction: step.instruction,
                    label: step.label,
                    action: step.action,
                    controlHint: step.label,
                    roughTargetX: step.targetX,
                    roughTargetY: step.targetY,
                    roughHighlightX: step.highlightX,
                    roughHighlightY: step.highlightY,
                    roughHighlightWidth: step.highlightWidth,
                    roughHighlightHeight: step.highlightHeight,
                    text: step.text,
                    keys: step.keys,
                    scrollAmount: step.scrollAmount
                )
            }
        )
    }

    private func preparedAnalysisImage(from screenshot: CGImage) -> PreparedVisionImage {
        PreparedVisionImage(
            image: screenshot.resized(maxDimension: analysisMaxDimension) ?? screenshot,
            additionalContext: "The image may be downscaled for speed, but all returned coordinates must still use the original full-screen pixel coordinate system."
        )
    }

    private struct PreparedVisionImage {
        let image: CGImage
        let additionalContext: String
    }

    // MARK: - Anthropic

    private func anthropicChat(system: String, messages: [[String: Any]]) async throws -> String {
        logModelUsage(provider: "anthropic", model: Self.anthropicModel, route: "https://api.anthropic.com/v1/messages")
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

    private func anthropicVision(system: String, userText: String, base64: String) async throws -> String {
        let messages: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                ["type": "text", "text": userText]
            ]]
        ]
        return try await anthropicChat(system: system, messages: messages)
    }

    // MARK: - Gemini

    private func geminiChat(system: String, messages: [[String: Any]]) async throws -> String {
        logModelUsage(provider: "gemini", model: Self.geminiModel, route: "generateContent")
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

    private func geminiVision(system: String, userText: String, base64: String) async throws -> String {
        logModelUsage(provider: "gemini-vision", model: Self.geminiModel, route: "generateContent")
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.geminiModel):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [
                ["parts": [
                    ["text": userText],
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

    private func logModelUsage(provider: String, model: String, route: String) {
        let message = "[Baymax] MODEL provider=\(provider) model=\(model) route=\(route)"
        print(message)
        NSLog("%@", message)
    }

    private func logModelAck(provider: String, requestedModel: String, acknowledgedModel: String?) {
        let ack = acknowledgedModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (ack?.isEmpty == false ? ack! : "unknown")
        let message = "[Baymax] MODEL_ACK provider=\(provider) requested=\(requestedModel) acknowledged=\(resolved)"
        print(message)
        NSLog("%@", message)
    }

    private func logScreenshotPayload(route: String, base64Length: Int, screenSize: CGSize) {
        let message = "[Baymax] SCREENSHOT route=\(route) base64_chars=\(base64Length) screen=\(Int(screenSize.width))x\(Int(screenSize.height))"
        print(message)
        NSLog("%@", message)
    }
}
