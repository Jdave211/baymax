import Foundation

// MARK: - Tutorial Plan (box-first runtime model)

struct TutorialPlan: Codable {
    let appName: String
    let greeting: String
    let steps: [TutorialStep]

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case greeting
        case steps
    }
}

struct TutorialStep: Codable, Identifiable {
    var id = UUID()
    let instruction: String
    let label: String
    let action: String
    let actionBoxX: Double
    let actionBoxY: Double
    let actionBoxWidth: Double
    let actionBoxHeight: Double
    let text: String?
    let keys: [String]?
    let scrollAmount: Double?

    enum CodingKeys: String, CodingKey {
        case instruction
        case label
        case action
        case actionBoxX = "action_box_x"
        case actionBoxY = "action_box_y"
        case actionBoxWidth = "action_box_width"
        case actionBoxHeight = "action_box_height"
        case text
        case keys
        case scrollAmount = "scroll_amount"
    }

    var actionBoxRegion: ScreenRegion {
        ScreenRegion(x: actionBoxX, y: actionBoxY, width: actionBoxWidth, height: actionBoxHeight)
    }

    var actionCenter: CGPoint {
        actionBoxRegion.center
    }

    var actionKind: TeachingAction {
        switch normalizedActionValue {
        case "doubleclick":
            return .doubleClick
        case "rightclick":
            return .rightClick
        case "presskey":
            return .pressKey
        case "type":
            return .type
        case "scroll":
            return .scroll
        case "hover":
            return .hover
        case "double_click":
            return .doubleClick
        case "right_click":
            return .rightClick
        case "press_key":
            return .pressKey
        default:
            return TeachingAction(rawValue: normalizedActionValue) ?? .click
        }
    }

    private var normalizedActionValue: String {
        action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    var searchHints: [String] {
        let raw = [label, instruction, action, text ?? ""]
            .joined(separator: " ")
            .lowercased()
        let tokens = raw
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        let stopwords: Set<String> = [
            "the", "and", "you", "your", "for", "with", "from", "this",
            "that", "step", "click", "tap", "open", "then", "here", "over",
            "into", "please", "move", "drag", "show", "point", "box", "area"
        ]

        return Array(Set(tokens.filter { !stopwords.contains($0) })).sorted()
    }
}

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

struct TeachingOutline: Codable {
    let appName: String
    let greeting: String
    let taskSummary: String
    let needsResearch: Bool
    let researchHint: String?
    let steps: [TeachingOutlineStep]

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case greeting
        case taskSummary = "task_summary"
        case needsResearch = "needs_research"
        case researchHint = "research_hint"
        case steps
    }
}

struct TeachingOutlineStep: Codable, Identifiable {
    var id = UUID()
    let instruction: String
    let label: String
    let action: String
    let controlHint: String
    let roughTargetX: Double?
    let roughTargetY: Double?
    let roughHighlightX: Double?
    let roughHighlightY: Double?
    let roughHighlightWidth: Double?
    let roughHighlightHeight: Double?
    let text: String?
    let keys: [String]?
    let scrollAmount: Double?

    enum CodingKeys: String, CodingKey {
        case instruction
        case label
        case action
        case controlHint = "control_hint"
        case roughTargetX = "rough_target_x"
        case roughTargetY = "rough_target_y"
        case roughHighlightX = "rough_highlight_x"
        case roughHighlightY = "rough_highlight_y"
        case roughHighlightWidth = "rough_highlight_width"
        case roughHighlightHeight = "rough_highlight_height"
        case text
        case keys
        case scrollAmount = "scroll_amount"
    }

    var roughHighlightRegion: ScreenRegion? {
        guard let x = roughHighlightX, let y = roughHighlightY,
              let w = roughHighlightWidth, let h = roughHighlightHeight else { return nil }
        return ScreenRegion(x: x, y: y, width: w, height: h)
    }

    var roughTeachingStep: TeachingStep {
        TeachingStep(
            instruction: instruction,
            label: label,
            targetX: roughTargetX ?? 0,
            targetY: roughTargetY ?? 0,
            action: action,
            highlightX: roughHighlightX,
            highlightY: roughHighlightY,
            highlightWidth: roughHighlightWidth,
            highlightHeight: roughHighlightHeight,
            text: text,
            keys: keys,
            scrollAmount: scrollAmount
        )
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
    let text: String?
    let keys: [String]?
    let scrollAmount: Double?

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
        case text
        case keys
        case scrollAmount = "scroll_amount"
    }

    var highlightRegion: ScreenRegion? {
        guard let x = highlightX, let y = highlightY,
              let w = highlightWidth, let h = highlightHeight else { return nil }
        return ScreenRegion(x: x, y: y, width: w, height: h)
    }

    var actionKind: TeachingAction {
        switch normalizedActionValue {
        case "doubleclick":
            return .doubleClick
        case "rightclick":
            return .rightClick
        case "presskey":
            return .pressKey
        case "type":
            return .type
        case "scroll":
            return .scroll
        case "hover":
            return .hover
        case "double_click":
            return .doubleClick
        case "right_click":
            return .rightClick
        case "press_key":
            return .pressKey
        default:
            return TeachingAction(rawValue: normalizedActionValue) ?? .click
        }
    }

    private var normalizedActionValue: String {
        action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    var searchHints: [String] {
        let raw = [label, instruction, action, text ?? ""]
            .joined(separator: " ")
            .lowercased()
        let tokens = raw
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        let stopwords: Set<String> = [
            "the", "and", "you", "your", "for", "with", "from", "this",
            "that", "step", "click", "tap", "open", "then", "here", "over",
            "into", "please", "move", "drag", "show", "point"
        ]

        return Array(Set(tokens.filter { !stopwords.contains($0) })).sorted()
    }
}

struct StepValidationResult: Codable {
    let decision: StepValidationDecision
    let message: String
    let nextStepIndex: Int?

    enum CodingKeys: String, CodingKey {
        case decision
        case message
        case nextStepIndex = "next_step_index"
    }
}

enum StepValidationDecision: String, Codable {
    case next
    case done
    case replan
}

struct PlannedTeachingSession {
    let outline: TeachingOutline
    let plan: TeachingPlan
    let needsResearch: Bool
    let researchHint: String?
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

enum TeachingAction: String {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case scroll
    case type
    case pressKey = "press_key"
    case hover
    case unknown
}
