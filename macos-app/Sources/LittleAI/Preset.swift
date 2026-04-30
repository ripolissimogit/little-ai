import Foundation

/// User-selectable workflow profile. The active preset's `systemAddendum` and
/// `glossary` are appended to every action's system prompt before the request is sent
/// to the AI provider, so the model can adapt voice, vocabulary and stylistic choices
/// to the user's current domain (editorial writing, coding, email, etc.) without the
/// user having to retype the context every time.
///
/// Presets persist in `UserDefaults` as JSON. Three defaults ship preinstalled
/// (`Generale` empty, `Editoriale`, `Coding` with a tech glossary) and the user can
/// edit, add or remove any of them from the Settings tab.
struct Preset: Codable, Identifiable, Equatable {
    var id: String                // stable UUID/string used by activePresetID
    var name: String              // shown in menu bar and Settings list
    var systemAddendum: String    // appended to system prompt under "## Contesto utente"
    var glossary: String          // appended under "## Glossario / preferenze stilistiche"
}

extension Preset {
    /// First-run defaults. The user can edit or delete these from Settings; the only
    /// invariant is that at least one preset always remains (Settings enforces this).
    static let factory: [Preset] = [
        Preset(
            id: "generale",
            name: "Generale",
            systemAddendum: "",
            glossary: ""
        ),
        Preset(
            id: "editoriale",
            name: "Editoriale",
            systemAddendum: """
            L'utente lavora in ambito editoriale (giornalismo, content writing, copy). \
            Privilegia uno stile chiaro, scorrevole, italiano corretto e idiomatico. \
            Evita anglicismi non necessari e gergo tecnico salvo richiesta esplicita. \
            Cura il ritmo della frase e la varietà lessicale; preferisci forme attive \
            alle passive quando suona più naturale.
            """,
            glossary: ""
        ),
        Preset(
            id: "coding",
            name: "Coding",
            systemAddendum: """
            L'utente è uno sviluppatore software. Le richieste possono riguardare codice, \
            commit message, descrizioni di pull request, documentazione tecnica, log di \
            errore, query SQL, configurazioni. Preserva sempre identifier, path, comandi \
            shell e blocchi di codice esattamente come scritti. Preferisci precisione \
            tecnica all'eleganza retorica. Se traduci documentazione tecnica, lascia in \
            inglese i termini consolidati (callback, pull request, container, runtime, …).
            """,
            glossary: """
            JavaScript (non "Javascript")
            TypeScript (non "Typescript")
            GitHub (non "Github")
            npm (sempre minuscolo)
            macOS, iOS, watchOS (minuscola iniziale)
            API (sempre maiuscolo)
            URL (sempre maiuscolo)
            HTTP/HTTPS (maiuscolo)
            JSON (maiuscolo)
            React, Next.js, Vue.js, Node.js (con punto)
            open source (due parole, non "opensource")
            front-end / back-end (con trattino)
            tech stack, code review, pull request, merge conflict (in inglese)
            """
        ),
    ]
}
