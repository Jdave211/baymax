//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import IOKit
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionCharacter: String, CaseIterable, Identifiable {
    case baymax = "Baymax"
    case hiro = "Hiro"
    case fred = "Fred"
    case honey = "Honey Lemon"
    case wasabi = "Wasabi"
    case gogo = "Go Go"

    var id: String { rawValue }

    var envKey: String {
        switch self {
        case .baymax: return "VOICE_ID_BAYMAX"
        case .hiro: return "VOICE_ID_HIRO"
        case .fred: return "VOICE_ID_FRED"
        case .honey: return "VOICE_ID_HONEY"
        case .wasabi: return "VOICE_ID_WASABI"
        case .gogo: return "VOICE_ID_GOGO"
        }
    }

    var defaultVoiceId: String {
        switch self {
        case .baymax: return "fI7zKH1sH6G6Q8W6fnyw"
        case .hiro: return "6PLaTBXSaElahoG7pqck"
        case .fred: return "jCgWmtaY0UcN3OVQ1YIf"
        case .honey: return "dW8aMNf4RMYhX6RtnxEW"
        case .wasabi: return "ynfAdxqiG6IfLl9UeEDb"
        case .gogo: return "tGcrS0B6QK60wtUlhBGs"
        }
    }

    var voiceId: String {
        return DotEnv.get(envKey) ?? DotEnv.get("ELEVENLABS_VOICE_ID") ?? defaultVoiceId
    }

    var color: Color {
        switch self {
        case .baymax: return Color(white: 0.9) // offwhitish/silver
        case .hiro: return Color.indigo
        case .fred: return Color.blue
        case .honey: return Color(red: 1.0, green: 0.4, blue: 0.7) // brighter, more vibrant pink
        case .wasabi: return Color.green
        case .gogo: return Color.yellow
        }
    }

    var textColor: Color {
        switch self {
        case .baymax, .gogo, .honey:
            // Lighter backgrounds need dark text
            return Color.black.opacity(0.8)
        case .hiro, .fred, .wasabi:
            // Darker backgrounds need white text
            return Color.white
        }
    }
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(apiKey: "", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(apiKey: "", voiceId: selectedCharacter.voiceId)
    }()

    /// Conversation history so Claude remembers prior exchanges across sessions.
    /// Only the most recent 3 exchanges are kept verbatim. Older exchanges are
    /// condensed into `conversationSummary` by a background Haiku call, keeping
    /// token cost low on every subsequent interaction.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = {
        guard let jsonData = UserDefaults.standard.data(forKey: "conversationHistory"),
              let decoded = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: String]] else {
            return []
        }
        return decoded.compactMap { entry in
            guard let transcript = entry["userTranscript"],
                  let response = entry["assistantResponse"] else { return nil }
            return (userTranscript: transcript, assistantResponse: response)
        }
    }()

    /// Condensed recap of conversation exchanges older than the last 3.
    /// Generated asynchronously by a cheap Haiku call so it never blocks
    /// the main response pipeline. Prepended to the API history so Claude
    /// retains context from earlier in the session.
    private var conversationSummary: String? = UserDefaults.standard.string(forKey: "conversationSummary")

    /// Tracks the in-flight background summarization task to prevent
    /// duplicate concurrent calls.
    private var pendingSummarizationTask: Task<Void, Never>?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// Timestamp when the user released the push-to-talk key, used to measure
    /// how long transcription finalization takes.
    private var pushToTalkReleaseTime: CFAbsoluteTime?

    /// Pre-captured screenshots started at key release to overlap with STT finalization.
    private var pendingScreenCapture: Task<[CompanionScreenCapture], Error>?

    /// Worker proxy URL for logging and other server-side operations.
    /// Routing logs through the Worker uses the service_role key, bypassing
    /// RLS so inserts always succeed regardless of auth state.
    private let workerBaseURL = DotEnv.get("WORKER_URL") ?? "https://clicky-proxy.baymac.workers.dev"
    @Published private(set) var currentUserId: String? = UserDefaults.standard.string(forKey: "currentUserId")
    @Published private(set) var currentUserEmail: String? = UserDefaults.standard.string(forKey: "currentUserEmail")
    @Published private(set) var currentUserTier: String = UserDefaults.standard.string(forKey: "currentUserTier") ?? "free"
    @Published private(set) var currentAccessToken: String? = UserDefaults.standard.string(forKey: "currentUserToken")

    /// Stable per-machine identifier so anonymous (not signed in) users can be
    /// tracked against the free tier. Uses the macOS hardware UUID which persists
    /// across app reinstalls, preventing double free-tier abuse.
    lazy var deviceIdentifier: String = {
        let platformExpert = IOServiceGetMatchingService(
            kIOMasterPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )
        return (uuidCF?.takeRetainedValue() as? String) ?? UUID().uuidString
    }()

    /// The effective user ID for usage tracking. Uses the authenticated user ID
    /// if signed in, otherwise falls back to a device-based identifier.
    var effectiveUserId: String {
        currentUserId ?? "anon_\(deviceIdentifier)"
    }

    /// Whether the user is signed in with a real account.
    var isSignedIn: Bool {
        currentUserId != nil && currentAccessToken != nil
    }

    // Monthly usage tracking — resets on the 1st of each month
    @Published private(set) var monthlyInteractionCount: Int = UserDefaults.standard.integer(forKey: "monthlyInteractionCount")
    private var currentInteractionMonth: String? = UserDefaults.standard.string(forKey: "currentInteractionMonth")

    // Pay-as-you-go state for free users who enabled metered billing
    @Published private(set) var hasPayAsYouGo: Bool = UserDefaults.standard.bool(forKey: "hasPayAsYouGo")
    @Published private(set) var paygUsageThisPeriod: Int = UserDefaults.standard.integer(forKey: "paygUsageThisPeriod")
    @Published private(set) var paygCap: Int = UserDefaults.standard.integer(forKey: "paygCap") {
        didSet {
            UserDefaults.standard.set(paygCap, forKey: "paygCap")
        }
    }

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// The active voice/color profile.
    @Published var selectedCharacter: CompanionCharacter = {
        let saved = UserDefaults.standard.string(forKey: "selectedCompanionCharacter") ?? CompanionCharacter.baymax.rawValue
        return CompanionCharacter(rawValue: saved) ?? .baymax
    }()

    func setSelectedCharacter(_ character: CompanionCharacter) {
        selectedCharacter = character
        UserDefaults.standard.set(character.rawValue, forKey: "selectedCompanionCharacter")
        elevenLabsTTSClient.setVoiceId(character.voiceId)
    }

    /// User preference for whether the Baymax cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isBaymaxCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isBaymaxCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isBaymaxCursorEnabled")

    func setBaymaxCursorEnabled(_ enabled: Bool) {
        isBaymaxCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isBaymaxCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Authentication & Limits

    /// Opens the landing page with `?client=mac` so the user can sign in with
    /// Google via Supabase OAuth. After sign-in, the landing page redirects to
    /// `baymac://auth?access_token=...&userId=...` which the app catches via
    /// `handleAuthCallback`.
    func signInWithGoogle() {
        let landingPageURL = DotEnv.get("LANDING_PAGE_URL") ?? "https://baymac.app"
        if let url = URL(string: "\(landingPageURL)?client=mac") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Handles the `baymac://auth` callback from the landing page after Google
    /// OAuth completes. Parses `access_token` and `userId` from query params
    /// or fragment, fetches user info + tier from Supabase, and logs in.
    func handleAuthCallback(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        var token: String?
        var userId: String?

        // Tokens can arrive as query params or in the URL fragment
        let queryItems = components.queryItems ?? []
        for item in queryItems {
            if item.name == "access_token" { token = item.value }
            if item.name == "userId" { userId = item.value }
        }

        if let fragment = components.fragment {
            let fragmentItems = fragment.components(separatedBy: "&").map {
                let pair = $0.components(separatedBy: "=")
                return (pair[0], pair.count > 1 ? pair[1] : "")
            }
            for item in fragmentItems {
                if item.0 == "access_token" { token = item.1 }
                if item.0 == "userId" { userId = item.1 }
            }
        }

        guard let accessToken = token else {
            print("⚠️ Baymax: Missing access_token in auth callback")
            return
        }

        do {
            // If the landing page didn't include userId (e.g., OAuth fragment
            // flow), fetch it from the Supabase user endpoint
            let resolvedUserId: String
            if let uid = userId, !uid.isEmpty {
                resolvedUserId = uid
            } else {
                guard let userInfo = try await SupabaseAuthClient.shared.fetchUserInfo(accessToken: accessToken) else {
                    print("⚠️ Baymax: Could not fetch user info from access token")
                    return
                }
                resolvedUserId = userInfo.userId
            }

            let tier = try await SupabaseAuthClient.shared.fetchTier(userId: resolvedUserId, accessToken: accessToken)
            let email = try await SupabaseAuthClient.shared.fetchUserEmail(accessToken: accessToken)

            await MainActor.run {
                self.currentAccessToken = accessToken
                self.currentUserId = resolvedUserId
                if let e = email { self.currentUserEmail = e }
                self.currentUserTier = tier

                if let e = email { UserDefaults.standard.set(e, forKey: "currentUserEmail") }
                UserDefaults.standard.set(tier, forKey: "currentUserTier")
                UserDefaults.standard.set(accessToken, forKey: "currentUserToken")
                UserDefaults.standard.set(resolvedUserId, forKey: "currentUserId")

                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .baymaxShowPanel, object: nil)

                syncUsageFromServer()
                syncPaygStatus()
            }
        } catch {
            print("⚠️ Baymax: Failed to verify session: \(error)")
        }
    }

    
    func logout() {
        self.currentUserEmail = nil
        self.currentUserTier = "free"
        self.currentAccessToken = nil
        self.currentUserId = nil
        self.conversationHistory = []
        self.conversationSummary = nil
        self.pendingSummarizationTask?.cancel()
        self.pendingSummarizationTask = nil
        
        UserDefaults.standard.removeObject(forKey: "currentUserEmail")
        UserDefaults.standard.removeObject(forKey: "currentUserTier")
        UserDefaults.standard.removeObject(forKey: "currentUserToken")
        UserDefaults.standard.removeObject(forKey: "currentUserId")
        UserDefaults.standard.removeObject(forKey: "conversationHistory")
        UserDefaults.standard.removeObject(forKey: "conversationSummary")
        UserDefaults.standard.removeObject(forKey: "monthlyInteractionCount")
        UserDefaults.standard.removeObject(forKey: "currentInteractionMonth")
        UserDefaults.standard.removeObject(forKey: "hasPayAsYouGo")
        UserDefaults.standard.removeObject(forKey: "paygUsageThisPeriod")
        UserDefaults.standard.removeObject(forKey: "paygCap")
    }

    /// Writes the current conversationHistory and conversationSummary to
    /// UserDefaults so context survives app restarts.
    private func persistConversationHistory() {
        let serializable = conversationHistory.map { entry in
            ["userTranscript": entry.userTranscript, "assistantResponse": entry.assistantResponse]
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: serializable) {
            UserDefaults.standard.set(jsonData, forKey: "conversationHistory")
        }

        if let summary = conversationSummary {
            UserDefaults.standard.set(summary, forKey: "conversationSummary")
        } else {
            UserDefaults.standard.removeObject(forKey: "conversationSummary")
        }
    }

    /// Summarizes older conversation exchanges (beyond the last 3) into a
    /// ~100-token recap using a cheap Haiku call. Runs in the background so
    /// it never blocks the response pipeline or adds latency to the user's
    /// next interaction. Cost is negligible (~$0.0001 per summarization).
    private func triggerBackgroundSummarization() {
        guard pendingSummarizationTask == nil else { return }

        let exchangesToSummarizeCount = conversationHistory.count - 3
        guard exchangesToSummarizeCount > 0 else { return }

        let exchangesToSummarize = Array(conversationHistory.prefix(exchangesToSummarizeCount))
        let existingSummary = conversationSummary

        pendingSummarizationTask = Task {
            do {
                var promptParts: [String] = []

                if let existingSummary {
                    promptParts.append("Previous conversation summary:\n\(existingSummary)")
                }

                promptParts.append("New exchanges to incorporate:")
                for exchange in exchangesToSummarize {
                    promptParts.append("User: \(exchange.userTranscript)")
                    promptParts.append("Assistant: \(exchange.assistantResponse)")
                }

                promptParts.append("""
                    Summarize ALL of the above into a single concise paragraph \
                    of about 100 tokens. Capture key topics discussed, decisions \
                    made, and important context the assistant should remember. \
                    Write in third person past tense. Do not use bullet points.
                    """)

                let summarizationPrompt = promptParts.joined(separator: "\n")
                let summary = try await claudeAPI.summarizeText(prompt: summarizationPrompt)

                conversationSummary = summary

                if conversationHistory.count > 3 {
                    conversationHistory.removeFirst(conversationHistory.count - 3)
                }

                persistConversationHistory()
                print("🧠 Summarized \(exchangesToSummarize.count) older exchanges (\(summary.count) chars)")
            } catch {
                print("⚠️ Background summarization failed (non-blocking): \(error)")
            }

            pendingSummarizationTask = nil
        }
    }

    /// Monthly interaction caps per tier. Priced for healthy margins at
    /// ~$0.020/interaction (960px screenshots, history summarization, prompt
    /// caching, ElevenLabs TTS). Monthly caps instead of daily because they
    /// feel less punitive and let users have heavy + light days naturally.
    ///
    /// | Tier     | Cap/mo | Price   | Max cost | Margin at avg 40% usage |
    /// |----------|--------|---------|----------|------------------------|
    /// | Free     | 25     | $0      | $0.50    | -$0.20 (acquisition)   |
    /// | Pro      | 500    | $10/mo  | $10.00   | $6.00 (60%)            |
    /// | Max      | 1500   | $25/mo  | $30.00   | $13.00 (52%)           |
    /// | Lifetime | 500    | $149    | $10/mo   | break-even ~25mo       |
    static func monthlyLimitForTier(_ tier: String) -> Int {
        switch tier {
        case "pro": return 500
        case "max": return 1500
        case "lifetime": return 500
        default: return 20
        }
    }

    /// The monthly interaction cap for the current user's tier.
    var monthlyInteractionLimit: Int {
        Self.monthlyLimitForTier(currentUserTier)
    }

    /// Returns true if the user has hit their monthly interaction cap.
    /// For free users with pay-as-you-go enabled, checks the payg cap instead.
    /// Resets the counter when the calendar month rolls over.
    func isMonthlyLimitExceeded() -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let thisMonth = formatter.string(from: Date())

        if currentInteractionMonth != thisMonth {
            currentInteractionMonth = thisMonth
            monthlyInteractionCount = 0
            paygUsageThisPeriod = 0
            UserDefaults.standard.set(thisMonth, forKey: "currentInteractionMonth")
            UserDefaults.standard.set(0, forKey: "monthlyInteractionCount")
            UserDefaults.standard.set(0, forKey: "paygUsageThisPeriod")
        }

        // Free users with pay-as-you-go: check payg cap after free tier exhausted
        if currentUserTier == "free" && hasPayAsYouGo {
            if monthlyInteractionCount < monthlyInteractionLimit {
                return false // Still within free tier
            }
            return paygUsageThisPeriod >= paygCap // Check payg cap
        }

        return monthlyInteractionCount >= monthlyInteractionLimit
    }

    /// Returns true if this interaction should be billed to pay-as-you-go.
    /// Only true for free users who have exhausted their free tier.
    private var shouldBillToPayg: Bool {
        currentUserTier == "free" && hasPayAsYouGo && monthlyInteractionCount >= monthlyInteractionLimit
    }

    /// Bumps the monthly interaction counter. Called after a successful
    /// Claude response + TTS cycle, not at the start of recording.
    private func incrementMonthlyInteractionCount() {
        monthlyInteractionCount += 1
        UserDefaults.standard.set(monthlyInteractionCount, forKey: "monthlyInteractionCount")
    }

    /// Speaks a natural limit-exceeded message via TTS so the user knows
    /// why their push-to-talk didn't do anything.
    private func speakLimitExceededMessage() {
        let message: String

        switch currentUserTier {
        case "free":
            if hasPayAsYouGo && paygUsageThisPeriod >= paygCap {
                message = "you've hit your pay-as-you-go cap for the month. upgrade to pro for more, or wait until next month."
            } else {
                message = "hey, you've hit your free limit for the month. head to baymac dot app to upgrade or enable pay-as-you-go."
            }
        case "pro":
            message = "you've hit your monthly limit on pro. upgrade to max for more, or it resets next month."
        default:
            message = "you've hit your monthly limit. it resets at the start of next month."
        }

        speakErrorMessage(message)
    }

    /// Speaks an error message to the user via TTS, falling back to the system
    /// voice synthesizer if ElevenLabs is unavailable.
    private func speakErrorMessage(_ message: String) {
        Task {
            do {
                try await elevenLabsTTSClient.speakText(message)
                voiceState = .responding
            } catch {
                let synthesizer = NSSpeechSynthesizer()
                synthesizer.startSpeaking(message)
                voiceState = .responding
            }
        }
    }

    /// Reports one interaction to Stripe for pay-as-you-go billing.
    /// Called after a successful interaction for free users who have
    /// exhausted their free tier and enabled pay-as-you-go.
    private func reportPaygUsage() {
        guard let userId = currentUserId, shouldBillToPayg else { return }

        Task {
            do {
                let payload: [String: Any] = ["userId": userId]
                var request = URLRequest(url: URL(string: "\(workerBaseURL)/stripe/report-usage")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let usage = json["usage"] as? Int {
                    paygUsageThisPeriod = usage
                    UserDefaults.standard.set(usage, forKey: "paygUsageThisPeriod")
                    print("💳 Pay-as-you-go usage reported: \(usage)/\(paygCap)")
                }
            } catch {
                print("⚠️ Pay-as-you-go usage report failed: \(error)")
            }
        }
    }

    /// Syncs pay-as-you-go status from the server.
    func syncPaygStatus() {
        guard let userId = currentUserId else { return }

        Task {
            do {
                let payload: [String: Any] = ["userId": userId]
                var request = URLRequest(url: URL(string: "\(workerBaseURL)/stripe/payg-status")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if let enabled = json["enabled"] as? Bool {
                    hasPayAsYouGo = enabled
                    UserDefaults.standard.set(enabled, forKey: "hasPayAsYouGo")
                }
                if let usage = json["usage"] as? Int {
                    paygUsageThisPeriod = usage
                    UserDefaults.standard.set(usage, forKey: "paygUsageThisPeriod")
                }
                if let cap = json["cap"] as? Int {
                    paygCap = cap
                }

                print("💳 Pay-as-you-go status: \(hasPayAsYouGo ? "enabled" : "disabled"), usage: \(paygUsageThisPeriod)/\(paygCap)")
            } catch {
                print("⚠️ Pay-as-you-go status sync failed: \(error)")
            }
        }
    }

    /// Fetches the server-side interaction count for today so the local
    /// cache stays in sync with actual logged usage. Called on launch and
    /// after login. Non-blocking — failures are silently ignored.
    func syncUsageFromServer() {
        guard let userId = currentUserId else { return }

        Task {
            do {
                let payload: [String: Any] = ["userId": userId]
                var request = URLRequest(url: URL(string: "\(workerBaseURL)/usage")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }

                if let serverCount = json["interactionsThisMonth"] as? Int {
                    monthlyInteractionCount = serverCount
                    UserDefaults.standard.set(serverCount, forKey: "monthlyInteractionCount")

                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM"
                    let thisMonth = formatter.string(from: Date())
                    currentInteractionMonth = thisMonth
                    UserDefaults.standard.set(thisMonth, forKey: "currentInteractionMonth")
                }

                if let serverTier = json["tier"] as? String, serverTier != currentUserTier {
                    currentUserTier = serverTier
                    UserDefaults.standard.set(serverTier, forKey: "currentUserTier")
                }

                print("📊 Usage synced from server: \(monthlyInteractionCount)/\(monthlyInteractionLimit) this month")
            } catch {
                print("⚠️ Usage sync failed (non-blocking): \(error)")
            }
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Baymax start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        _ = claudeAPI

        // Sync usage from server so local cache reflects actual logged interactions
        syncUsageFromServer()
        syncPaygStatus()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isBaymaxCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .baymaxDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        BaymaxAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .baymaxDismissPanel, object: nil)
        BaymaxAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Baymax: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Baymax: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            BaymaxAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            BaymaxAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            BaymaxAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            BaymaxAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    BaymaxAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isBaymaxCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding or .processing while the AI
                // response pipeline is running — it manages those states
                // directly until TTS finishes.
                if self.currentResponseTask != nil
                    && (self.voiceState == .responding || self.voiceState == .processing) {
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    let wasProcessing = self.voiceState == .processing || self.voiceState == .listening
                    self.voiceState = .idle
                    if wasProcessing && self.currentResponseTask == nil {
                        print("⚠️ Dictation ended without triggering AI response — likely empty transcript or mic issue")
                        self.pendingScreenCapture?.cancel()
                        self.pendingScreenCapture = nil

                        // If the dictation manager set an error message (e.g. no mic
                        // detected, no speech timeout), speak it so the user knows why
                        if let errorMessage = self.buddyDictationManager.lastErrorMessage {
                            self.speakErrorMessage(errorMessage)
                        }
                    }
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            // Check daily limit BEFORE starting recording so the user doesn't
            // speak into the void when they've already hit their cap
            if isMonthlyLimitExceeded() {
                speakLimitExceededMessage()
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isBaymaxCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .baymaxDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            BaymaxAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        if let releaseTime = self?.pushToTalkReleaseTime {
                            let transcribeDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - releaseTime) * 1000)
                            print("⏱️ Transcription finalized in \(transcribeDurationMilliseconds)ms")
                        }
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        BaymaxAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            BaymaxAnalytics.trackPushToTalkReleased()
            pushToTalkReleaseTime = CFAbsoluteTimeGetCurrent()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil

            // Start capturing screenshots immediately so they overlap with STT
            // finalization instead of waiting until the transcript is ready.
            pendingScreenCapture = Task {
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            }

            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're baymac, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    multi-step guidance:
    when the user asks how to do something that requires multiple steps, break it down clearly. give them the FIRST step to do right now, point at the relevant element, and tell them what comes next. for example: "first, click the file menu up top. once that opens, you'll see an export option — click that, then choose the format you want." give the full roadmap in your spoken response so they know the whole process, but point at the FIRST thing they need to interact with. when they come back after completing a step (they'll press push-to-talk again), look at the screen to see where they are now and guide them through the next step. you have conversation history, so you'll know what step they're on. be adaptive — if they skipped ahead or did something different, adjust accordingly.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    - user asks how to create a new project in xcode: "first, go up to file in the menu bar. from there you'll hit new, then project, and you'll get a template picker where you can choose what kind of app you want. [POINT:42,11:file menu]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        print("🧠 CompanionManager: sendTranscriptToClaudeWithScreenshot called with transcript: '\(transcript)'")
        BaymaxDebugLog.log("sendTranscriptToClaudeWithScreenshot: '\(transcript)'")
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            let pipelineStartTime = CFAbsoluteTimeGetCurrent()

            do {
                // Use pre-captured screenshots (started at key release) if available,
                // otherwise capture fresh. This overlaps screenshot capture with STT
                // finalization, shaving ~200-500ms off the pipeline.
                let screenshotStartTime = CFAbsoluteTimeGetCurrent()
                let screenCaptures: [CompanionScreenCapture]
                if let pending = pendingScreenCapture {
                    pendingScreenCapture = nil
                    do {
                        screenCaptures = try await pending.value
                    } catch {
                        print("⚠️ Pre-captured screenshot failed, trying fresh capture: \(error.localizedDescription)")
                        screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
                    }
                } else {
                    screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
                }
                let screenshotDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - screenshotStartTime) * 1000)

                if screenCaptures.isEmpty {
                    print("⚠️ No screenshots captured — Screen Recording permission may not be granted. Proceeding without screenshots.")
                }

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Build API history: prepend the condensed summary of older
                // exchanges (if any), then include the recent verbatim exchanges.
                var historyForAPI: [(userPlaceholder: String, assistantResponse: String)] = []

                if let summary = conversationSummary {
                    historyForAPI.append((
                        userPlaceholder: "[Earlier conversation context: \(summary)]",
                        assistantResponse: "got it, i remember our earlier conversation."
                    ))
                }

                historyForAPI += conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let claudeStartTime = CFAbsoluteTimeGetCurrent()
                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )
                let claudeDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - claudeStartTime) * 1000)

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    BaymaxAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // When more than 3 exchanges exist, summarize the older ones
                // in the background via a cheap Haiku call. This keeps the
                // verbatim history small (3 exchanges) while retaining context
                // from the full conversation via the condensed summary.
                if conversationHistory.count > 3 {
                    triggerBackgroundSummarization()
                }

                persistConversationHistory()
                print("🧠 Conversation history: \(conversationHistory.count) verbatim + \(conversationSummary != nil ? "summary" : "no summary")")

                BaymaxAnalytics.trackAIResponseReceived(response: spokenText)

                // Count this as a successful interaction against the monthly limit.
                // Placed here (after Claude response) rather than at recording start
                // so failed/cancelled attempts don't consume the user's quota.
                incrementMonthlyInteractionCount()

                // If this interaction should be billed to pay-as-you-go, report it
                if shouldBillToPayg {
                    reportPaygUsage()
                }

                // Log interaction through the Worker proxy which uses the
                // service_role key, bypassing RLS so inserts always succeed.
                if let userId = currentUserId {
                    Task {
                        do {
                            let logPayload: [String: Any] = [
                                "userId": userId,
                                "transcript": transcript,
                                "aiResponse": spokenText,
                                "characterName": selectedCharacter.rawValue,
                                "characterColor": selectedCharacter.color.description,
                            ]
                            
                            var request = URLRequest(url: URL(string: "\(workerBaseURL)/log")!)
                            request.httpMethod = "POST"
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            request.httpBody = try JSONSerialization.data(withJSONObject: logPayload)
                            
                            let (_, response) = try await URLSession.shared.data(for: request)
                            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 300 {
                                print("⚠️ Worker log error: HTTP \(httpResponse.statusCode)")
                            } else {
                                print("✅ Interaction logged via Worker")
                            }
                        } catch {
                            print("⚠️ Worker log error: \(error)")
                        }
                    }
                }

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        let ttsStartTime = CFAbsoluteTimeGetCurrent()
                        try await elevenLabsTTSClient.speakText(spokenText)
                        let ttsDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - ttsStartTime) * 1000)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding

                        let totalPipelineDurationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - pipelineStartTime) * 1000)
                        print("⏱️ Pipeline timing — Screenshot: \(screenshotDurationMilliseconds)ms | Claude: \(claudeDurationMilliseconds)ms | TTS: \(ttsDurationMilliseconds)ms | Total: \(totalPipelineDurationMilliseconds)ms")
                    } catch {
                        BaymaxAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakAPIErrorFallback(error: error, service: "ElevenLabs")
                    }
                } else {
                    print("⚠️ Claude returned empty response for transcript: \(transcript)")
                    do {
                        try await elevenLabsTTSClient.speakText("sorry, i didn't catch that. try again?")
                        voiceState = .responding
                    } catch {
                        let synthesizer = NSSpeechSynthesizer()
                        synthesizer.startSpeaking("sorry, i didn't catch that. try again?")
                        voiceState = .responding
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                BaymaxAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakAPIErrorFallback(error: error, service: "Anthropic Claude")
            }

            if !Task.isCancelled {
                voiceState = .idle
                currentResponseTask = nil
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Baymax" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isBaymaxCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a dynamic error message using macOS system TTS when API
    /// credits run out or another API error occurs.
    private func speakAPIErrorFallback(error: Error, service: String) {
        let errorDesc = error.localizedDescription.lowercased()
        let utterance: String
        
        if errorDesc.contains("credit balance is too low") || errorDesc.contains("out of credits") || errorDesc.contains("402") {
            utterance = "Your \(service) API credits have run out. Please check your billing dashboard."
        } else if errorDesc.contains("401") || errorDesc.contains("unauthorized") {
            utterance = "Your \(service) API key is invalid or expired."
        } else {
            utterance = "A \(service) API error occurred. Check the Xcode console for details."
        }
        
        // Try to use ElevenLabs first if the error wasn't ElevenLabs itself
        if service != "ElevenLabs" {
            Task {
                do {
                    try await elevenLabsTTSClient.speakText(utterance)
                    voiceState = .responding
                } catch {
                    let synthesizer = NSSpeechSynthesizer()
                    synthesizer.startSpeaking(utterance)
                    voiceState = .responding
                }
            }
        } else {
            let synthesizer = NSSpeechSynthesizer()
            synthesizer.startSpeaking(utterance)
            voiceState = .responding
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Baymax flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            BaymaxAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            BaymaxAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're baymac, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
