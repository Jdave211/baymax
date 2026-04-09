import SwiftUI
import CoreGraphics
import AppKit

// MARK: - CGImage → Base64

extension CGImage {
    var imageSize: CGSize {
        CGSize(width: width, height: height)
    }

    func jpegBase64(quality: CGFloat = 0.5, maxDimension: CGFloat? = nil) -> String {
        let sourceImage = maxDimension.flatMap { resized(maxDimension: $0) } ?? self
        let rep = NSBitmapImageRep(cgImage: sourceImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return "" }
        return data.base64EncodedString()
    }

    func resized(maxDimension: CGFloat) -> CGImage? {
        guard max(width, height) > Int(maxDimension) else { return self }

        let scale = maxDimension / CGFloat(max(width, height))
        let newWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let newHeight = max(1, Int((CGFloat(height) * scale).rounded()))

        guard
            let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    func cropped(to rect: CGRect) -> CGImage? {
        let integralRect = CGRect(
            x: rect.origin.x.rounded(.down),
            y: rect.origin.y.rounded(.down),
            width: rect.size.width.rounded(.up),
            height: rect.size.height.rounded(.up)
        ).intersection(CGRect(origin: .zero, size: imageSize))

        guard !integralRect.isNull, integralRect.width >= 1, integralRect.height >= 1 else { return nil }
        return cropping(to: integralRect)
    }
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24 & 0xFF, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (128, 128, 128, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Reverse Mask (spotlight cutout)

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

// MARK: - Comparable Clamping

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
