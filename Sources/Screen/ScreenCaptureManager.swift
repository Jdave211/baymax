import ScreenCaptureKit
import CoreGraphics
import AppKit

final class ScreenCaptureManager: @unchecked Sendable {

    func capture() async throws -> CGImage {
        // Check permission first — request if needed so the app appears in Settings
        let hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess {
            print("[Baymax] Screen Recording not granted — requesting...")
            CGRequestScreenCaptureAccess()
            // Give macOS a moment to process the request
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard CGPreflightScreenCaptureAccess() else {
                print("[Baymax] Screen Recording still denied after request")
                throw BaymaxError.networkError("screenRecordingDenied")
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let code = (error as NSError).code
            if code == -3801 {
                print("[Baymax] Screen Recording denied (-3801)")
                throw BaymaxError.networkError("screenRecordingDenied")
            }
            throw error
        }

        guard let display = content.displays.first else {
            throw BaymaxError.noDisplay
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        let screenSize = await NSScreen.main?.frame.size ?? CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        config.width = Int(screenSize.width)
        config.height = Int(screenSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
