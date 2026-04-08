import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isActive = false
    @Published var mode: AssistantMode = .idle

    // Positions (top-left origin, matching SwiftUI coords in full-screen overlay)
    @Published var cursorPosition: CGPoint = .zero
    @Published var characterPosition: CGPoint = CGPoint(x: 100, y: 100)

    // Voice state
    @Published var isRecording = false
    @Published var liveTranscript = ""

    // Teaching state
    @Published var highlightRegion: ScreenRegion? = nil
    @Published var currentStepIndex: Int = 0
    @Published var totalSteps: Int = 0
    @Published var currentLabel: String? = nil
    @Published var spokenSubtitle: String? = nil

    // Multi-LLM Provider
    @Published var llmProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: "baymax_llm_provider")
            currentApiKey = apiKey(for: llmProvider)
        }
    }

    @Published var currentApiKey: String {
        didSet {
            setApiKey(currentApiKey, for: llmProvider)
        }
    }

    // Voice Provider
    @Published var elevenLabsKey: String {
        didSet { UserDefaults.standard.set(elevenLabsKey, forKey: "baymax_elevenlabs_key") }
    }
    @Published var elevenLabsVoiceId: String {
        didSet { UserDefaults.standard.set(elevenLabsVoiceId, forKey: "baymax_elevenlabs_voice") }
    }

    // Helpers
    var openAIKey: String { apiKey(for: .openai) }

    var dockedPosition: CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 100, y: 100) }
        return CGPoint(x: screen.frame.width - 100, y: screen.frame.height - 120)
    }

    init() {
        let env = DotEnv.load()
        let savedProviderName = UserDefaults.standard.string(forKey: "baymax_llm_provider") ?? LLMProvider.openai.rawValue
        let provider = LLMProvider(rawValue: savedProviderName) ?? .openai
        self.llmProvider = provider

        let resolvedKey = env[provider.envKey]
            ?? UserDefaults.standard.string(forKey: "baymax_key_\(provider.rawValue)")
            ?? ""
        self.currentApiKey = resolvedKey

        let resolvedELKey = env["ELEVENLABS_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "baymax_elevenlabs_key")
            ?? ""
        self.elevenLabsKey = resolvedELKey

        let resolvedVoiceId = env["ELEVENLABS_VOICE_ID"]
            ?? UserDefaults.standard.string(forKey: "baymax_elevenlabs_voice")
            ?? "21m00Tcm4TlvDq8ikWAM"
        self.elevenLabsVoiceId = resolvedVoiceId

        // didSet doesn't fire during init — persist loaded values explicitly
        if !resolvedKey.isEmpty {
            UserDefaults.standard.set(resolvedKey, forKey: "baymax_key_\(provider.rawValue)")
        }
        if !resolvedELKey.isEmpty {
            UserDefaults.standard.set(resolvedELKey, forKey: "baymax_elevenlabs_key")
        }
        UserDefaults.standard.set(resolvedVoiceId, forKey: "baymax_elevenlabs_voice")

        // Also persist keys for all other providers from .env so switching works
        for p in LLMProvider.allCases where p != provider {
            if let envVal = env[p.envKey], !envVal.isEmpty {
                UserDefaults.standard.set(envVal, forKey: "baymax_key_\(p.rawValue)")
            }
        }

        print("[Baymax] AppState init — provider: \(provider.rawValue)")
        print("[Baymax]   currentApiKey: \(resolvedKey.isEmpty ? "EMPTY" : "\(resolvedKey.prefix(8))...")")
        print("[Baymax]   openAI (UD):   \(apiKey(for: .openai).isEmpty ? "EMPTY" : "\(apiKey(for: .openai).prefix(8))...")")
        print("[Baymax]   elevenLabs:    \(resolvedELKey.isEmpty ? "EMPTY" : "\(resolvedELKey.prefix(8))...")")
    }

    func apiKey(for provider: LLMProvider) -> String {
        UserDefaults.standard.string(forKey: "baymax_key_\(provider.rawValue)") ?? ""
    }

    func setApiKey(_ key: String, for provider: LLMProvider) {
        UserDefaults.standard.set(key, forKey: "baymax_key_\(provider.rawValue)")
    }

    func hasValidProvider() -> Bool {
        return !currentApiKey.isEmpty
    }

    func reset() {
        mode = .idle
        isRecording = false
        liveTranscript = ""
        highlightRegion = nil
        currentStepIndex = 0
        totalSteps = 0
        currentLabel = nil
        spokenSubtitle = nil
    }
}
