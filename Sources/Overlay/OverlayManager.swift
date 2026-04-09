import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayManager {
    private let appState: AppState
    private(set) var sessionController: TeachingSessionController!
    let speechRecognizer: SpeechRecognizer

    private var overlayWindow: OverlayWindow?
    private var cursorTracker: CursorTracker?
    private var cancellables = Set<AnyCancellable>()

    /// Pre-captured screenshot taken when user starts holding Ctrl+Option
    private var preCapture: CGImage?
    private var preCaptureSize: CGSize?
    private let screenCapture = ScreenCaptureManager()

    init(appState: AppState) {
        self.appState = appState
        // Whisper transcription always needs the OpenAI key specifically
        self.speechRecognizer = SpeechRecognizer(openAIKeyProvider: { [weak appState] in
            appState?.openAIKey ?? ""
        })
        self.sessionController = TeachingSessionController(appState: appState)

        sessionController.onSessionComplete = { [weak self] in
            Task { @MainActor in
                self?.appState.mode = .idle
            }
        }

        // Voice finalized → submit question
        speechRecognizer.onFinalized = { [weak self] text in
            Task { @MainActor in
                self?.handleQuestion(text)
            }
        }

        // Transcription error → show feedback
        speechRecognizer.onError = { [weak self] message in
            Task { @MainActor in
                self?.handleTranscriptionError(message)
            }
        }

        // Bridge speech state to AppState
        speechRecognizer.$transcript
            .receive(on: RunLoop.main)
            .sink { [weak appState] text in appState?.liveTranscript = text }
            .store(in: &cancellables)

        speechRecognizer.$isListening
            .receive(on: RunLoop.main)
            .sink { [weak appState] val in appState?.isRecording = val }
            .store(in: &cancellables)
    }

    // MARK: - Hotkey Hold State Machine

    func handleHoldBegan() {
        if !appState.isActive {
            appState.isActive = true
            activate()
        }

        switch appState.mode {
        case .idle, .listening:
            startListening()
        case .thinking, .teaching:
            sessionController.stop()
            appState.spokenSubtitle = nil
            startListening()
        }

        // Pre-capture screen while user is talking — saves ~1s later
        Task {
            do {
                let img = try await screenCapture.capture()
                self.preCapture = img
                self.preCaptureSize = CGSize(width: img.width, height: img.height)
                print("[Baymax] Screen pre-captured")
            } catch {
                print("[Baymax] Pre-capture failed: \(error.localizedDescription)")
                self.preCapture = nil
                self.preCaptureSize = nil
            }
        }
    }

    func handleHoldEnded() {
        guard appState.mode == .listening else { return }
        speechRecognizer.stopListening()
        // Show thinking state while transcription runs
        appState.mode = .thinking
        appState.isRecording = false
        appState.liveTranscript = ""
    }

    func handleEscape() {
        guard appState.isActive else { return }
        deactivate()
    }

    // MARK: - Activate / Deactivate

    func activate() {
        guard let screen = NSScreen.main else { return }
        setupOverlayWindow(screen: screen)
        setupCursorTracking()
    }

    private func deactivate() {
        sessionController.stop()
        sessionController.clearHistory()
        speechRecognizer.stopListening()
        cursorTracker?.stop()
        cursorTracker = nil
        overlayWindow?.close()
        overlayWindow = nil
        appState.reset()
        appState.isActive = false
    }

    // MARK: - Overlay Window

    private func setupOverlayWindow(screen: NSScreen) {
        let window = OverlayWindow(screen: screen)
        let content = OverlayContentView(appState: appState)
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        self.overlayWindow = window
    }

    // MARK: - Voice

    func startListening() {
        appState.liveTranscript = ""
        appState.mode = .listening
        speechRecognizer.startListening()
    }

    // MARK: - Cursor Tracking

    private func setupCursorTracking() {
        cursorTracker = CursorTracker { [weak self] position in
            Task { @MainActor in
                guard let self else { return }
                self.appState.cursorPosition = position
                if self.appState.mode == .idle || self.appState.mode == .listening || self.appState.mode == .thinking {
                    self.appState.characterPosition = CGPoint(
                        x: position.x + 30,
                        y: position.y + 28
                    )
                }
            }
        }
        cursorTracker?.start()
    }

    // MARK: - Question Handling

    private func handleQuestion(_ question: String) {
        guard !question.isEmpty else {
            print("[Baymax] Empty transcription — ignoring")
            appState.mode = .idle
            return
        }

        guard appState.hasValidProvider() || !appState.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[Baymax] No valid API key for \(appState.llmProvider.rawValue)")
            appState.spokenSubtitle = "Please set an API key in the menu bar first."
            appState.mode = .idle
            return
        }

        print("[Baymax] Question: \(question)")
        appState.mode = .thinking
        appState.spokenSubtitle = "Thinking..."

        let screenshot = preCapture
        let screenshotSize = preCaptureSize
        preCapture = nil
        preCaptureSize = nil

        Task {
            await sessionController.start(question: question, preCapture: screenshot, preCaptureSize: screenshotSize)
        }
    }

    /// Called when transcription fails — reset gracefully
    private func handleTranscriptionError(_ message: String) {
        print("[Baymax] Transcription error: \(message)")
        let lower = message.lowercased()
        if lower.contains("microphone access denied") {
            appState.spokenSubtitle = "Microphone access is off. Enable it in System Settings and try again."
        } else if lower.contains("openai api key missing") {
            appState.spokenSubtitle = "Speech transcription needs an OpenAI key in Baymax menu settings."
        } else if lower.contains("transcription failed") {
            appState.spokenSubtitle = "Transcription failed. Check your OpenAI key/network and try again."
        } else {
            appState.spokenSubtitle = message
        }
        appState.mode = .idle
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if appState.mode == .idle {
                appState.spokenSubtitle = nil
            }
        }
    }
}
