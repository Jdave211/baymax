import AppKit
import SwiftUI
import Combine
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private(set) var overlayManager: OverlayManager!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        overlayManager = OverlayManager(appState: appState)
        hotkeyManager = HotkeyManager()

        setupMenuBar()
        setupHotkeys()
        logPermissionStatus()

        // Baymax starts visible as a cursor companion on launch.
        appState.isActive = true
        overlayManager.activate()
    }

    // MARK: - Menu Bar (Control Center)

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Baymax")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
            // Use left/right click for the popover
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ControlCenterView(appState: appState))
    }

    @objc private func togglePopover(_ sender: AnyObject) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeyManager.onHoldBegan = { [weak self] in
            Task { @MainActor in
                self?.overlayManager.handleHoldBegan()
            }
        }
        hotkeyManager.onHoldEnded = { [weak self] in
            Task { @MainActor in
                self?.overlayManager.handleHoldEnded()
            }
        }
        hotkeyManager.onEscape = { [weak self] in
            Task { @MainActor in
                self?.overlayManager.handleEscape()
            }
        }
        hotkeyManager.register()
    }

    // MARK: - Permissions (log only — system prompts automatically when needed)

    private func logPermissionStatus() {
        let ax = AXIsProcessTrusted()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[Baymax] Permissions — Accessibility: \(ax ? "✓" : "pending"), Microphone: \(mic.rawValue == 3 ? "✓" : "pending")")
    }

    // MARK: - Quit

    func quitApp() {
        NSApp.terminate(nil)
    }
}
