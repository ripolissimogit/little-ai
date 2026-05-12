import Foundation

/// Tavily Search — provider esterno di ricerca web orientato ad agenti AI.
/// Endpoint: POST https://api.tavily.com/search.
/// Restituisce snippet già ripuliti + un campo `answer` riassuntivo. Lo usiamo come
/// alternativa al server-side `web_search_20250305` di Anthropic, che si è rivelato
/// poco affidabile per query non banali. Il flusso è:
///   1. App.complete() chiama Tavily.search(query)
///   2. La risposta viene formattata come blocco di contesto e iniettata nel system
///      prompt
///   3. Il provider AI (Anthropic / OpenAI) genera la risposta con i fatti già a portata
enum Tavily {
    struct Result: Decodable {
        let title: String
        let url: String
        let content: String
        let score: Double?
    }

    private struct Response: Decodable {
        let answer: String?
        let results: [Result]
    }

    struct SearchOutcome {
        let answer: String?
        let results: [Result]

        var isEmpty: Bool { (answer?.isEmpty ?? true) && results.isEmpty }
    }

    enum SearchError: LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return "Tavily API key non configurata."
            case .http(let s, let b): return "Tavily HTTP \(s): \(b)"
            case .decoding(let m): return "Tavily decoding: \(m)"
            }
        }
    }

    /// Esegue una ricerca. La query viene troncata a 400 caratteri per restare nei
    /// limiti dell'endpoint e per evitare di mandare paragrafi interi (Tavily lavora
    /// meglio con query short). Timeout 12 s: `advanced` è più lento di `basic` ma
    /// va dietro al testo della pagina, non solo al meta — necessario per query
    /// fattuali (numeri specifici, date, incassi) che gli snippet di `basic` non
    /// catturano.
    /// Tavily fattura per ricerca, non per risultato — `max_results` non incide sul
    /// costo. 20 è il massimo accettato dall'endpoint e il setting più utile per
    /// query fattuali: garantisce che fonti specifiche (testate locali, blog di
    /// nicchia, pagine di distributori cinematografici come Cinetel/Lucky Red)
    /// abbiano spazio anche quando i primi risultati sono Wikipedia o aggregatori
    /// generici.
    static func search(_ rawQuery: String, maxResults: Int = 20) async throws -> SearchOutcome {
        guard let key = Secrets.tavilyAPIKey, !key.isEmpty else {
            throw SearchError.missingKey
        }
        let query = String(rawQuery.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return SearchOutcome(answer: nil, results: [])
        }

        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Tavily auth is via api_key in the body, not Bearer header
        req.timeoutInterval = 12

        let topic = Prefs.tavilyTopic
        var body: [String: Any] = [
            "api_key": key,
            "query": query,
            // `general` indexes Wikipedia, blog posts, official docs, news outlets
            // and forums — basically the open web. `news` filters to press articles
            // only (narrower, better for breaking-news queries). Toggled by the
            // user in the toolbar info row.
            "topic": topic.rawValue,
            // Advanced fetches the full text of each result instead of just the meta
            // description. Costs ~2 credits per call (vs 1 for basic) but is the
            // difference between "the film grossed €X million" appearing in the
            // snippet vs being scraped from inside the article.
            "search_depth": "advanced",
            "max_results": maxResults,
            "include_answer": true,
            "include_raw_content": false,
            "include_images": false,
        ]
        // Tavily `news` defaults to the last 7 days. Most "verify a recent claim"
        // cases in Scarabot — film releases, product launches, sports results —
        // need a longer window; we set 365 so a story from any time in the past
        // year is reachable without making it a UI knob.
        if topic == .news {
            body["days"] = 365
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.info("tavily search query=\"\(query.prefix(120))\" len=\(query.count) maxResults=\(maxResults) depth=advanced topic=\(topic.rawValue)", tag: "search")
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw SearchError.http(status: 0, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.error("tavily HTTP \(http.statusCode) body=\(body.prefix(200))", tag: "search")
            throw SearchError.http(status: http.statusCode, body: String(body.prefix(300)))
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // Log the synthesised answer (truncated) so we can tell, after the fact,
            // whether Tavily found the relevant fact or just generic context. When
            // the AI replies "I don't have this data", checking this line tells us
            // immediately whether to blame Tavily or the model.
            let answerPreview = decoded.answer.map {
                $0.replacingOccurrences(of: "\n", with: " ").prefix(200)
            } ?? "<nil>"
            Log.info("tavily ok results=\(decoded.results.count) hasAnswer=\(decoded.answer != nil) elapsed=\(String(format: "%.2f", elapsed))s answer=\"\(answerPreview)\"", tag: "search")
            return SearchOutcome(answer: decoded.answer, results: decoded.results)
        } catch {
            throw SearchError.decoding(String(describing: error))
        }
    }

    /// Formatta i risultati come blocco di contesto da appendere al system prompt.
    /// Numerato per facilitare riferimenti incrociati nel ragionamento del modello.
    static func formatAsContext(_ outcome: SearchOutcome) -> String {
        var parts: [String] = ["## Risultati di ricerca (Tavily) per verifica fattuale"]
        if let answer = outcome.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            parts.append("**Riassunto**: \(answer)")
        }
        for (i, r) in outcome.results.enumerated() {
            let snippet = r.content.replacingOccurrences(of: "\n", with: " ")
            let trimmed = snippet.count > 600 ? String(snippet.prefix(600)) + "…" : snippet
            parts.append("\(i + 1). \(r.title) — \(r.url)\n\(trimmed)")
        }
        parts.append("Usa queste informazioni per correggere eventuali inesattezze nel testo dell'utente. Non aggiungere link o citazioni nel testo restituito a meno che l'utente non li chieda esplicitamente.")
        return parts.joined(separator: "\n\n")
    }
}

