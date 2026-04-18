import AppKit

@MainActor
final class MenuBarController {
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Little AI")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Impostazioni…", action: #selector(settingsClicked), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Esci", action: #selector(quitClicked), keyEquivalent: "q").target = self
        item.menu = menu

        statusItem = item
    }

    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}
