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
        win.title = "Scarabot — Impostazioni"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 560, height: 480))
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
    @State private var tavily = Keychain.tavilyKey ?? ""
    @State private var webSearchProvider: WebSearchProvider = Prefs.webSearchProvider
    @State private var axiomToken = Keychain.axiomToken ?? ""
    @State private var axiomDataset = Keychain.axiomDataset ?? "scarabot"
    @State private var idleOpacity: Double = Prefs.idleOpacity
    @State private var saved = false

    var body: some View {
        VStack(spacing: 20) {
            TabView {
                providerTab
                    .tabItem { Label("Provider", systemImage: "brain") }
                advancedTab
                    .tabItem { Label("Avanzate", systemImage: "gearshape.2") }
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
        .frame(width: 520, height: 420)
    }

    private var providerTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Intelligenza artificiale")
                TestableFieldRow(label: "Anthropic", placeholder: "sk-ant-…", text: $anthropic, secure: true,
                                 tester: { await KeyTester.testAnthropic($0) })
                TestableFieldRow(label: "OpenAI", placeholder: "sk-proj-…", text: $openai, secure: true,
                                 tester: { await KeyTester.testOpenAI($0) })

                Divider().padding(.vertical, 2)

                sectionHeader("Ricerca web")
                TestableFieldRow(label: "Tavily", placeholder: "tvly-…", text: $tavily, secure: true,
                                 tester: { await KeyTester.testTavily($0) })
                HStack {
                    Text("Motore")
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $webSearchProvider) {
                        ForEach(WebSearchProvider.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: webSearchProvider) { _, newValue in
                        Prefs.webSearchProvider = newValue
                    }
                    Spacer()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Aspetto")
                HStack {
                    Text("Opacità inattiva")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(idleOpacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $idleOpacity, in: 0.1...1.0, step: 0.05)
                    .onChange(of: idleOpacity) { _, newValue in
                        Prefs.idleOpacity = newValue
                    }

                Divider().padding(.vertical, 2)

                sectionHeader("Logging remoto")
                FieldRow(label: "Dataset", placeholder: "scarabot", text: $axiomDataset, secure: false)
                TestableFieldRow(label: "Token", placeholder: "xaat-…", text: $axiomToken, secure: true,
                                 tester: { await KeyTester.testAxiom($0) })
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func save() {
        let trimAnthropic = anthropic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimOpenAI = openai.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimTavily = tavily.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimToken = axiomToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimDataset = axiomDataset.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimAnthropic.isEmpty { Keychain.delete(Keychain.Key.anthropic) }
        else { Keychain.set(trimAnthropic, for: Keychain.Key.anthropic) }

        if trimOpenAI.isEmpty { Keychain.delete(Keychain.Key.openai) }
        else { Keychain.set(trimOpenAI, for: Keychain.Key.openai) }

        if trimTavily.isEmpty { Keychain.delete(Keychain.Key.tavily) }
        else { Keychain.set(trimTavily, for: Keychain.Key.tavily) }

        if trimToken.isEmpty { Keychain.delete(Keychain.Key.axiomToken) }
        else { Keychain.set(trimToken, for: Keychain.Key.axiomToken) }

        if trimDataset.isEmpty { Keychain.delete(Keychain.Key.axiomDataset) }
        else { Keychain.set(trimDataset, for: Keychain.Key.axiomDataset) }

        Log.info("settings saved anthropic=\(!trimAnthropic.isEmpty) openai=\(!trimOpenAI.isEmpty) tavily=\(!trimTavily.isEmpty) axiom=\(!trimToken.isEmpty)", tag: "app")
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

/// Field row with an inline "Verifica" button that hits the provider's API to check
/// whether the entered key is valid. Result rendered as a colored line below the
/// field — green ✓ on 2xx (with elapsed seconds for sanity), red ✗ with the HTTP
/// code / message otherwise. The test runs against the *current text in the field*,
/// not against what's saved in Keychain — so the user can paste, verify, and only
/// then click Salva.
private struct TestableFieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let secure: Bool
    let tester: (String) async -> KeyTester.Outcome

    @State private var status: Status = .idle

    enum Status {
        case idle
        case testing
        case ok(TimeInterval)
        case fail(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                Group {
                    if secure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onChange(of: text) { _, _ in
                    // Stale: any edit invalidates the previous test result so the
                    // user doesn't trust a green tick that no longer reflects what
                    // they have typed.
                    if case .idle = status { return }
                    status = .idle
                }

                Button(action: runTest) {
                    if case .testing = status {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Verifica")
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                .controlSize(.small)
            }
            statusLine
        }
    }

    private var isTesting: Bool {
        if case .testing = status { return true }
        return false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Label("Verifica in corso…", systemImage: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ok(let elapsed):
            Label("Valida (\(String(format: "%.1f", elapsed))s)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .fail(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runTest() {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        status = .testing
        Task { @MainActor in
            let outcome = await tester(key)
            switch outcome {
            case .valid(let elapsed): status = .ok(elapsed)
            case .invalid(let msg):    status = .fail(msg)
            }
        }
    }
}
