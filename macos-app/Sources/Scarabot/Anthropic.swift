import Foundation

struct AIRequest {
    let system: String
    let user: String

    init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

enum Prompt {
    private static let editSystem = """
    Sei un editor di testo integrato in un'app macOS. Ricevi un'istruzione e una porzione di \
    testo selezionata dall'utente: modifica SOLO quella selezione, senza ricordare o usare testi \
    di turni precedenti. Restituisci soltanto il testo finale da inserire nell'app sorgente: \
    niente preamboli, niente oggetti strutturati, niente markdown, niente virgolette esterne, \
    niente commenti.

    Mantieni la lingua originale del testo salvo esplicita richiesta di traduzione. Conserva \
    formattazione, a capo, elenchi e indentazione salvo richiesta esplicita di modificarli. \
    Non migliorare lo stile oltre l'istruzione ricevuta: se l'utente chiede correzione, correggi; \
    se chiede sintesi, sintetizza; se chiede traduzione, traduci.
    """

    private static let generateIT = """
    Sei un assistente di scrittura integrato in un'app desktop. L'utente ti scrive in italiano \
    cosa vuole comunicare e tu produci il testo finale IN ITALIANO da inserire al punto del \
    cursore. Restituisci SOLO il testo, senza preamboli, senza commenti, senza markdown di \
    blocco, senza virgolette di apertura/chiusura.
    """

    /// ISO 639-1 codes → English language name. The user prefixes their prompt with one of
    /// these codes (e.g. "fr Puoi scrivere...") and the system prompt instructs Claude to
    /// produce the final text in that language.
    private static let languageNames: [String: String] = [
        "en": "English", "fr": "French", "es": "Spanish", "de": "German",
        "pt": "Portuguese", "it": "Italian", "nl": "Dutch", "sv": "Swedish",
        "no": "Norwegian", "da": "Danish", "fi": "Finnish", "pl": "Polish",
        "cs": "Czech", "ro": "Romanian", "hu": "Hungarian", "el": "Greek",
        "tr": "Turkish", "ru": "Russian", "uk": "Ukrainian", "ar": "Arabic",
        "he": "Hebrew", "hi": "Hindi", "ja": "Japanese", "ko": "Korean",
        "zh": "Chinese", "th": "Thai", "vi": "Vietnamese", "id": "Indonesian",
    ]

    private static func generateSystemFor(language: String) -> String {
        """
        You are a writing assistant embedded in a desktop app. The user describes (typically \
        in Italian) what they want to communicate; you produce the final text IN \(language.uppercased()) \
        to be inserted at the cursor. Return ONLY the text in \(language), with no preamble, \
        no commentary, no code fences, and no surrounding quotes.
        """
    }

    /// Free-form edit: the user typed an arbitrary instruction (e.g. "rendi più
    /// formale", "traduci in inglese", "riassumi in 2 righe") and selected text in
    /// the source app. The model returns only the rewritten text. This is what
    /// gets applied / copied; diagnostics are deliberately omitted because this is
    /// an inline editor, not a chat transcript.
    static func editFreeform(instruction: String, selection: String) -> AIRequest {
        let user = """
        Istruzione dell'utente: \(instruction)

        Testo selezionato da modificare:
        \"\"\"
        \(selection)
        \"\"\"

        Regole rigide:
        - Rispondi con PURO testo finale, mai con preambolo, mai con oggetti strutturati, \
        mai con virgolette esterne, mai con marker tipo '---'.
        - Usa esclusivamente il testo dentro "Testo selezionato da modificare"; ignora \
        qualsiasi contenuto non presente in quella sezione.
        - Se non hai dovuto cambiare nulla (testo già perfetto secondo l'istruzione), \
        restituisci il testo originale senza spiegazioni.
        - Mantieni la formattazione originale (a capo, elenchi, indentazione) salvo \
        richiesta esplicita di modifica.
        """
        return AIRequest(system: editSystem, user: user)
    }

    /// If the prompt starts with a 2-letter ISO 639-1 language code followed by a space
    /// (e.g. "fr ...", "ja ...", "es ..."), the output is produced in that language and
    /// the code is stripped from the user text. Otherwise the default is Italian.
    static func generate(prompt: String) -> AIRequest {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            let head = trimmed[..<spaceIdx].lowercased()
            if let language = languageNames[head] {
                let rest = String(trimmed[trimmed.index(after: spaceIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return AIRequest(system: generateSystemFor(language: language), user: rest)
                }
            }
        }
        return AIRequest(system: generateIT, user: trimmed)
    }
}

enum Anthropic {
    static let model = "claude-sonnet-4-20250514"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "HTTP \(status): \(message)" }
    }

    static func complete(_ request: AIRequest) async throws -> String {
        guard let apiKey = Secrets.anthropicAPIKey else {
            throw APIError(status: 0, message: "API key Anthropic mancante. Apri Impostazioni (⌘,) dal menu bar.")
        }
        let keyPreview = maskKey(apiKey)
        Log.info("request model=\(model) systemLen=\(request.system.count) userLen=\(request.user.count) key=\(keyPreview)", tag: "ai")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]]
        ]
        // Server-side web search tool (Anthropic native, not client-executed). When the
        // user has opted into fact-checking we attach the tool: Claude decides whether
        // to invoke it based on the prompt content. `max_uses` caps the per-request
        // search budget so a runaway prompt can't spend dozens of dollars by accident.
        // Allega il tool server-side solo quando l'utente ha esplicitamente scelto
        // Anthropic come motore di ricerca. Se ha scelto Tavily la search avviene
        // upstream in App.complete() e i risultati arrivano nel system prompt.
        if Prefs.useWebSearch && Prefs.webSearchProvider == .anthropic {
            bodyDict["tools"] = [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 5,
            ] as [String: Any]]
            Log.info("request includes web_search tool (max_uses=5)", tag: "ai")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        Log.debug("request bodyBytes=\(req.httpBody?.count ?? 0)", tag: "ai")

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.error("URLSession failed: \(error)", tag: "ai")
            throw error
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            Log.error("response not HTTPURLResponse: \(type(of: response))", tag: "ai")
            throw APIError(status: 0, message: "Risposta non valida")
        }
        Log.info("response status=\(http.statusCode) bytes=\(data.count) elapsed=\(String(format: "%.2f", elapsed))s", tag: "ai")

        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? raw
            Log.error("HTTP \(http.statusCode) body=\(raw.prefix(500))", tag: "ai")
            throw APIError(status: http.statusCode, message: message)
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Log.error("decode failed: \(error) body=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "")", tag: "ai")
            throw error
        }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("parsed resultLen=\(result.count) blocks=\(decoded.content.count)", tag: "ai")
        return result
    }

    private static func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return "***" }
        return "\(key.prefix(10))…\(key.suffix(4))"
    }

    private struct Response: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let content: [Content]
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
