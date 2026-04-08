import SwiftUI
import AppKit

/// Cursor companion rendered from the provided asset.
/// Background stays clear; the cursor's own shadow is preserved.
struct CharacterView: View {
    let mode: AssistantMode

    @State private var floating = false
    @State private var isBlinking = false

    var body: some View {
        ZStack {
            ZStack {
                if mode == .listening {
                    ListeningAccent()
                        .scaleEffect(floating ? 1.03 : 0.98)
                        .rotationEffect(.degrees(-2))
                } else {
                    cursorImage
                        .overlay(alignment: .center) {
                            stateOverlay
                        }
                        .scaleEffect(floating ? 1.03 : 0.98)
                        .rotationEffect(.degrees(-2))
                }
            }
            .offset(y: floating ? -3 : 3)
        }
        .frame(width: 44, height: 46)
        .onAppear {
            floating = true
            startBlinkLoop()
        }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: floating)
    }

    private var cursorImage: some View {
        Image(nsImage: Self.cursorNSImage)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: 37.5, height: 37.5)
            // Nudge the image so the tip behaves like the anchor point.
            .offset(x: -1, y: -3)
            .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
            .background(Color.clear)
    }

    private static var cursorNSImage: NSImage {
        let candidates = [
            "/Users/davejaga/Desktop/Startups/baymax/assets/base-cursor.png",
            "/Users/davejaga/Desktop/Startups/baymax/Resources/Assets.xcassets/BaseCursor.imageset/base-cursor.png",
            "/Users/davejaga/Desktop/Startups/baymax/Resources/Assets/base-cursor.png",
            "/Users/davejaga/Desktop/Startups/baymax/Resources/base-cursor.png"
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                return image
            }
        }

        return NSImage(size: .init(width: 72, height: 72))
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .listening:
            ListeningAccent()
        case .thinking:
            LoadingAccent()
        case .teaching:
            TalkingAccent()
        }
    }

    private func startBlinkLoop() {
        func blink() {
            let delay = Double.random(in: 2.8...5.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.08)) { isBlinking = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeInOut(duration: 0.08)) { isBlinking = false }
                    blink()
                }
            }
        }

        blink()
    }
}

// MARK: - Idle

private struct IdleAccent: View {
    let isBlinking: Bool

    var body: some View {
        // Keep it extremely subtle in idle; the asset itself is the star.
        Group {
            if isBlinking {
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 16, height: 2)
                    .offset(y: -1)
            }
        }
        .animation(.easeInOut(duration: 0.08), value: isBlinking)
    }
}

// MARK: - Listening

private struct ListeningAccent: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(hex: "22C55E"))
                        .frame(width: 2.5, height: barHeight(index: i))
                        .shadow(color: Color(hex: "22C55E").opacity(0.55), radius: 2)
                }
            }
        }
        .frame(width: 36, height: 36)
        .onAppear { pulse = true }
        .animation(
            .easeInOut(duration: 0.28).repeatForever(autoreverses: true),
            value: pulse
        )
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = 4
        let heights: [CGFloat] = [7, 12, 6, 10, 7]
        return pulse ? heights[index] : base
    }
}

// MARK: - Thinking

private struct LoadingAccent: View {
    @State private var move = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(hex: "FBBF24").opacity(0.18))
                .frame(width: 28, height: 4)
                .offset(y: 24)

            Circle()
                .fill(Color(hex: "FBBF24"))
                .frame(width: 8, height: 8)
                .offset(x: move ? 5 : -5, y: 12)
                .shadow(color: Color(hex: "FBBF24").opacity(0.55), radius: 4)
        }
        .frame(width: 36, height: 36)
        .onAppear { move = true }
        .animation(
            .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
            value: move
        )
    }
}

// MARK: - Teaching / Talking

private struct TalkingAccent: View {
    @State private var bob = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hex: "60A5FA"))
                    .frame(width: 10, height: bob ? 5 : 2)
                Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4)
            }
            .shadow(color: Color(hex: "60A5FA").opacity(0.45), radius: 4)
            .offset(y: 11)
        }
        .frame(width: 72, height: 72)
        .onAppear { bob = true }
        .animation(
            .easeInOut(duration: 0.25).repeatForever(autoreverses: true),
            value: bob
        )
    }
}
