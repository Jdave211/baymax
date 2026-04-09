import AVFoundation
import AppKit
import Speech

/// Push-to-talk capture.
/// Records while Ctrl+Option is held, streams live speech recognition locally,
/// and falls back to OpenAI transcription if the live pass is empty.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var audioLevel: Float = 0

    var onFinalized: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let openAIKeyProvider: () -> String
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var bestTranscript = ""
    private var localRecognitionFailed = false
    private var hasDeliveredResult = false
    private var isStopping = false

    /// Prevent re-entrant startListening calls while permission dialog is showing
    private var isRequestingPermission = false

    init(openAIKeyProvider: @escaping () -> String = { DotEnv.value(for: "OPENAI_API_KEY") ?? DotEnv.value(for: "BAYMAX_OPENAI_KEY") ?? "" }) {
        self.openAIKeyProvider = openAIKeyProvider
    }

    // MARK: - Start / Stop

    func startListening() {
        guard !isListening, !isRequestingPermission else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            requestSpeechPermissionIfNeededAndBegin()
        case .notDetermined:
            // Request permission once, then start — guard prevents re-entry
            isRequestingPermission = true
            Task {
                let granted = await withCheckedContinuation { cont in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
                isRequestingPermission = false
                if granted {
                    requestSpeechPermissionIfNeededAndBegin()
                } else {
                    onError?("Microphone access denied — enable it in System Settings → Privacy → Microphone")
                }
            }
        default:
            onError?("Microphone access denied — enable it in System Settings → Privacy → Microphone")
        }
    }

    func stopListening() {
        guard isListening else { return }

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        isStopping = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isListening = false
        audioLevel = 0

        print("[Baymax] Recording stopped — duration: \(String(format: "%.1f", duration))s")

        guard let url = recordingURL else {
            onError?("Recording failed — no audio captured")
            cleanup()
            return
        }

        if duration < 0.2 {
            print("[Baymax] Recording too short — ignoring")
            onError?("Hold Ctrl+Option a bit longer and speak")
            cleanup()
            return
        }

        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            await self?.finalizeRecognition(using: url)
        }
    }

    // MARK: - Private

    private func requestSpeechPermissionIfNeededAndBegin() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginRecording(enableLiveRecognition: true)
        case .notDetermined:
            isRequestingPermission = true
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    self?.isRequestingPermission = false
                    self?.beginRecording(enableLiveRecognition: status == .authorized)
                }
            }
        default:
            beginRecording(enableLiveRecognition: false)
        }
    }

    private func beginRecording(enableLiveRecognition: Bool) {
        guard !isListening else { return }

        transcript = ""
        audioLevel = 0
        bestTranscript = ""
        localRecognitionFailed = false
        hasDeliveredResult = false
        isStopping = false
        recordingStartedAt = Date()
        finalizeTask?.cancel()
        transcriptionTask?.cancel()
        teardownSpeechPipeline(deleteRecording: true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baymax_\(UUID().uuidString).wav")
        recordingURL = url

        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            recordingFile = try AVAudioFile(forWriting: url, settings: format.settings)

            if enableLiveRecognition, let speechRecognizer {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                recognitionRequest = request

                recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                    if let result {
                        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            guard let self else { return }
                            if !text.isEmpty {
                                self.bestTranscript = text
                                self.transcript = text
                            }
                        }
                    }

                    if let error {
                        Task { @MainActor in
                            guard let self, !self.isStopping else { return }
                            self.localRecognitionFailed = true
                            print("[Baymax] Live speech recognition failed: \(error.localizedDescription)")
                        }
                    }
                }
            }

            let request = recognitionRequest
            let recordingFile = self.recordingFile
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request?.append(buffer)
                try? recordingFile?.write(from: buffer)
                Task { @MainActor in
                    self?.updateMeter(from: buffer)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            print("[Baymax] Recording started → \(url.lastPathComponent)")
        } catch {
            print("[Baymax] Audio engine start failed: \(error)")
            onError?("Could not start microphone: \(error.localizedDescription)")
            cleanup()
        }
    }

    private func finalizeRecognition(using url: URL) async {
        let cleaned = bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localRecognitionFailed, cleaned.count >= 2 {
            deliverTranscript(cleaned)
            return
        }

        let key = openAIKeyProvider()
        guard !key.isEmpty else {
            print("[Baymax] No OpenAI API key for transcription")
            onError?("OpenAI API key missing — needed for speech recognition")
            cleanup()
            return
        }

        print("[Baymax] Falling back to OpenAI transcription (local_failed=\(localRecognitionFailed), local_len=\(cleaned.count))...")
        transcriptionTask = Task { [weak self] in
            do {
                let client = OpenAIClient(apiKey: key)
                let text = try await client.transcribeAudio(fileURL: url)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Baymax] Transcript: \"\(cleaned)\"")
                await MainActor.run {
                    self?.deliverTranscript(cleaned)
                }
            } catch is CancellationError {
                await MainActor.run { self?.cleanup() }
            } catch {
                let msg = (error as NSError).code == -999 ? "cancelled" : error.localizedDescription
                if msg == "cancelled" {
                    await MainActor.run { self?.cleanup() }
                } else {
                    print("[Baymax] Transcription failed: \(error)")
                    await MainActor.run {
                        self?.onError?("Transcription failed — try again")
                        self?.cleanup()
                    }
                }
            }
        }
    }

    private func deliverTranscript(_ text: String) {
        guard !hasDeliveredResult else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = cleaned
        hasDeliveredResult = true
        if !cleaned.isEmpty {
            onFinalized?(cleaned)
        } else {
            onError?("Couldn't make that out — try again")
        }
        cleanup()
    }

    private func updateMeter(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        audioLevel = max(0, min(1, rms * 4.5))
    }

    private func cleanup() {
        finalizeTask?.cancel()
        finalizeTask = nil
        teardownSpeechPipeline(deleteRecording: true)
        isListening = false
        isStopping = false
        audioLevel = 0
        recordingStartedAt = nil
    }

    private func teardownSpeechPipeline(deleteRecording: Bool) {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recordingFile = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if deleteRecording, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    deinit {
        finalizeTask?.cancel()
        audioEngine.stop()
    }
}
