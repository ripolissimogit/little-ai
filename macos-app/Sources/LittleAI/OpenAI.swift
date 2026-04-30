import Foundation

/// OpenAI Chat Completions client. Same external shape as `Anthropic.complete(_:)` so
/// `App.complete` can switch providers via `Prefs.provider` without knowing which one.
enum OpenAI {
    static let model = "gpt-4o"
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "HTTP \(status): \(message)" }
    }

    static func complete(_ request: AIRequest) async throws -> String {
        guard let apiKey = Secrets.openAIAPIKey else {
            throw APIError(status: 0, message: "API key OpenAI mancante. Apri Impostazioni (⌘,) dal menu bar.")
        }
        let keyPreview = maskKey(apiKey)
        Log.info("request model=\(model) systemLen=\(request.system.count) userLen=\(request.user.count) images=\(request.images.count) key=\(keyPreview)", tag: "ai.openai")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Mirror the Anthropic path: plain string when no images (keeps the payload small
        // and behaviour identical to pre-vision builds), content-part array otherwise.
        let userContent: Any
        if request.images.isEmpty {
            userContent = request.user
        } else {
            var parts: [[String: Any]] = request.images.map { img in
                let b64 = img.data.base64EncodedString()
                return [
                    "type": "image_url",
                    "image_url": ["url": "data:\(img.mediaType);base64,\(b64)"],
                ]
            }
            parts.append(["type": "text", "text": request.user])
            userContent = parts
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": userContent],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        Log.debug("request bodyBytes=\(req.httpBody?.count ?? 0)", tag: "ai.openai")

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.error("URLSession failed: \(error)", tag: "ai.openai")
            throw error
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            Log.error("response not HTTPURLResponse: \(type(of: response))", tag: "ai.openai")
            throw APIError(status: 0, message: "Risposta non valida")
        }
        Log.info("response status=\(http.statusCode) bytes=\(data.count) elapsed=\(String(format: "%.2f", elapsed))s", tag: "ai.openai")

        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? raw
            Log.error("HTTP \(http.statusCode) body=\(raw.prefix(500))", tag: "ai.openai")
            throw APIError(status: http.statusCode, message: message)
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Log.error("decode failed: \(error) body=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "")", tag: "ai.openai")
            throw error
        }
        guard let text = decoded.choices.first?.message.content else {
            throw APIError(status: 0, message: "Risposta vuota dal modello")
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("parsed resultLen=\(result.count) choices=\(decoded.choices.count)", tag: "ai.openai")
        return result
    }

    private static func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return "***" }
        return "\(key.prefix(10))…\(key.suffix(4))"
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
