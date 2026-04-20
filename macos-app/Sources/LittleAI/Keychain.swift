import Foundation
import Security

/// Thin wrapper around `SecItem*` for string values, scoped by service bundle id.
/// Stores API keys and tokens that the user enters via the Settings window — nothing
/// is ever hard-coded into the binary.
enum Keychain {
    private static let service = "ai.little.LittleAI"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("keychain set failed key=\(key) status=\(status)", tag: "keychain")
        }
    }

    static func value(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string.isEmpty ? nil : string
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Convenience accessors

    enum Key {
        static let anthropic = "anthropic"
        static let openai = "openai"
        static let axiomToken = "axiom_token"
        static let axiomDataset = "axiom_dataset"
    }

    static var anthropicKey: String? { value(for: Key.anthropic) }
    static var openAIKey: String? { value(for: Key.openai) }
    static var axiomToken: String? { value(for: Key.axiomToken) }
    static var axiomDataset: String? { value(for: Key.axiomDataset) }
}
