import AppKit
import SwiftUI

/// Floating NSPanel with a SwiftUI toolbar. Shown over the caret of the focused text field,
/// dismissed on Escape or any click outside.
@MainActor
final class Toolbar {
    var onEdit: ((Action, Tone?, PromptTarget?) -> Void)?
    var onGenerate: ((String) -> Void)?
    var onPromptifyCompose: ((String, PromptTarget) -> Void)?
    var onPromptFromImage: (() -> Void)?
    var onAccept: ((String, ApplyMode) -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<RootView>?
    private var target: Target?
    private let vm = ViewModel()
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private let panelDelegate = PanelDelegate()

    private let minWidth: CGFloat = 360
    private let maxWidth: CGFloat = 560
    private let gap: CGFloat = 8            // margin from screen edges
    private let cursorOffset: CGFloat = 24  // distance from the mouse cursor

    var isVisible: Bool { panel != nil }

    func show(target: Target) {
        // Defensive: if a panel is already up (e.g. the hotkey fired twice and a stale
        // panel survived), tear it down before creating a fresh one so we never stack.
        if panel != nil {
            Log.warn("show() called while a panel is already visible — dismissing the old one", tag: "ui")
            hide()
        }
        self.target = target
        vm.reset(selection: target.selection, isEditable: target.isEditable)
        Log.info("toolbar show selLen=\(target.selection.count) rect=\(target.selectionRect.map { "\($0)" } ?? "nil")", tag: "ui")
        vm.onAction = { [weak self] a, t, pt in
            Log.info("vm.onAction action=\(a.rawValue) tone=\(t?.rawValue ?? "-") target=\(pt?.rawValue ?? "-")", tag: "ui")
            self?.onEdit?(a, t, pt)
        }
        vm.onGenerate = { [weak self] p in
            Log.info("vm.onGenerate promptLen=\(p.count)", tag: "ui")
            self?.onGenerate?(p)
        }
        vm.onPromptifyCompose = { [weak self] p, t in
            Log.info("vm.onPromptifyCompose promptLen=\(p.count) target=\(t.rawValue)", tag: "ui")
            self?.onPromptifyCompose?(p, t)
        }
        vm.onPromptFromImage = { [weak self] in
            Log.info("vm.onPromptFromImage", tag: "ui")
            self?.onPromptFromImage?()
        }
        vm.onAccept = { [weak self] text, mode in
            Log.info("vm.onAccept mode=\(mode) len=\(text.count)", tag: "ui")
            self?.onAccept?(text, mode)
        }
        vm.onCancel = { [weak self] in
            Log.info("vm.onCancel (Annulla button)", tag: "ui")
            self?.hide()
        }
        vm.onContentSizeChange = { [weak self] in
            // Defer to the next runloop tick so SwiftUI has finished re-rendering the
            // new text before we measure with sizeThatFits.
            DispatchQueue.main.async { self?.relayout() }
        }

        let hc = NSHostingController(rootView: RootView(vm: vm))
        hosting = hc
        // NSVisualEffectView is the panel's root contentView: it's an opaque hit target
        // across its entire frame, provides the HUD blur, and carries the rounded corners
        // via CALayer. The SwiftUI hosting view rides on top as a transparent overlay.
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
            contentRect: NSRect(x: 0, y: 0, width: minWidth, height: 56),
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

        // Idle transparency: when the panel loses key status (user clicks back into the
        // source app, or the panel was just placed bottom-center in free mode and isn't
        // the focus), fade it down to the user-configured opacity. Restore full opacity
        // when the panel regains focus. The closures read Prefs each time so changes in
        // Settings take effect on the next focus transition without restarting.
        panelDelegate.onBecomeKey = { [weak self] in
            self?.panel?.alphaValue = 1.0
        }
        panelDelegate.onResignKey = { [weak self] in
            self?.panel?.alphaValue = CGFloat(Prefs.idleOpacity)
        }

        relayout()
        // Accessory apps can't receive key status for their panels — switch to .regular for
        // the duration the panel is visible, restore .accessory on hide(). Without this the
        // panel stays isKey=false and SwiftUI buttons miss clicks.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        // Clear first responder so the first button doesn't get a focus ring. The
        // compose TextField sets its own focus via @FocusState when it appears.
        p.makeFirstResponder(nil)
        Log.info("toolbar shown isKey=\(p.isKeyWindow) isVisible=\(p.isVisible)", tag: "ui")
        installDismissMonitors()
    }

    func hide() {
        guard panel != nil else { return }
        Log.debug("toolbar hide", tag: "ui")
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        target = nil
        onDismiss?()
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

    func setPreview(result: String, mode: ApplyMode) {
        Log.info("setPreview resultLen=\(result.count) mode=\(mode)", tag: "ui")
        vm.state = .preview(result, mode)
        relayout()
        refocus()
    }

    /// After a state change the NSHostingController may lose key status (especially while
    /// the user was in another app during a long network call). Re-assert key so SwiftUI
    /// buttons receive clicks and `.keyboardShortcut(.defaultAction)` fires on Enter.
    private func refocus() {
        guard let panel else { return }
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
        // No global click-dismiss: the panel is a persistent workspace, not a popover.
        // The user closes it explicitly via Esc, the Annulla button, or by completing an
        // action. This lets them click away to fix the focused field without losing work.
    }

    private func removeDismissMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }

    /// Resize the panel to hug SwiftUI content and reposition near the selection.
    /// NSHostingController.sizeThatFits honours a width proposal — NSHostingView.fittingSize
    /// ignores it. We ask twice: unconstrained for a width hint, then with the clamped width
    /// for height-for-width.
    private func relayout() {
        guard let panel, let hc = hosting, let t = target else { return }
        // Flush pending SwiftUI view-update before measuring.
        hc.view.needsLayout = true
        hc.view.layoutSubtreeIfNeeded()

        let big: CGFloat = 10_000
        let unconstrained = hc.sizeThatFits(in: NSSize(width: big, height: big))
        let width = min(max(unconstrained.width, minWidth), maxWidth)
        let fitted = hc.sizeThatFits(in: NSSize(width: width, height: big))

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxHeight = screen.visibleFrame.height - (gap * 2)
        let height = min(max(fitted.height, 44), maxHeight)
        let size = NSSize(width: width, height: height)
        let finalFrame = NSRect(origin: origin(for: t, panelSize: size), size: size)
        panel.setFrame(finalFrame, display: true, animate: false)
        Log.debug("relayout size=\(size) origin=\(finalFrame.origin) isKey=\(panel.isKeyWindow)", tag: "ui")
    }

    /// Positions the panel. Two regimes:
    ///   - "Free" mode (no selection captured → Generate / Promptify / image prompt): pin
    ///     to the bottom-center of the screen the cursor is on. The panel has no anchor
    ///     to follow, and floating it next to the cursor is invasive — it appears wherever
    ///     the mouse happens to be when the user double-shifts.
    ///   - "Anchored" mode (selection present → Edit / Explain): keep the historical
    ///     behaviour and place it next to the cursor, since the panel is conceptually
    ///     attached to the highlighted text. AX selection bounds aren't reliable on
    ///     Electron/WebArea apps, so we use the mouse position as the anchor.
    private func origin(for target: Target, panelSize: NSSize) -> NSPoint {
        let cursor = target.fallbackCursor
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        if target.selection.isEmpty {
            let x = visible.midX - panelSize.width / 2
            let y = visible.minY + gap
            return NSPoint(
                x: max(visible.minX + gap, min(x, visible.maxX - panelSize.width - gap)),
                y: y
            )
        }

        var o = NSPoint(x: cursor.x + cursorOffset, y: cursor.y - panelSize.height / 2)
        // If the panel would run off the right edge, put it to the left of the cursor.
        if o.x + panelSize.width > visible.maxX - gap {
            o.x = cursor.x - panelSize.width - cursorOffset
        }
        o.x = max(visible.minX + gap, min(o.x, visible.maxX - panelSize.width - gap))
        o.y = max(visible.minY + gap, min(o.y, visible.maxY - panelSize.height - gap))
        return o
    }
}

/// NSPanel that can become key even when borderless/nonactivating — required so SwiftUI
/// TextField receives keystrokes.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Window delegate on the panel — logs every key/main/close transition so we can see
/// exactly why/when the panel loses focus or goes away unexpectedly.
@MainActor
final class PanelDelegate: NSObject, NSWindowDelegate {
    var onWillClose: (() -> Void)?
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
            self.onWillClose?()
        }
    }
}

/// How the generated result is delivered to the user.
enum ApplyMode {
    case replace  // selection → ⌘V in source app (overwrites selection)
    case insert   // compose → ⌘V at cursor
    case copy     // readonly source → pasteboard only, no paste
}

@MainActor
final class ViewModel: ObservableObject {
    enum State {
        case idle
        case compose
        case loading
        case preview(String, ApplyMode)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var selection: String = ""
    @Published var composeText: String = ""
    @Published var isEditable: Bool = true

    var onAction: ((Action, Tone?, PromptTarget?) -> Void)?
    var onGenerate: ((String) -> Void)?
    var onPromptifyCompose: ((String, PromptTarget) -> Void)?
    var onPromptFromImage: (() -> Void)?
    var onAccept: ((String, ApplyMode) -> Void)?
    var onCancel: (() -> Void)?
    var onContentSizeChange: (() -> Void)?

    func reset(selection: String, isEditable: Bool) {
        self.selection = selection
        self.composeText = ""
        self.isEditable = isEditable
        state = selection.isEmpty ? .compose : .idle
    }
}

struct RootView: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        // Background/blur/corners/border are all provided by the NSVisualEffectView
        // panel root — no SwiftUI border overlay here, otherwise the stroke ends up
        // inset by the padding and produces a visible double edge.
        VStack(alignment: .leading, spacing: 10) {
            content
            if showsLegend {
                ShortcutLegend(state: vm.state)
            }
        }
        .padding(16)
    }

    private var showsLegend: Bool {
        switch vm.state {
        case .idle, .compose, .preview: return true
        case .loading, .error: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            if vm.isEditable {
                ActionBar(vm: vm)
            } else {
                ReadonlyActionBar(vm: vm)
            }
        case .compose: Compose(vm: vm)
        case .loading: Loading()
        case let .preview(result, mode): Preview(result: result, mode: mode, vm: vm)
        case let .error(message): ErrorRow(message: message, vm: vm)
        }
    }
}

private struct ShortcutLegend: View {
    let state: ViewModel.State

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { keys, label in
                HStack(spacing: 4) {
                    Text(keys)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.secondary.opacity(0.15))
                        )
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var items: [(String, String)] {
        switch state {
        case .compose:
            return [("⇧⇧", "apri/chiudi"), ("↩", "invia"), ("esc", "chiudi")]
        case .preview:
            return [("↩", "conferma"), ("esc", "annulla")]
        default:
            return [("⇧⇧", "apri/chiudi"), ("esc", "chiudi")]
        }
    }
}

private struct ActionBar: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        HStack(spacing: 4) {
            Item(symbol: "checkmark.seal", label: "Correggi") { vm.onAction?(.correct, nil, nil) }
            Item(symbol: "arrow.up.left.and.arrow.down.right", label: "Estendi") { vm.onAction?(.extend, nil, nil) }
            Item(symbol: "arrow.down.right.and.arrow.up.left", label: "Riduci") { vm.onAction?(.reduce, nil, nil) }
            Item(symbol: "globe", label: "Traduci") { vm.onAction?(.translate, nil, nil) }
            Item(symbol: "lightbulb", label: "Spiega") { vm.onAction?(.explain, nil, nil) }
            Menu {
                ForEach(Tone.allCases) { t in
                    Button(t.label) { vm.onAction?(.tone, t, nil) }
                }
            } label: {
                Label("Tono", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu {
                ForEach(PromptTarget.allCases) { target in
                    Button {
                        vm.onAction?(.promptify, nil, target)
                    } label: {
                        Label(target.label, systemImage: target.symbol)
                    }
                }
                if Clipboard.hasImage {
                    Divider()
                    Button {
                        vm.onPromptFromImage?()
                    } label: {
                        Label("Da immagine (clipboard)", systemImage: "photo.on.rectangle.angled")
                    }
                }
            } label: {
                Label("Prompt", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

private struct ReadonlyActionBar: View {
    @ObservedObject var vm: ViewModel

    var body: some View {
        HStack(spacing: 4) {
            ActionBar.Item(symbol: "lightbulb", label: "Spiega") { vm.onAction?(.explain, nil, nil) }
            ActionBar.Item(symbol: "globe", label: "Traduci") { vm.onAction?(.translate, nil, nil) }
            Menu {
                ForEach(PromptTarget.allCases) { target in
                    Button {
                        vm.onAction?(.promptify, nil, target)
                    } label: {
                        Label(target.label, systemImage: target.symbol)
                    }
                }
                if Clipboard.hasImage {
                    Divider()
                    Button {
                        vm.onPromptFromImage?()
                    } label: {
                        Label("Da immagine (clipboard)", systemImage: "photo.on.rectangle.angled")
                    }
                }
            } label: {
                Label("Prompt", systemImage: "wand.and.stars")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            Text("sola lettura")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

extension ActionBar {
    struct Item: View {
        let symbol: String
        let label: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(label, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

private struct Compose: View {
    @ObservedObject var vm: ViewModel
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        vm.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            TextField("Cosa vuoi scrivere?", text: $vm.composeText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onChange(of: vm.composeText) { _, newValue in
                    Log.debug("compose onChange len=\(newValue.count)", tag: "ui")
                    vm.onContentSizeChange?()
                }
            // Promptify dropdown: same menu surfaced in the selection-mode ActionBar,
            // applied to the text currently typed in the compose field. The "Da immagine"
            // entry appears only when the clipboard holds an image — and it's the only
            // entry usable when the compose text is empty, so we keep the menu enabled
            // in that case.
            Menu {
                ForEach(PromptTarget.allCases) { target in
                    Button {
                        promptify(target: target)
                    } label: {
                        Label(target.label, systemImage: target.symbol)
                    }
                    .disabled(isEmpty)
                }
                if Clipboard.hasImage {
                    Divider()
                    Button {
                        vm.onPromptFromImage?()
                    } label: {
                        Label("Da immagine (clipboard)", systemImage: "photo.on.rectangle.angled")
                    }
                }
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16))
                    .foregroundStyle((isEmpty && !Clipboard.hasImage) ? .tertiary : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isEmpty && !Clipboard.hasImage)
            .help("Trasforma in prompt ottimizzato")
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }

    private func submit() {
        let text = vm.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { vm.onGenerate?(text) }
    }

    private func promptify(target: PromptTarget) {
        let text = vm.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { vm.onPromptifyCompose?(text, target) }
    }
}

private struct Loading: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Generazione…").font(.system(size: 13))
            Spacer()
        }
    }
}

private struct Preview: View {
    let result: String
    let mode: ApplyMode
    @ObservedObject var vm: ViewModel

    private var acceptLabel: String {
        switch mode {
        case .replace: return "Sostituisci"
        case .insert: return "Inserisci"
        case .copy: return "Copia"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anteprima")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(result)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Annulla") {
                    Log.info("Preview: Annulla tapped", tag: "ui")
                    vm.onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(acceptLabel) {
                    Log.info("Preview: Accept tapped mode=\(mode)", tag: "ui")
                    vm.onAccept?(result, mode)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct ErrorRow: View {
    let message: String
    @ObservedObject var vm: ViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Chiudi") { vm.onCancel?() }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

