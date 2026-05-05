import AppKit

@main
@MainActor
final class App: NSObject, NSApplicationDelegate {
    static let version = "0.9"

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
            img.size = NSSize(width: 22, height: 22)
            // Templated rendering: macOS reads only the alpha channel and paints it
            // white (dark menu bar) or black (light menu bar). Without this the PNG
            // is drawn verbatim and a dark glyph vanishes against a dark menu bar.
            // MenuIcon.png is rendered from menu-icon.svg as a black glyph on a
            // transparent background — exactly what isTemplate expects.
            img.isTemplate = true
            item.button?.image = img
        } else {
            let img = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: "Scarabot")
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
        let webSearchToggle = NSMenuItem(title: "Verifica fattuale (ricerca online)", action: #selector(toggleWebSearch(_:)), keyEquivalent: "")
        webSearchToggle.target = self
        webSearchToggle.state = Prefs.useWebSearch ? .on : .off
        menu.addItem(webSearchToggle)

        let searchProviderItem = NSMenuItem(title: "Motore di ricerca", action: nil, keyEquivalent: "")
        let searchProviderMenu = NSMenu()
        for p in WebSearchProvider.allCases {
            let mi = NSMenuItem(title: p.label, action: #selector(selectWebSearchProvider(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = p.rawValue
            mi.state = (Prefs.webSearchProvider == p) ? .on : .off
            searchProviderMenu.addItem(mi)
        }
        searchProviderItem.submenu = searchProviderMenu
        menu.addItem(searchProviderItem)
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

        toolbar.onSubmit = { [weak self] prompt in self?.runSubmit(prompt: prompt) }
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

    @objc private func toggleWebSearch(_ sender: NSMenuItem) {
        Prefs.useWebSearch.toggle()
        sender.state = Prefs.useWebSearch ? .on : .off
        Log.info("useWebSearch toggled -> \(Prefs.useWebSearch)", tag: "app")
    }

    @objc private func selectWebSearchProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = WebSearchProvider(rawValue: raw) else { return }
        Prefs.webSearchProvider = p
        Log.info("webSearchProvider switched -> \(p.rawValue)", tag: "app")
        if let owner = sender.menu {
            for item in owner.items {
                item.state = (item == sender) ? .on : .off
            }
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Provider(rawValue: raw) else { return }
        Prefs.provider = p
        Log.info("provider switched -> \(p.rawValue)", tag: "app")
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
        toolbar.show(target: t)
        Log.debug("trigger: toolbar shown selLen=\(t.selection.count)", tag: "app")
    }

    /// Single submit handler. The user typed a prompt in the toolbar and pressed ⏎ /
    /// the send button. Two routes:
    ///   - Selection captured → treat the prompt as an *instruction* to apply to the
    ///     selected text. Anteprima offre Sostituisci (editable) o Copia (readonly).
    ///   - No selection → free generation. Anteprima offre Inserisci (al cursor,
    ///     editable) o Copia (readonly).
    private func runSubmit(prompt: String) {
        guard let t = target else {
            Log.warn("runSubmit ignored — no target", tag: "app")
            return
        }
        toolbar.setLoading()
        if !t.selection.isEmpty {
            Log.info("runSubmit edit promptLen=\(prompt.count) selLen=\(t.selection.count) editable=\(t.isEditable)", tag: "app")
            let mode: ApplyMode = t.isEditable ? .replace : .copy
            // Tavily query is the user's instruction + selection joined as plain
            // text — keeps factual context (the actual subject) without dragging
            // along the prompt template ("Istruzione dell'utente:", quoting fences,
            // output rules) which would dilute the search.
            let searchQuery = "\(prompt)\n\(t.selection)"
            complete(Prompt.editFreeform(instruction: prompt, selection: t.selection),
                     mode: mode, searchQuery: searchQuery, structured: true)
        } else {
            Log.info("runSubmit generate promptLen=\(prompt.count) editable=\(t.isEditable)", tag: "app")
            let mode: ApplyMode = t.isEditable ? .insert : .copy
            complete(Prompt.generate(prompt: prompt), mode: mode, searchQuery: prompt, structured: false)
        }
    }

    /// Output of a single AI call: the text to apply (always present) and an optional
    /// human-facing diagnostic block (only present when the prompt asked for it
    /// and the response could be parsed). Parsing is best-effort: if the model
    /// drifts off JSON we keep the whole reply as `result` and lose diagnostics
    /// for that turn rather than failing the request.
    struct EditOutput {
        let result: String
        let diagnostics: String?
    }

    private func complete(_ req: AIRequest, mode: ApplyMode, searchQuery: String, structured: Bool) {
        if inFlight {
            Log.warn("complete ignored — another request already in flight", tag: "app")
            return
        }
        inFlight = true
        let provider = Prefs.provider
        var augmented = Self.augmentForWebSearch(req)
        Log.info("complete via provider=\(provider.rawValue) structured=\(structured)", tag: "app")
        Task { @MainActor in
            defer { inFlight = false }
            do {
                // Pre-fetch Tavily search results (when fact-checking is on and Tavily is
                // the chosen engine) and append them to the system prompt as context. We
                // do this *before* the AI call so any provider — Anthropic or OpenAI —
                // benefits, and so we can fall back gracefully if the search fails.
                if Prefs.useWebSearch && Prefs.webSearchProvider == .tavily {
                    let outcome = await Self.augmentWithTavily(augmented, query: searchQuery)
                    augmented = outcome.request
                    self.toolbar.setSearchWarning(outcome.warning)
                } else {
                    self.toolbar.setSearchWarning(nil)
                }
                let raw: String
                switch provider {
                case .anthropic: raw = try await Anthropic.complete(augmented)
                case .openai:    raw = try await OpenAI.complete(augmented)
                }
                let parsed: EditOutput = structured ? Self.parseEditOutput(raw) : EditOutput(result: raw, diagnostics: nil)
                Log.info("complete ok resultLen=\(parsed.result.count) diagLen=\(parsed.diagnostics?.count ?? 0)", tag: "app")
                if Prefs.skipPreview {
                    Log.info("apply directly (skipPreview) mode=\(mode)", tag: "app")
                    apply(parsed.result, mode: mode)
                } else {
                    toolbar.setPreview(result: parsed.result, diagnostics: parsed.diagnostics, mode: mode)
                }
            } catch {
                Log.error("complete failed: \(error.localizedDescription)", tag: "app")
                toolbar.setError(error.localizedDescription)
            }
        }
    }

    /// Best-effort JSON parsing for edit responses. The model is instructed to
    /// return `{"result": "...", "diagnostics": "..."}` but real-world output
    /// drifts: occasional markdown fences, leading prose, the diagnostics field
    /// missing entirely. Heuristic order:
    ///   1. Try parsing the whole reply as a JSON object → ideal path.
    ///   2. Try extracting the substring between the first `{` and the last `}`
    ///      and parsing that → handles "Here's the JSON: { … }" prefixes.
    ///   3. Give up: treat the whole reply as `result` and drop diagnostics.
    /// The user always sees something usable in `result`; diagnostics is a
    /// best-effort enrichment.
    static func parseEditOutput(_ raw: String) -> EditOutput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading/trailing code fence markers some models add despite
        // being told not to.
        let stripped = trimmed
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = decode(stripped) { return parsed }

        // Fallback: substring between first `{` and last `}`.
        if let lo = stripped.firstIndex(of: "{"),
           let hi = stripped.lastIndex(of: "}"),
           lo < hi {
            let candidate = String(stripped[lo...hi])
            if let parsed = decode(candidate) { return parsed }
        }

        Log.warn("parseEditOutput: model didn't return parseable JSON, using raw text as result", tag: "app")
        return EditOutput(result: trimmed, diagnostics: nil)
    }

    /// Strict JSON decode used by parseEditOutput. Keeps a separate function so
    /// the fallback path can call it on a substring without duplicating the
    /// `data(using:)` + `JSONSerialization` boilerplate.
    private static func decode(_ s: String) -> EditOutput? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String,
              !result.isEmpty
        else { return nil }
        let diag = (obj["diagnostics"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return EditOutput(result: result, diagnostics: (diag?.isEmpty == false) ? diag : nil)
    }

    /// Result of a Tavily augmentation pass.
    /// `request` is the prompt to actually send (augmented on success, untouched on
    /// failure). `warning` is set when the user asked for fact-checking but it
    /// couldn't run — surfaced in the UI so the user knows their result came back
    /// without the verification they enabled.
    struct TavilyOutcome {
        let request: AIRequest
        let warning: String?
    }

    /// Esegue una ricerca Tavily usando `query` (NON il `req.user` raw, che contiene
    /// il template editFreeform inquinato di "Istruzione dell'utente:" eccetera) e
    /// appende i risultati al system prompt. Mai bloccante: in caso di errore
    /// (chiave mancante, rete, HTTP non-2xx) ritorna la richiesta originale + un
    /// warning testuale che l'UI mostra inline. Il modello procede senza contesto
    /// extra: meglio una risposta senza fatti freschi che nessuna risposta.
    static func augmentWithTavily(_ req: AIRequest, query: String) async -> TavilyOutcome {
        if Secrets.tavilyAPIKey == nil {
            return TavilyOutcome(
                request: req,
                warning: "Ricerca web non disponibile: chiave Tavily mancante. Impostazioni → Provider AI."
            )
        }
        do {
            let outcome = try await Tavily.search(query)
            guard !outcome.isEmpty else {
                Log.info("tavily returned no usable context", tag: "app")
                return TavilyOutcome(request: req, warning: nil)
            }
            let block = Tavily.formatAsContext(outcome)
            return TavilyOutcome(
                request: AIRequest(
                    system: req.system + "\n\n" + block,
                    user: req.user
                ),
                warning: nil
            )
        } catch {
            Log.warn("tavily search failed, proceeding without web context: \(error.localizedDescription)", tag: "app")
            // 401 is the most common failure mode (wrong/expired key, hidden non-ASCII
            // characters from autofill). Detect it specifically so the user knows what
            // to fix; everything else gets the generic message.
            let warning: String
            let lower = error.localizedDescription.lowercased()
            if lower.contains("401") || lower.contains("unauthorized") {
                warning = "Ricerca web fallita: chiave Tavily non valida (HTTP 401). Apri Impostazioni → Provider AI e reincollala (deve iniziare con tvly-)."
            } else {
                warning = "Ricerca web fallita: \(error.localizedDescription)"
            }
            return TavilyOutcome(request: req, warning: warning)
        }
    }

    /// When the Anthropic-native web_search tool is enabled we instruct the model to use
    /// it conservatively. The Tavily branch doesn't need this — Tavily results land in
    /// the system prompt directly (see `augmentWithTavily`).
    static func augmentForWebSearch(_ req: AIRequest) -> AIRequest {
        guard Prefs.useWebSearch && Prefs.provider == .anthropic && Prefs.webSearchProvider == .anthropic else {
            return req
        }
        let addendum = """


        ## Verifica fattuale
        Hai accesso a uno strumento web_search per verificare informazioni online. \
        Quando incontri affermazioni fattuali (date, nomi propri, prezzi, eventi, \
        statistiche, citazioni, riferimenti normativi, dettagli di prodotto) sulla \
        cui correttezza non sei sicuro, fai una ricerca prima di confermare o \
        modificare il testo. Se trovi un'inesattezza, correggila basandoti sulla \
        fonte più autorevole reperita. Se la ricerca non chiarisce, mantieni il \
        testo originale invece di rischiare un'allucinazione. Non aggiungere \
        citazioni o link nel testo restituito a meno che l'utente non li chieda.
        """
        return AIRequest(system: req.system + addendum, user: req.user)
    }

    private func apply(_ text: String, mode: ApplyMode) {
        let locked = Prefs.toolbarLocked
        Log.info("apply mode=\(mode) textLen=\(text.count) locked=\(locked)", tag: "app")
        let captured = target
        // Lock: keep the panel up so the user can fire another prompt without
        // ⇧⇧'ing again. We still drop the cached selection because it no longer
        // matches the source app's state after a replace, and operating on a
        // stale string would silently corrupt the user's text.
        if locked {
            toolbar.resetToReady(keepSelection: false)
        } else {
            toolbar.hide()
        }
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
    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Nascondi Scarabot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
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

enum WebSearchProvider: String, CaseIterable {
    case anthropic
    case tavily

    var label: String {
        switch self {
        case .anthropic: return "Anthropic web_search"
        case .tavily: return "Tavily"
        }
    }
}

/// Tavily search topic. `general` indexes the open web (Wikipedia, blog, docs,
/// news, forums) and is the right default for fact-checking arbitrary text.
/// `news` filters to press articles only — narrower but better for queries
/// about recent events / breaking news.
enum TavilyTopic: String, CaseIterable {
    case general
    case news

    var label: String {
        switch self {
        case .general: return "Web (tutto)"
        case .news: return "Solo news"
        }
    }
}

enum Prefs {
    static var skipPreview: Bool {
        get { UserDefaults.standard.bool(forKey: "skipPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "skipPreview") }
    }

    static var provider: Provider {
        get {
            let raw = UserDefaults.standard.string(forKey: "provider") ?? Provider.anthropic.rawValue
            return Provider(rawValue: raw) ?? .anthropic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "provider") }
    }

    /// Alpha applied to the toolbar panel when it loses key status (idle). 1.0 = fully
    /// opaque, 0.1 = barely visible. Default 0.35 keeps the panel readable but not
    /// invasive while the user works in the source app. Clamped on read to stay inside
    /// [0.1, 1.0] so a corrupted UserDefaults can't make the panel invisible.
    static var idleOpacity: Double {
        get {
            if UserDefaults.standard.object(forKey: "idleOpacity") == nil { return 0.35 }
            return min(max(UserDefaults.standard.double(forKey: "idleOpacity"), 0.1), 1.0)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0.1), 1.0), forKey: "idleOpacity") }
    }

    /// When true, requests to Anthropic include the server-side `web_search_20250305`
    /// tool so Claude can verify factual claims (dates, names, prices, events,
    /// statistics) against the live web before returning. Default OFF.
    static var useWebSearch: Bool {
        get { UserDefaults.standard.bool(forKey: "useWebSearch") }
        set { UserDefaults.standard.set(newValue, forKey: "useWebSearch") }
    }

    /// When true, applying an AI result (replace / insert / copy) does NOT close the
    /// toolbar — the panel resets to .ready so the user can fire another prompt.
    /// Useful for "burst" workflows like translate → tone → reduce in sequence on
    /// related text. Esc, the Annulla button and double-⇧ still close it
    /// explicitly. Default OFF.
    static var toolbarLocked: Bool {
        get { UserDefaults.standard.bool(forKey: "toolbarLocked") }
        set { UserDefaults.standard.set(newValue, forKey: "toolbarLocked") }
    }

    /// Quale motore di ricerca alimenta la verifica fattuale quando `useWebSearch` è ON.
    static var webSearchProvider: WebSearchProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: "webSearchProvider"),
               let p = WebSearchProvider(rawValue: raw) {
                return p
            }
            return Secrets.tavilyAPIKey != nil ? .tavily : .anthropic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "webSearchProvider") }
    }

    /// Topic Tavily quando `webSearchProvider == .tavily`. Default `general`.
    static var tavilyTopic: TavilyTopic {
        get {
            let raw = UserDefaults.standard.string(forKey: "tavilyTopic") ?? "general"
            return TavilyTopic(rawValue: raw) ?? .general
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tavilyTopic") }
    }
}
