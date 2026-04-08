import SwiftUI

/// Short contextual label that appears next to the virtual cursor during teaching.
/// Mimics a real teacher pointing and saying "over here!", "this one!", "found it!"
struct ContextLabel: View {
    let text: String

    @State private var appeared = false

    var body: some View {
        Text(text)
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(hex: "3B82F6"))
            )
            .shadow(color: Color(hex: "3B82F6").opacity(0.5), radius: 10, y: 3)
            .scaleEffect(appeared ? 1 : 0.4)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                    appeared = true
                }
            }
    }
}

/// Minimal transcript bubble shown briefly while the assistant is speaking.
/// Fades out after a few seconds — the real instruction is audio.
struct TranscriptBubble: View {
    let text: String

    @State private var opacity: Double = 0

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeIn(duration: 0.2)) { opacity = 1 }
                // Auto-fade since the voice carries the message
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation(.easeOut(duration: 0.6)) { opacity = 0 }
                }
            }
    }
}
