// Helper for scripts/lib/ios_device_state.sh — compiled on demand (see that file).
//
// Subcommands:
//   running              Exit 0 when com.apple.ScreenContinuity is running.
//   window-id            Print the CGWindowID of the iPhone Mirroring window.
//   window-bounds        JSON {id,x,y,w,h} for the largest on-screen window.
//   ocr <png-path>       Print Vision-recognized text lines (fr + en), lowercased.
//   classify <png-path>  JSON {verdict, matchedKeyword, ocrLines[], frameVariance}.
//   frame-stats <png>    JSON {meanLuminance, variance, width, height}.
//
// Process discovery uses bundle ID (com.apple.ScreenContinuity), never the localized
// process name ("Recopie de l'iPhone" on French macOS).

import AppKit
import CoreGraphics
import Foundation
import Vision

let mirroringBundleID = "com.apple.ScreenContinuity"

struct WindowInfo {
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func mirroringPIDs() -> [pid_t] {
    NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == mirroringBundleID }
        .map(\.processIdentifier)
}

func bestMirroringWindow() -> WindowInfo? {
    let pids = Set(mirroringPIDs().map { Int($0) })
    guard !pids.isEmpty else { return nil }
    guard let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    var best: WindowInfo?
    var bestArea = 0.0
    for entry in info {
        guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
              pids.contains(ownerPID),
              let windowID = entry[kCGWindowNumber as String] as? Int,
              let bounds = entry[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"],
              width > 80, height > 80
        else { continue }
        let area = width * height
        if area > bestArea {
            bestArea = area
            best = WindowInfo(
                id: CGWindowID(windowID),
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: width,
                height: height
            )
        }
    }
    return best
}

func loadCGImage(pngPath: String) -> CGImage? {
    guard let image = NSImage(contentsOfFile: pngPath) else { return nil }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func runOCR(on cgImage: CGImage) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["fr-FR", "en-US"]
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        fail("Vision OCR failed: \(error.localizedDescription)")
    }
    return (request.results ?? []).compactMap {
        $0.topCandidates(1).first?.string.lowercased()
    }
}

func frameStats(for cgImage: CGImage) -> (mean: Double, variance: Double) {
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0,
          let data = cgImage.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data)
    else { return (0, 0) }

    let bytesPerPixel = cgImage.bitsPerPixel / 8
    let bytesPerRow = cgImage.bytesPerRow
    guard bytesPerPixel >= 3 else { return (0, 0) }

    var sum = 0.0
    var sumSq = 0.0
    var count = 0.0
    let step = max(1, min(width, height) / 64)
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let r = Double(ptr[offset])
            let g = Double(ptr[offset + 1])
            let b = Double(ptr[offset + 2])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sum += lum
            sumSq += lum * lum
            count += 1
            x += step
        }
        y += step
    }
    guard count > 0 else { return (0, 0) }
    let mean = sum / count
    let variance = max(0, (sumSq / count) - (mean * mean))
    return (mean, variance)
}

struct Classification {
    let verdict: String
    let matchedKeyword: String?
    let ocrLines: [String]
    let frameVariance: Double
}

func classifyMirrorContent(text: String, frameVariance: Double) -> (verdict: String, keyword: String?) {
    let inUse = [
        "en cours d'utilisation", "en cours d'utilisation",
        "iphone in use", "is in use",
        "verrouillez votre iphone", "lock your iphone",
    ]
    let connecting = [
        "connexion en pause", "connection paused",
        "connexion", "connecting",
        "se connecter", "connect to", "réessayer", "try again",
        "impossible de se connecter", "unable to connect",
        "reprendre", "resume",
    ]
    let call = [
        "appel entrant", "incoming call",
        "touchez pour revenir", "tap to return to call",
        "raccrocher", "end call",
        "appel en cours", "call in progress",
        "refuser", "decline",
    ]

    func hit(_ keys: [String]) -> String? {
        keys.first { text.contains($0) }
    }

    if let k = hit(inUse) { return ("PHONE_IN_USE", k) }
    if let k = hit(call) { return ("CALL_ACTIVE", k) }
    if let k = hit(connecting) { return ("MIRROR_CONNECTING", k) }

    // Low-variance frames often indicate a solid pause/connect overlay with no OCR text.
    if frameVariance < 120 {
        return ("MIRROR_CONNECTING", "low frame variance (\(Int(frameVariance)))")
    }
    return ("MIRROR_ACTIVE", nil)
}

func classifyPNG(_ pngPath: String) -> Classification {
    guard let cgImage = loadCGImage(pngPath: pngPath) else {
        fail("could not load image at \(pngPath)")
    }
    let lines = runOCR(on: cgImage)
    let text = lines.joined(separator: "\n")
    let stats = frameStats(for: cgImage)
    let result = classifyMirrorContent(text: text, frameVariance: stats.variance)
    return Classification(
        verdict: result.verdict,
        matchedKeyword: result.keyword,
        ocrLines: lines,
        frameVariance: stats.variance
    )
}

func printJSON(_ obj: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let str = String(data: data, encoding: .utf8)
    else { fail("JSON encode failed") }
    print(str)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "running":
    exit(mirroringPIDs().isEmpty ? 1 : 0)
case "window-id":
    guard let win = bestMirroringWindow() else { fail("no iPhone Mirroring window on screen") }
    print(win.id)
case "window-bounds":
    guard let win = bestMirroringWindow() else { fail("no iPhone Mirroring window on screen") }
    printJSON([
        "id": Int(win.id),
        "x": win.x,
        "y": win.y,
        "w": win.width,
        "h": win.height,
    ])
case "ocr":
    guard args.count > 2 else { fail("usage: mirror_state_ocr ocr <png-path>") }
    guard let cgImage = loadCGImage(pngPath: args[2]) else { fail("could not load image") }
    for line in runOCR(on: cgImage) { print(line) }
case "classify-text":
    let text = FileHandle.standardInput.readDataToEndOfFile()
    let joined = String(data: text, encoding: .utf8)?.lowercased() ?? ""
    let result = classifyMirrorContent(text: joined, frameVariance: 500)
    printJSON([
        "verdict": result.verdict,
        "matchedKeyword": result.keyword as Any,
    ])
case "classify":
    guard args.count > 2 else { fail("usage: mirror_state_ocr classify <png-path>") }
    let c = classifyPNG(args[2])
    printJSON([
        "verdict": c.verdict,
        "matchedKeyword": c.matchedKeyword as Any,
        "ocrLines": c.ocrLines,
        "frameVariance": c.frameVariance,
    ])
case "frame-stats":
    guard args.count > 2 else { fail("usage: mirror_state_ocr frame-stats <png-path>") }
    guard let cgImage = loadCGImage(pngPath: args[2]) else { fail("could not load image") }
    let stats = frameStats(for: cgImage)
    printJSON([
        "meanLuminance": stats.mean,
        "variance": stats.variance,
        "width": cgImage.width,
        "height": cgImage.height,
    ])
default:
    fail("usage: mirror_state_ocr running|window-id|window-bounds|ocr|classify|frame-stats <png>")
}
