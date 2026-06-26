import XCTest

/// macOS XCUITest screenshot helper — attaches the screenshot to the `.xcresult` and,
/// when `MAC_TEST_SCREENSHOT_DIR` is set, also writes a PNG to disk. Mirror of the iOS
/// `VocelloUITestApp.captureScreenshot`; used by the review tour (+ optionally the smoke
/// suite for failure evidence).
enum VocelloMacTestSupport {
    static func captureScreenshot(_ app: XCUIApplication, named name: String) {
        let screenshot = app.screenshot()
        if let dir = ProcessInfo.processInfo.environment["MAC_TEST_SCREENSHOT_DIR"] {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("\(name).png")))
        }
        // Build the attachment INSIDE the @Sendable activity closure so no non-Sendable
        // value is captured across it (Swift 6 strict concurrency).
        XCTContext.runActivity(named: "Screenshot: \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
