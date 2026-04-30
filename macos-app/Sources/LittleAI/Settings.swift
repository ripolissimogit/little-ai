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
    @State private var idleOpacity: Double = Prefs.idleOpacity
    @State private var saved = false

    var body: some View {
        VStack(spacing: 16) {
            TabView {
                providerTab
                    .tabItem { Label("Provider AI", systemImage: "brain") }
                PresetTab()
                    .tabItem { Label("Preset", systemImage: "person.crop.rectangle.stack") }
                appearanceTab
                    .tabItem { Label("Aspetto", systemImage: "paintbrush") }
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

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trasparenza quando inattiva")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(idleOpacity * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $idleOpacity, in: 0.1...1.0, step: 0.05) {
                    Text("Trasparenza")
                } minimumValueLabel: {
                    Text("10%").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("100%").font(.caption2).foregroundStyle(.secondary)
                }
                .onChange(of: idleOpacity) { _, newValue in
                    Prefs.idleOpacity = newValue
                }
                Text("Quando la barra non è la finestra attiva (es. mentre lavori nell'app sottostante) viene attenuata a questa opacità. La modifica si applica al prossimo cambio di focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

/// Settings tab for managing the user's preset library. Lists all stored presets,
/// lets the user select the active one, edit name / addendum / glossary, add new
/// presets, and delete custom ones. Each change writes back to Prefs immediately and
/// asks the AppDelegate to rebuild the menu bar submenu so the change is visible
/// everywhere without a relaunch.
private struct PresetTab: View {
    @State private var presets: [Preset] = Prefs.presets
    @State private var selectedID: String = Prefs.activePresetID
    @State private var editID: String = Prefs.activePresetID

    private var editIndex: Int? {
        presets.firstIndex(where: { $0.id == editID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preset")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                List(selection: $editID) {
                    ForEach(presets) { p in
                        HStack {
                            if p.id == selectedID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .frame(width: 14)
                            } else {
                                Spacer().frame(width: 14)
                            }
                            Text(p.name)
                        }
                        .tag(p.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(width: 180)

                HStack(spacing: 6) {
                    Button { addPreset() } label: { Image(systemName: "plus") }
                    Button { deletePreset() } label: { Image(systemName: "minus") }
                        .disabled(presets.count <= 1)
                    Spacer()
                    Button("Imposta attivo") { activate() }
                        .disabled(editIndex == nil || presets[editIndex!].id == selectedID)
                }
                .controlSize(.small)
            }

            Divider()

            if let idx = editIndex {
                editor(for: idx)
            } else {
                Spacer()
                Text("Seleziona un preset dalla lista").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func editor(for idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nome")
                    .font(.system(size: 12, weight: .medium))
                TextField("Nome preset", text: Binding(
                    get: { presets[idx].name },
                    set: { presets[idx].name = $0; persist() }
                ))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Contesto / istruzioni di sistema")
                    .font(.system(size: 12, weight: .medium))
                Text("Appeso al system prompt di ogni azione (Edit, Generate, Promptify…) sotto la sezione \"Contesto utente\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { presets[idx].systemAddendum },
                    set: { presets[idx].systemAddendum = $0; persist() }
                ))
                .font(.system(size: 12))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.25))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Glossario / preferenze stilistiche")
                    .font(.system(size: 12, weight: .medium))
                Text("Termini canonici, abbreviazioni preferite, regole di stile. Una riga per voce.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { presets[idx].glossary },
                    set: { presets[idx].glossary = $0; persist() }
                ))
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100)
                .border(Color.secondary.opacity(0.25))
            }
            Spacer(minLength: 0)
        }
    }

    private func persist() {
        Prefs.presets = presets
        notifyMenuRebuild()
    }

    private func activate() {
        guard let idx = editIndex else { return }
        let id = presets[idx].id
        Prefs.activePresetID = id
        selectedID = id
        notifyMenuRebuild()
    }

    private func addPreset() {
        let new = Preset(
            id: UUID().uuidString,
            name: "Nuovo preset",
            systemAddendum: "",
            glossary: ""
        )
        presets.append(new)
        editID = new.id
        persist()
    }

    private func deletePreset() {
        guard let idx = editIndex, presets.count > 1 else { return }
        let removedID = presets[idx].id
        presets.remove(at: idx)
        // If we deleted the active one, fall back to the first preset.
        if selectedID == removedID {
            selectedID = presets.first?.id ?? ""
            Prefs.activePresetID = selectedID
        }
        editID = presets.first?.id ?? ""
        persist()
    }

    private func notifyMenuRebuild() {
        // The AppDelegate is the NSApplication delegate; cast back to App and ask it
        // to refresh the menu bar submenu. Avoids a global notification roundtrip.
        if let app = NSApp.delegate as? App {
            app.rebuildPresetMenu()
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
