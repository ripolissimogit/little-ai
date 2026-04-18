import Foundation

protocol AIProvider {
    func complete(_ request: AIRequest) async throws -> String
}

enum AIProviderError: LocalizedError {
    case invalidResponse
    case http(Int, String)
    case missingContent

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Risposta non valida dal server."
        case let .http(code, body): return "HTTP \(code): \(body)"
        case .missingContent: return "Risposta vuota dal modello."
        }
    }
}
