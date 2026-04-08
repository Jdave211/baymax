import AVFoundation
import AppKit

/// Push-to-talk capture.
/// Records while Ctrl+Option is held and transcribes the clip with OpenAI Whisper when released.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var audioLevel: Float = 0

    var onFinalized: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let openAIKeyProvider: () -> String
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?

    /// Prevent re-entrant startListening calls while permission dialog is showing
    private var isRequestingPermission = false

    init(openAIKeyProvider: @escaping () -> String = { DotEnv.value(for: "BAYMAX_OPENAI_KEY") ?? "" }) {
        self.openAIKeyProvider = openAIKeyProvider
    }

    // MARK: - Start / Stop

    func startListening() {
        guard !isListening, !isRequestingPermission else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            // Request permission once, then start — guard prevents re-entry
            isRequestingPermission = true
            Task {
                let granted = await withCheckedContinuation { cont in
                    AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
                }
                isRequestingPermission = false
                if granted {
                    beginRecording()
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

        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        isListening = false
        audioLevel = 0

        print("[Baymax] Recording stopped — duration: \(String(format: "%.1f", duration))s")

        guard let url = recordingURL else {
            onError?("Recording failed — no audio captured")
            cleanup()
            return
        }

        if duration < 0.3 {
            print("[Baymax] Recording too short — ignoring")
            onError?("Hold Ctrl+Option a bit longer and speak")
            cleanup()
            return
        }

        let key = openAIKeyProvider()
        guard !key.isEmpty else {
            print("[Baymax] No OpenAI API key for transcription")
            onError?("OpenAI API key missing — needed for speech recognition")
            cleanup()
            return
        }

        print("[Baymax] Sending audio to Whisper...")
        transcriptionTask = Task { [weak self] in
            do {
                let client = OpenAIClient(apiKey: key)
                let text = try await client.transcribeAudio(fileURL: url)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Baymax] Whisper transcript: \"\(cleaned)\"")
                await MainActor.run {
                    self?.transcript = text
                    self?.cleanup()
                    if !cleaned.isEmpty {
                        self?.onFinalized?(cleaned)
                    } else {
                        self?.onError?("Couldn't make that out — try again")
                    }
                }
            } catch is CancellationError {
                // Intentionally cancelled (user held again) — silent
                await MainActor.run { self?.cleanup() }
            } catch {
                let msg = (error as NSError).code == -999 ? "cancelled" : error.localizedDescription
                if msg == "cancelled" {
                    await MainActor.run { self?.cleanup() }
                } else {
                    print("[Baymax] Whisper failed: \(error)")
                    await MainActor.run {
                        self?.onError?("Transcription failed — try again")
                        self?.cleanup()
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func beginRecording() {
        guard !isListening else { return }

        transcript = ""
        audioLevel = 0
        transcriptionTask?.cancel()
        transcriptionTask = nil

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baymax_\(UUID().uuidString).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.prepareToRecord()
            guard recorder?.record() == true else {
                print("[Baymax] recorder.record() returned false")
                onError?("Microphone unavailable — try again")
                cleanup()
                return
            }
            isListening = true
            print("[Baymax] Recording started → \(url.lastPathComponent)")

            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeter() }
            }
            RunLoop.main.add(meterTimer!, forMode: .common)
        } catch {
            print("[Baymax] AVAudioRecorder init failed: \(error)")
            onError?("Could not start microphone: \(error.localizedDescription)")
            cleanup()
        }
    }

    private func updateMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        audioLevel = max(0, min(1, pow(10, power / 20) * 1.7))
    }

    private func cleanup() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        isListening = false
        audioLevel = 0
    }

    deinit { meterTimer?.invalidate() }
}
