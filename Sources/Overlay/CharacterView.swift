import SwiftUI
import AppKit

/// Cursor companion rendered from the provided asset.
/// Background stays clear; the cursor's own shadow is preserved.
struct CharacterView: View {
    let mode: AssistantMode

    @State private var floating = false

    private var cursorSize: CGFloat { max(11, Self.systemCursorSize * 0.88) }
    private var bodySize: CGSize {
        switch mode {
        case .idle, .teaching:
            return CGSize(width: max(cursorSize + 6, 26), height: max(cursorSize + 6, 26))
        case .listening:
            return CGSize(width: 20, height: 20)
        case .thinking:
            return CGSize(width: 18, height: 18)
        }
    }
    private var floatOffset: CGFloat { max(0.8, bodySize.height * 0.05) }
    private var tiltAngle: Double { -2.5 }

    var body: some View {
        ZStack {
            ZStack {
                switch mode {
                case .idle, .teaching:
                    cursorImage
                        .scaleEffect(floating ? 1.03 : 0.98)
                        .rotationEffect(.degrees(tiltAngle))
                case .listening:
                    VoiceGlyph()
                        .scaleEffect(floating ? 1.03 : 0.98)
                        .rotationEffect(.degrees(tiltAngle))
                case .thinking:
                    LoadingGlyph()
                        .scaleEffect(floating ? 1.03 : 0.98)
                        .rotationEffect(.degrees(tiltAngle))
                }
            }
            .offset(y: floating ? -floatOffset : floatOffset)
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .onAppear {
            floating = true
        }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: floating)
    }

    private var cursorImage: some View {
        Image(nsImage: Self.cursorNSImage)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: cursorSize, height: cursorSize)
            // Nudge the image so the tip behaves like the anchor point.
            .offset(x: max(0.4, cursorSize * 0.03), y: max(0.4, cursorSize * 0.03))
            .foregroundStyle(Color(hex: "3B82F6"))
            .overlay {
                Image(nsImage: Self.cursorNSImage)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: cursorSize, height: cursorSize)
                    .foregroundStyle(Color(hex: "3B82F6").opacity(0.80))
                    .blur(radius: max(0.55, cursorSize * 0.04))
            }
            .shadow(color: .black.opacity(0.24), radius: max(0.8, cursorSize * 0.04), x: 0, y: max(0.8, cursorSize * 0.04))
            .shadow(color: .white.opacity(0.10), radius: max(0.35, cursorSize * 0.016), x: 0, y: 0)
            .shadow(color: Color(hex: "3B82F6").opacity(0.48), radius: max(1.8, cursorSize * 0.12), x: 0, y: 0)
            .background(Color.clear)
    }

    private static var cursorNSImage: NSImage {
        let candidates = [
            "assets/base_cursor.png",
            "Assets/base_cursor.png",
            "assets.xcassets/BaseCursor.imageset/base-cursor.png",
            "Assets.xcassets/BaseCursor.imageset/base-cursor.png"
        ]

        for path in candidates {
            if let url = Bundle.main.resourceURL?.appendingPathComponent(path),
               FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                return trimmedCursorImage(image)
            }
        }

        return NSImage(size: .init(width: 72, height: 72))
    }

    private static func trimmedCursorImage(_ image: NSImage) -> NSImage {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return image
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh

        guard width > 1, height > 1 else { return image }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.02 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )

        guard
            let cgImage = bitmap.cgImage,
            let cropped = cgImage.cropping(to: cropRect)
        else {
            return image
        }

        return NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
    }

    private static var systemCursorSize: CGFloat {
        let native = max(NSCursor.arrow.image.size.width, NSCursor.arrow.image.size.height)
        guard native.isFinite, native >= 8 else { return 13 }
        // Keep in a normal pointer range regardless of display scaling quirks.
        return native.clamped(to: 13...18)
    }

}

// MARK: - Listening (voice glyph only, no bubble wrapper)

private struct VoiceGlyph: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hex: "3B82F6"))
                    .frame(width: 2.2, height: barHeight(index: i))
                    .shadow(color: Color(hex: "3B82F6").opacity(0.50), radius: 1.8)
            }
        }
        .frame(width: 18, height: 16)
        .onAppear { pulse = true }
        .animation(
            .easeInOut(duration: 0.22).repeatForever(autoreverses: true),
            value: pulse
        )
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = 4.5
        let heights: [CGFloat] = [10, 6.5, 11, 7]
        return pulse ? heights[index] : base
    }
}

// MARK: - Thinking (loader)

private struct LoadingGlyph: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "3B82F6").opacity(0.18), lineWidth: 2)
                .frame(width: 13, height: 13)

            Circle()
                .trim(from: 0.12, to: 0.44)
                .stroke(
                    Color(hex: "3B82F6"),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .shadow(color: Color(hex: "3B82F6").opacity(0.45), radius: 3)
        }
        .frame(width: 15, height: 15)
        .onAppear { spin = true }
        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
    }
}
