import Foundation

/// One-shot validation calls for each API key/token the user can configure.
/// Each test makes the smallest realistic request the provider supports so the
/// answer is unambiguous (HTTP 200 = valid, 401/403 = bad key, …) without spending
/// meaningfully on a roundtrip. Results are surfaced in the Settings UI right next
/// to the field the user just filled in.
enum KeyTester {
    /// Outcome shape used by the Settings UI. `elapsed` is included so the user
    /// gets a quick "yes it reached the server in N seconds" signal — useful when
    /// the issue is network latency rather than auth.
    enum Outcome {
        case valid(TimeInterval)
        case invalid(String)
    }

    // MARK: - Anthropic

    /// Hits `/v1/messages` with `max_tokens=1` and a one-token user message. Costs
    /// fractions of a cent per call. Returns `valid` on any 2xx, `invalid(reason)`
    /// otherwise. The reason includes the HTTP code so 401 vs 429 vs network are
    /// distinguishable in the UI.
    static func testAnthropic(_ key: String) async -> Outcome {
        guard !key.isEmpty else { return .invalid("Chiave vuota") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ok"]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await runTest(req, label: "anthropic")
    }

    // MARK: - OpenAI

    /// `GET /v1/models` is free, gated by the same Bearer auth the Chat endpoint
    /// uses. 200 means the key is live; 401 means it's revoked or wrong.
    static func testOpenAI(_ key: String) async -> Outcome {
        guard !key.isEmpty else { return .invalid("Chiave vuota") }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return await runTest(req, label: "openai")
    }

    // MARK: - Tavily

    /// Smallest possible Tavily search. Counts as one credit on the user's plan
    /// but is the only way Tavily exposes auth — there's no separate health
    /// endpoint. We deliberately ask for 1 result and `basic` depth so the call
    /// returns fast.
    static func testTavily(_ key: String) async -> Outcome {
        guard !key.isEmpty else { return .invalid("Chiave vuota") }
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": key,
            "query": "ping",
            "max_results": 1,
            "search_depth": "basic",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await runTest(req, label: "tavily")
    }

    // MARK: - Axiom

    /// `GET /v1/datasets` is the simplest authenticated endpoint Axiom offers.
    /// Returns 200 with the dataset list when the token is valid.
    static func testAxiom(_ token: String) async -> Outcome {
        guard !token.isEmpty else { return .invalid("Token vuoto") }
        var req = URLRequest(url: URL(string: "https://api.axiom.co/v1/datasets")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return await runTest(req, label: "axiom")
    }

    // MARK: - Shared transport

    /// Runs the request, classifies the response, returns a UI-friendly outcome.
    /// Failure paths are deliberately verbose: the user wants to know *why* a
    /// key is bad, not just that it is.
    private static func runTest(_ req: URLRequest, label: String) async -> Outcome {
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(start)
            guard let http = response as? HTTPURLResponse else {
                return .invalid("Risposta non HTTP")
            }
            if (200..<300).contains(http.statusCode) {
                Log.info("\(label) test ok status=\(http.statusCode) elapsed=\(String(format: "%.2f", elapsed))s", tag: "keytest")
                return .valid(elapsed)
            }
            // Try to extract a human-readable message from the body. Each provider
            // wraps it differently; we fall back to a snippet of the raw body.
            let raw = String(data: data, encoding: .utf8) ?? ""
            let detail = extractErrorMessage(from: data) ?? String(raw.prefix(160))
            Log.warn("\(label) test fail status=\(http.statusCode) detail=\(detail)", tag: "keytest")
            switch http.statusCode {
            case 401: return .invalid("HTTP 401: chiave non valida")
            case 403: return .invalid("HTTP 403: chiave senza permessi")
            case 429: return .invalid("HTTP 429: rate limit (ma la chiave è plausibilmente valida)")
            default:  return .invalid("HTTP \(http.statusCode): \(detail)")
            }
        } catch {
            Log.warn("\(label) test transport error: \(error.localizedDescription)", tag: "keytest")
            return .invalid("Errore di rete: \(error.localizedDescription)")
        }
    }

    /// Best-effort extraction of an error message from common provider error
    /// shapes: `{error: {message: "..."}}`, `{message: "..."}`, `{detail: "..."}`.
    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let nested = json["error"] as? [String: Any], let msg = nested["message"] as? String {
            return msg
        }
        if let msg = json["error"] as? String { return msg }
        if let msg = json["message"] as? String { return msg }
        if let msg = json["detail"] as? String { return msg }
        return nil
    }
}
