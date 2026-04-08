import AppKit

/// Tracks mouse cursor position at 60 fps and reports in top-left origin coordinates
/// (matching SwiftUI's coordinate system in our full-screen overlay window).
final class CursorTracker {
    private var mouseMonitor: Any?
    private var moveMonitor: Any?
    private let onMoved: @Sendable (CGPoint) -> Void

    init(onMoved: @escaping @Sendable (CGPoint) -> Void) {
        self.onMoved = onMoved
    }

    func start() {
        // Event-driven tracking instead of a constant timer.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.poll()
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.poll()
            return event
        }
    }

    func stop() {
        if let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func poll() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        // Convert from AppKit bottom-left origin → top-left origin
        let point = CGPoint(
            x: mouse.x,
            y: screen.frame.height - mouse.y
        )
        onMoved(point)
    }

    deinit {
        stop()
    }
}
