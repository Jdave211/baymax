import CoreGraphics
import AppKit

final class ScreenCaptureManager: @unchecked Sendable {

    func capture() async throws -> CGImage {
        try await ensureAccess()

        let displayID = mainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            print("[Baymax] CGDisplayCreateImage returned nil for display \(displayID)")
            throw BaymaxError.noDisplay
        }
        return image
    }

    private func ensureAccess() async throws {
        let hasAccess = await MainActor.run { CGPreflightScreenCaptureAccess() }
        guard hasAccess else {
            print("[Baymax] Screen Recording not granted")
            throw BaymaxError.networkError("screenRecordingDenied")
        }
    }

    private func mainDisplayID() -> CGDirectDisplayID {
        if let screen = NSScreen.main,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }
}
