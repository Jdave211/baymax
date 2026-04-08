import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcut manager.
/// Listens for Control + Option (Hold) to activate/listen.
final class HotkeyManager {
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    var onEscape: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isHolding = false

    func register() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if self?.handleEvent(event) == true {
                return nil
            }
            return event
        }
    }

    func unregister() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    @discardableResult
    private func handleEvent(_ event: NSEvent) -> Bool {
        // Escape
        if event.type == .keyDown && event.keyCode == 53 {
            onEscape?()
            return true
        }

        // Control + Option hold
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Check if ONLY Control and Option are pressed
            let hasCtrlOpt = flags.contains([.control, .option])
            let hasExtra = flags.contains(.command) || flags.contains(.shift)

            if hasCtrlOpt && !hasExtra {
                if !isHolding {
                    isHolding = true
                    onHoldBegan?()
                }
            } else {
                if isHolding {
                    isHolding = false
                    onHoldEnded?()
                }
            }
            return false // Don't consume modifier events to avoid interfering with system
        }

        return false
    }

    deinit { unregister() }
}
