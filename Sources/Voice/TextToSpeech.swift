import AVFoundation

/// Voice engine — ElevenLabs primary, OpenAI fallback, system synth last resort.
@MainActor
final class TextToSpeech {
    private let elevenLabsKey: String
    private let elevenLabsVoiceId: String
    private let openAIKey: String
    private var audioPlayer: AVAudioPlayer?
    private let systemSynth = AVSpeechSynthesizer()
    private var currentTask: Task<Void, Never>?

    init(elevenLabsKey: String, elevenLabsVoiceId: String, openAIKey: String) {
        self.elevenLabsKey = elevenLabsKey
        self.elevenLabsVoiceId = elevenLabsVoiceId
        self.openAIKey = openAIKey
    }

    /// Fire-and-forget. Speaks text asynchronously.
    func play(_ text: String) {
        currentTask?.cancel()
        currentTask = Task { await speakAsync(text) }
    }

    /// Awaitable — blocks until audio finishes.
    func speakAndWait(_ text: String) async {
        await speakAsync(text)
    }

    func stop() {
        currentTask?.cancel()
        audioPlayer?.stop()
        systemSynth.stopSpeaking(at: .immediate)
    }

    // MARK: - Internal

    private func speakAsync(_ text: String) async {
        guard !text.isEmpty else { return }

        // 1. Try ElevenLabs
        if !elevenLabsKey.isEmpty {
            do {
                let client = ElevenLabsClient(apiKey: elevenLabsKey)
                let mp3Data = try await client.textToSpeech(
                    text: text,
                    voiceId: elevenLabsVoiceId.isEmpty ? AppState.defaultElevenLabsVoiceId : elevenLabsVoiceId
                )

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("baymax_\(UUID().uuidString).mp3")
                try mp3Data.write(to: tempURL)

                audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
                audioPlayer?.play()

                while audioPlayer?.isPlaying == true {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }

                try? FileManager.default.removeItem(at: tempURL)
                return
            } catch {
                // Fall through
            }
        }

        // 2. Try OpenAI TTS
        if !openAIKey.isEmpty {
            do {
                let client = OpenAIClient(apiKey: openAIKey)
                let audioData = try await client.textToSpeech(text: text, voice: "alloy")

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("baymax_\(UUID().uuidString).aac")
                try audioData.write(to: tempURL)

                audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
                audioPlayer?.play()

                while audioPlayer?.isPlaying == true {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }

                try? FileManager.default.removeItem(at: tempURL)
                return
            } catch {
                // Fall through
            }
        }

        // 3. System fallback
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.05
        systemSynth.speak(utterance)
    }
}
