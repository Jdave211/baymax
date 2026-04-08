import Foundation

// MARK: - Teaching Plan (AI Response)

struct TeachingPlan: Codable {
    let appName: String
    let greeting: String
    let steps: [TeachingStep]

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case greeting
        case steps
    }
}

struct TeachingStep: Codable, Identifiable {
    var id = UUID()
    let instruction: String   // Spoken aloud by TTS (conversational, 1-2 sentences)
    let label: String          // Short on-screen context label ("over here!", "this one!")
    let targetX: Double
    let targetY: Double
    let action: String
    let highlightX: Double?
    let highlightY: Double?
    let highlightWidth: Double?
    let highlightHeight: Double?

    enum CodingKeys: String, CodingKey {
        case instruction
        case label
        case targetX = "target_x"
        case targetY = "target_y"
        case action
        case highlightX = "highlight_x"
        case highlightY = "highlight_y"
        case highlightWidth = "highlight_width"
        case highlightHeight = "highlight_height"
    }

    var highlightRegion: ScreenRegion? {
        guard let x = highlightX, let y = highlightY,
              let w = highlightWidth, let h = highlightHeight else { return nil }
        return ScreenRegion(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Chat

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isAssistant: Bool
    let timestamp = Date()
}

// MARK: - Screen

struct ScreenRegion: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Assistant Mode

enum AssistantMode: Equatable {
    case idle
    case listening
    case thinking
    case teaching
}
