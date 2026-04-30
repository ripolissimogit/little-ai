import AppKit
import ApplicationServices

struct Target {
    let selection: String
    let selectionRect: CGRect?
    let fallbackCursor: CGPoint
    let sourceApp: NSRunningApplication?
    /// True if the focused element's value can be mutated (editable text field/area).
    /// False for PDF selections, static text, received email threads, etc.
    let isEditable: Bool
}

/// Accessibility bridge: reads the focused text selection from any app, writes it back via
/// a clipboard-paste strategy. The paste approach works on AppKit, Electron (VSCode/Slack),
/// Chrome and Terminal — none of which honour AXUIElementSetAttributeValue on a non-frontmost
/// app.
enum AX {
    /// Bundle IDs for terminal emulators where a synthetic ⌘C keystroke is dangerous: if
    /// no selection is active it is interpreted by the shell as SIGINT, killing whatever
    /// process is running. For these we avoid the keystroke path entirely and rely on
    /// AXPress on the Edit→Copy menu item instead.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
    ]

    /// `NSPasteboard.general.changeCount` observed at the end of the last `captureFocused`
    /// call. Used to detect whether the user has copied something between two invocations:
    /// if the count moved we treat the current pasteboard as a "fresh" selection sniffing
    /// fallback. -1 means we haven't observed yet (cold start), so the first invocation
    /// never triggers the fresh-pasteboard path.
    private static var lastSeenChangeCount: Int = -1

    static func captureFocused() -> Target? {
        let trusted = AXIsProcessTrusted()
        Log.info("captureFocused start trusted=\(trusted) frontmost=\(frontmostDescription())", tag: "ax")
        if !trusted {
            Log.error("accessibility permission NOT granted", tag: "ax")
        }

        let app = NSWorkspace.shared.frontmostApplication

        // Snapshot the pasteboard's "freshness" before any AX path runs — sniffViaMenuCopy /
        // sniffViaClipboard temporarily mutate the pasteboard, which would invalidate the
        // signal if we read it later. The pasteboard is "fresh" when its changeCount has
        // moved since the previous captureFocused call: that means the user (or another
        // process) wrote to it in the meantime — typically a manual ⌘C right before the
        // hotkey. Update lastSeenChangeCount only at the very end, after our own
        // restorePasteboard mutations, so we don't accidentally flag our own writes.
        let pbCountAtEntry = NSPasteboard.general.changeCount
        let pbWasFresh = (lastSeenChangeCount >= 0) && pbCountAtEntry != lastSeenChangeCount

        guard let element = focusedElement() else {
            // No focused UI element: Chrome without a focused input, plain desktop,
            // our own accessory app frontmost, etc. Return a blank target instead of
            // nil so the toolbar still opens — Generate / PromptifyCompose / PromptFromImage
            // don't need a selection. Selection-required actions (Edit / Explain) will
            // no-op gracefully because target.selection.isEmpty. We still consult a fresh
            // pasteboard: if the user just ⌘C'd inside an unsupported app we want their
            // text to feed into Edit/Explain.
            var fallbackSelection = ""
            if pbWasFresh, let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                fallbackSelection = s
                Log.info("no focused element but pasteboard was fresh — using it as selection (len=\(s.count))", tag: "ax")
            } else {
                Log.warn("no focused UI element — returning blank target so toolbar can still open", tag: "ax")
            }
            lastSeenChangeCount = NSPasteboard.general.changeCount
            return Target(
                selection: fallbackSelection,
                selectionRect: nil,
                fallbackCursor: NSEvent.mouseLocation,
                sourceApp: app,
                isEditable: false
            )
        }
        Log.debug("focused element: \(describe(element))", tag: "ax")

        let bundleID = app?.bundleIdentifier ?? ""
        let isTerminal = terminalBundleIDs.contains(bundleID)
        Log.debug("app bundleID=\(bundleID) isTerminal=\(isTerminal)", tag: "ax")

        var selected = ""
        var source = "none"

        // 1. Plain AXSelectedText — fastest, works for AppKit text fields, most native apps.
        if let s = attrString(element, kAXSelectedTextAttribute), !s.isEmpty {
            selected = s
            source = "AXSelectedText"
            Log.info("AXSelectedText len=\(selected.count)", tag: "ax")
        }

        // 2. WebKit text markers — Safari, Mail (compose is AppKit, but quoted replies are
        // WebKit), Notes (rich text), any embedded WKWebView. Exposes selection via
        // AXSelectedTextMarkerRange instead of AXSelectedText.
        if selected.isEmpty {
            if let s = readWebKitSelection(element), !s.isEmpty {
                selected = s
                source = "AXTextMarkerRange"
                Log.info("WebKit marker selection len=\(selected.count)", tag: "ax")
            }
        }

        // 3. Menu AXPress on Edit→Copy — safe everywhere. Doesn't generate a ⌘C keystroke so
        // it can't be interpreted as SIGINT by a running shell process in Terminal.app.
        if selected.isEmpty {
            if let s = sniffViaMenuCopy(app: app), !s.isEmpty {
                selected = s
                source = "menu-copy"
                Log.info("menu-copy selection len=\(selected.count)", tag: "ax")
            }
        }

        // 4. Synthetic ⌘C via CGEvent. Skipped for terminal emulators — without an active
        // selection this would deliver SIGINT to whatever is running in the shell.
        if selected.isEmpty && !isTerminal {
            Log.warn("AX/menu paths empty, trying CGEvent ⌘C sniff", tag: "ax")
            if let s = sniffViaClipboard(), !s.isEmpty {
                selected = s
                source = "clipboard-sniff"
            }
        } else if selected.isEmpty && isTerminal {
            Log.info("skipping CGEvent ⌘C sniff for terminal-like app (\(bundleID)) to avoid SIGINT", tag: "ax")
        }

        // 5. Synthetic ⌘C via AppleScript "System Events". Electron / Chromium / many
        // IDE-style apps (VSCode, Cursor, Claude Desktop, Slack, Discord, ChatGPT app, …)
        // ignore raw CGEvent keystrokes but accept Apple Events high-level keystrokes.
        // Same SIGINT guard for terminals.
        if selected.isEmpty && !isTerminal {
            Log.warn("CGEvent ⌘C sniff empty, trying AppleScript ⌘C sniff", tag: "ax")
            if let s = sniffViaAppleScript(), !s.isEmpty {
                selected = s
                source = "applescript-sniff"
            }
        }

        // 6. Final fallback: if every AX/menu/keystroke path failed but the user wrote
        // something to the pasteboard between this capture and the previous one (typically
        // a manual ⌘C right before the hotkey), use that. This is the path that "rescues"
        // Terminal and any other app where AX selection is opaque — the user's documented
        // workaround is to copy first, then double-shift. We compare to pbCountAtEntry, not
        // the current count, because our own sniffs above mutate the pasteboard.
        if selected.isEmpty && pbWasFresh {
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                selected = s
                source = "pasteboard-fresh"
                Log.info("using fresh pasteboard content len=\(selected.count) (changeCount \(lastSeenChangeCount)→\(pbCountAtEntry))", tag: "ax")
            }
        }

        let rect = selectionRect(element)
        let editable = isEditable(element)
        Log.info("captureFocused done source=\(source) selLen=\(selected.count) editable=\(editable) rect=\(rect.map { "\($0)" } ?? "nil") app=\(app?.localizedName ?? "?")", tag: "ax")

        lastSeenChangeCount = NSPasteboard.general.changeCount

        return Target(
            selection: selected,
            selectionRect: rect,
            fallbackCursor: NSEvent.mouseLocation,
            sourceApp: app,
            isEditable: editable
        )
    }

    /// Returns true when the focused element accepts value mutation. Order matters:
    /// `AXValue settable` is checked LAST because rich-text apps (Word, Pages, Notes,
    /// many WebArea hosts, …) compose their document from sub-elements and report
    /// settable=false on the focused element even though the caret is alive and paste
    /// works. We trust insertion-point presence and known-editable roles first.
    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = attrString(el, kAXRoleAttribute) ?? ""
        if role == "AXStaticText" { return false }

        // 1. Insertion point: only present on elements that host a typing caret. Strong
        //    positive signal across AppKit, WebKit, Word, Pages, Notes, IDE editors.
        var insertionValue: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXInsertionPointLineNumberAttribute as CFString, &insertionValue) == .success {
            Log.debug("isEditable role=\(role) has insertion point → editable", tag: "ax")
            return true
        }

        // 2. Roles that are unambiguously editable on macOS.
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            Log.debug("isEditable role=\(role) → editable (role)", tag: "ax")
            return true
        }

        // 3. Last resort: AXValue settable flag. Only honoured for elements that don't
        //    match the stronger signals above, since plenty of editable surfaces (Word
        //    document body, Pages, Notes rich text) report it as false.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            Log.debug("isEditable role=\(role) AXValue settable=true → editable", tag: "ax")
            return true
        }

        Log.debug("isEditable role=\(role) → readonly (fallback)", tag: "ax")
        return false
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
        if status == .success, let v = value {
            return (v as! AXUIElement)
        }
        Log.warn("systemWide AXFocusedUIElement failed status=\(status.rawValue) — falling back to frontmost app element", tag: "ax")

        // Chrome (and a few other apps) often refuse to expose focus through the systemWide
        // element but answer the same query when asked through their own application
        // element. Try that before giving up.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Log.error("no frontmost application to query for focused element", tag: "ax")
            return nil
        }
        let appEl = AXUIElementCreateApplication(pid)
        var appValue: AnyObject?
        let appStatus = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &appValue)
        if appStatus == .success, let av = appValue {
            Log.info("focusedElement recovered via app-pid fallback (pid=\(pid))", tag: "ax")
            return (av as! AXUIElement)
        }
        Log.error("app-pid AXFocusedUIElement also failed status=\(appStatus.rawValue) pid=\(pid)", tag: "ax")
        return nil
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

    /// WebKit/Safari/Mail quoted-reply selection. WebKit doesn't fill AXSelectedText on the
    /// web content element; selection lives in an opaque `AXTextMarkerRange`. We resolve it
    /// to a plain string via the parameterized attribute `AXStringForTextMarkerRange`.
    private static func readWebKitSelection(_ el: AXUIElement) -> String? {
        let rangeAttr = "AXSelectedTextMarkerRange" as CFString
        let stringAttr = "AXStringForTextMarkerRange" as CFString
        var range: AnyObject?
        let rs = AXUIElementCopyAttributeValue(el, rangeAttr, &range)
        guard rs == .success, let r = range else {
            Log.debug("readWebKitSelection: no AXSelectedTextMarkerRange status=\(rs.rawValue)", tag: "ax")
            return nil
        }
        var str: AnyObject?
        let ss = AXUIElementCopyParameterizedAttributeValue(el, stringAttr, r, &str)
        if ss != .success {
            Log.debug("readWebKitSelection: AXStringForTextMarkerRange failed status=\(ss.rawValue)", tag: "ax")
            return nil
        }
        return (str as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Performs the Copy command via AXPress on the focused app's Edit menu item. Localised
    /// title match — works across macOS languages. Safe in Terminal: AXPress dispatches
    /// through the first responder's `copy:` action, never through the keyboard, so no ⌘C
    /// keystroke is synthesised and no SIGINT is sent to a running shell process.
    ///
    /// We intentionally do NOT pre-check `kAXEnabledAttribute` on the menu item: Cocoa
    /// updates enablement via `validateMenuItem:` only when the menu is actually opened, so
    /// the AX-visible enabled flag is stale until then (reports `false` even when a text
    /// selection exists). Instead we always invoke AXPress and rely on the pasteboard's
    /// `changeCount` to tell us whether the copy happened — if nothing was selected, Cocoa
    /// no-ops and `changeCount` stays put.
    private static func sniffViaMenuCopy(app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let copyItem = findEditMenuItem(appEl, names: copyMenuTitles)
            ?? findEditMenuItemByShortcut(appEl, char: "c")
        guard let copy = copyItem else {
            Log.debug("sniffViaMenuCopy: Copy menu item not found (neither by title nor by ⌘C shortcut)", tag: "ax")
            return nil
        }

        let pb = NSPasteboard.general
        let previousChange = pb.changeCount
        let snapshot = snapshotPasteboard(pb)
        let pressStatus = AXUIElementPerformAction(copy, kAXPressAction as CFString)
        Log.debug("sniffViaMenuCopy: AXPress status=\(pressStatus.rawValue)", tag: "ax")
        if pressStatus != .success {
            restorePasteboard(pb, items: snapshot)
            return nil
        }

        let sniffed = waitForPasteboardWrite(pb: pb, baseline: previousChange, timeout: 0.3, settleDelay: 0.08)
        restorePasteboard(pb, items: snapshot)
        Log.info("sniffViaMenuCopy changed=\(pb.changeCount != previousChange) len=\(sniffed?.count ?? 0)", tag: "ax")
        return (sniffed?.isEmpty == false) ? sniffed : nil
    }

    /// Waits for a pasteboard write to land and stabilise. AppKit and many third-party apps
    /// implement `Copy` as `clearContents()` followed by `setString(...)`, which produces
    /// two separate `changeCount` bumps. A naive "exit on first bump" reader sees the empty
    /// intermediate state. This helper waits for the first bump within `timeout`, then
    /// sleeps `settleDelay` so the subsequent setString completes, then reads the string.
    /// Returns nil if no bump was observed within the timeout.
    private static func waitForPasteboardWrite(pb: NSPasteboard, baseline: Int, timeout: TimeInterval, settleDelay: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(20_000)
            if pb.changeCount != baseline { break }
        }
        guard pb.changeCount != baseline else { return nil }
        if settleDelay > 0 {
            usleep(useconds_t(settleDelay * 1_000_000))
        }
        return pb.string(forType: .string)
    }

    /// Fallback for apps whose Edit submenu children aren't populated until the menu opens,
    /// or where the Copy item has a non-standard title. Searches by keyboard equivalent:
    /// the menu item bound to `⌘<char>`. Cmd char attributes are populated eagerly on the
    /// menu-bar tree, unlike children arrays.
    private static func findEditMenuItemByShortcut(_ appEl: AXUIElement, char: String) -> AXUIElement? {
        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let mb = menuBar else { return nil }
        let menuBarEl = mb as! AXUIElement
        guard let editTop = findChild(menuBarEl, matchingAny: editMenuTitles),
              let submenu = firstChild(editTop) else { return nil }
        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(submenu, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return nil }
        let wanted = char.lowercased()
        for child in children {
            let cmdChar = (attrString(child, "AXMenuItemCmdChar") ?? "").lowercased()
            // Cmd-only modifier is encoded as 0 in AppKit's AX menu model.
            var modsVal: AnyObject?
            let modsOK = AXUIElementCopyAttributeValue(child, "AXMenuItemCmdModifiers" as CFString, &modsVal) == .success
            let mods = (modsVal as? Int) ?? -1
            if cmdChar == wanted && modsOK && mods == 0 {
                return child
            }
        }
        return nil
    }

    /// Localised titles for the Edit menu and the Copy item across the macOS languages we
    /// plausibly encounter. Kept small and matched case-insensitively downstream.
    private static let editMenuTitles: [String] = [
        "Edit", "Modifica", "Édition", "Edición", "Bearbeiten", "Editar",
        "Bewerken", "Redigera", "Rediger", "Muokkaa", "Edytuj", "Upravit",
        "Επεξεργασία", "Düzen", "Правка", "编辑", "編集", "편집",
    ]
    private static let copyMenuTitles: [String] = [
        "Copy", "Copia", "Copier", "Copiar", "Kopieren", "Kopiëren",
        "Kopiera", "Kopier", "Kopioi", "Kopiuj", "Kopírovat",
        "Αντιγραφή", "Kopyala", "Копировать", "复制", "コピー", "복사",
    ]

    private static func findEditMenuItem(_ appEl: AXUIElement, names: [String]) -> AXUIElement? {
        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let mb = menuBar else { return nil }
        let menuBarEl = mb as! AXUIElement
        guard let editTop = findChild(menuBarEl, matchingAny: editMenuTitles) else { return nil }
        // The top-level menu-bar item has a single AXMenu child that holds the actual items.
        guard let submenu = firstChild(editTop) else { return nil }
        return findChild(submenu, matchingAny: names)
    }

    private static func findChild(_ el: AXUIElement, matchingAny titles: [String]) -> AXUIElement? {
        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return nil }
        let lowered = Set(titles.map { $0.lowercased() })
        for child in children {
            let title = (attrString(child, kAXTitleAttribute) ?? "").lowercased()
            if lowered.contains(title) { return child }
        }
        return nil
    }

    private static func firstChild(_ el: AXUIElement) -> AXUIElement? {
        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let children = childrenVal as? [AXUIElement] else { return nil }
        return children.first
    }

    private static func sniffViaClipboard() -> String? {
        let pb = NSPasteboard.general
        let previousChange = pb.changeCount
        let snapshot = snapshotPasteboard(pb)
        Log.debug("sniff: pre changeCount=\(previousChange) snapshot=\(snapshot.count)", tag: "ax")
        withMutedAlertVolume {
            postCmdC()
        }
        let sniffed = waitForPasteboardWrite(pb: pb, baseline: previousChange, timeout: 0.25, settleDelay: 0.08)
        restorePasteboard(pb, items: snapshot)
        let len = sniffed?.count ?? 0
        Log.info("sniff done changed=\(pb.changeCount != previousChange) len=\(len)", tag: "ax")
        return (sniffed?.isEmpty == false) ? sniffed : nil
    }

    /// Last-chance copy via AppleScript's `tell application "System Events" to keystroke
    /// "c" using {command down}`. AppleScript routes through the Apple Events high-level
    /// keystroke pipeline, which Electron / Chromium / many webview-hosted apps accept
    /// even when raw CGEvent keystrokes are silently ignored. Slower (~150 ms) than the
    /// CGEvent path so it runs only as a step-5 fallback. Mutes the system alert volume
    /// to prevent the empty-selection beep, and restores the pasteboard at the end.
    private static func sniffViaAppleScript() -> String? {
        let pb = NSPasteboard.general
        let previousChange = pb.changeCount
        let snapshot = snapshotPasteboard(pb)

        let source = """
        set savedVolume to alert volume of (get volume settings)
        tell application "System Events" to set volume alert volume 0
        try
            tell application "System Events" to keystroke "c" using {command down}
        end try
        delay 0.05
        tell application "System Events" to set volume alert volume savedVolume
        """
        var scriptError: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&scriptError)
            if let err = scriptError {
                Log.warn("sniffViaAppleScript: NSAppleScript error \(err)", tag: "ax")
                restorePasteboard(pb, items: snapshot)
                return nil
            }
        } else {
            Log.warn("sniffViaAppleScript: NSAppleScript init failed", tag: "ax")
            restorePasteboard(pb, items: snapshot)
            return nil
        }

        let sniffed = waitForPasteboardWrite(pb: pb, baseline: previousChange, timeout: 0.4, settleDelay: 0.08)
        restorePasteboard(pb, items: snapshot)
        let len = sniffed?.count ?? 0
        Log.info("sniffViaAppleScript changed=\(pb.changeCount != previousChange) len=\(len)", tag: "ax")
        return (sniffed?.isEmpty == false) ? sniffed : nil
    }

    /// Run a block while the system alert volume is muted, then restore the previous
    /// volume. Used to silence the empty-selection beep that ⌘C produces when no text is
    /// actually selected. Failures are logged and don't propagate — the worst case is a
    /// momentary beep.
    private static func withMutedAlertVolume(_ block: () -> Void) {
        let muteScript = """
        set savedVolume to alert volume of (get volume settings)
        tell application "System Events" to set volume alert volume 0
        return savedVolume
        """
        var error: NSDictionary?
        var savedVolume: Int = -1
        if let script = NSAppleScript(source: muteScript) {
            let result = script.executeAndReturnError(&error)
            if error == nil {
                savedVolume = Int(result.int32Value)
            }
        }
        block()
        if savedVolume >= 0 {
            let restoreScript = "tell application \"System Events\" to set volume alert volume \(savedVolume)"
            if let script = NSAppleScript(source: restoreScript) {
                script.executeAndReturnError(&error)
            }
        }
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

    /// Posts a synthetic ⌘C with full modifier sequencing: cmd-down → c-down → c-up →
    /// cmd-up, plus the matching `flags` mask on the C events. The shorter `postCmd`
    /// variant works for AppKit / Cocoa apps but Electron and some Chromium-derived apps
    /// only honour the chord when they observe the explicit cmd flagsChanged transition,
    /// not just the modifier mask attached to the keyDown.
    private static func postCmdC() {
        let cKey: CGKeyCode = 0x08
        let cmdLeft: CGKeyCode = 0x37
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmdLeft, keyDown: true)
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let cUp = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmdLeft, keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
