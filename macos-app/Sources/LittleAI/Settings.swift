import AppKit
import SwiftUI

enum Settings {
    static let model = "claude-sonnet-4-6"
    static var apiKey: String? { Secrets.anthropicAPIKey }

    static var skipPreview: Bool {
        get { UserDefaults.standard.bool(forKey: "skipPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "skipPreview") }
    }

    @MainActor
    static func show() { SettingsWindow.shared.show() }
}

@MainActor
private final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: host)
        win.title = "Little AI — Impostazioni"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 380, height: 160))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @State private var skipPreview: Bool = Settings.skipPreview

    var body: some View {
        Form {
            Section("Comportamento") {
                Toggle("Inserisci senza anteprima", isOn: Binding(
                    get: { skipPreview },
                    set: { newValue in
                        skipPreview = newValue
                        Settings.skipPreview = newValue
                    }
                ))
            }
            Section("Scorciatoia") {
                Text("Doppio Shift — apri la barra sul testo selezionato")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
