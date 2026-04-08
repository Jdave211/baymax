import SwiftUI

struct InputBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var speechRecognizer: SpeechRecognizer
    let onSubmit: (String) -> Void

    @State private var inputText = ""
    @State private var isTextMode = false
    @FocusState private var textFieldFocused: Bool
    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 14) {
            if isTextMode {
                keyboardContent
            } else {
                voiceContent
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .environment(\.colorScheme, .dark)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        speechRecognizer.isListening
                            ? Color(hex: "818CF8").opacity(0.4)
                            : .white.opacity(0.08),
                        lineWidth: 1.5
                    )
            }
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 10)
        .frame(width: 480)
        .scaleEffect(scale)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                scale = 1; opacity = 1
            }
            // Auto-start listening in voice mode
            if !isTextMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    speechRecognizer.startListening()
                }
            }
        }
        .animation(.spring(response: 0.25), value: isTextMode)
    }

    // MARK: - Voice Mode

    @ViewBuilder
    private var voiceContent: some View {
        // Mic button
        MicButton(isActive: speechRecognizer.isListening) {
            if speechRecognizer.isListening {
                speechRecognizer.stopListening()
            } else {
                speechRecognizer.startListening()
            }
        }

        if speechRecognizer.isListening {
            WaveformBars(level: speechRecognizer.audioLevel)
                .frame(width: 48, height: 22)

            Text(speechRecognizer.transcript.isEmpty ? "Listening..." : speechRecognizer.transcript)
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(speechRecognizer.transcript.isEmpty ? 0.4 : 0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Tap to talk or start speaking...")
                .font(.system(size: 14.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Switch to keyboard
        Button(action: { isTextMode = true; speechRecognizer.stopListening() }) {
            Image(systemName: "keyboard")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keyboard Mode

    @ViewBuilder
    private var keyboardContent: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color(hex: "818CF8"))

        TextField("Ask me anything...", text: $inputText)
            .textFieldStyle(.plain)
            .font(.system(size: 14.5, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
            .focused($textFieldFocused)
            .onSubmit(submitText)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { textFieldFocused = true }
            }

        // Switch to mic
        Button(action: { isTextMode = false }) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "818CF8"))
        }
        .buttonStyle(.plain)

        if !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
            Button(action: submitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: "6366F1"))
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func submitText() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputText = ""
        onSubmit(text)
    }
}

// MARK: - Mic Button

struct MicButton: View {
    let isActive: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(Color(hex: "EF4444").opacity(0.2))
                        .frame(width: 40, height: 40)
                        .scaleEffect(pulse ? 1.3 : 1)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: pulse
                        )
                }

                Circle()
                    .fill(isActive ? Color(hex: "EF4444") : Color(hex: "6366F1"))
                    .frame(width: 32, height: 32)

                Image(systemName: isActive ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .onAppear { if isActive { pulse = true } }
        .onChange(of: isActive) { _, active in pulse = active }
    }
}

// MARK: - Waveform Bars

struct WaveformBars: View {
    let level: Float

    @State private var animating = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: "818CF8"))
                    .frame(
                        width: 3,
                        height: barHeight(index: i)
                    )
                    .animation(
                        .easeInOut(duration: 0.15 + Double(i) * 0.03),
                        value: level
                    )
            }
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = 4
        let maxExtra: CGFloat = 18
        let phase = sin(Double(index) * 1.2 + Double(level) * 10)
        return base + maxExtra * CGFloat(level) * CGFloat(0.5 + 0.5 * phase)
    }
}
