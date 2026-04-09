import AppKit
import Vision

struct VisualTarget {
    let anchorPoint: CGPoint
    let region: ScreenRegion?
    let summary: String?
    let confidence: Double
}

enum VisualLocator {
    static func resolveTarget(in screenshot: CGImage, step: TeachingStep) -> VisualTarget? {
        let hints = step.searchHints
        let closeIntent = isCloseIntent(hints)
        let imageSize = CGSize(width: screenshot.width, height: screenshot.height)

        let focus = CGPoint(
            x: step.highlightRegion.map { Double($0.center.x) } ?? step.targetX,
            y: step.highlightRegion.map { Double($0.center.y) } ?? step.targetY
        )

        let crops = candidateCrops(
            focus: focus,
            imageSize: imageSize,
            closeIntent: closeIntent
        )

        var best: VisualCandidate?
        for crop in crops {
            guard let cropImage = screenshot.cropped(to: crop) else { continue }
            let candidates = recognizeText(in: cropImage, offset: crop.origin, hints: hints, closeIntent: closeIntent, imageSize: imageSize)
            for candidate in candidates {
                if best == nil || candidate.score > best!.score {
                    best = candidate
                }
                if let best, best.score >= 0.92 {
                    break
                }
            }

            if let best, best.score >= 0.92 {
                break
            }
        }

        guard let best, best.score >= confidenceThreshold(for: step) else { return nil }

        return VisualTarget(
            anchorPoint: best.anchorPoint,
            region: best.region,
            summary: best.summary,
            confidence: best.score
        )
    }

    private static func recognizeText(
        in crop: CGImage,
        offset: CGPoint,
        hints: [String],
        closeIntent: Bool,
        imageSize: CGSize
    ) -> [VisualCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[Baymax] Vision OCR failed: \(error.localizedDescription)")
            return []
        }

        guard let observations = request.results else { return [] }

        var candidates: [VisualCandidate] = []
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let textLower = text.lowercased()
            let box = boundingBox(for: observation, in: crop.imageSize, offset: offset)
            let score = score(text: textLower, box: box, hints: hints, closeIntent: closeIntent)
            guard score > 0.2 else { continue }

            let anchorPoint = anchorPoint(for: box, text: textLower, closeIntent: closeIntent)
            let region = ScreenRegion(x: box.minX, y: box.minY, width: box.width, height: box.height)
            let summary = summary(for: text, score: score)

            candidates.append(VisualCandidate(anchorPoint: anchorPoint, region: region, summary: summary, score: score))
        }

        return candidates
    }

    private static func boundingBox(for observation: VNRecognizedTextObservation, in cropSize: CGSize, offset: CGPoint) -> CGRect {
        let rect = observation.boundingBox
        let width = cropSize.width
        let height = cropSize.height

        let local = CGRect(
            x: rect.minX * width,
            y: (1 - rect.maxY) * height,
            width: rect.width * width,
            height: rect.height * height
        )

        return local.offsetBy(dx: offset.x, dy: offset.y)
    }

    private static func anchorPoint(for box: CGRect, text: String, closeIntent: Bool) -> CGPoint {
        if closeIntent {
            let hasCloseWord = text.contains("close") || text.contains("dismiss") || text.contains("quit") || text.contains("exit") || text.contains("tab")
            if hasCloseWord {
                let leftOffset = max(10, box.width * 0.22)
                return CGPoint(x: max(0, box.minX - leftOffset), y: box.midY)
            }
        }

        return CGPoint(x: box.midX, y: box.midY)
    }

    private static func score(
        text: String,
        box: CGRect,
        hints: [String],
        closeIntent: Bool
    ) -> Double {
        let tokens = text
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }

        let hintMatches = hints.reduce(0) { partial, hint in
            partial + (text.contains(hint.lowercased()) ? 1 : 0)
        }

        var score = Double(hintMatches) * 0.25
        score += min(0.35, Double(tokens.count) * 0.03)
        score += min(0.2, Double(box.width / 1400.0))

        if closeIntent {
            if text.contains("close") || text.contains("dismiss") || text.contains("quit") || text.contains("exit") || text.contains("tab") {
                score += 0.6
            }
            if box.minY < 320 {
                score += 0.1
            }
        }

        if hints.contains(where: { text.contains($0.lowercased()) }) {
            score += 0.25
        }

        return min(score, 1.0)
    }

    private static func summary(for text: String, score: Double) -> String {
        let rounded = Int((score * 100).rounded())
        return "\(text) • visual \(rounded)%"
    }

    private static func isCloseIntent(_ hints: [String]) -> Bool {
        hints.contains(where: { hint in
            let lower = hint.lowercased()
            return lower.contains("close") || lower.contains("dismiss") || lower.contains("quit") || lower.contains("exit")
        })
    }

    private static func candidateCrops(focus: CGPoint, imageSize: CGSize, closeIntent: Bool) -> [CGRect] {
        let safeFocus = CGPoint(
            x: focus.x.clamped(to: 0...max(imageSize.width, 1)),
            y: focus.y.clamped(to: 0...max(imageSize.height, 1))
        )

        let base: [CGRect] = closeIntent ? [
            CGRect(x: 0, y: 0, width: imageSize.width, height: min(imageSize.height, 420)),
            CGRect(x: 0, y: 0, width: imageSize.width, height: min(imageSize.height, 560))
        ] : [
            CGRect(x: safeFocus.x - 420, y: safeFocus.y - 280, width: 840, height: 560),
            CGRect(x: safeFocus.x - 640, y: safeFocus.y - 420, width: 1280, height: 840)
        ]

        return base.map { rect in
            rect.intersection(CGRect(origin: .zero, size: imageSize))
        }.filter { !$0.isNull && !$0.isEmpty }
    }

    private static func confidenceThreshold(for step: TeachingStep) -> Double {
        switch step.actionKind {
        case .click, .doubleClick, .rightClick:
            return 0.55
        case .type, .pressKey:
            return 0.45
        case .scroll, .hover:
            return 0.4
        default:
            return 0.5
        }
    }
}

private struct VisualCandidate {
    let anchorPoint: CGPoint
    let region: ScreenRegion?
    let summary: String?
    let score: Double
}
