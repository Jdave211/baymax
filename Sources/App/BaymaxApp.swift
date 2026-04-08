import SwiftUI

@main
struct BaymaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows, entirely menu bar and overlay driven
        Settings {
            EmptyView()
        }
    }
}
