//
//  BaymaxApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct BaymaxApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Redirect print output to a log file for debugging release builds
        BaymaxDebugLog.setup()
        BaymaxDebugLog.log("applicationDidFinishLaunching")

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        if redirectToStableInstallIfNeeded() {
            BaymaxDebugLog.log("Redirecting to stable install — terminating this instance")
            return
        }

        BaymaxDebugLog.log("Starting v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        print("🎯 Baymax: Starting...")
        print("🎯 Baymax: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        BaymaxAnalytics.configure()
        BaymaxAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    private func redirectToStableInstallIfNeeded() -> Bool {
        let fm = FileManager.default
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        let stableURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Baymac.app")
            .standardizedFileURL

        guard runningURL != stableURL else { return false }

        print("🎯 Baymax: Updating stable install at \(stableURL.path)")
        
        // We use rsync instead of FileManager.removeItem/copyItem to preserve the
        // inode of the .app directory. If we delete the .app folder, macOS instantly
        // revokes all TCC permissions (Screen Recording/Accessibility).
        try? fm.createDirectory(at: stableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = ["-a", "--delete", runningURL.path + "/", stableURL.path + "/"]
        try? process.run()
        process.waitUntilExit()

        NSWorkspace.shared.open(stableURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Baymax: Registered as login item")
            } catch {
                print("⚠️ Baymax: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Baymax: Sparkle updater failed to start: \(error)")
        }
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        
        print("🎯 Baymax: Received URL: \(url)")
        Task {
            await companionManager.handleAuthCallback(url: url)
        }
    }
}
