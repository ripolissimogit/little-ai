import AppKit

@MainActor
final class Coordinator {
    private let menuBar = MenuBarController()
    private let hotkey = DoubleShiftDetector()
    private let toolbar = FloatingToolbarController()

    private var currentTarget: AXTextTarget?

    func start() {
        menuBar.onSettings = { Settings.show() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()

        hotkey.onTrigger = { [weak self] in
            Task { @MainActor in self?.handleTrigger() }
        }
        hotkey.start()

        toolbar.onAction = { [weak self] action, tone in
            self?.runEdit(action: action, tone: tone)
        }
        toolbar.onGenerate = { [weak self] prompt in
            self?.runGenerate(prompt: prompt)
        }
        toolbar.onAccept = { [weak self] text, isInsertion in
            self?.applyResult(text, isInsertion: isInsertion)
        }
        toolbar.onDismiss = { [weak self] in self?.currentTarget = nil }
    }

    private func handleTrigger() {
        guard let target = AXService.captureFocusedTarget() else {
            NSSound.beep()
            return
        }
        currentTarget = target
        toolbar.show(target: target)
    }

    private func runEdit(action: ActionType, tone: Tone?) {
        guard let target = currentTarget, !target.selectedText.isEmpty else { return }
        guard let apiKey = ensureAPIKey() else { return }
        toolbar.showLoading()
        let request = PromptBuilder.buildEdit(action: action, tone: tone, selection: target.selectedText)
        runRequest(request, apiKey: apiKey, isInsertion: false)
    }

    private func runGenerate(prompt: String) {
        guard currentTarget != nil else { return }
        guard let apiKey = ensureAPIKey() else { return }
        toolbar.showLoading()
        let request = PromptBuilder.buildGenerate(prompt: prompt)
        runRequest(request, apiKey: apiKey, isInsertion: true)
    }

    private func runRequest(_ request: AIRequest, apiKey: String, isInsertion: Bool) {
        let provider = AnthropicProvider(apiKey: apiKey)
        Task { @MainActor in
            do {
                let result = try await provider.complete(request)
                if Settings.skipPreview {
                    applyResult(result, isInsertion: isInsertion)
                } else {
                    toolbar.showPreview(result: result, isInsertion: isInsertion)
                }
            } catch {
                toolbar.showError("Errore: \(error.localizedDescription)")
            }
        }
    }

    private func ensureAPIKey() -> String? {
        guard let apiKey = Settings.apiKey, !apiKey.isEmpty else {
            toolbar.showError("API key mancante. Apri Impostazioni.")
            return nil
        }
        return apiKey
    }

    private func applyResult(_ text: String, isInsertion: Bool) {
        guard let target = currentTarget else { return }
        // Hide first so the focus/activation dance can land on the original app cleanly.
        toolbar.hide()
        AXService.writeText(text, to: target)
        currentTarget = nil
    }
}
