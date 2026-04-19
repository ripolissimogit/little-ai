import AppKit
import ApplicationServices

struct Target {
    let selection: String
    let selectionRect: CGRect?
    let fallbackCursor: CGPoint
    let sourceApp: NSRunningApplication?
}

/// Accessibility bridge: reads the focused text selection from any app, writes it back via
/// a clipboard-paste strategy. The paste approach works on AppKit, Electron (VSCode/Slack),
/// Chrome and Terminal — none of which honour AXUIElementSetAttributeValue on a non-frontmost
/// app.
enum AX {
    static func captureFocused() -> Target? {
        let trusted = AXIsProcessTrusted()
        Log.info("captureFocused start trusted=\(trusted) frontmost=\(frontmostDescription())", tag: "ax")
        if !trusted {
            Log.error("accessibility permission NOT granted", tag: "ax")
        }

        guard let element = focusedElement() else {
            Log.error("no focused UI element (systemWide AXFocusedUIElement returned nil)", tag: "ax")
            return nil
        }
        Log.debug("focused element: \(describe(element))", tag: "ax")

        var selected = attrString(element, kAXSelectedTextAttribute) ?? ""
        var source = "AXSelectedText"
        Log.info("AXSelectedText len=\(selected.count)", tag: "ax")
        if selected.isEmpty {
            Log.warn("empty AXSelectedText, falling back to clipboard sniff (⌘C)", tag: "ax")
            selected = sniffViaClipboard() ?? ""
            source = selected.isEmpty ? "none" : "clipboard-sniff"
        }
        let rect = selectionRect(element)
        let app = NSWorkspace.shared.frontmostApplication
        Log.info("captureFocused done source=\(source) selLen=\(selected.count) rect=\(rect.map { "\($0)" } ?? "nil") app=\(app?.localizedName ?? "?")", tag: "ax")

        return Target(
            selection: selected,
            selectionRect: rect,
            fallbackCursor: NSEvent.mouseLocation,
            sourceApp: app
        )
    }

    static func write(_ text: String, to target: Target) {
        let sourcePID = target.sourceApp?.processIdentifier ?? -1
        let sourceName = target.sourceApp?.localizedName ?? "?"
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        Log.info("write start sourceApp=\(sourceName)(\(sourcePID)) frontmost=\(frontPID) textLen=\(text.count)", tag: "ax")

        NSApp.deactivate()
        if let app = target.sourceApp {
            let ok = activate(app)
            Log.debug("activate(\(sourceName)) returned=\(ok)", tag: "ax")
        } else {
            Log.warn("no sourceApp recorded — skipping activation", tag: "ax")
        }

        let deadline = Date().addingTimeInterval(0.3)
        var pollCount = 0
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != sourcePID && Date() < deadline {
            usleep(15_000)
            pollCount += 1
        }
        let finalFront = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let activated = finalFront == sourcePID
        if activated {
            Log.info("source app became frontmost after \(pollCount) polls", tag: "ax")
        } else {
            Log.error("source app did NOT become frontmost (polls=\(pollCount) front=\(finalFront) wanted=\(sourcePID))", tag: "ax")
        }

        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)
        Log.debug("pasteboard snapshot items=\(snapshot.count)", tag: "ax")
        pb.clearContents()
        pb.setString(text, forType: .string)
        postCmd(0x09) // V
        Log.info("posted ⌘V (virtualKey=0x09)", tag: "ax")
        // Restore the previous clipboard after paste has landed.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            restorePasteboard(pb, items: snapshot)
            Log.debug("pasteboard restored", tag: "ax")
        }
    }

    @available(macOS, deprecated: 14.0)
    private static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &value)
        if status != .success {
            Log.error("AXUIElementCopyAttributeValue(focusedUI) failed status=\(status.rawValue)", tag: "ax")
            return nil
        }
        guard let v = value else { return nil }
        return (v as! AXUIElement)
    }

    private static func attrString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        if status != .success {
            Log.debug("attr \(attr) status=\(status.rawValue)", tag: "ax")
            return nil
        }
        return value as? String
    }

    private static func describe(_ el: AXUIElement) -> String {
        let role = attrString(el, kAXRoleAttribute) ?? "?"
        let subrole = attrString(el, kAXSubroleAttribute) ?? ""
        let title = attrString(el, kAXTitleAttribute) ?? ""
        return "role=\(role) subrole=\(subrole) title=\(title.prefix(40))"
    }

    private static func frontmostDescription() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return "\(app?.localizedName ?? "?")(\(app?.processIdentifier ?? -1))"
    }

    private static func selectionRect(_ el: AXUIElement) -> CGRect? {
        var range: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let r = range {
            var bounds: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, r, &bounds) == .success,
               let b = bounds {
                var rect = CGRect.zero
                AXValueGetValue(b as! AXValue, .cgRect, &rect)
                if rect.width > 0 || rect.height > 0 {
                    Log.debug("selectionRect from AXBoundsForRange=\(rect)", tag: "ax")
                    return rect
                }
            }
        }
        let frame = elementFrame(el)
        Log.debug("selectionRect fallback elementFrame=\(frame.map { "\($0)" } ?? "nil")", tag: "ax")
        return frame
    }

    private static func elementFrame(_ el: AXUIElement) -> CGRect? {
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let p = pos, let s = size else { return nil }
        var origin = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: origin, size: sz)
    }

    private static func sniffViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let previousChange = pb.changeCount
        let snapshot = snapshotPasteboard(pb)
        Log.debug("sniff: pre changeCount=\(previousChange) snapshot=\(snapshot.count)", tag: "ax")
        postCmd(0x08) // C
        var sniffed: String?
        let deadline = Date().addingTimeInterval(0.25)
        var polls = 0
        while Date() < deadline {
            usleep(20_000)
            polls += 1
            if pb.changeCount != previousChange {
                sniffed = pb.string(forType: .string)
                break
            }
        }
        restorePasteboard(pb, items: snapshot)
        let len = sniffed?.count ?? 0
        Log.info("sniff done polls=\(polls) changed=\(pb.changeCount != previousChange) len=\(len)", tag: "ax")
        return (sniffed?.isEmpty == false) ? sniffed : nil
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem]) {
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    private static func postCmd(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
