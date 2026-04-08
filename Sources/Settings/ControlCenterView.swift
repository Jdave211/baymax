import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI (GPT-4o mini)"
    case anthropic = "Anthropic (Claude 3.5)"
    case gemini = "Google (Gemini 1.5 Flash)"
    case deepseek = "DeepSeek (V3)"

    var id: String { rawValue }

    var envKey: String {
        switch self {
        case .openai: return "BAYMAX_OPENAI_KEY"
        case .anthropic: return "BAYMAX_ANTHROPIC_KEY"
        case .gemini: return "BAYMAX_GEMINI_KEY"
        case .deepseek: return "BAYMAX_DEEPSEEK_KEY"
        }
    }
}

struct ControlCenterView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: "22C55E")) // Green dot
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(hex: "22C55E").opacity(0.6), radius: 4)

                Text("Baymax")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Text("Active")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .background(.white.opacity(0.1))

            // Info
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)

                Text("Baymax only captures your screen while you hold the hotkeys. No background recording.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()
                .background(.white.opacity(0.1))

            // LLM Settings
            VStack(alignment: .leading, spacing: 16) {
                Text("AI PROVIDER")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(0.5)

                Picker("", selection: $appState.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()

                SecureField("API Key", text: $appState.currentApiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .padding(20)

            Spacer(minLength: 0)

            Divider()
                .background(.white.opacity(0.1))

            // Footer
            HStack {
                Button(action: quit) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                        Text("Quit Baymax")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(hex: "1C1C1E"))
        .environment(\.colorScheme, .dark)
    }

    private func quit() {
        AppDelegate.shared.quitApp()
    }
}
