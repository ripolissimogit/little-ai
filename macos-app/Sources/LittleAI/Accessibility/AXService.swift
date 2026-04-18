import AppKit
import ApplicationServices

struct AXTextTarget {
    let element: AXUIElement
    let selectedText: String
    let broaderContext: String?
    let anchorPoint: CGPoint
}

enum AXService {
    static func captureFocusedSelection() -> AXTextTarget? {
        guard let element = focusedElement() else { return nil }
        guard let selected = selectedText(in: element), !selected.isEmpty else { return nil }
        let context = broaderContext(in: element, around: selected)
        let anchor = selectionBottomLeft(in: element) ?? mouseLocation()
        return AXTextTarget(
            element: element,
            selectedText: selected,
            broaderContext: context,
            anchorPoint: anchor
        )
    }

    static func replaceSelection(in element: AXUIElement, with text: String) {
        let cf = text as CFString
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, cf)
        if status != .success {
            // Fallback: paste via clipboard + cmd+V
            paste(text: text)
        }
    }

    // MARK: - Internals

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    private static func fullText(in element: AXUIElement) -> String? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    /// Returns the selected text plus surrounding text (up to ~800 chars before/after) to
    /// give the model better context for tonally consistent edits.
    private static func broaderContext(in element: AXUIElement, around selected: String) -> String? {
        guard let full = fullText(in: element), full.count > selected.count else { return nil }
        guard let range = full.range(of: selected) else { return full }
        let window = 800
        let start = full.index(range.lowerBound, offsetBy: -min(window, full.distance(from: full.startIndex, to: range.lowerBound)))
        let end = full.index(range.upperBound, offsetBy: min(window, full.distance(from: range.upperBound, to: full.endIndex)))
        return String(full[start..<end])
    }

    private static func selectionBottomLeft(in element: AXUIElement) -> CGPoint? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let range = rangeValue else { return nil }

        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsValue
        ) == .success, let bounds = boundsValue else { return nil }

        var rect = CGRect.zero
        AXValueGetValue(bounds as! AXValue, .cgRect, &rect)

        // AX coords have origin at top-left of the primary screen; convert to NSScreen bottom-left.
        guard let screen = NSScreen.screens.first else { return nil }
        let flippedY = screen.frame.height - rect.maxY
        return CGPoint(x: rect.minX, y: flippedY)
    }

    private static func mouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: p.y)
    }

    private static func paste(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum AccessibilityPermission {
    static func requestIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
