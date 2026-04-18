import AppKit
import SwiftUI

/// NSPanel subclass that can become key window even when borderless/nonactivating.
/// Without this override, SwiftUI TextField inside the panel never receives keystrokes.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingToolbarController {
    var onAction: ((ActionType, Tone?) -> Void)?
    var onGenerate: ((String) -> Void)?
    var onAccept: ((String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var hostingController: NSHostingController<ToolbarRootView>?
    private var currentTarget: AXTextTarget?
    private let viewModel = ToolbarViewModel()
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    private let minWidth: CGFloat = 360
    private let maxWidth: CGFloat = 560
    private let gap: CGFloat = 8

    func show(target: AXTextTarget) {
        currentTarget = target
        viewModel.reset(selection: target.selectedText)
        viewModel.onAction = { [weak self] action, tone in
            self?.onAction?(action, tone)
        }
        viewModel.onGenerate = { [weak self] prompt in
            self?.onGenerate?(prompt)
        }
        viewModel.onAccept = { [weak self] text, isInsertion in
            self?.onAccept?(text, isInsertion)
        }
        viewModel.onCancel = { [weak self] in self?.hide() }

        let hc = NSHostingController(rootView: ToolbarRootView(viewModel: viewModel))
        hostingController = hc

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: minWidth, height: 56),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentViewController = hc
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        self.panel = panel
        relayout()
        panel.makeKey()
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    func hide() {
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        currentTarget = nil
        onDismiss?()
    }

    private func installDismissMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.hide()
                return nil
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Any click outside the panel (global monitor only fires outside) dismisses.
            self?.hide()
        }
    }

    private func removeDismissMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }

    func showLoading() {
        viewModel.state = .loading
        relayout()
    }

    func showError(_ message: String) {
        viewModel.state = .error(message)
        relayout()
    }

    func showPreview(result: String, isInsertion: Bool) {
        viewModel.state = .preview(result: result, isInsertion: isInsertion)
        relayout()
    }

    /// Resizes the panel to hug the SwiftUI content and repositions it relative to the target.
    ///
    /// NSHostingController.sizeThatFits(in:) honours the proposed width and returns the
    /// SwiftUI-computed height-for-width — unlike NSHostingView.fittingSize, which ignores
    /// width constraints and returns the unconstrained preferred size. We:
    /// 1. Ask for the fully-unconstrained preferred width (tells us how wide the content
    ///    wants to be when nothing is wrapping).
    /// 2. Clamp that width to [minWidth, maxWidth].
    /// 3. Ask again with that width as the proposal — this returns the real height-for-width.
    private func relayout() {
        guard let panel = panel, let hc = hostingController, let target = currentTarget else { return }

        // Force SwiftUI to flush any pending view-update from the just-mutated view model
        // before we measure — otherwise sizeThatFits() can return the previous state's size.
        hc.view.needsLayout = true
        hc.view.layoutSubtreeIfNeeded()

        let big: CGFloat = 10_000
        let unconstrained = hc.sizeThatFits(in: NSSize(width: big, height: big))
        let width = min(max(unconstrained.width, minWidth), maxWidth)
        let fitted = hc.sizeThatFits(in: NSSize(width: width, height: big))

        // Cap the height to the visible screen (minus a small margin) so very long previews
        // never push the panel off-screen. Content grows naturally up to that cap.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let maxHeight = screen.visibleFrame.height - (gap * 2)
        let height = min(max(fitted.height, 44), maxHeight)

        let size = NSSize(width: width, height: height)
        let origin = preferredOrigin(for: target, panelSize: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func preferredOrigin(for target: AXTextTarget, panelSize: NSSize) -> NSPoint {
        if let rect = target.selectionRect, let screen = screenContainingAX(rect: rect) {
            let selectionFrame = convertAXRectToAppKit(rect, on: screen)
            let visible = screen.visibleFrame

            var x = selectionFrame.midX - panelSize.width / 2
            x = max(visible.minX + gap, min(x, visible.maxX - panelSize.width - gap))

            let above = selectionFrame.maxY + gap
            let below = selectionFrame.minY - panelSize.height - gap
            let y: CGFloat
            if above + panelSize.height <= visible.maxY - gap {
                y = above
            } else if below >= visible.minY + gap {
                y = below
            } else {
                y = max(visible.minY + gap, min(above, visible.maxY - panelSize.height - gap))
            }
            return NSPoint(x: x, y: y)
        }
        let p = target.fallbackCursor
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin = NSPoint(x: p.x - panelSize.width / 2, y: p.y + gap)
        origin.x = max(visible.minX + gap, min(origin.x, visible.maxX - panelSize.width - gap))
        origin.y = max(visible.minY + gap, min(origin.y, visible.maxY - panelSize.height - gap))
        return origin
    }

    private func convertAXRectToAppKit(_ rect: CGRect, on screen: NSScreen) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let flippedY = primary.frame.maxY - rect.maxY
        return NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    private func screenContainingAX(rect: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return NSScreen.main }
        let flippedY = primary.frame.maxY - rect.maxY
        let appkitRect = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let center = NSPoint(x: appkitRect.midX, y: appkitRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}
