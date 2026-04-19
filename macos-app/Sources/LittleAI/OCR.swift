import AppKit
import ScreenCaptureKit
import Vision

/// Captures a rectangle around a screen point and runs Apple Vision OCR on it.
/// Used to extract surrounding text as context when the target app (Electron, WebArea)
/// doesn't expose the full content via the Accessibility API.
enum OCR {
    static func isPermissionGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Captures an area around `point` (AppKit bottom-left origin) and returns recognized
    /// text, or nil if the permission is missing, the capture failed, or nothing readable.
    static func captureContext(around point: CGPoint,
                                size: CGSize = CGSize(width: 900, height: 600)) async -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            Log.warn("screen capture permission not granted — requesting", tag: "ocr")
            CGRequestScreenCaptureAccess()
            return nil
        }

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return nil }
        let screenH = screen.frame.height

        // ScreenCaptureKit wants top-left origin rects in display pixel coords.
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: screenH - point.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        guard let cgImage = await captureImage(rect: rect) else {
            Log.warn("capture returned nil for rect=\(rect)", tag: "ocr")
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.error("Vision perform failed: \(error)", tag: "ocr")
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            Log.info("no text recognized", tag: "ocr")
            return nil
        }

        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        Log.info("\(lines.count) lines, \(text.count) chars recognized", tag: "ocr")
        return text.isEmpty ? nil : text
    }

    private static func captureImage(rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            // Pick the display that contains the rect.
            guard let display = content.displays.first(where: { d in
                let f = CGRect(x: 0, y: 0, width: CGFloat(d.width), height: CGFloat(d.height))
                return f.intersects(rect)
            }) ?? content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width)
            config.height = Int(rect.height)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            Log.error("SCScreenshotManager failed: \(error)", tag: "ocr")
            return nil
        }
    }
}
