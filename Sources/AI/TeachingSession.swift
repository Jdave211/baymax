import SwiftUI
import AppKit
import Combine

@MainActor
final class TeachingSessionController: ObservableObject {
    @Published var plan: TutorialPlan?
    @Published var isRunning = false

    var onSessionComplete: (() -> Void)?

    private let appState: AppState
    private var aiService: AIService?
    private var visionService: AIService?
    private let screenCapture = ScreenCaptureManager()
    private var tts: TextToSpeech?
    private var interactionMonitor: Any?
    private var stepTimeoutTask: Task<Void, Never>?
    private var captureScale: CGFloat = 1
    private var screenPointSize: CGSize = .zero
    private var workingSteps: [TutorialStep] = []
    private var sessionQuestion: String = ""
    private var sessionHistory: [[String: Any]] = []

    private let chatSystemPrompt = """
    You are Baymax — a warm, casual on-screen teaching buddy for macOS. \
    You talk to the user like a friend. Keep answers conversational — 2-3 sentences max. \
    Be helpful, concise, and natural. If you can't see their screen, just answer based on what they tell you.
    """

    var currentStep: TutorialStep? {
        guard appState.currentStepIndex < workingSteps.count else { return nil }
        return workingSteps[appState.currentStepIndex]
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start Teaching

    func start(question: String, preCapture: CGImage? = nil, preCaptureSize: CGSize? = nil) async {
        let openAIInferenceKey = appState.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !openAIInferenceKey.isEmpty else {
            print("[Baymax] Missing OPENAI_API_KEY for inference")
            appState.spokenSubtitle = "Missing OPENAI_API_KEY. Add it in your .env and try again."
            appState.mode = .idle
            return
        }

        sessionQuestion = question
        appendSessionHistory(role: "user", content: question)
        print("[Baymax] Starting session — provider: \(appState.llmProvider.rawValue), question: \(question)")
        if appState.hasValidProvider() {
            aiService = AIService(provider: appState.llmProvider, apiKey: appState.currentApiKey)
        } else {
            aiService = AIService(provider: .openai, apiKey: openAIInferenceKey)
            print("[Baymax] Chat provider fallback: OpenAI (\(AIService.openAIInferenceModel))")
        }

        visionService = AIService(provider: .openai, apiKey: openAIInferenceKey)
        print("[Baymax] Vision/inference provider: OpenAI (\(AIService.openAIInferenceModel))")
        tts = TextToSpeech(
            elevenLabsKey: appState.elevenLabsKey,
            elevenLabsVoiceId: appState.elevenLabsVoiceId,
            openAIKey: appState.openAIKey
        )
        isRunning = true

        let t0 = CFAbsoluteTimeGetCurrent()
        screenPointSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)

        var screenshot: CGImage? = preCapture
        let screenshotSize: CGSize = preCaptureSize ?? (screenshot.map {
            CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
        } ?? screenPointSize)
        captureScale = max(1, screenshotSize.width / max(screenPointSize.width, 1))

        if screenshot == nil {
            do {
                print("[Baymax] Capturing screen now...")
                screenshot = try await screenCapture.capture()
                if let screenshot {
                    let capturedSize = CGSize(width: CGFloat(screenshot.width), height: CGFloat(screenshot.height))
                    captureScale = max(1, capturedSize.width / max(screenPointSize.width, 1))
                    print("[Baymax] Screenshot ready (\(Int(capturedSize.width))x\(Int(capturedSize.height)))")
                }
                print("[Baymax] ⏱ Screen capture: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
            } catch {
                let isPermissionError = (error as? BaymaxError).map {
                    if case .networkError(let m) = $0 { return m == "screenRecordingDenied" }
                    return false
                } ?? false
                if isPermissionError {
                    print("[Baymax] Screen Recording not granted — running in text-only mode")
                    appState.spokenSubtitle = "Screen Recording is off. In Baymax menu, open Permissions, tap Grant, then add Baymax.app with the + button."
                } else {
                    print("[Baymax] Screen capture failed: \(error.localizedDescription) — text-only mode")
                }
            }
        } else {
            if let screenshot {
                print("[Baymax] Using pre-captured screenshot (\(screenshot.width)x\(screenshot.height), 0ms)")
            }
        }

        let t1 = CFAbsoluteTimeGetCurrent()

        if let screenshot {
            let planner = visionService ?? aiService!
            do {
                print("[Baymax] Sending one-shot tutorial request with screenshot...")
                let result = try await planner.planTutorialSession(
                    screenshot: screenshot,
                    question: question,
                    screenSize: screenshotSize,
                    conversationContext: conversationContextSummary()
                )
                print("[Baymax] ⏱ AI response: \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000))ms")
                print("[Baymax] Got plan: \(result.steps.count) steps — app: \(result.appName)")
                print("[Baymax] ⏱ Total to plan: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
                await applyTutorialPlan(result, screenSize: screenshotSize)
            } catch {
                print("[Baymax] One-shot planning failed: \(error)")
                print("[Baymax] Retrying screenshot flow with legacy vision planner...")
                do {
                    let fallback = try await planner.analyzeScreen(
                        screenshot: screenshot,
                        question: question,
                        screenSize: screenshotSize,
                        conversationContext: conversationContextSummary()
                    )
                    let converted = tutorialPlan(from: fallback, screenSize: screenshotSize)
                    print("[Baymax] Legacy vision planner succeeded: \(converted.steps.count) steps")
                    await applyTutorialPlan(converted, screenSize: screenshotSize)
                } catch {
                    print("[Baymax] Legacy vision planner failed: \(error)")
                    print("[Baymax] Trying text-only structured planner fallback...")
                    do {
                        let textOnly = try await planner.planTutorialSessionTextOnly(
                            question: question,
                            screenSize: screenshotSize,
                            conversationContext: conversationContextSummary()
                        )
                        print("[Baymax] Text-only planner fallback succeeded: \(textOnly.steps.count) steps")
                        await applyTutorialPlan(textOnly, screenSize: screenshotSize)
                    } catch {
                        print("[Baymax] Text-only planner fallback failed: \(error)")
                        let fallback = fallbackSingleStepPlan(question: question, screenSize: screenshotSize)
                        await applyTutorialPlan(fallback, screenSize: screenshotSize)
                    }
                }
            }
        } else {
            print("[Baymax] No screenshot available; using text-only structured planner path")
            do {
                let textOnly = try await (visionService ?? aiService!).planTutorialSessionTextOnly(
                    question: question,
                    screenSize: screenshotSize,
                    conversationContext: conversationContextSummary()
                )
                await applyTutorialPlan(textOnly, screenSize: screenshotSize)
            } catch {
                print("[Baymax] Text-only structured planner failed: \(error)")
                let fallback = fallbackSingleStepPlan(question: question, screenSize: screenshotSize)
                await applyTutorialPlan(fallback, screenSize: screenshotSize)
            }
        }
    }

    // MARK: - Step Execution

    private func showStep() async {
        guard let step = currentStep else {
            await complete()
            return
        }

        clearResolvedState()
        appState.spokenSubtitle = step.instruction
        appState.currentLabel = step.label

        let box = convertedActionBoxRegion(step.actionBoxRegion) ?? step.actionBoxRegion
        let effectiveAction = effectiveActionKind(for: step)
        let grounded = await groundedTarget(for: step, fallbackBox: box, preferredAction: effectiveAction)
        let displayedPoint = displayedTargetPoint(from: grounded.point)

        withAnimation(.spring(response: 0.22, dampingFraction: 0.95)) {
            appState.characterPosition = displayedPoint
        }

        appState.highlightRegion = nil

        appState.targetMarkerPoint = displayedPoint
        appState.targetMarkerLabel = step.label
        appState.targetMarkerSource = grounded.source

        tts?.play(step.instruction)
        appendSessionHistory(role: "assistant", content: step.instruction)

        startInteractionMonitor(for: step)
        scheduleStepTimeout(for: appState.currentStepIndex)
    }

    private func startInteractionMonitor(for step: TutorialStep) {
        removeInteractionMonitor()

        let actionKind = effectiveActionKind(for: step)
        let eventMask: NSEvent.EventTypeMask
        switch actionKind {
        case .scroll:
            eventMask = [.scrollWheel]
        case .type, .pressKey:
            eventMask = [.keyDown]
        default:
            eventMask = [.leftMouseDown, .rightMouseDown]
        }

        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            Task { @MainActor in
                self?.handleInteraction(event: event, step: step)
            }
        }
    }

    private func handleInteraction(event: NSEvent?, step: TutorialStep) {
        let actionKind = effectiveActionKind(for: step)
        let target = appState.targetMarkerPoint ?? displayedTargetPoint(from: step.actionCenter)
        let box = convertedActionBoxRegion(step.actionBoxRegion) ?? step.actionBoxRegion
        let closeIntent = isCloseIntent(for: step)
        let tolerance: CGFloat = {
            if closeIntent { return 16 }
            switch actionKind {
            case .scroll, .type, .pressKey:
                return 16
            default:
                let raw = max(CGFloat(box.width), CGFloat(box.height)) * 0.33 + 6
                return raw.clamped(to: 10...24)
            }
        }()

        let mouse = NSEvent.mouseLocation
        let screenFrame = NSScreen.main?.frame ?? .zero
        let mouseTopLeft = CGPoint(
            x: (mouse.x - screenFrame.minX).clamped(to: 0...max(screenFrame.width, 1)),
            y: (screenFrame.maxY - mouse.y).clamped(to: 0...max(screenFrame.height, 1))
        )
        let distance = hypot(mouseTopLeft.x - target.x, mouseTopLeft.y - target.y)
        let expandedActionRect = box.rect.insetBy(dx: -8, dy: -8)
        let insideActionBox = expandedActionRect.contains(mouseTopLeft)

        switch actionKind {
        case .scroll:
            if let event, abs(event.scrollingDeltaY) > 0 || abs(event.scrollingDeltaX) > 0 {
                Task { await advanceToStep(index: appState.currentStepIndex + 1) }
            }
        case .type, .pressKey:
            if let event, event.type == .keyDown {
                Task { await advanceToStep(index: appState.currentStepIndex + 1) }
            }
        default:
            if insideActionBox || distance < tolerance {
                Task { await advanceToStep(index: appState.currentStepIndex + 1) }
            }
        }
    }

    func advanceStep() {
        Task {
            await advanceToStep(index: appState.currentStepIndex + 1)
        }
    }

    func skipStep() {
        advanceStep()
    }

    // MARK: - Completion

    private func complete(message: String? = nil) async {
        removeInteractionMonitor()
        cancelStepTimeout()
        clearResolvedState()

        let messages = [
            "Nice work! You nailed it.",
            "And that's it! You got it.",
            "Boom, done! See, easy right?",
            "There you go! All done.",
        ]
        let cleanedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = (cleanedMessage?.isEmpty == false) ? cleanedMessage! : messages.randomElement()!

        appState.spokenSubtitle = msg
        tts?.play(msg)

        appState.mode = .idle
        isRunning = false
        plan = nil
        workingSteps = []
        sessionQuestion = ""
        appState.totalSteps = 0
        appState.currentStepIndex = 0

        let completionMessage = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if appState.mode == .idle && appState.spokenSubtitle == completionMessage {
                appState.spokenSubtitle = nil
            }
        }

        onSessionComplete?()
    }

    // MARK: - Stop

    func stop() {
        removeInteractionMonitor()
        cancelStepTimeout()
        clearResolvedState()
        tts?.stop()
        isRunning = false
        plan = nil
        workingSteps = []
        sessionQuestion = ""
        appState.totalSteps = 0
        appState.currentStepIndex = 0
    }

    func clearHistory() {
        sessionHistory.removeAll()
        print("[Baymax] Session history cleared")
    }

    private func appendSessionHistory(role: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        sessionHistory.append([
            "role": role,
            "content": trimmed
        ])

        if sessionHistory.count > 12 {
            sessionHistory = Array(sessionHistory.suffix(12))
        }
    }

    private func conversationContextSummary(limit: Int = 12) -> String {
        let recent = sessionHistory.suffix(limit)
        guard !recent.isEmpty else { return "" }

        return recent.compactMap { message in
            guard
                let role = message["role"] as? String,
                let content = message["content"] as? String
            else { return nil }

            let clipped = String(content.prefix(320))
            return "\(role): \(clipped)"
        }
        .joined(separator: "\n")
    }

    private func applyTutorialPlan(_ result: TutorialPlan, screenSize: CGSize) async {
        let normalized = normalizedTutorialPlan(result, screenSize: screenSize)
        self.plan = normalized
        self.workingSteps = normalized.steps
        appState.currentStepIndex = 0
        appState.totalSteps = workingSteps.count
        appState.mode = .teaching
        appState.spokenSubtitle = normalized.greeting
        appendSessionHistory(role: "assistant", content: normalized.greeting)

        if workingSteps.isEmpty {
            await complete(message: normalized.greeting)
        } else {
            await showStep()
        }
    }

    private func tutorialPlan(from plan: TeachingPlan, screenSize: CGSize) -> TutorialPlan {
        let steps = plan.steps.map { step in
            let actionBox: ScreenRegion = {
                if let region = step.highlightRegion {
                    return region
                }

                let defaultWidth = 96.0
                let defaultHeight = 72.0
                let maxX = max(Double(screenSize.width) - defaultWidth, 0)
                let maxY = max(Double(screenSize.height) - defaultHeight, 0)
                let x = (step.targetX - defaultWidth / 2).clamped(to: 0...maxX)
                let y = (step.targetY - defaultHeight / 2).clamped(to: 0...maxY)
                return ScreenRegion(x: x, y: y, width: defaultWidth, height: defaultHeight)
            }()

            return TutorialStep(
                instruction: step.instruction,
                label: step.label,
                action: step.action,
                actionBoxX: actionBox.x,
                actionBoxY: actionBox.y,
                actionBoxWidth: actionBox.width,
                actionBoxHeight: actionBox.height,
                text: step.text,
                keys: step.keys,
                scrollAmount: step.scrollAmount
            )
        }

        return TutorialPlan(appName: plan.appName, greeting: plan.greeting, steps: steps)
    }

    private func replyInChatMode(startedAt: CFAbsoluteTime) async throws {
        print("[Baymax] Chat (turn \(sessionHistory.count / 2 + 1), \(sessionHistory.count) msgs in context)...")

        let reply = try await aiService!.chat(messages: sessionHistory, systemPrompt: chatSystemPrompt)
        print("[Baymax] ⏱ AI response: \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms")
        print("[Baymax] Reply: \(reply.prefix(100))...")

        sessionHistory.append(["role": "assistant", "content": reply])
        if sessionHistory.count > 12 {
            sessionHistory = Array(sessionHistory.suffix(12))
        }

        appState.spokenSubtitle = reply
        if let tts {
            await tts.speakAndWait(reply)
        }

        appState.mode = .idle
        appState.spokenSubtitle = nil
        isRunning = false
    }

    private func userFacingSessionError(_ error: Error) -> String {
        let raw: String
        if let baymaxError = error as? BaymaxError {
            switch baymaxError {
            case .networkError(let message):
                raw = message
            case .apiError(_, let message):
                raw = message
            case .parseError(let message):
                raw = message
            case .noDisplay:
                raw = "no display available"
            case .noApiKey:
                raw = "no api key"
            }
        } else {
            raw = error.localizedDescription
        }

        let lower = raw.lowercased()
        if lower.contains("screenrecordingdenied") || lower.contains("screen recording") {
            return "Screen Recording is off. Grant it in Baymax Permissions, then try again."
        }
        if lower.contains("invalid_api_key") || lower.contains("incorrect api key") || lower.contains("unauthorized") || lower.contains("401") {
            return "Your API key was rejected. Update it in Baymax menu settings."
        }
        if lower.contains("insufficient_quota") || lower.contains("billing") || lower.contains("rate limit") || lower.contains("429") || lower.contains("402") {
            return "API quota or billing limit reached. Check your provider billing, then try again."
        }
        if lower.contains("model_not_found") || lower.contains("does not exist") || lower.contains("not found") {
            return "This model is unavailable for your account. Switch provider/model and try again."
        }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("network") {
            return "Network request failed. Check connection and try again."
        }
        let compact = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.isEmpty {
            return "AI request failed. Check API key, quota, and network."
        }
        return "Something went wrong: \(String(compact.prefix(140)))"
    }

    private func removeInteractionMonitor() {
        if let monitor = interactionMonitor {
            NSEvent.removeMonitor(monitor)
            interactionMonitor = nil
        }
    }

    private func cancelStepTimeout() {
        stepTimeoutTask?.cancel()
        stepTimeoutTask = nil
    }

    private func scheduleStepTimeout(for stepIndex: Int) {
        cancelStepTimeout()

        stepTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_800_000_000)
            } catch {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.isRunning,
                      self.appState.mode == .teaching,
                      self.appState.currentStepIndex == stepIndex else { return }

                print("[Baymax] Step \(stepIndex + 1) timed out — validating with screenshot")
                Task {
                    await self.validateTimedOutStep(stepIndex: stepIndex)
                }
            }
        }
    }

    private func validateTimedOutStep(stepIndex: Int) async {
        guard let inferenceService = visionService ?? aiService else {
            await advanceToStep(index: stepIndex + 1)
            return
        }

        guard let screenshot = try? await screenCapture.capture() else {
            print("[Baymax] Timeout validation capture failed — advancing")
            await advanceToStep(index: stepIndex + 1)
            return
        }

        let screenshotSize = CGSize(width: CGFloat(screenshot.width), height: CGFloat(screenshot.height))
        let validationPlan = teachingPlanForValidation()

        do {
            let result = try await inferenceService.validateStepProgress(
                screenshot: screenshot,
                question: sessionQuestion,
                plan: validationPlan,
                currentStepIndex: stepIndex,
                screenSize: screenshotSize,
                conversationContext: conversationContextSummary()
            )

            switch result.decision {
            case .next:
                if !result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.spokenSubtitle = result.message
                    tts?.play(result.message)
                    appendSessionHistory(role: "assistant", content: result.message)
                }
                let proposed = result.nextStepIndex ?? (stepIndex + 1)
                let nextIndex = max(stepIndex + 1, proposed)
                await advanceToStep(index: nextIndex)

            case .done:
                await complete(message: result.message)

            case .replan:
                if !result.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appState.spokenSubtitle = result.message
                    tts?.play(result.message)
                    appendSessionHistory(role: "assistant", content: result.message)
                }
                await replanFromCurrentScreenshot(screenshot: screenshot, screenshotSize: screenshotSize)
            }
        } catch {
            print("[Baymax] Timeout validation failed: \(error.localizedDescription) — advancing")
            await advanceToStep(index: stepIndex + 1)
        }
    }

    private func replanFromCurrentScreenshot(screenshot: CGImage, screenshotSize: CGSize) async {
        guard let inferenceService = visionService ?? aiService else {
            await advanceToStep(index: appState.currentStepIndex + 1)
            return
        }

        do {
            let replanned = try await inferenceService.planTutorialSession(
                screenshot: screenshot,
                question: sessionQuestion,
                screenSize: screenshotSize,
                conversationContext: conversationContextSummary()
            )
            await applyTutorialPlan(replanned, screenSize: screenshotSize)
            return
        } catch {
            print("[Baymax] Replan (one-shot) failed: \(error.localizedDescription)")
        }

        do {
            let fallback = try await inferenceService.analyzeScreen(
                screenshot: screenshot,
                question: sessionQuestion,
                screenSize: screenshotSize,
                conversationContext: conversationContextSummary()
            )
            let converted = tutorialPlan(from: fallback, screenSize: screenshotSize)
            await applyTutorialPlan(converted, screenSize: screenshotSize)
        } catch {
            print("[Baymax] Replan fallback failed: \(error.localizedDescription) — using local fallback step")
            let fallback = fallbackSingleStepPlan(question: sessionQuestion, screenSize: screenshotSize)
            await applyTutorialPlan(fallback, screenSize: screenshotSize)
        }
    }

    private func teachingPlanForValidation() -> TeachingPlan {
        let steps = workingSteps.map { step in
            let box = convertedActionBoxRegion(step.actionBoxRegion) ?? step.actionBoxRegion
            let scaledBox = ScreenRegion(
                x: box.x * Double(captureScale),
                y: box.y * Double(captureScale),
                width: box.width * Double(captureScale),
                height: box.height * Double(captureScale)
            )

            return TeachingStep(
                instruction: step.instruction,
                label: step.label,
                targetX: (box.center.x) * Double(captureScale),
                targetY: (box.center.y) * Double(captureScale),
                action: step.action,
                highlightX: scaledBox.x,
                highlightY: scaledBox.y,
                highlightWidth: scaledBox.width,
                highlightHeight: scaledBox.height,
                text: step.text,
                keys: step.keys,
                scrollAmount: step.scrollAmount
            )
        }

        return TeachingPlan(
            appName: plan?.appName ?? "Unknown App",
            greeting: plan?.greeting ?? "",
            steps: steps
        )
    }

    private func clearResolvedState() {
        withAnimation {
            appState.highlightRegion = nil
        }
        appState.targetMarkerPoint = nil
        appState.targetMarkerLabel = nil
        appState.targetMarkerSource = nil
        appState.currentLabel = nil
    }

    private func advanceToStep(index: Int) async {
        removeInteractionMonitor()
        clearResolvedState()

        guard index < workingSteps.count else {
            await complete()
            return
        }

        appState.currentStepIndex = index
        await showStep()
    }

    private struct GroundedTarget {
        let point: CGPoint
        let source: String
    }

    private func groundedTarget(
        for step: TutorialStep,
        fallbackBox: ScreenRegion,
        preferredAction: TeachingAction
    ) async -> GroundedTarget {
        let fallback = GroundedTarget(point: fallbackBox.center, source: "box")
        guard let screen = NSScreen.main else { return fallback }

        let closeIntent = isCloseIntent(for: step)
        let hints = closeIntent ? withCloseHints(step.searchHints) : step.searchHints

        if closeIntent,
           let visibleClose = AccessibilityLocator.resolveVisibleTarget(
            on: screen,
            preferredAction: .click,
            searchHints: hints
           ),
           isGroundedCandidate(visibleClose.anchorPoint, near: fallbackBox, closeIntent: closeIntent) {
            return GroundedTarget(point: visibleClose.anchorPoint, source: "ax_visible_close")
        }

        if let target = AccessibilityLocator.resolveTarget(
            near: fallbackBox.center,
            on: screen,
            preferredAction: preferredAction,
            searchHints: hints
        ), target.isStrongMatch(for: preferredAction),
           isGroundedCandidate(target.anchorPoint, near: fallbackBox, closeIntent: closeIntent) {
            return GroundedTarget(point: target.anchorPoint, source: "ax")
        }

        if let screenshot = try? await screenCapture.capture() {
            let visualInstruction = closeIntent ? "\(step.instruction) close dismiss tab x" : step.instruction
            let visualLabel = closeIntent ? "\(step.label) close" : step.label
            let visualStep = TeachingStep(
                instruction: visualInstruction,
                label: visualLabel,
                targetX: step.actionCenter.x * Double(captureScale),
                targetY: step.actionCenter.y * Double(captureScale),
                action: closeIntent ? "click" : step.action,
                highlightX: step.actionBoxX * Double(captureScale),
                highlightY: step.actionBoxY * Double(captureScale),
                highlightWidth: step.actionBoxWidth * Double(captureScale),
                highlightHeight: step.actionBoxHeight * Double(captureScale),
                text: step.text,
                keys: step.keys,
                scrollAmount: step.scrollAmount
            )

            if let visual = VisualLocator.resolveTarget(in: screenshot, step: visualStep) {
                let point = CGPoint(
                    x: visual.anchorPoint.x / captureScale,
                    y: visual.anchorPoint.y / captureScale
                )
                if isGroundedCandidate(point, near: fallbackBox, closeIntent: closeIntent) {
                    return GroundedTarget(point: point, source: "vision")
                }
            }
        }

        if let target = AccessibilityLocator.resolveTarget(
            near: fallbackBox.center,
            on: screen,
            preferredAction: preferredAction,
            searchHints: hints
        ), isGroundedCandidate(target.anchorPoint, near: fallbackBox, closeIntent: closeIntent) {
            return GroundedTarget(point: target.anchorPoint, source: "ax_weak")
        }

        return fallback
    }

    private func effectiveActionKind(for step: TutorialStep) -> TeachingAction {
        let action = step.actionKind
        guard isCloseIntent(for: step) else { return action }
        switch action {
        case .scroll, .type, .pressKey, .hover, .unknown:
            return .click
        default:
            return action
        }
    }

    private func isCloseIntent(for step: TutorialStep) -> Bool {
        let corpus = [
            sessionQuestion,
            step.instruction,
            step.label,
            step.action,
            step.text ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        let closeKeywords = [
            "close", "dismiss", "quit", "exit", "x button",
            "close tab", "close page", "close window", "leave this page"
        ]
        return closeKeywords.contains(where: { corpus.contains($0) })
    }

    private func withCloseHints(_ base: [String]) -> [String] {
        let extras = ["close", "dismiss", "quit", "exit", "tab", "window", "x"]
        return Array(Set(base + extras)).sorted()
    }

    private func isGroundedCandidate(_ point: CGPoint, near fallbackBox: ScreenRegion, closeIntent: Bool) -> Bool {
        let center = fallbackBox.center
        let distance = hypot(point.x - center.x, point.y - center.y)
        let base = max(fallbackBox.width, fallbackBox.height)
        let multiplier = closeIntent ? 2.4 : 1.7
        let maxDistance = (base * multiplier).clamped(to: 28...240)
        return distance <= maxDistance
    }

    private func displayedTargetPoint(from point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x.clamped(to: 0...max(screenPointSize.width, 1)),
            y: point.y.clamped(to: 0...max(screenPointSize.height, 1))
        )
    }

    private func convertedActionBoxRegion(_ region: ScreenRegion?) -> ScreenRegion? {
        guard let region else { return nil }
        return ScreenRegion(
            x: region.x / Double(captureScale),
            y: region.y / Double(captureScale),
            width: region.width / Double(captureScale),
            height: region.height / Double(captureScale)
        )
    }

    private func normalizedTutorialPlan(_ result: TutorialPlan, screenSize: CGSize) -> TutorialPlan {
        let greeting = result.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = result.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSteps = result.steps.map { sanitizeTutorialStep($0, screenSize: screenSize) }
        let finalSteps = normalizedSteps.isEmpty
            ? [fallbackSingleStepPlan(question: sessionQuestion, screenSize: screenSize).steps[0]]
            : normalizedSteps

        return TutorialPlan(
            appName: appName.isEmpty ? "Current App" : appName,
            greeting: greeting.isEmpty ? "Alright, let's do this step by step." : greeting,
            steps: finalSteps
        )
    }

    private func sanitizeTutorialStep(_ step: TutorialStep, screenSize: CGSize) -> TutorialStep {
        let safeScreenWidth = max(1.0, Double(screenSize.width))
        let safeScreenHeight = max(1.0, Double(screenSize.height))

        let action = step.actionKind
        let centerX = step.actionCenter.x.isFinite ? step.actionCenter.x.clamped(to: 0...safeScreenWidth) : safeScreenWidth / 2
        let centerY = step.actionCenter.y.isFinite ? step.actionCenter.y.clamped(to: 0...safeScreenHeight) : safeScreenHeight / 2

        let minWidth: Double
        let minHeight: Double
        let maxWidth: Double
        let maxHeight: Double

        switch action {
        case .type:
            minWidth = 90
            minHeight = 28
            maxWidth = min(360, safeScreenWidth * 0.45)
            maxHeight = min(92, safeScreenHeight * 0.25)
        case .scroll:
            minWidth = 80
            minHeight = 70
            maxWidth = min(420, safeScreenWidth * 0.55)
            maxHeight = min(300, safeScreenHeight * 0.45)
        default:
            minWidth = 18
            minHeight = 18
            maxWidth = min(120, safeScreenWidth * 0.18)
            maxHeight = min(120, safeScreenHeight * 0.22)
        }

        var width = step.actionBoxWidth.isFinite ? abs(step.actionBoxWidth) : 0
        var height = step.actionBoxHeight.isFinite ? abs(step.actionBoxHeight) : 0
        if width < minWidth { width = minWidth }
        if height < minHeight { height = minHeight }
        if width > maxWidth { width = maxWidth }
        if height > maxHeight { height = maxHeight }

        var x = centerX - width / 2
        var y = centerY - height / 2
        x = x.clamped(to: 0...max(safeScreenWidth - width, 0))
        y = y.clamped(to: 0...max(safeScreenHeight - height, 0))

        return TutorialStep(
            instruction: step.instruction,
            label: step.label,
            action: step.action,
            actionBoxX: x,
            actionBoxY: y,
            actionBoxWidth: width,
            actionBoxHeight: height,
            text: step.text,
            keys: step.keys,
            scrollAmount: step.scrollAmount
        )
    }

    private func fallbackSingleStepPlan(question: String, screenSize: CGSize) -> TutorialPlan {
        let safeScreenWidth = max(1.0, Double(screenSize.width))
        let safeScreenHeight = max(1.0, Double(screenSize.height))
        let centerX = appState.cursorPosition.x.isFinite
            ? appState.cursorPosition.x.clamped(to: 0...safeScreenWidth)
            : safeScreenWidth / 2
        let centerY = appState.cursorPosition.y.isFinite
            ? appState.cursorPosition.y.clamped(to: 0...safeScreenHeight)
            : safeScreenHeight / 2

        let width = min(96.0, safeScreenWidth * 0.18)
        let height = min(72.0, safeScreenHeight * 0.18)
        let x = (centerX - width / 2).clamped(to: 0...max(safeScreenWidth - width, 0))
        let y = (centerY - height / 2).clamped(to: 0...max(safeScreenHeight - height, 0))

        let instruction = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Start here first, then tell me what you see."
            : "Start here. \(question)"

        let step = TutorialStep(
            instruction: instruction,
            label: "start here",
            action: "click",
            actionBoxX: x,
            actionBoxY: y,
            actionBoxWidth: width,
            actionBoxHeight: height,
            text: nil,
            keys: nil,
            scrollAmount: nil
        )

        return TutorialPlan(
            appName: "Current App",
            greeting: "I mapped this into steps. Let's do it one at a time.",
            steps: [step]
        )
    }
}
