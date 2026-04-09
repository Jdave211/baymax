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

        if redirectToStableInstallIfNeeded() {
            return
        }

        overlayManager = OverlayManager(appState: appState)
        hotkeyManager = HotkeyManager()

        setupMenuBar()
        setupHotkeys()
        refreshPermissionStatus()
        promptAccessibilityIfNeeded()

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
        popover.behavior = .transient
        let contentWidth: CGFloat = 340
        let contentHeight: CGFloat = 500
        let rootView = ControlCenterView(appState: appState)
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        let controller = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: contentWidth, height: contentHeight)
        popover.contentViewController = controller
    }

    @objc private func togglePopover(_ sender: AnyObject) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshPermissionStatus()
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

    // MARK: - Permissions

    func refreshPermissionStatus() {
        appState.refreshPermissionStatus()
        print(
            "[Baymax] Permissions — Screen: \(appState.screenRecordingGranted ? "✓" : "pending"), " +
            "Accessibility: \(appState.accessibilityGranted ? "✓" : "pending"), " +
            "Microphone: \(appState.microphoneGranted ? "✓" : "pending")"
        )
    }

    func promptAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.refreshPermissionStatus()
        }
    }

    @discardableResult
    func requestScreenRecordingPermission(openSettingsOnFailure: Bool = true) async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            refreshPermissionStatus()
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        _ = CGRequestScreenCaptureAccess()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let hasAccess = CGPreflightScreenCaptureAccess()
        refreshPermissionStatus()

        if !hasAccess && openSettingsOnFailure {
            openScreenRecordingSettings()
            revealSelfInFinder()
            showScreenRecordingManualAddAlert()
        }

        return hasAccess
    }

    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshPermissionStatus()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissionStatus() }
            }
        default:
            openMicrophoneSettings()
            refreshPermissionStatus()
        }
    }

    func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealSelfInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func showScreenRecordingManualAddAlert() {
        let appPath = Bundle.main.bundleURL.path
        let alert = NSAlert()
        alert.messageText = "Screen Recording needs manual add"
        alert.informativeText = "macOS didn’t show a direct prompt for Baymax.\n\nIn Screen & System Audio Recording, click + and select:\n\(appPath)\n\nThen enable Baymax and relaunch it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func redirectToStableInstallIfNeeded() -> Bool {
        let fm = FileManager.default
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        let stableURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Baymax.app")
            .standardizedFileURL

        guard runningURL != stableURL else { return false }
        guard fm.fileExists(atPath: stableURL.path) else { return false }

        print("[Baymax] Redirecting launch to stable install: \(stableURL.path)")
        NSWorkspace.shared.open(stableURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return true
    }

    // MARK: - Quit

    func quitApp() {
        NSApp.terminate(nil)
    }
}
