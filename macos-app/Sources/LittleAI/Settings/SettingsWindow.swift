import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Little AI — Impostazioni"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 280))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiKeyDraft: String = SettingsStore.shared.apiKey ?? ""
    @State private var savedFlash = false

    private let models = [
        "claude-sonnet-4-6",
        "claude-opus-4-7",
        "claude-haiku-4-5-20251001"
    ]

    var body: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API Key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Picker("Modello", selection: $settings.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Scorciatoia") {
                Text("⌥ Spazio — apri la barra sul testo selezionato")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if savedFlash {
                    Label("Salvato", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button("Salva") {
                    settings.apiKey = apiKeyDraft
                    withAnimation { savedFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { savedFlash = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
