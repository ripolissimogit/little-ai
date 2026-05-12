import AppKit
import SwiftUI

/// Floating NSPanel pinned at the bottom-center of the screen, hosting the unified
/// SwiftUI toolbar. Toggled by the global hotkey, dismissed with Esc, the Annulla
/// button, or after applying a result.
@MainActor
final class Toolbar {
    var onSubmit: ((String) -> Void)?
    var onAccept: ((String, ApplyMode) -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<RootView>?
    private var target: Target?
    private let vm = ViewModel()
    private var localKeyMonitor: Any?
    private let panelDelegate = PanelDelegate()

    private let minWidth: CGFloat = 480
    private let maxWidth: CGFloat = 640
    private let gap: CGFloat = 12  // margin from screen edges

    var isVisible: Bool { panel != nil }
    var isInteractive: Bool {
        guard let panel else { return false }
        return panel.isKeyWindow && !panel.ignoresMouseEvents
    }

    func show(target: Target) {
        // Defensive: if a panel is already up (e.g. the hotkey fired twice and a stale
        // panel survived), tear it down before creating a fresh one so we never stack.
        // This is an internal replacement, not a user dismiss: do not fire `onDismiss`,
        // otherwise App clears the freshly captured target and the visible toolbar
        // becomes unable to submit.
        if panel != nil {
            Log.warn("show() called while a panel is already visible — dismissing the old one", tag: "ui")
            hide(notify: false)
        }
        self.target = target
        vm.reset(selection: target.selection, isEditable: target.isEditable)
        Log.info("toolbar show selLen=\(target.selection.count)", tag: "ui")
        vm.onSubmit = { [weak self] p in
            Log.info("vm.onSubmit promptLen=\(p.count) hasSelection=\(self?.target?.selection.isEmpty == false)", tag: "ui")
            self?.onSubmit?(p)
        }
        vm.onAccept = { [weak self] text, mode in
            Log.info("vm.onAccept mode=\(mode) len=\(text.count)", tag: "ui")
            self?.onAccept?(text, mode)
        }
        vm.onCancel = { [weak self] in
            Log.info("vm.onCancel", tag: "ui")
            self?.hide()
        }
        vm.onClean = { [weak self] in
            Log.info("vm.onClean", tag: "ui")
            self?.resetToReady(keepSelection: true)
        }
        vm.onContentSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.relayout() }
        }

        let hc = NSHostingController(rootView: RootView(vm: vm))
        hosting = hc
        // NSVisualEffectView is the panel's root contentView: opaque hit target across
        // its frame, HUD blur, rounded corners via CALayer. The SwiftUI hosting view
        // rides on top as a transparent overlay.
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = .clear
        visualEffect.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: minWidth, height: 96),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.contentView = visualEffect
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.delegate = panelDelegate
        panel = p

        // Idle transparency: when the panel loses key status (user clicks back into the
        // source app), fade to the user-configured opacity. Restore on regain. Reads
        // Prefs each time so live changes apply at the next focus transition.
        panelDelegate.onBecomeKey = { [weak self] in
            self?.panel?.alphaValue = 1.0
            self?.panel?.ignoresMouseEvents = false
            Log.debug("panel interactive", tag: "ui")
        }
        panelDelegate.onResignKey = { [weak self] in
            self?.panel?.alphaValue = CGFloat(Prefs.idleOpacity)
            self?.panel?.ignoresMouseEvents = true
            Log.debug("panel idle click-through", tag: "ui")
        }

        relayout()
        // Accessory apps can't receive key status for their panels — ActivationPolicy is
        // .regular for the lifetime of the app so this just ensures focus.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(nil)
        Log.info("toolbar shown isKey=\(p.isKeyWindow) isVisible=\(p.isVisible)", tag: "ui")
        installDismissMonitors()
    }

    func activateExisting() {
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1.0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        Log.info("toolbar reactivated isKey=\(panel.isKeyWindow) frame=\(panel.frame)", tag: "ui")
    }

    func hide() {
        hide(notify: true)
    }

    private func hide(notify: Bool) {
        guard panel != nil else { return }
        Log.debug("toolbar hide notify=\(notify)", tag: "ui")
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        target = nil
        if notify {
            onDismiss?()
        }
    }

    func setLoading() {
        Log.debug("setLoading", tag: "ui")
        vm.state = .loading
        relayout()
        refocus()
    }

    func setError(_ m: String) {
        Log.info("setError: \(m)", tag: "ui")
        vm.state = .error(m)
        relayout()
        refocus()
    }

    func setPreview(result: String, sources: [SourceLink], mode: ApplyMode) {
        Log.info("setPreview resultLen=\(result.count) sources=\(sources.count) mode=\(mode)", tag: "ui")
        vm.state = .preview(result, sources, mode)
        relayout()
        refocus()
    }

    /// Surface a transient warning about web search (Tavily 401, network down, …).
    /// Visible inline in the preview view so the user knows their last result was
    /// produced *without* the fact-checking they enabled. Pass nil to clear.
    func setSearchWarning(_ message: String?) {
        if let message {
            Log.warn("setSearchWarning: \(message)", tag: "ui")
        }
        vm.searchWarning = message
        relayout()
    }

    /// Soft reset: returns the panel to the `.ready` state without dismissing it.
    /// Two callers:
    ///   - The "Riprova" button in the preview view (`keepSelection=true`): the
    ///     user wants to discard the AI result and try a different prompt on the
    ///     same selection.
    ///   - `App.apply()` when the lock toggle is on (`keepSelection=false`): the
    ///     selection has been consumed by the apply, but the user wants the panel
    ///     to stay up for the next prompt.
    func resetToReady(keepSelection: Bool) {
        Log.debug("resetToReady keepSelection=\(keepSelection)", tag: "ui")
        if !keepSelection {
            vm.selection = ""
        }
        vm.composeText = ""
        vm.searchWarning = nil
        vm.state = .ready
        relayout()
        refocus()
    }

    /// After a state change the NSHostingController may lose key status (especially
    /// during long network calls). Re-assert key so SwiftUI buttons receive clicks
    /// and `.keyboardShortcut(.defaultAction)` fires on Enter.
    private func refocus() {
        guard let panel else { return }
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1.0
        panel.makeKey()
        panel.orderFrontRegardless()
        Log.debug("refocus: panel isKey=\(panel.isKeyWindow) isVisible=\(panel.isVisible) frame=\(panel.frame)", tag: "ui")
    }

    private func installDismissMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Log.info("dismiss: Esc pressed", tag: "ui")
                self?.hide()
                return nil
            }
            // Forward standard editing shortcuts to the first responder. Borderless
            // panels can miss main-menu routing for ⌘V/⌘C/⌘X/⌘A, so we dispatch manually.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .command, let chars = event.charactersIgnoringModifiers {
                let sel: Selector?
                switch chars.lowercased() {
                case "v": sel = #selector(NSText.paste(_:))
                case "c": sel = #selector(NSText.copy(_:))
                case "x": sel = #selector(NSText.cut(_:))
                case "a": sel = #selector(NSResponder.selectAll(_:))
                default: sel = nil
                }
                if let sel, NSApp.sendAction(sel, to: nil, from: nil) {
                    Log.debug("forwarded ⌘\(chars) to first responder", tag: "ui")
                    return nil
                }
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
    }

    /// Resize to hug SwiftUI content, then pin to the bottom-center of the screen the
    /// cursor is on. NSHostingController.sizeThatFits honours a width proposal —
    /// NSHostingView.fittingSize ignores it. We ask twice: unconstrained for a width
    /// hint, then with the clamped width for height-for-width.
    private func relayout() {
        guard let panel, let hc = hosting, let t = target else { return }
        hc.view.needsLayout = true
        hc.view.layoutSubtreeIfNeeded()

        let big: CGFloat = 10_000
        let unconstrained = hc.sizeThatFits(in: NSSize(width: big, height: big))
        let width = min(max(unconstrained.width, minWidth), maxWidth)
        let fitted = hc.sizeThatFits(in: NSSize(width: width, height: big))

        let cursor = t.fallbackCursor
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let maxHeight = visible.height - (gap * 2)
        let height = min(max(fitted.height, 60), maxHeight)
        let size = NSSize(width: width, height: height)
        let x = visible.midX - size.width / 2
        let y = visible.minY + gap
        let origin = NSPoint(
            x: max(visible.minX + gap, min(x, visible.maxX - size.width - gap)),
            y: y
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        Log.debug("relayout size=\(size) origin=\(origin) isKey=\(panel.isKeyWindow)", tag: "ui")
    }
}

/// NSPanel that can become key even when borderless — required so SwiftUI TextField
/// receives keystrokes.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Logs every key/main/close transition so we can see exactly when the panel loses
/// focus or goes away unexpectedly.
@MainActor
final class PanelDelegate: NSObject, NSWindowDelegate {
    var onBecomeKey: (() -> Void)?
    var onResignKey: (() -> Void)?

    nonisolated func windowDidBecomeKey(_ n: Notification) {
        Task { @MainActor in
            Log.debug("panel didBecomeKey", tag: "ui")
            self.onBecomeKey?()
        }
    }
    nonisolated func windowDidResignKey(_ n: Notification) {
        Task { @MainActor in
            Log.warn("panel didResignKey", tag: "ui")
            self.onResignKey?()
        }
    }
    nonisolated func windowWillClose(_ n: Notification) {
        Task { @MainActor in
            Log.warn("panel willClose", tag: "ui")
        }
    }
}

/// How the AI result is delivered to the user.
enum ApplyMode {
    case replace  // selection → ⌘V in source app (overwrites selection)
    case insert   // compose → ⌘V at cursor
    case copy     // readonly source → pasteboard only, no paste
}

/// One Tavily result surfaced to the UI: title, url, and the relevance score
/// the engine assigned. Shown in a collapsible "Fonti consultate" block so the
/// user can audit what the model was given to read.
/// Identifiable so SwiftUI's ForEach can diff a list of them.
struct SourceLink: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String
    let score: Double?
}

extension Color {
    static let scarabotAccent = Color.accentColor
}

@MainActor
final class ViewModel: ObservableObject {
    enum State {
        case ready
        case loading
        /// Preview state. (result, sources, mode).
        /// - `sources` are the Tavily URLs consulted for this turn (empty when
        ///   web search was off or returned nothing).
        case preview(String, [SourceLink], ApplyMode)
        case error(String)
    }

    @Published var state: State = .ready
    @Published var selection: String = ""
    @Published var composeText: String = ""
    @Published var isEditable: Bool = true
    /// Last web-search failure message (Tavily HTTP error, network failure, …).
    /// Set by the App layer when augmentWithTavily fails. Cleared on the next
    /// successful request or when the user toggles the web search button.
    @Published var searchWarning: String?

    /// User submitted a prompt. Boolean is `hasSelection`: when true, the prompt is
    /// the *instruction* applied to the captured selection (sostituisci); when false,
    /// the prompt is generation instruction (inserisci al cursor).
    var onSubmit: ((String) -> Void)?
    var onAccept: ((String, ApplyMode) -> Void)?
    var onCancel: (() -> Void)?
    /// Discard the current preview / error and return to the ready state without
    /// dismissing the panel. Selection is preserved.
    var onClean: (() -> Void)?
    var onContentSizeChange: (() -> Void)?

    func reset(selection: String, isEditable: Bool) {
        self.selection = selection
        self.composeText = ""
        self.isEditable = isEditable
        self.state = .ready
    }

    var hasSelection: Bool { !selection.isEmpty }
}

struct RootView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .ready:
            ReadyView(vm: vm)
        case .loading:
            LoadingView()
        case let .preview(result, sources, mode):
            PreviewView(result: result, sources: sources, mode: mode, vm: vm)
        case let .error(message):
            ErrorView(message: message, vm: vm)
        }
    }
}

/// Two rows. Compose TextField (the only input) on top, info row (selection stats +
/// web search toggle) at the bottom. The TextField placeholder shifts depending on
/// whether a selection was captured: with selection it asks for an *instruction*
/// applied to the selection; without selection it asks for generation prompt.
/// There are no action buttons — the prompt is the action.
private struct ReadyView: View {
    @ObservedObject var vm: ViewModel
    @FocusState private var composeFocused: Bool

    private var composeIsEmpty: Bool {
        vm.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        vm.hasSelection
            ? "Cosa vuoi fare con il testo selezionato? (es. \u{201C}rendi pi\u{00F9} formale\u{201D}, \u{201C}traduci in inglese\u{201D})"
            : "Cosa vuoi scrivere?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            composeRow
            Divider()
            infoRow
            if !vm.hasSelection {
                CaptureWarningBanner()
            }
            if let warning = vm.searchWarning {
                SearchWarningBanner(message: warning)
            }
        }
        .onAppear {
            // Defer the focus assignment so the panel has time to receive
            // `windowDidBecomeKey` before the TextField asks to become first
            // responder. Without this hop the field never wins focus and the
            // user can't type.
            DispatchQueue.main.async { composeFocused = true }
        }
    }

    private var composeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
            TextField(placeholder, text: $vm.composeText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($composeFocused)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .disabled(composeIsEmpty)
            .keyboardShortcut(.defaultAction)
            .help(vm.hasSelection ? "Applica al testo selezionato (\u{21A9})" : "Genera (\u{21A9})")
        }
        .padding(.vertical, 4)
    }

    private var infoRow: some View {
        HStack(spacing: 8) {
            SelectionStats(selection: vm.selection)
            Spacer(minLength: 8)
            LockToggle()
            TavilyTopicToggle()
            WebSearchToggle()
        }
    }

    private func submit() {
        let text = vm.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { vm.onSubmit?(text) }
    }
}

/// Compact stats row: word/char count of the captured selection, or a hint when no
/// selection was captured. Replaces the old captureFailed banner — same information
/// in a single tertiary-foregrounded line, no orange box that fights with the layout.
private struct SelectionStats: View {
    let selection: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .help(selection.isEmpty
                ? "Per usare le azioni qui sotto, seleziona del testo nell'app sorgente prima della doppia ⇧ (oppure copia con ⌘C)."
                : "Selezione catturata dall'app sorgente.")
    }

    private var text: String {
        if selection.isEmpty {
            return "Nessuna selezione"
        }
        let words = selection.split(whereSeparator: { $0.isWhitespace }).count
        let chars = selection.count
        let wLabel = words == 1 ? "parola" : "parole"
        let cLabel = chars == 1 ? "carattere" : "caratteri"
        return "Selezione · \(words) \(wLabel) · \(chars) \(cLabel)"
    }
}

/// Lock toggle: when on, applying a result (replace / insert / copy) doesn't close
/// the panel — the toolbar resets to .ready so the user can fire another prompt
/// without re-triggering ⇧⇧. Persistent via @AppStorage so it survives app restarts.
private struct LockToggle: View {
    @AppStorage("toolbarLocked") private var locked: Bool = false

    var body: some View {
        Button {
            locked.toggle()
            Log.info("LockToggle: locked -> \(locked)", tag: "ui")
        } label: {
            // Just the icon — the system symbol already encodes the state
            // (lock.fill = closed/locked, lock.open = open/unlocked). Adding a
            // separate "on"/"off" pill duplicated the same information twice.
            // Accent tint when locked makes the active state visible at a
            // glance against the HUD background without hard-coding a palette.
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(locked ? Color.scarabotAccent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(locked
            ? "Lucchetto attivo: la barra resta aperta dopo aver applicato un risultato. Click per disattivare."
            : "Lucchetto: click per tenere aperta la barra dopo le applicazioni e concatenare più prompt.")
    }
}

/// Tavily topic toggle: web (general) ↔ news. Visible only when web search is on
/// AND the chosen engine is Tavily — Anthropic web_search has its own topic logic.
/// Persistent via @AppStorage. Faded out when not active so the user knows the
/// setting won't take effect until they enable Tavily.
private struct TavilyTopicToggle: View {
    @AppStorage("tavilyTopic") private var topicRaw: String = "general"
    @AppStorage("useWebSearch") private var useWebSearch: Bool = false
    @AppStorage("webSearchProvider") private var searchProviderRaw: String = "tavily"

    private var isActive: Bool {
        useWebSearch && (WebSearchProvider(rawValue: searchProviderRaw) ?? .tavily) == .tavily
    }
    private var isNews: Bool { topicRaw == "news" }

    var body: some View {
        Button {
            topicRaw = isNews ? "general" : "news"
            Log.info("TavilyTopicToggle: topic -> \(topicRaw)", tag: "ui")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isNews ? "newspaper" : "globe")
                    .font(.system(size: 11, weight: .medium))
                Text(isNews ? "news" : "web")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(isActive ? 1 : 0.4)
        .disabled(!isActive)
        .help(isNews
            ? "Tavily filtra solo articoli di stampa degli ultimi 12 mesi. Click per tornare a Web (Wikipedia, blog, doc + news)."
            : "Tavily indicizza l'intero web. Click per restringere a sole news (utile per fatti recenti).")
    }
}

/// Web search toggle button. Compact and always visible. Disabled only when the user
/// picked Anthropic web_search but the AI provider is OpenAI (incompatible combo).
private struct WebSearchToggle: View {
    @AppStorage("useWebSearch") private var useWebSearch: Bool = false
    @AppStorage("provider") private var providerRaw: String = "anthropic"
    @AppStorage("webSearchProvider") private var searchProviderRaw: String = "tavily"

    private var searchProvider: WebSearchProvider {
        WebSearchProvider(rawValue: searchProviderRaw) ?? .tavily
    }
    private var isCompatible: Bool {
        searchProvider == .tavily || providerRaw == "anthropic"
    }
    private var isOn: Bool { useWebSearch && isCompatible }

    var body: some View {
        Button {
            useWebSearch.toggle()
            Log.info("WebSearchToggle: useWebSearch -> \(useWebSearch)", tag: "ui")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "globe.badge.chevron.backward" : "globe")
                    .font(.system(size: 11, weight: .medium))
                Text(searchProvider == .tavily ? "Tavily" : "Web")
                    .font(.system(size: 11, weight: .medium))
                Text(isOn ? "on" : "off")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isOn ? Color.scarabotAccent.opacity(0.20) : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(isOn ? Color.scarabotAccent : Color.secondary)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!isCompatible)
        .help(isCompatible
            ? (searchProvider == .tavily
                ? "Verifica fattuale via Tavily (snippet web iniettati nel prompt)"
                : "Verifica fattuale via Anthropic web_search (max 5 ricerche per richiesta)")
            : "Anthropic web_search disponibile solo con provider AI Anthropic")
    }
}

private struct CaptureWarningBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "selection.pin.in.out")
                .font(.system(size: 10, weight: .medium))
            Text("Nessuna selezione catturata. Il prompt genererà testo nuovo. Se avevi evidenziato testo, richiama Scarabot dopo la selezione oppure usa ⌘C come fallback.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

/// Inline orange banner shown when the last request couldn't reach the web search
/// provider (Tavily HTTP error, network down, …). The AI result still came through —
/// this just tells the user that the fact-checking they asked for didn't happen.
private struct SearchWarningBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

/// Audit panel: lists every URL Tavily returned for the last query so the user
/// can verify *what the model was given* — not just what it inferred. Collapsed
/// by default because the list can be 20 items long; click the header to expand.
/// URL clicks open in the system default browser via NSWorkspace.
private struct SourcesBlock: View {
    let sources: [SourceLink]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("Fonti consultate (\(sources.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sources) { src in
                            SourceRow(source: src)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
            }
        }
    }
}

/// One row in the sources audit. Title (clickable, opens in default browser) +
/// URL host on the same line, score badge on the right when Tavily returned it.
/// We show host instead of full URL to keep the row scannable; the link target
/// is still the full URL.
private struct SourceRow: View {
    let source: SourceLink

    private var host: String {
        URL(string: source.url)?.host ?? source.url
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let url = URL(string: source.url) {
                        NSWorkspace.shared.open(url)
                        Log.info("SourceRow: opened \(source.url)", tag: "ui")
                    }
                } label: {
                    Text(source.title.isEmpty ? source.url : source.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.scarabotAccent)
                        .underline()
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help(source.url)
                Text(host)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let score = source.score {
                Text(String(format: "%.2f", score))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }
}

private struct LoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Generazione…").font(.system(size: 13))
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct PreviewView: View {
    let result: String
    let sources: [SourceLink]
    let mode: ApplyMode
    @ObservedObject var vm: ViewModel
    @State private var copiedFlash = false
    @State private var showSources = false  // collapsed by default — list can be long

    private var acceptLabel: String {
        switch mode {
        case .replace: return "Sostituisci"
        case .insert: return "Inserisci"
        case .copy: return "Copia"
        }
    }

    /// `Copia` shows up as a secondary action only when the primary isn't already
    /// "Copia". When the source surface is readonly the primary already does the same
    /// thing so a duplicate would be confusing.
    private var showsSecondaryCopy: Bool {
        switch mode {
        case .copy: return false
        case .replace, .insert: return true
        }
    }

    private var showsInsertAction: Bool {
        mode != .insert && !vm.selection.isEmpty
    }

    private var resultBoxHeight: CGFloat {
        let explicitLines = result.split(separator: "\n", omittingEmptySubsequences: false).count
        let wrappedLines = max(1, (result.count / 76) + 1)
        let lines = max(explicitLines, wrappedLines)
        return min(max(CGFloat(lines) * 19 + 24, 70), 220)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = vm.searchWarning {
                SearchWarningBanner(message: warning)
            }
            HStack {
                Text("Anteprima")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(stats(result))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ScrollView {
                Text(result)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(height: resultBoxHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
            )
            if !sources.isEmpty {
                SourcesBlock(sources: sources, expanded: $showSources)
            }
            HStack(spacing: 8) {
                Button("Annulla") {
                    Log.info("Preview: Annulla tapped", tag: "ui")
                    vm.onCancel?()
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button {
                    Log.info("Preview: Riprova tapped", tag: "ui")
                    vm.onClean?()
                } label: {
                    Label("Riprova", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Scarta il risultato e modifica il prompt senza chiudere la barra")
                Spacer()
                if showsSecondaryCopy {
                    Button(action: copyToPasteboard) {
                        Label(copiedFlash ? "Copiato" : "Copia",
                              systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                    .help("Copia il risultato negli appunti senza sostituire la selezione (\u{2318}\u{21E7}C)")
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                if showsInsertAction {
                    Button {
                        Log.info("Preview: Inserisci tapped", tag: "ui")
                        vm.onAccept?(result, .insert)
                    } label: {
                        Label("Inserisci", systemImage: "text.insert")
                            .labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                    .help("Incolla il risultato nel punto attivo dell'app sorgente senza usare Sostituisci")
                }
                Button(acceptLabel) {
                    Log.info("Preview: Accept tapped mode=\(mode)", tag: "ui")
                    vm.onAccept?(result, mode)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
    }

    /// Copy without leaving preview. Lets the user grab the output for use elsewhere
    /// (e.g. paste into a third app) while still being able to Sostituisci / Inserisci
    /// in the source. Cheap NSPasteboard write — no need to round-trip through App.
    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(result, forType: .string)
        Log.info("Preview: secondary Copia tapped resultLen=\(result.count)", tag: "ui")
        withAnimation(.easeOut(duration: 0.15)) { copiedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { copiedFlash = false }
        }
    }

    private func stats(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        let chars = s.count
        let wLabel = words == 1 ? "parola" : "parole"
        let cLabel = chars == 1 ? "carattere" : "caratteri"
        return "\(words) \(wLabel) · \(chars) \(cLabel)"
    }
}

private struct ErrorView: View {
    let message: String
    @ObservedObject var vm: ViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 13))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Chiudi") { vm.onCancel?() }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}
