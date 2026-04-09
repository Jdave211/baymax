import AppKit

/// Tracks mouse cursor position at 60 fps and reports in top-left origin coordinates
/// (matching SwiftUI's coordinate system in our full-screen overlay window).
final class CursorTracker {
    private var timer: Timer?
    private let onMoved: @Sendable (CGPoint) -> Void

    init(onMoved: @escaping @Sendable (CGPoint) -> Void) {
        self.onMoved = onMoved
    }

    func start() {
        stop()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        // Convert from global AppKit coordinates to local top-left coordinates
        // for the current screen. Clamp so the cursor companion stays on-screen.
        let localX = (mouse.x - screen.frame.minX).clamped(to: 0...screen.frame.width)
        let localY = (screen.frame.maxY - mouse.y).clamped(to: 0...screen.frame.height)
        let point = CGPoint(
            x: localX,
            y: localY
        )
        onMoved(point)
    }

    deinit {
        stop()
    }
}
