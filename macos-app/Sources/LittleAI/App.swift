import AppKit

@main
@MainActor
final class App: NSObject, NSApplicationDelegate {
    static let version = "0.3"

    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private var statusItem: NSStatusItem?
    private let hotkey = Hotkey()
    private let toolbar = Toolbar()
    private var target: Target?
    private var context: String?
    private var contextTask: Task<Void, Never>?
    private var inFlight = false

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.boot(version: App.version)

        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        Log.info("accessibility trusted=\(trusted)", tag: "app")

        // Minimal main menu — needed so the standard ⌘X/⌘C/⌘V/⌘A shortcuts reach the
        // first responder (SwiftUI TextField) when the panel is key. Without this,
        // pasting into the compose field silently fails.
        NSApp.mainMenu = Self.buildMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            item.button?.image = img
        } else {
            let img = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: "Little AI")
            img?.isTemplate = true
            item.button?.image = img
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Inserisci senza anteprima", action: #selector(toggleSkipPreview(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = Prefs.skipPreview ? .on : .off
        menu.addItem(toggle)
        let ocrToggle = NSMenuItem(title: "Usa contesto OCR", action: #selector(toggleOCR(_:)), keyEquivalent: "")
        ocrToggle.target = self
        ocrToggle.state = Prefs.useOCRContext ? .on : .off
        menu.addItem(ocrToggle)
        menu.addItem(.separator())
        let openLog = NSMenuItem(title: "Apri log", action: #selector(openLog(_:)), keyEquivalent: "l")
        openLog.target = self
        menu.addItem(openLog)
        let revealLog = NSMenuItem(title: "Mostra log nel Finder", action: #selector(revealLog(_:)), keyEquivalent: "")
        revealLog.target = self
        menu.addItem(revealLog)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        hotkey.onTrigger = { [weak self] in Task { @MainActor in self?.trigger() } }
        hotkey.start()

        toolbar.onEdit = { [weak self] action, tone in self?.runEdit(action: action, tone: tone) }
        toolbar.onGenerate = { [weak self] prompt in self?.runGenerate(prompt: prompt) }
        toolbar.onAccept = { [weak self] text, mode in self?.apply(text, mode: mode) }
        toolbar.onDismiss = { [weak self] in
            self?.target = nil
            Log.debug("toolbar dismissed", tag: "app")
        }
    }

    @objc private func toggleSkipPreview(_ sender: NSMenuItem) {
        Prefs.skipPreview.toggle()
        sender.state = Prefs.skipPreview ? .on : .off
        Log.info("skipPreview toggled -> \(Prefs.skipPreview)", tag: "app")
    }

    @objc private func toggleOCR(_ sender: NSMenuItem) {
        Prefs.useOCRContext.toggle()
        sender.state = Prefs.useOCRContext ? .on : .off
        Log.info("useOCRContext toggled -> \(Prefs.useOCRContext)", tag: "app")
        if Prefs.useOCRContext && !OCR.isPermissionGranted() {
            OCR.requestPermission()
        }
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func revealLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    private func trigger() {
        Log.info("trigger (double-shift) toolbarVisible=\(toolbar.isVisible) inFlight=\(inFlight)", tag: "app")
        // Toggle: if toolbar is already up, dismiss it and bail.
        if toolbar.isVisible {
            Log.info("trigger: toolbar already visible — dismissing (toggle)", tag: "app")
            toolbar.hide()
            return
        }
        guard let t = AX.captureFocused() else {
            Log.error("trigger: no target captured → beep", tag: "app")
            NSSound.beep()
            return
        }
        target = t
        context = nil
        contextTask?.cancel()
        toolbar.show(target: t)
        Log.debug("trigger: toolbar shown selLen=\(t.selection.count)", tag: "app")

        // Kick off OCR context capture in parallel with the UI. Stored for runEdit to use.
        if Prefs.useOCRContext && !t.selection.isEmpty {
            let cursor = t.fallbackCursor
            contextTask = Task { @MainActor [weak self] in
                let ctx = await OCR.captureContext(around: cursor)
                guard let self, !Task.isCancelled else { return }
                self.context = ctx
                Log.info("context ready (len=\(ctx?.count ?? 0))", tag: "app")
            }
        }
    }

    private func runEdit(action: Action, tone: Tone?) {
        guard let t = target, !t.selection.isEmpty else {
            Log.warn("runEdit ignored — no target or empty selection", tag: "app")
            return
        }
        Log.info("runEdit action=\(action.rawValue) tone=\(tone?.rawValue ?? "-") selLen=\(t.selection.count) ctxLen=\(context?.count ?? 0) editable=\(t.isEditable)", tag: "app")
        toolbar.setLoading()
        // Wait up to ~500ms for the OCR context task to finish, if it's still running.
        Task { @MainActor [weak self] in
            if let self, let task = self.contextTask, Prefs.useOCRContext {
                _ = await withTaskGroup(of: Void.self) { group in
                    group.addTask { await task.value }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
            guard let self else { return }
            let mode: ApplyMode = t.isEditable ? .replace : .copy
            self.complete(Prompt.edit(action: action, tone: tone, selection: t.selection, context: self.context), mode: mode)
        }
    }

    private func runGenerate(prompt: String) {
        guard let t = target else {
            Log.warn("runGenerate ignored — no target", tag: "app")
            return
        }
        Log.info("runGenerate promptLen=\(prompt.count)", tag: "app")
        toolbar.setLoading()
        let mode: ApplyMode = t.isEditable ? .insert : .copy
        complete(Prompt.generate(prompt: prompt), mode: mode)
    }

    private func complete(_ req: AIRequest, mode: ApplyMode) {
        if inFlight {
            Log.warn("complete ignored — another request already in flight", tag: "app")
            return
        }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let result = try await Anthropic.complete(req)
                if Prefs.skipPreview {
                    Log.info("complete ok (skipPreview) → applying directly mode=\(mode)", tag: "app")
                    apply(result, mode: mode)
                } else {
                    Log.info("complete ok → showing preview mode=\(mode)", tag: "app")
                    toolbar.setPreview(result: result, mode: mode)
                }
            } catch {
                Log.error("complete failed: \(error.localizedDescription)", tag: "app")
                toolbar.setError(error.localizedDescription)
            }
        }
    }

    private func apply(_ text: String, mode: ApplyMode) {
        Log.info("apply mode=\(mode) textLen=\(text.count)", tag: "app")
        toolbar.hide()
        switch mode {
        case .replace, .insert:
            guard let t = target else {
                Log.error("apply ignored — no target", tag: "app")
                return
            }
            AX.write(text, to: t)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            Log.info("copied result to pasteboard", tag: "app")
        }
        target = nil
    }
}

extension App {
    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Nascondi LittleAI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Modifica")
        editMenu.addItem(NSMenuItem(title: "Annulla", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Ripristina", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Seleziona tutto", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }
}

enum Prefs {
    static var skipPreview: Bool {
        get { UserDefaults.standard.bool(forKey: "skipPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "skipPreview") }
    }

    /// Default ON: apps without AX text support (Electron, browsers, Claude Desktop)
    /// benefit from OCR context for better tone/style alignment.
    static var useOCRContext: Bool {
        get {
            if UserDefaults.standard.object(forKey: "useOCRContext") == nil { return true }
            return UserDefaults.standard.bool(forKey: "useOCRContext")
        }
        set { UserDefaults.standard.set(newValue, forKey: "useOCRContext") }
    }
}
