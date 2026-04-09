import AppKit
import ApplicationServices

struct AccessibilityTarget {
    let element: AXUIElement
    let anchorPoint: CGPoint
    let region: ScreenRegion?
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let actions: [String]
}

extension AccessibilityTarget {
    func isStrongMatch(for action: TeachingAction) -> Bool {
        guard region != nil else { return false }

        let roleValue = role?.lowercased() ?? ""
        let actionSet = Set(actions)

        switch action {
        case .type:
            return roleValue.contains("text") || roleValue.contains("field") || actionSet.contains("AXSetValue")
        case .scroll:
            return roleValue.contains("scroll") || roleValue.contains("list") || roleValue.contains("table")
        case .pressKey:
            return false
        default:
            return actionSet.contains("AXPress") || roleValue.contains("button") || roleValue.contains("menuitem") || roleValue.contains("checkbox")
        }
    }

    func debugSummary(hints: [String] = []) -> String {
        let roleValue = role?.lowercased()
        let subroleValue = subrole?.lowercased()
        let titleValue = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueText = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionText = description?.trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if let roleValue, !roleValue.isEmpty {
            parts.append(roleValue.replacingOccurrences(of: "ax", with: ""))
        }
        if let subroleValue, !subroleValue.isEmpty, subroleValue != roleValue {
            parts.append(subroleValue.replacingOccurrences(of: "ax", with: ""))
        }
        if let titleValue, !titleValue.isEmpty {
            parts.append(titleValue)
        } else if let valueText, !valueText.isEmpty {
            parts.append(valueText)
        } else if let descriptionText, !descriptionText.isEmpty {
            parts.append(descriptionText)
        }

        if let hint = hints.first(where: { hint in
            let lower = hint.lowercased()
            return (titleValue?.lowercased().contains(lower) ?? false)
                || (valueText?.lowercased().contains(lower) ?? false)
                || (descriptionText?.lowercased().contains(lower) ?? false)
        }) {
            parts.append("match: \(hint)")
        }

        return parts.filter { !$0.isEmpty }.prefix(3).joined(separator: " • ")
    }
}

enum AccessibilityLocator {
    static func snapTarget(near topLeftPoint: CGPoint, on screen: NSScreen) -> AccessibilityTarget? {
        resolveTarget(near: topLeftPoint, on: screen, preferredAction: .click)
    }

    static func resolveTarget(
        near topLeftPoint: CGPoint,
        on screen: NSScreen,
        preferredAction: TeachingAction,
        searchHints: [String] = []
    ) -> AccessibilityTarget? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        let candidates = candidatePoints(around: topLeftPoint)
        var seen = Set<String>()
        var scored: [(score: Double, target: AccessibilityTarget)] = []
        let closeIntent = isCloseIntent(searchHints)

        for candidate in candidates {
            let globalPoint = toGlobalScreenPoint(candidate, screen: screen)
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(
                systemWide,
                Float(globalPoint.x),
                Float(globalPoint.y),
                &element
            )
            guard error == .success, let element else { continue }

            let resolved = normalize(element: element, screen: screen, fallbackPoint: candidate)
            appendCandidate(
                resolved,
                to: &scored,
                seen: &seen,
                preferredAction: preferredAction,
                searchHints: searchHints,
                distance: distance(from: candidate, to: topLeftPoint)
            )

            for descendant in descendantTargets(from: element, screen: screen, fallbackPoint: candidate, maxDepth: 4) {
                appendCandidate(
                    descendant,
                    to: &scored,
                    seen: &seen,
                    preferredAction: preferredAction,
                    searchHints: searchHints,
                    distance: distance(from: candidate, to: topLeftPoint) + 18
                )
            }
        }

        if closeIntent {
            for target in frontmostApplicationTargets(
                screen: screen,
                fallbackPoint: topLeftPoint,
                preferredAction: preferredAction,
                searchHints: searchHints
            ) {
                appendCandidate(
                    target,
                    to: &scored,
                    seen: &seen,
                    preferredAction: preferredAction,
                    searchHints: searchHints,
                    distance: distance(from: target.anchorPoint, to: topLeftPoint)
                )
            }
        }

        return scored.sorted { $0.score > $1.score }.first?.target
    }

    static func resolveVisibleTarget(
        on screen: NSScreen,
        preferredAction: TeachingAction,
        searchHints: [String] = []
    ) -> AccessibilityTarget? {
        guard AXIsProcessTrusted() else { return nil }

        let fallbackPoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let candidates = frontmostApplicationTargets(
            screen: screen,
            fallbackPoint: fallbackPoint,
            preferredAction: preferredAction,
            searchHints: searchHints
        )

        var seen = Set<String>()
        var scored: [(score: Double, target: AccessibilityTarget)] = []
        for candidate in candidates {
            appendCandidate(
                candidate,
                to: &scored,
                seen: &seen,
                preferredAction: preferredAction,
                searchHints: searchHints,
                distance: distance(from: candidate.anchorPoint, to: fallbackPoint) * 0.3
            )
        }

        return scored.sorted { $0.score > $1.score }.first?.target
    }

    static func performDirectAction(
        on target: AccessibilityTarget,
        preferredAction: TeachingAction,
        typedText: String? = nil
    ) -> Bool {
        switch preferredAction {
        case .click:
            return performPress(target.element)
        case .doubleClick:
            let first = performPress(target.element)
            usleep(120_000)
            let second = performPress(target.element)
            return first || second
        case .type:
            guard let text = typedText, !text.isEmpty else { return false }
            return setValue(text, on: target.element)
        default:
            return false
        }
    }

    private static func normalize(element: AXUIElement, screen: NSScreen, fallbackPoint: CGPoint = .zero) -> AccessibilityTarget {
        let actionable = actionableAncestor(startingAt: element) ?? element
        let frame = frame(of: actionable)
        let role = stringAttribute(kAXRoleAttribute, of: actionable)
        let subrole = stringAttribute(kAXSubroleAttribute, of: actionable)
        let title = stringAttribute(kAXTitleAttribute, of: actionable)
        let value = stringValueAttribute(kAXValueAttribute, of: actionable)
        let description = stringAttribute(kAXDescriptionAttribute, of: actionable)
        let actions = actionNames(of: actionable)

        let anchorPoint: CGPoint
        let region: ScreenRegion?
        if let frame {
            anchorPoint = toTopLeftPoint(CGPoint(x: frame.midX, y: frame.midY), screen: screen)
            region = toTopLeftRegion(frame, screen: screen)
        } else {
            anchorPoint = fallbackPoint
            region = nil
        }

        return AccessibilityTarget(
            element: actionable,
            anchorPoint: anchorPoint,
            region: region,
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            description: description,
            actions: actions
        )
    }

    private static func actionableAncestor(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0

        while let element = current, hops < 4 {
            if isActionable(element) {
                return element
            }
            current = parent(of: element)
            hops += 1
        }

        return nil
    }

    private static func isActionable(_ element: AXUIElement) -> Bool {
        let actions = Set(actionNames(of: element))
        if actions.contains("AXPress") || actions.contains(String(kAXPressAction as String)) {
            return true
        }

        guard let role = stringAttribute(kAXRoleAttribute, of: element)?.lowercased() else { return false }
        let roleHints = [
            "button",
            "checkbox",
            "radio",
            "menuitem",
            "pop up button",
            "popupbutton",
            "slider",
            "text field",
            "textarea",
            "combo box",
            "table",
            "list",
            "tab",
        ]
        if roleHints.contains(where: { role.contains($0.replacingOccurrences(of: " ", with: "")) || role.contains($0) }) {
            return true
        }

        return false
    }

    private static func score(
        target: AccessibilityTarget,
        preferredAction: TeachingAction,
        distance: CGFloat,
        hints: [String]
    ) -> Double {
        var score = max(0, 1_000 - Double(distance))
        let role = target.role?.lowercased() ?? ""
        let subrole = target.subrole?.lowercased() ?? ""
        let title = (target.title ?? target.value ?? target.description ?? "").lowercased()
        let actions = Set(target.actions)
        let hintMatches = hints.filter { hint in
            let lower = hint.lowercased()
            return title.contains(lower) || role.contains(lower)
        }.count
        let isCloseIntent = hints.contains(where: { hint in
            let lower = hint.lowercased()
            return lower.contains("close") || lower.contains("dismiss") || lower.contains("quit") || lower.contains("exit")
        })

        if preferredAction == .type {
            if role.contains("text") || role.contains("field") || actions.contains("AXSetValue") || actions.contains("AXConfirm") {
                score += 500
            }
        } else {
            if actions.contains("AXPress") {
                score += 700
            }
            if role.contains("button") || role.contains("checkbox") || role.contains("menuitem") {
                score += 300
            }
        }

        if !title.isEmpty { score += 50 }
        if target.region != nil { score += 20 }
        score += Double(hintMatches * 80)
        if role.contains("group") || role.contains("splitgroup") || role.contains("layout") {
            score -= 300
        }
        if isCloseIntent {
            if role.contains("button") || subrole.contains("closebutton") || actions.contains("AXPress") {
                score += 650
            }
            if title.contains("close") || title.contains("dismiss") || title.contains("quit") || title.contains("tab") {
                score += 900
            }
            if subrole.contains("closebutton") {
                score += 1200
            }
            if role.contains("group") || role.contains("splitgroup") || role.contains("layout") {
                score -= 700
            }
        }
        return score
    }

    private static func appendCandidate(
        _ target: AccessibilityTarget,
        to scored: inout [(score: Double, target: AccessibilityTarget)],
        seen: inout Set<String>,
        preferredAction: TeachingAction,
        searchHints: [String],
        distance: CGFloat
    ) {
        let fingerprint = target.fingerprint
        guard !seen.contains(fingerprint) else { return }
        seen.insert(fingerprint)

        let scoreValue = score(
            target: target,
            preferredAction: preferredAction,
            distance: distance,
            hints: searchHints
        )
        scored.append((score: scoreValue, target: target))
    }

    private static func descendantTargets(
        from element: AXUIElement,
        screen: NSScreen,
        fallbackPoint: CGPoint,
        maxDepth: Int
    ) -> [AccessibilityTarget] {
        guard maxDepth > 0 else { return [] }

        var results: [AccessibilityTarget] = []
        for child in children(of: element) {
            let resolved = normalize(element: child, screen: screen, fallbackPoint: fallbackPoint)
            results.append(resolved)
            results.append(contentsOf: descendantTargets(from: child, screen: screen, fallbackPoint: fallbackPoint, maxDepth: maxDepth - 1))
        }
        return results
    }

    private static func frontmostApplicationTargets(
        screen: NSScreen,
        fallbackPoint: CGPoint,
        preferredAction: TeachingAction,
        searchHints: [String]
    ) -> [AccessibilityTarget] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var results: [AccessibilityTarget] = []
        var seen = Set<String>()

        func record(_ target: AccessibilityTarget) {
            let fingerprint = target.fingerprint
            guard !seen.contains(fingerprint) else { return }
            seen.insert(fingerprint)
            results.append(target)
        }

        for window in windows(of: appElement) {
            if let closeButton = closeButton(of: window) {
                record(normalize(element: closeButton, screen: screen, fallbackPoint: fallbackPoint))
            }

            record(normalize(element: window, screen: screen, fallbackPoint: fallbackPoint))

            for descendant in descendantTargets(from: window, screen: screen, fallbackPoint: fallbackPoint, maxDepth: 5) {
                record(descendant)
            }
        }

        return results
    }

    private static func performPress(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func setValue(_ text: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func candidatePoints(around point: CGPoint) -> [CGPoint] {
        let offsets: [CGPoint] = [
            .zero,
            CGPoint(x: 0, y: -6),
            CGPoint(x: 6, y: 0),
            CGPoint(x: 0, y: 6),
            CGPoint(x: -6, y: 0),
            CGPoint(x: 10, y: -10),
            CGPoint(x: -10, y: -10),
            CGPoint(x: 10, y: 10),
            CGPoint(x: -10, y: 10),
            CGPoint(x: 16, y: 0),
            CGPoint(x: -16, y: 0),
            CGPoint(x: 0, y: 16),
            CGPoint(x: 0, y: -16),
            CGPoint(x: 24, y: 0),
            CGPoint(x: -24, y: 0),
            CGPoint(x: 0, y: 24),
            CGPoint(x: 0, y: -24),
        ]
        return offsets.map { CGPoint(x: point.x + $0.x, y: point.y + $0.y) }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [Any] else {
            return []
        }

        return array.compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item as CFTypeRef, to: AXUIElement.self)
        }
    }

    private static func windows(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [Any] else {
            return []
        }

        return array.compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item as CFTypeRef, to: AXUIElement.self)
        }
    }

    private static func closeButton(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func distance(from candidate: CGPoint, to origin: CGPoint) -> CGFloat {
        hypot(candidate.x - origin.x, candidate.y - origin.y)
    }

    private static func toGlobalScreenPoint(_ topLeft: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(
            x: screen.frame.minX + topLeft.x,
            y: screen.frame.maxY - topLeft.y
        )
    }

    private static func toTopLeftPoint(_ global: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(
            x: global.x - screen.frame.minX,
            y: screen.frame.maxY - global.y
        )
    }

    private static func toTopLeftRegion(_ rect: CGRect, screen: NSScreen) -> ScreenRegion {
        ScreenRegion(
            x: rect.minX - screen.frame.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        let position = pointAttribute(kAXPositionAttribute, of: element)
        let size = sizeAttribute(kAXSizeAttribute, of: element)
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isCloseIntent(_ hints: [String]) -> Bool {
        hints.contains(where: { hint in
            let lower = hint.lowercased()
            return lower.contains("close") || lower.contains("dismiss") || lower.contains("quit") || lower.contains("exit")
        })
    }

    private static func stringValueAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }

        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as? Bool).map { $0 ? "true" : "false" }
        }

        return nil
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let array = value as? [String] else {
            return []
        }
        return array
    }
}

private extension AccessibilityTarget {
    var fingerprint: String {
        let regionKey = region.map {
            [
                Int($0.x.rounded()),
                Int($0.y.rounded()),
                Int($0.width.rounded()),
                Int($0.height.rounded())
            ].map(String.init).joined(separator: ":")
        } ?? "none"

        return [
            role ?? "",
            subrole ?? "",
            title ?? "",
            value ?? "",
            description ?? "",
            actions.sorted().joined(separator: ","),
            regionKey
        ].joined(separator: "|")
    }
}
