import AppKit
import ApplicationServices

struct AXTextTarget {
    let element: AXUIElement
    let selectedText: String
    /// Selection rect in AX coordinates (origin top-left of primary screen). Nil if unavailable.
    let selectionRect: CGRect?
    /// Fallback point in AppKit screen coordinates (origin bottom-left).
    let fallbackCursor: CGPoint
    /// The frontmost app when the trigger fired, so we can restore focus before writing back.
    let sourceApp: NSRunningApplication?
}

enum AXService {
    static func captureFocusedTarget() -> AXTextTarget? {
        guard let element = focusedElement() else { return nil }
        var selected = selectedText(in: element) ?? ""
        if selected.isEmpty {
            // Fallback: many apps (Terminal, Electron, VSCode) don't expose AXSelectedText.
            // Sniff via a synthetic ⌘C and restore the pasteboard afterwards.
            selected = pasteboardSelectionSniff() ?? ""
        }
        return AXTextTarget(
            element: element,
            selectedText: selected,
            selectionRect: selectionRect(in: element),
            fallbackCursor: NSEvent.mouseLocation,
            sourceApp: NSWorkspace.shared.frontmostApplication
        )
    }

    /// Writes `text` back into the source app. Uses a clipboard-paste strategy that works
    /// reliably across AppKit, Electron (VSCode/Slack), Chrome, and Terminal — none of which
    /// honour `AXUIElementSetAttributeValue` on a non-frontmost app.
    ///
    /// Sequence:
    /// 1. Deactivate our app so the system will actually accept the next activation request.
    /// 2. Activate the source app with `activateIgnoringOtherApps` (still works on macOS 13/14/15).
    /// 3. Poll up to ~300ms until `frontmostApplication` matches the target PID.
    /// 4. Snapshot the pasteboard, set our text, send ⌘V, restore the pasteboard after ~200ms.
    static func writeText(_ text: String, to target: AXTextTarget) {
        let sourcePID = target.sourceApp?.processIdentifier ?? -1
        NSLog("[AXService] writeText start sourcePID=\(sourcePID) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) len=\(text.count)")

        // 1. Yield key status. Our app runs as .accessory; deactivate() nudges the system
        //    to surface the previously-frontmost app.
        NSApp.deactivate()

        // 2. Activate the source app. `.activateIgnoringOtherApps` is deprecated in newer
        //    SDKs but still the only reliable way to force focus back from an accessory app.
        if let source = target.sourceApp {
            activateIgnoringOtherApps(source)
        }

        // 3. Poll until the source app is frontmost (or give up after 300ms).
        let deadline = Date().addingTimeInterval(0.3)
        var frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        while frontmost != sourcePID && Date() < deadline {
            usleep(15_000)
            frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        NSLog("[AXService] writeText post-activate frontmostPID=\(frontmost ?? -1) match=\(frontmost == sourcePID)")

        // 4. Paste with pasteboard restore.
        pasteWithRestore(text: text)
        NSLog("[AXService] writeText done")
    }

    /// Deprecation-silenced wrapper for NSRunningApplication.activate(options:).
    /// The options-based API is deprecated on macOS 14+ but is still the only way to
    /// force focus to another app from an `.accessory` process (Raycast, Alfred,
    /// TextExpander etc. all still call this).
    @available(macOS, deprecated: 14.0)
    private static func activateIgnoringOtherApps(_ app: NSRunningApplication) {
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Returns the selection bounds in AX coordinates (origin top-left of primary screen),
    /// or the element frame as fallback.
    private static func selectionRect(in element: AXUIElement) -> CGRect? {
        var rangeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let range = rangeValue {
            var boundsValue: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range,
                &boundsValue
            ) == .success, let bounds = boundsValue {
                var rect = CGRect.zero
                AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
                if rect.width > 0 || rect.height > 0 { return rect }
            }
        }
        return elementFrame(element)
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posVal = posValue, let sizeVal = sizeValue else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Sets `text` on the general pasteboard, sends ⌘V, then restores the previous
    /// pasteboard contents after 200ms (so ⌘V has time to land in the target app before
    /// we yank the string out from under it).
    private static func pasteWithRestore(text: String) {
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSLog("[AXService] pasteWithRestore posting cmd-V")
        sendCmd(virtualKey: 0x09) // V
        // Restore pasteboard on a background queue so we don't block the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            restorePasteboard(pb, items: snapshot)
            NSLog("[AXService] pasteWithRestore pasteboard restored")
        }
    }

    /// Synthesizes ⌘C, waits briefly, reads the pasteboard, restores the previous contents.
    /// Returns the sniffed selection or nil if nothing changed / nothing selected.
    private static func pasteboardSelectionSniff() -> String? {
        let pb = NSPasteboard.general
        let previousChangeCount = pb.changeCount
        let snapshot = snapshotPasteboard(pb)

        sendCmd(virtualKey: 0x08) // C

        // Poll up to ~250ms for the pasteboard to change.
        var sniffed: String?
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            usleep(20_000)
            if pb.changeCount != previousChangeCount {
                sniffed = pb.string(forType: .string)
                break
            }
        }

        restorePasteboard(pb, items: snapshot)

        guard let text = sniffed, !text.isEmpty else { return nil }
        return text
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        let copies: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return copies
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }

    private static func sendCmd(virtualKey: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum AccessibilityPermission {
    static func requestIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
