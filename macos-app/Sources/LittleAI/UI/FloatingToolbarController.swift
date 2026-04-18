import AppKit
import SwiftUI

@MainActor
final class FloatingToolbarController {
    var onAction: ((ActionType, Tone?, Bool) -> Void)?
    var onAccept: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private let viewModel = ToolbarViewModel()

    func show(near point: CGPoint, selectedText: String) {
        viewModel.reset(selection: selectedText)
        viewModel.onAction = { [weak self] action, tone, includeContext in
            self?.onAction?(action, tone, includeContext)
        }
        viewModel.onAccept = { [weak self] text in self?.onAccept?(text) }
        viewModel.onCancel = { [weak self] in self?.hide() }

        let view = ToolbarRootView(viewModel: viewModel)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 56)

        let panel = NSPanel(
            contentRect: host.frame,
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
        panel.contentView = host
        panel.becomesKeyOnlyIfNeeded = true

        // Position above selection with 8pt gap; clamp to screen.
        var origin = NSPoint(x: point.x, y: point.y + 8)
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            origin.x = max(f.minX + 8, min(origin.x, f.maxX - host.frame.width - 8))
            origin.y = max(f.minY + 8, min(origin.y, f.maxY - host.frame.height - 8))
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        onDismiss?()
    }

    func showLoading() { viewModel.state = .loading }
    func showError(_ message: String) { viewModel.state = .error(message) }
    func showPreview(original: String, result: String) {
        viewModel.state = .preview(original: original, result: result)
        // Grow panel to fit preview.
        panel?.setContentSize(NSSize(width: 480, height: 280))
    }
}
