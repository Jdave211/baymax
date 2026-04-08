import SwiftUI
import AppKit
import Combine

@MainActor
final class TeachingSessionController: ObservableObject {
    @Published var plan: TeachingPlan?
    @Published var isRunning = false

    var onSessionComplete: (() -> Void)?

    private let appState: AppState
    private var aiService: AIService?
    private let screenCapture = ScreenCaptureManager()
    private var tts: TextToSpeech?
    private var clickMonitor: Any?
    private var hasShownScreenRecordingHint = true // ScreenCaptureManager handles the prompt now

    /// Conversation history for the current session (cleared on escape/stop)
    private var sessionHistory: [[String: Any]] = []

    private let chatSystemPrompt = """
    You are Baymax — a warm, casual on-screen teaching buddy for macOS. \
    You talk to the user like a friend. Keep answers conversational — 2-3 sentences max. \
    Be helpful, concise, and natural. If you can't see their screen, just answer based on what they tell you.
    """

    var currentStep: TeachingStep? {
        guard let plan, appState.currentStepIndex < plan.steps.count else { return nil }
        return plan.steps[appState.currentStepIndex]
    }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start Teaching

    func start(question: String, preCapture: CGImage? = nil, preCaptureSize: CGSize? = nil) async {
        guard appState.hasValidProvider() else {
            print("[Baymax] No valid provider — currentApiKey is empty")
            appState.spokenSubtitle = "Please set an API key in the menu bar first."
            appState.mode = .idle
            return
        }

        print("[Baymax] Starting session — provider: \(appState.llmProvider.rawValue), question: \(question)")
        aiService = AIService(provider: appState.llmProvider, apiKey: appState.currentApiKey)
        tts = TextToSpeech(
            elevenLabsKey: appState.elevenLabsKey,
            elevenLabsVoiceId: appState.elevenLabsVoiceId,
            openAIKey: appState.openAIKey
        )
        isRunning = true

        let t0 = CFAbsoluteTimeGetCurrent()

        // Try to get a screenshot — fall back to text-only chat if screen capture is unavailable
        var screenshot: CGImage? = preCapture
        var screenSize: CGSize = preCaptureSize ?? (NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080))

        if screenshot == nil {
            do {
                print("[Baymax] Capturing screen now...")
                screenshot = try await screenCapture.capture()
                print("[Baymax] ⏱ Screen capture: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
            } catch {
                let isPermissionError = (error as? BaymaxError).map {
                    if case .networkError(let m) = $0 { return m == "screenRecordingDenied" }
                    return false
                } ?? false
                if isPermissionError {
                    print("[Baymax] Screen Recording not granted — running in text-only mode")
                } else {
                    print("[Baymax] Screen capture failed: \(error.localizedDescription) — text-only mode")
                }
            }
        } else {
            print("[Baymax] Using pre-captured screenshot (0ms)")
        }

        do {
            let t1 = CFAbsoluteTimeGetCurrent()

            if let screenshot {
                // Full vision mode — analyze screen and create teaching plan
                print("[Baymax] Sending to AI with vision (\(appState.llmProvider.rawValue))...")
                let plan = try await aiService!.analyzeScreen(
                    screenshot: screenshot,
                    question: question,
                    screenSize: screenSize
                )
                print("[Baymax] ⏱ AI response: \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000))ms")
                print("[Baymax] Got plan: \(plan.steps.count) steps — greeting: \(plan.greeting)")
                print("[Baymax] ⏱ Total to plan: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")

                self.plan = plan
                appState.currentStepIndex = 0
                appState.totalSteps = plan.steps.count

                appState.spokenSubtitle = plan.greeting
                await tts!.speakAndWait(plan.greeting)

                appState.mode = .teaching
                await showStep()
            } else {
                // Conversational chat — with session history
                sessionHistory.append(["role": "user", "content": question])
                print("[Baymax] Chat (turn \(sessionHistory.count / 2 + 1), \(sessionHistory.count) msgs in context)...")

                let reply = try await aiService!.chat(messages: sessionHistory, systemPrompt: chatSystemPrompt)
                print("[Baymax] ⏱ AI response: \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000))ms")
                print("[Baymax] Reply: \(reply.prefix(100))...")

                sessionHistory.append(["role": "assistant", "content": reply])

                // Cap history to last 20 messages to avoid token bloat
                if sessionHistory.count > 20 {
                    sessionHistory = Array(sessionHistory.suffix(20))
                }

                appState.spokenSubtitle = reply
                await tts!.speakAndWait(reply)

                appState.mode = .idle
                appState.spokenSubtitle = nil
                isRunning = false
            }

        } catch {
            print("[Baymax] Session error: \(error)")
            appState.spokenSubtitle = "Hmm, something went wrong. Try again?"
            tts?.play("Hmm, something went wrong. Try again?")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            appState.mode = .idle
            isRunning = false
        }
    }

    // MARK: - Step Execution

    private func showStep() async {
        guard let step = currentStep else {
            await complete()
            return
        }

        // Show context label on screen
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            appState.currentLabel = step.label
        }

        // Show faint subtitle of what's being said
        appState.spokenSubtitle = step.instruction

        // Move Baymax (the cursor companion) to the target
        withAnimation(.spring(response: 0.9, dampingFraction: 0.72)) {
            appState.characterPosition = CGPoint(x: step.targetX, y: step.targetY)
        }

        // Set highlight region
        withAnimation(.easeOut(duration: 0.35)) {
            appState.highlightRegion = step.highlightRegion
        }

        // Speak the instruction (conversational voice)
        tts?.play(step.instruction)

        // Listen for user clicks near the target
        startClickMonitor()
    }

    // MARK: - Click Monitoring

    private func startClickMonitor() {
        removeClickMonitor()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                self?.handleClick()
            }
        }
    }

    private func handleClick() {
        guard let step = currentStep, let screen = NSScreen.main else { return }

        let mouse = NSEvent.mouseLocation
        let mouseTopLeft = CGPoint(x: mouse.x, y: screen.frame.height - mouse.y)

        let target = CGPoint(x: step.targetX, y: step.targetY)
        let tolerance: CGFloat = max(step.highlightWidth ?? 80, step.highlightHeight ?? 80) / 2 + 40
        let distance = hypot(mouseTopLeft.x - target.x, mouseTopLeft.y - target.y)

        if distance < tolerance {
            advanceStep()
        }
    }

    func advanceStep() {
        removeClickMonitor()

        // Brief label change to acknowledge
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
            appState.currentLabel = ["nice!", "got it!", "perfect!", "yes!"].randomElement()
        }

        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)

            appState.currentStepIndex += 1

            if appState.currentStepIndex < (plan?.steps.count ?? 0) {
                await showStep()
            } else {
                await complete()
            }
        }
    }

    func skipStep() {
        advanceStep()
    }

    // MARK: - Completion

    private func complete() async {
        removeClickMonitor()

        let messages = [
            "Nice work! You nailed it.",
            "And that's it! You got it.",
            "Boom, done! See, easy right?",
            "There you go! All done.",
        ]
        let msg = messages.randomElement()!

        appState.spokenSubtitle = msg
        withAnimation {
            appState.currentLabel = nil
            appState.highlightRegion = nil
        }

        await tts?.speakAndWait(msg)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        appState.mode = .idle
        appState.spokenSubtitle = nil
        isRunning = false
        plan = nil

        onSessionComplete?()
    }

    // MARK: - Stop

    func stop() {
        removeClickMonitor()
        tts?.stop()
        isRunning = false
        plan = nil
    }

    func clearHistory() {
        sessionHistory.removeAll()
        print("[Baymax] Session history cleared")
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
