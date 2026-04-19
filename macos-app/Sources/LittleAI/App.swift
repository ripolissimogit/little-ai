import AppKit

@main
@MainActor
final class App: NSObject, NSApplicationDelegate {
    static let version = "0.3"

    static func main() {
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
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

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Little AI")
        item.button?.image?.isTemplate = true
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
        toolbar.onAccept = { [weak self] text, insert in self?.apply(text, insert: insert) }
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
        Log.info("runEdit action=\(action.rawValue) tone=\(tone?.rawValue ?? "-") selLen=\(t.selection.count) ctxLen=\(context?.count ?? 0)", tag: "app")
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
            self.complete(Prompt.edit(action: action, tone: tone, selection: t.selection, context: self.context), insert: false)
        }
    }

    private func runGenerate(prompt: String) {
        guard target != nil else {
            Log.warn("runGenerate ignored — no target", tag: "app")
            return
        }
        Log.info("runGenerate promptLen=\(prompt.count)", tag: "app")
        toolbar.setLoading()
        complete(Prompt.generate(prompt: prompt), insert: true)
    }

    private func complete(_ req: AIRequest, insert: Bool) {
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
                    Log.info("complete ok (skipPreview) → applying directly", tag: "app")
                    apply(result, insert: insert)
                } else {
                    Log.info("complete ok → showing preview", tag: "app")
                    toolbar.setPreview(result: result, insert: insert)
                }
            } catch {
                Log.error("complete failed: \(error.localizedDescription)", tag: "app")
                toolbar.setError(error.localizedDescription)
            }
        }
    }

    private func apply(_ text: String, insert: Bool) {
        guard let t = target else {
            Log.error("apply ignored — no target", tag: "app")
            return
        }
        Log.info("apply insert=\(insert) textLen=\(text.count)", tag: "app")
        toolbar.hide()
        AX.write(text, to: t)
        target = nil
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
