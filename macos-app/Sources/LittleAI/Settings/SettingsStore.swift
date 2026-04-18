import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let apiKeyAccount = "anthropic-api-key"
    private let modelKey = "model"
    private let defaults = UserDefaults.standard

    @Published var model: String {
        didSet { defaults.set(model, forKey: modelKey) }
    }

    var apiKey: String? {
        get { Keychain.get(apiKeyAccount) }
        set {
            if let value = newValue, !value.isEmpty {
                Keychain.set(value, for: apiKeyAccount)
            } else {
                Keychain.delete(apiKeyAccount)
            }
        }
    }

    private init() {
        self.model = defaults.string(forKey: modelKey) ?? "claude-sonnet-4-6"
    }
}
