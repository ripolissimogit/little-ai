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
        win.setContentSize(NSSize(width: 520, height: 460))
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
        VStack(spacing: 16) {
            TabView {
                providerTab
                    .tabItem { Label("Provider AI", systemImage: "brain") }
                axiomTab
                    .tabItem { Label("Logging", systemImage: "list.bullet.rectangle") }
            }

            HStack {
                if saved {
                    Label("Salvato", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button("Salva") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    private var providerTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            FieldRow(label: "Anthropic API key", placeholder: "sk-ant-…", text: $anthropic, secure: true)
            FieldRow(label: "OpenAI API key", placeholder: "sk-proj-…", text: $openai, secure: true)
            Text("Serve almeno una delle due. Il provider attivo si sceglie dal menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var axiomTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            FieldRow(label: "Axiom API token", placeholder: "xaat-…", text: $axiomToken, secure: true)
            FieldRow(label: "Axiom dataset", placeholder: "littleai", text: $axiomDataset, secure: false)
            Text("Lascia vuoto per disabilitare Axiom. I log restano comunque su file locale.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
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

private struct FieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let secure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, design: .monospaced))
        }
    }
}
