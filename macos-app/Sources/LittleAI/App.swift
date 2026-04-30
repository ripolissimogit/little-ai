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
            img.size = NSSize(width: 20, height: 20)
            item.button?.image = img
        } else {
            let img = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: "Little AI")
            img?.isTemplate = true
            item.button?.image = img
        }
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Impostazioni…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Inserisci senza anteprima", action: #selector(toggleSkipPreview(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = Prefs.skipPreview ? .on : .off
        menu.addItem(toggle)
        let ocrToggle = NSMenuItem(title: "Usa contesto OCR", action: #selector(toggleOCR(_:)), keyEquivalent: "")
        ocrToggle.target = self
        ocrToggle.state = Prefs.useOCRContext ? .on : .off
        menu.addItem(ocrToggle)
        menu.addItem(.separator())

        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for p in [Provider.anthropic, Provider.openai] {
            let mi = NSMenuItem(title: p.label, action: #selector(selectProvider(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.rawValue
            mi.state = (Prefs.provider == p) ? .on : .off
            providerMenu.addItem(mi)
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        let presetItem = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        presetItem.submenu = buildPresetMenu()
        menu.addItem(presetItem)

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

        toolbar.onEdit = { [weak self] action, tone, target in self?.runEdit(action: action, tone: tone, target: target) }
        toolbar.onGenerate = { [weak self] prompt in self?.runGenerate(prompt: prompt) }
        toolbar.onPromptifyCompose = { [weak self] text, target in self?.runPromptifyCompose(text: text, target: target) }
        toolbar.onPromptFromImage = { [weak self] in self?.runPromptFromImage() }
        toolbar.onAccept = { [weak self] text, mode in self?.apply(text, mode: mode) }
        toolbar.onDismiss = { [weak self] in
            self?.target = nil
            Log.debug("toolbar dismissed", tag: "app")
        }

        if !SettingsWindow.isConfigured {
            Log.info("no API keys configured — opening Settings", tag: "app")
            SettingsWindow.show()
        }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        SettingsWindow.show()
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

    /// Builds the Preset submenu freshly each call so it reflects the current preset
    /// list and active selection — Settings can add, edit or delete presets, and the
    /// menu must catch up. Called from applicationDidFinishLaunching and after each
    /// preset change.
    private func buildPresetMenu() -> NSMenu {
        let m = NSMenu()
        for p in Prefs.presets {
            let mi = NSMenuItem(title: p.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.id
            mi.state = (Prefs.activePresetID == p.id) ? .on : .off
            m.addItem(mi)
        }
        m.addItem(.separator())
        let editItem = NSMenuItem(title: "Modifica preset…", action: #selector(openSettings(_:)), keyEquivalent: "")
        editItem.target = self
        m.addItem(editItem)
        return m
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.activePresetID = id
        Log.info("preset switched -> \(id)", tag: "app")
        if let parent = sender.menu {
            for item in parent.items {
                item.state = (item.representedObject as? String == id) ? .on : .off
            }
        }
    }

    /// Public hook for SettingsView: after the user edits the preset list it calls
    /// this so the menu bar picks up the changes without a relaunch.
    @MainActor
    func rebuildPresetMenu() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            if item.title == "Preset" {
                item.submenu = buildPresetMenu()
                return
            }
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Provider(rawValue: raw) else { return }
        Prefs.provider = p
        Log.info("provider switched -> \(p.rawValue)", tag: "app")
        // Update check marks on sibling items.
        if let parent = sender.menu {
            for item in parent.items {
                item.state = (item.representedObject as? String == raw) ? .on : .off
            }
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

    private func runEdit(action: Action, tone: Tone?, target promptTarget: PromptTarget?) {
        guard let t = target, !t.selection.isEmpty else {
            Log.warn("runEdit ignored — no target or empty selection", tag: "app")
            return
        }
        Log.info("runEdit action=\(action.rawValue) tone=\(tone?.rawValue ?? "-") target=\(promptTarget?.rawValue ?? "-") selLen=\(t.selection.count) ctxLen=\(context?.count ?? 0) editable=\(t.isEditable)", tag: "app")
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
            // Explain always yields copy-only — replacing the selection with an explanation
            // of itself would be nonsense. Everything else respects editable-vs-readonly.
            let mode: ApplyMode
            if action == .explain {
                mode = .copy
            } else {
                mode = t.isEditable ? .replace : .copy
            }
            self.complete(Prompt.edit(action: action, tone: tone, target: promptTarget, selection: t.selection, context: self.context), mode: mode)
        }
    }

    private func runGenerate(prompt: String) {
        guard let t = target else {
            Log.warn("runGenerate ignored — no target", tag: "app")
            return
        }
        // The free-mode TextField doubles as a "describe this image" entry point: any
        // absolute path to an image file inside the prompt is loaded from disk and shipped
        // to the vision model. If the prompt is *only* paths, we substitute a default
        // "describe" instruction so the model knows what to do.
        let extracted = Clipboard.extractImagePaths(from: prompt)
        let userText = extracted.cleaned.isEmpty && !extracted.images.isEmpty
            ? "Descrivi questa immagine in dettaglio, in italiano."
            : extracted.cleaned.isEmpty ? prompt : extracted.cleaned
        Log.info("runGenerate promptLen=\(prompt.count) cleanedLen=\(userText.count) images=\(extracted.images.count)", tag: "app")
        toolbar.setLoading()
        let mode: ApplyMode = t.isEditable ? .insert : .copy
        var req = Prompt.generate(prompt: userText)
        if !extracted.images.isEmpty {
            req = AIRequest(system: req.system, user: req.user, images: extracted.images)
        }
        complete(req, mode: mode)
    }

    private func runPromptifyCompose(text: String, target promptTarget: PromptTarget) {
        guard let t = target else {
            Log.warn("runPromptifyCompose ignored — no target", tag: "app")
            return
        }
        Log.info("runPromptifyCompose textLen=\(text.count) target=\(promptTarget.rawValue)", tag: "app")
        toolbar.setLoading()
        let mode: ApplyMode = t.isEditable ? .insert : .copy
        complete(Prompt.promptify(target: promptTarget, text: text), mode: mode)
    }

    private func runPromptFromImage() {
        guard let t = target else {
            Log.warn("runPromptFromImage ignored — no target", tag: "app")
            return
        }
        guard let image = Clipboard.image() else {
            Log.error("runPromptFromImage: no image in clipboard", tag: "app")
            toolbar.setError("Nessuna immagine nella clipboard.")
            return
        }
        Log.info("runPromptFromImage imageBytes=\(image.data.count) mediaType=\(image.mediaType)", tag: "app")
        toolbar.setLoading()
        let mode: ApplyMode = t.isEditable ? .insert : .copy
        var req = Prompt.promptifyFromImage()
        req = AIRequest(system: req.system, user: req.user, images: [image])
        complete(req, mode: mode)
    }

    private func complete(_ req: AIRequest, mode: ApplyMode) {
        if inFlight {
            Log.warn("complete ignored — another request already in flight", tag: "app")
            return
        }
        inFlight = true
        let provider = Prefs.provider
        let augmented = Self.augmentWithPreset(req)
        Log.info("complete via provider=\(provider.rawValue) preset=\(Prefs.activePreset?.name ?? "-")", tag: "app")
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let result: String
                switch provider {
                case .anthropic: result = try await Anthropic.complete(augmented)
                case .openai:    result = try await OpenAI.complete(augmented)
                }
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
        // Capture target before hide(): toolbar.hide() triggers onDismiss which clears
        // self.target, so any read after hide() would see nil.
        let captured = target
        toolbar.hide()
        switch mode {
        case .replace, .insert:
            guard let captured else {
                Log.error("apply ignored — no target", tag: "app")
                return
            }
            AX.write(text, to: captured)
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
    /// Splice the active preset's contextual addendum and glossary into the system
    /// prompt. Called once per request so every action (Edit, Generate, Promptify,
    /// PromptFromImage, …) inherits the same domain context. The original `system`
    /// stays at the top of the prompt — preset content is appended in clearly labelled
    /// sections so the model knows what's task instruction vs. user-supplied context.
    static func augmentWithPreset(_ req: AIRequest) -> AIRequest {
        guard let preset = Prefs.activePreset,
              !preset.systemAddendum.isEmpty || !preset.glossary.isEmpty else {
            return req
        }
        var addendum = ""
        let trimmedAddendum = preset.systemAddendum.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGlossary = preset.glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAddendum.isEmpty {
            addendum += "\n\n## Contesto utente (preset: \(preset.name))\n\(trimmedAddendum)"
        }
        if !trimmedGlossary.isEmpty {
            addendum += "\n\n## Glossario / preferenze stilistiche\n\(trimmedGlossary)"
        }
        return AIRequest(system: req.system + addendum, user: req.user, images: req.images)
    }

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

enum Provider: String {
    case anthropic
    case openai

    var label: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI GPT-4o"
        }
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

    static var provider: Provider {
        get {
            let raw = UserDefaults.standard.string(forKey: "provider") ?? Provider.anthropic.rawValue
            return Provider(rawValue: raw) ?? .anthropic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
    }

    /// Alpha applied to the toolbar panel when it loses key status (idle). 1.0 = fully
    /// opaque, 0.1 = barely visible. Default 0.35 keeps the bottom-center "free" panel
    /// readable but not invasive while the user works in the source app. Clamped on read
    /// to stay inside [0.1, 1.0] so a corrupted UserDefaults can't make the panel
    /// invisible.
    static var idleOpacity: Double {
        get {
            if UserDefaults.standard.object(forKey: "idleOpacity") == nil { return 0.35 }
            return min(max(UserDefaults.standard.double(forKey: "idleOpacity"), 0.1), 1.0)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0.1), 1.0), forKey: "idleOpacity") }
    }

    /// User's preset library. Persisted as JSON in UserDefaults. Falls back to the
    /// factory list on first run or if the stored data fails to decode (forward
    /// compatibility: older builds or hand-edited defaults shouldn't crash the app).
    static var presets: [Preset] {
        get {
            if let data = UserDefaults.standard.data(forKey: "presets"),
               let decoded = try? JSONDecoder().decode([Preset].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            return Preset.factory
        }
        set {
            // Empty list is meaningless — keep at least the factory list available so
            // the menu bar / settings UI never ends up with no rows to select.
            let toStore = newValue.isEmpty ? Preset.factory : newValue
            if let data = try? JSONEncoder().encode(toStore) {
                UserDefaults.standard.set(data, forKey: "presets")
            }
        }
    }

    /// Identifier of the currently active preset. Default = "generale" (the empty,
    /// no-op preset). If the stored ID points at a deleted preset we fall back to the
    /// first available one, never to nil — the menu/settings always show a checkmark.
    static var activePresetID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "activePresetID") ?? "generale"
            return presets.contains(where: { $0.id == stored }) ? stored : (presets.first?.id ?? "generale")
        }
        set { UserDefaults.standard.set(newValue, forKey: "activePresetID") }
    }

    static var activePreset: Preset? {
        let id = activePresetID
        return presets.first { $0.id == id }
    }
}
