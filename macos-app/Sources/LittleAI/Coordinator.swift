import AppKit

@MainActor
final class Coordinator {
    private let menuBar = MenuBarController()
    private let hotkey = HotkeyManager()
    private let toolbar = FloatingToolbarController()
    private let settings = SettingsStore.shared

    private var currentTarget: AXTextTarget?

    func start() {
        menuBar.onSettings = { [weak self] in self?.openSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()

        hotkey.onTrigger = { [weak self] in
            Task { @MainActor in self?.handleTrigger() }
        }
        hotkey.register()

        toolbar.onAction = { [weak self] action, tone, includeContext in
            self?.runAction(action, tone: tone, includeContext: includeContext)
        }
        toolbar.onAccept = { [weak self] text in self?.applyResult(text) }
        toolbar.onDismiss = { [weak self] in self?.currentTarget = nil }
    }

    private func handleTrigger() {
        guard let target = AXService.captureFocusedSelection() else {
            NSSound.beep()
            return
        }
        currentTarget = target
        toolbar.show(near: target.anchorPoint, selectedText: target.selectedText)
    }

    private func runAction(_ action: ActionType, tone: Tone?, includeContext: Bool) {
        guard let target = currentTarget else { return }
        guard let apiKey = settings.apiKey, !apiKey.isEmpty else {
            toolbar.showError("API key mancante. Apri Impostazioni.")
            return
        }
        toolbar.showLoading()
        let provider = AnthropicProvider(apiKey: apiKey, model: settings.model)
        let request = PromptBuilder.build(
            action: action,
            tone: tone,
            selection: target.selectedText,
            broaderContext: includeContext ? target.broaderContext : nil
        )
        Task { @MainActor in
            do {
                let result = try await provider.complete(request)
                toolbar.showPreview(original: target.selectedText, result: result)
            } catch {
                toolbar.showError("Errore: \(error.localizedDescription)")
            }
        }
    }

    private func applyResult(_ text: String) {
        guard let target = currentTarget else { return }
        AXService.replaceSelection(in: target.element, with: text)
        toolbar.hide()
        currentTarget = nil
    }

    private func openSettings() {
        SettingsWindow.shared.show()
    }
}
