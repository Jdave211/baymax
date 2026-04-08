import SwiftUI

struct OverlayContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Spotlight annotation
                if appState.mode == .teaching, let region = appState.highlightRegion {
                    AnnotationView(region: region, screenSize: geo.size)
                        .transition(.opacity)
                }

                // Baymax cursor (Character) + Context Label
                ZStack(alignment: .topLeading) {
                    CharacterView(mode: appState.mode)

                    if let label = appState.currentLabel {
                        ContextLabel(text: label)
                            // Offset label right and down from the cursor body
                            .offset(x: 48, y: 36)
                            .id(label)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.4).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .position(appState.characterPosition)
                .animation(
                    .spring(response: 0.35, dampingFraction: 0.72),
                    value: appState.characterPosition
                )

                // Live transcript (only when user is actively speaking)
                if appState.isRecording && !appState.liveTranscript.isEmpty {
                    Text(appState.liveTranscript)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                        )
                        .frame(maxWidth: 220)
                        .position(
                            x: appState.characterPosition.x,
                            y: appState.characterPosition.y + 40
                        )
                        .animation(
                            .spring(response: 0.35, dampingFraction: 0.72),
                            value: appState.characterPosition
                        )
                        .transition(.opacity)
                }

                // Faint subtitle of what Baymax is saying
                if let subtitle = appState.spokenSubtitle,
                   appState.mode == .teaching || appState.mode == .thinking {
                    TranscriptBubble(text: subtitle)
                        .position(
                            x: subtitleX(in: geo.size),
                            y: appState.characterPosition.y - 50
                        )
                        .id(subtitle)
                        .transition(.opacity)
                }

                // Step counter
                if appState.mode == .teaching && appState.totalSteps > 0 {
                    StepBadge(
                        current: appState.currentStepIndex + 1,
                        total: appState.totalSteps
                    )
                    .position(
                        x: appState.characterPosition.x,
                        y: appState.characterPosition.y + 40
                    )
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.72),
                        value: appState.characterPosition
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private func subtitleX(in screenSize: CGSize) -> CGFloat {
        let charX = appState.characterPosition.x
        let offset: CGFloat = charX > screenSize.width / 2 ? -160 : 160
        return (charX + offset).clamped(to: 160...screenSize.width - 160)
    }
}

// MARK: - Step Badge

struct StepBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("Step \(current) of \(total)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }
}
