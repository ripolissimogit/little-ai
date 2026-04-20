import AppKit
import SwiftUI

/// Settings window: the only place API keys live at runtime. Values are persisted to
/// the macOS Keychain — nothing ever touches disk in plaintext.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: host)
        win.title = "Little AI — Impostazioni"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 460, height: 360))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns true when the user has configured at least one provider's API key.
    static var isConfigured: Bool {
        Secrets.anthropicAPIKey != nil || Secrets.openAIAPIKey != nil
    }
}

private struct SettingsView: View {
    @State private var anthropic = Keychain.anthropicKey ?? ""
    @State private var openai = Keychain.openAIKey ?? ""
    @State private var axiomToken = Keychain.axiomToken ?? ""
    @State private var axiomDataset = Keychain.axiomDataset ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Provider AI") {
                SecureField("Anthropic API key (sk-ant-…)", text: $anthropic)
                    .textFieldStyle(.roundedBorder)
                SecureField("OpenAI API key (sk-proj-…)", text: $openai)
                    .textFieldStyle(.roundedBorder)
                Text("Serve almeno una delle due. Il provider attivo si sceglie dal menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logging remoto (opzionale)") {
                SecureField("Axiom API token (xaat-…)", text: $axiomToken)
                    .textFieldStyle(.roundedBorder)
                TextField("Axiom dataset", text: $axiomDataset, prompt: Text("littleai"))
                    .textFieldStyle(.roundedBorder)
                Text("Lascia vuoto per disabilitare Axiom. I log restano comunque su file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if saved {
                    Label("Salvato", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Salva") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let trimAnthropic = anthropic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimOpenAI = openai.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimToken = axiomToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimDataset = axiomDataset.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimAnthropic.isEmpty { Keychain.delete(Keychain.Key.anthropic) }
        else { Keychain.set(trimAnthropic, for: Keychain.Key.anthropic) }

        if trimOpenAI.isEmpty { Keychain.delete(Keychain.Key.openai) }
        else { Keychain.set(trimOpenAI, for: Keychain.Key.openai) }

        if trimToken.isEmpty { Keychain.delete(Keychain.Key.axiomToken) }
        else { Keychain.set(trimToken, for: Keychain.Key.axiomToken) }

        if trimDataset.isEmpty { Keychain.delete(Keychain.Key.axiomDataset) }
        else { Keychain.set(trimDataset, for: Keychain.Key.axiomDataset) }

        Log.info("settings saved anthropic=\(!trimAnthropic.isEmpty) openai=\(!trimOpenAI.isEmpty) axiom=\(!trimToken.isEmpty)", tag: "app")
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { saved = false }
        }
    }
}
