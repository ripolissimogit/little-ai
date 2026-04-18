import Foundation

struct AnthropicProvider: AIProvider {
    let apiKey: String
    var model: String = Settings.model
    var endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    var maxTokens: Int = 4096

    func complete(_ request: AIRequest) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.http(http.statusCode, bodyText)
        }

        struct Response: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let content: [Content]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw AIProviderError.missingContent }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
