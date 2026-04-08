import SwiftUI

struct AnnotationView: View {
    let region: ScreenRegion
    let screenSize: CGSize

    @State private var pulse = false
    @State private var appeared = false

    private var expandedRect: CGRect {
        CGRect(
            x: region.x - 12,
            y: region.y - 12,
            width: region.width + 24,
            height: region.height + 24
        )
    }

    var body: some View {
        ZStack {
            // Dim overlay with spotlight cutout
            Rectangle()
                .fill(.black.opacity(appeared ? 0.35 : 0))
                .reverseMask {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .frame(width: expandedRect.width, height: expandedRect.height)
                        .position(x: expandedRect.midX, y: expandedRect.midY)
                }
                .animation(.easeOut(duration: 0.4), value: appeared)

            // Pulsing border — white/silver
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(pulse ? 0.9 : 0.3), lineWidth: 2)
                .frame(width: expandedRect.width, height: expandedRect.height)
                .position(x: expandedRect.midX, y: expandedRect.midY)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )

            // Corner accents — white
            ForEach(corners) { corner in
                CornerAccent()
                    .position(
                        x: corner.offset.x == 0 ? expandedRect.minX : expandedRect.maxX,
                        y: corner.offset.y == 0 ? expandedRect.minY : expandedRect.maxY
                    )
                    .rotationEffect(.degrees(corner.rotation))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            appeared = true
            pulse = true
        }
    }

    private var corners: [CornerPosition] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }
}

private enum CornerPosition: Int, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Int { rawValue }

    var offset: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft:     return (0, 0)
        case .topRight:    return (1, 0)
        case .bottomLeft:  return (0, 1)
        case .bottomRight: return (1, 1)
        }
    }

    var rotation: Double {
        switch self {
        case .topLeft:     return 0
        case .topRight:    return 90
        case .bottomRight: return 180
        case .bottomLeft:  return 270
        }
    }
}

private struct CornerAccent: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 12))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 12, y: 0))
        }
        .stroke(Color.white.opacity(0.7), lineWidth: 2)
        .frame(width: 12, height: 12)
    }
}
