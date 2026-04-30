import AppKit

/// Reads image payloads from the system pasteboard or from absolute filesystem paths,
/// in a form ready to ship to a vision model (PNG bytes + media type). Handles the common
/// macOS pasteboard representations (TIFF, PNG, NSImage), and on disk it accepts whatever
/// `NSImage(contentsOf:)` can decode (PNG, JPEG, GIF, WebP, HEIC, TIFF, BMP, …).
enum Clipboard {
    /// True if the pasteboard currently contains a bitmap image in any recognised form.
    /// Evaluated once per access — callers should invoke right before they need the value
    /// (e.g. when opening a menu), not cache it.
    static var hasImage: Bool {
        let types = NSPasteboard.general.types ?? []
        return types.contains(.png) || types.contains(.tiff) || NSImage(pasteboard: .general) != nil
    }

    /// Returns the current pasteboard image, downscaled to `maxDimension` on the longest
    /// side, encoded as PNG. Returns nil if the pasteboard doesn't contain an image or the
    /// image can't be decoded.
    static func image(maxDimension: CGFloat = 2048) -> AIImage? {
        guard let source = NSImage(pasteboard: .general) else {
            Log.debug("Clipboard.image: no NSImage on pasteboard", tag: "clip")
            return nil
        }
        return encode(source, maxDimension: maxDimension, sourceLabel: "pasteboard")
    }

    /// Loads an image from an absolute filesystem path (with optional `~` and
    /// `file://` prefix), downscales it, and PNG-encodes it. Returns nil if the path
    /// doesn't exist, isn't readable, or doesn't contain a decodable image.
    static func image(atPath rawPath: String, maxDimension: CGFloat = 2048) -> AIImage? {
        let resolved = resolvePath(rawPath)
        guard FileManager.default.fileExists(atPath: resolved) else {
            Log.warn("Clipboard.image(atPath): file not found at \(resolved)", tag: "clip")
            return nil
        }
        let url = URL(fileURLWithPath: resolved)
        guard let source = NSImage(contentsOf: url) else {
            Log.warn("Clipboard.image(atPath): NSImage failed to decode \(resolved)", tag: "clip")
            return nil
        }
        return encode(source, maxDimension: maxDimension, sourceLabel: resolved)
    }

    /// Scans `prompt` for absolute paths to image files (`/foo.png`, `~/bar.jpg`,
    /// `file:///...`), loads each into an `AIImage`, and returns the prompt with those
    /// path tokens stripped. Image order is preserved. Paths whose files don't exist or
    /// can't be decoded are left as-is in the prompt so the user sees something is off.
    /// Whitespace-only prompts that contained only paths come back as the empty string —
    /// callers can substitute a sensible default ("Describe this image").
    static func extractImagePaths(from prompt: String) -> (cleaned: String, images: [AIImage]) {
        let pattern = #"(?:file://)?(?:~|/)[^\s"'<>]*\.(?:png|jpe?g|gif|webp|heic|heif|tiff|tif|bmp)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (prompt, [])
        }
        let ns = prompt as NSString
        let matches = regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return (prompt, []) }

        var loadedImages: [(rangeStart: Int, image: AIImage)] = []
        var cleaned = prompt
        // Walk matches in reverse so `cleaned` index ranges remain valid as we remove.
        for m in matches.reversed() {
            let raw = ns.substring(with: m.range)
            guard let image = image(atPath: raw) else {
                Log.warn("extractImagePaths: skipping unreadable path '\(raw)'", tag: "clip")
                continue
            }
            loadedImages.append((m.range.location, image))
            if let r = Range(m.range, in: cleaned) {
                cleaned.removeSubrange(r)
            }
        }
        // Restore the natural reading order: matches were reversed for safe removal,
        // but we want images[0] to correspond to the first path the user typed.
        let images = loadedImages.sorted { $0.rangeStart < $1.rangeStart }.map { $0.image }
        let trimmed = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        Log.info("extractImagePaths: found \(images.count) image(s), cleaned len=\(trimmed.count)", tag: "clip")
        return (trimmed, images)
    }

    // MARK: - Private helpers

    private static func resolvePath(_ raw: String) -> String {
        var p = raw
        if p.hasPrefix("file://") {
            if let url = URL(string: p), url.isFileURL {
                return url.path
            }
            // Some drag-from-Finder payloads come URL-encoded without scheme normalisation;
            // strip and percent-decode by hand as a fallback.
            p = String(p.dropFirst("file://".count))
            p = p.removingPercentEncoding ?? p
        }
        if p.hasPrefix("~") {
            p = (p as NSString).expandingTildeInPath
        }
        return p
    }

    /// Render `source` into a downscaled bitmap and PNG-encode. Centralised here so
    /// pasteboard-image and disk-image code paths share identical encoding semantics:
    /// we always render to actual pixel dimensions (NSImage's tiffRepresentation can
    /// lie about size when the source has multiple representations), and we cap the
    /// long side at `maxDimension` (Claude tops out around 1568 px, OpenAI at 2048).
    private static func encode(_ source: NSImage, maxDimension: CGFloat, sourceLabel: String) -> AIImage? {
        let originalSize = source.size
        guard originalSize.width > 0, originalSize.height > 0 else {
            Log.debug("Clipboard.encode: zero-sized NSImage from \(sourceLabel)", tag: "clip")
            return nil
        }
        let longest = max(originalSize.width, originalSize.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1.0
        let targetSize = NSSize(width: floor(originalSize.width * scale),
                                height: floor(originalSize.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            Log.error("Clipboard.encode: failed to create bitmap rep for \(sourceLabel)", tag: "clip")
            return nil
        }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            Log.error("Clipboard.encode: failed to create graphics context for \(sourceLabel)", tag: "clip")
            return nil
        }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize),
                    from: .zero,
                    operation: .copy,
                    fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            Log.error("Clipboard.encode: PNG encoding failed for \(sourceLabel)", tag: "clip")
            return nil
        }
        Log.info("Clipboard.encode ok source=\(sourceLabel) originalSize=\(originalSize) scaledSize=\(targetSize) bytes=\(png.count)", tag: "clip")
        return AIImage(data: png, mediaType: "image/png")
    }
}
