import AppKit
import Combine
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
        return panel.isKeyWindow
    }

    func show(target: Target) {
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

        if panel == nil {
            preparePanel()
        }

        relayout()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(nil)
        vm.focusRequest.send()
        Log.info("toolbar shown isKey=\(panel?.isKeyWindow ?? false) isVisible=\(panel?.isVisible ?? false)", tag: "ui")
        installDismissMonitors()
    }

    private func preparePanel() {
        let hc = NSHostingController(rootView: RootView(vm: vm))
        hosting = hc
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
        p.delegate = panelDelegate
        panel = p

        panelDelegate.onBecomeKey = { [weak self] in
            self?.panel?.alphaValue = 1.0
            Log.debug("panel interactive", tag: "ui")
        }
        panelDelegate.onResignKey = { [weak self] in
            self?.panel?.alphaValue = CGFloat(Prefs.idleOpacity)
            Log.debug("panel idle transparent", tag: "ui")
        }
    }

    func activateExisting() {
        guard let panel else { return }
        panel.alphaValue = 1.0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        vm.focusRequest.send()
        installDismissMonitors()
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

    func setSearchWarning(_ message: String?) {
        if let message {
            Log.warn("setSearchWarning: \(message)", tag: "ui")
        }
        vm.searchWarning = message
        relayout()
    }

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
        vm.focusRequest.send()
    }

    private func refocus() {
        guard let panel else { return }
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
    /// Signal to ReadyView that it should grab focus. Fired after every state
    /// transition back to .ready, after activateExisting, and after show.
    let focusRequest = PassthroughSubject<Void, Never>()

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
        }
        .onAppear {
            DispatchQueue.main.async { composeFocused = true }
        }
        .onReceive(vm.focusRequest) { _ in
            composeFocused = true
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
            if let warning = vm.searchWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                    Text(warning)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
            }
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
    @State private var showSources = false

    private var acceptLabel: String {
        switch mode {
        case .replace: return "Sostituisci"
        case .insert: return "Inserisci"
        case .copy: return "Copia"
        }
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
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                    Text(warning)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
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
                    Image(systemName: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .help("Scarta e modifica il prompt")
                Spacer()
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
