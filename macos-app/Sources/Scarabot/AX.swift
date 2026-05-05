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
        let bundleID = app?.bundleIdentifier ?? ""
        let isTerminal = terminalBundleIDs.contains(bundleID)
        Log.debug("captureFocused: bundleID=\(bundleID) isTerminal=\(isTerminal)", tag: "ax")

        // Strategy: a synthetic ⌘C is the only thing that works reliably on Chrome,
        // Electron apps, Word, Pages, IDE editors, and any host whose AX tree is
        // unreliable or dormant. So we treat ⌘C as the *primary* path, not the fallback.
        //
        // Order:
        //   1. Pasteboard-fresh: if the user did ⌘C themselves between the previous
        //      capture and this one, that's already the selection — skip the synthetic.
        //   2. Synthetic ⌘C via CGEvent (cheap, ~15ms). Works on AppKit and most native
        //      Cocoa apps. Skipped on terminals (would SIGINT the shell if no selection).
        //   3. Synthetic ⌘C via AppleScript / System Events. Slower (~150ms) but the
        //      only thing Electron, Chromium tabs, and Apple Events-only apps honour.
        //      Skipped on terminals.
        //   4. Menu Edit → Copy via AXPress. Safe on terminals (dispatches `copy:`
        //      action, not a keystroke, so no SIGINT). Used as the *only* synthetic
        //      path in terminals.
        //   5. AX direct (AXSelectedText / WebKit marker range). These are now strictly
        //      a "couldn't synthesize anything" backstop — they were unreliable enough
        //      as primary that promoting ⌘C ahead of them dramatically reduces the
        //      "I selected text and nothing happened" failure mode.
        //
        // The pasteboard is restored at the end of every synthetic step so the user's
        // clipboard is preserved.

        let pb = NSPasteboard.general
        let pbCountAtEntry = pb.changeCount
        let pbWasFresh = (lastSeenChangeCount >= 0) && pbCountAtEntry != lastSeenChangeCount

        var selected = ""
        var source = "none"

        // 1. Fresh pasteboard wins outright — we trust the user's explicit ⌘C.
        if pbWasFresh, let s = pb.string(forType: .string), !s.isEmpty {
            selected = s
            source = "pasteboard-fresh"
            Log.info("pasteboard was fresh — using as selection (len=\(s.count))", tag: "ax")
        }

        // 2. + 3. + 4. Synthetic copy. Try CGEvent first (fastest and silent for native
        // apps), then AppleScript (works on Electron / Chromium where CGEvent is
        // ignored), then menu AXPress (safe on terminals).
        if selected.isEmpty {
            if !isTerminal {
                if let s = sniffViaClipboard(), !s.isEmpty {
                    selected = s
                    source = "cgevent"
                }
                if selected.isEmpty, let s = sniffViaAppleScript(), !s.isEmpty {
                    selected = s
                    source = "applescript"
                }
            }
            if selected.isEmpty, let s = sniffViaMenuCopy(app: app), !s.isEmpty {
                selected = s
                source = "menu-copy"
            }
        }

        // 5. Last-resort AX direct read. Most apps either let synthetic ⌘C land in 2-4
        // or hide their selection from AX entirely — this catches the rare case (some
        // legacy Carbon apps) where neither holds.
        if selected.isEmpty, let element = focusedElement() {
            if let s = attrString(element, kAXSelectedTextAttribute), !s.isEmpty {
                selected = s
                source = "AXSelectedText"
            } else if let s = readWebKitSelection(element), !s.isEmpty {
                selected = s
                source = "AXTextMarkerRange"
            }
        }

        // Determine editability + rect when we can find a focused element. If we can't
        // (Chrome with dormant AX tree, etc.), assume the surface is editable when we
        // captured a selection — the same surface that responded to ⌘C will respond to
        // ⌘V too. Static-text views (PDF readers, received emails) lack a selection so
        // they fall through to non-editable.
        let element = focusedElement()
        let rect = element.flatMap { selectionRect($0) }
        let editable: Bool
        if let element {
            editable = isEditable(element, hasSelection: !selected.isEmpty)
        } else {
            editable = !selected.isEmpty
        }

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

    /// Returns true when the focused element accepts value mutation. Strong signals
    /// first (insertion point, editable role, settable AXValue), then a selection-based
    /// heuristic for container-style hosts: Word exposes the focused element as an
    /// `AXSplitGroup`, Pages as `AXGroup`, Notes/Outlook as `AXScrollArea`, and most
    /// IDEs and Electron apps wrap their editor in a webview. None of these answer the
    /// strong checks, but if Copy succeeded against them (selection captured) we can
    /// safely assume Paste will land too — the same surface that honoured ⌘C honours ⌘V.
    private static func isEditable(_ el: AXUIElement, hasSelection: Bool) -> Bool {
        let role = attrString(el, kAXRoleAttribute) ?? ""
        if role == "AXStaticText" { return false }

        // 1. Insertion point: only present on elements that host a typing caret. Strong
        //    positive across AppKit, WebKit, IDE editors that expose the caret element.
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

        // 3. AXValue settable flag.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            Log.debug("isEditable role=\(role) AXValue settable=true → editable", tag: "ax")
            return true
        }

        // 4. Selection-presence heuristic for container-style focus elements
        //    (AXSplitGroup, AXScrollArea, AXGroup, AXWebArea, AXLayoutArea …). Word /
        //    Pages / Notes / IDE editors all park focus on a host node whose AX info
        //    looks readonly, but if the menu-copy / ⌘C path returned text, the surface
        //    is responsive to clipboard commands and Paste should land.
        if hasSelection {
            Log.debug("isEditable role=\(role) → editable (selection captured implies paste-capable)", tag: "ax")
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
