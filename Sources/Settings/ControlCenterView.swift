import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI (GPT-5.4 mini)"
    case anthropic = "Anthropic (Claude 3.5)"
    case gemini = "Google (Gemini 1.5 Flash)"
    case deepseek = "DeepSeek (V3)"

    var id: String { rawValue }

    var envKey: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
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
                    .fill(Color(hex: "3B82F6")) // Blue dot
                    .frame(width: 8, height: 8)
                    .shadow(color: Color(hex: "3B82F6").opacity(0.6), radius: 4)

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

            // Permissions
            VStack(alignment: .leading, spacing: 12) {
                Text("PERMISSIONS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(0.5)

                permissionRow(
                    title: "Screen Recording",
                    granted: appState.screenRecordingGranted,
                    actionTitle: "Grant"
                ) {
                    Task { @MainActor in
                        _ = await AppDelegate.shared.requestScreenRecordingPermission()
                    }
                }

                permissionRow(
                    title: "Accessibility",
                    granted: appState.accessibilityGranted,
                    actionTitle: "Grant"
                ) {
                    AppDelegate.shared.promptAccessibilityIfNeeded()
                    AppDelegate.shared.openAccessibilitySettings()
                }

                permissionRow(
                    title: "Microphone",
                    granted: appState.microphoneGranted,
                    actionTitle: "Grant"
                ) {
                    AppDelegate.shared.requestMicrophonePermission()
                }
            }
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
            }
            .padding(20)

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

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? Color(hex: "3B82F6") : Color(hex: "F59E0B"))
                .frame(width: 7, height: 7)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hex: "3B82F6"))
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
