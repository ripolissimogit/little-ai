// Secrets are no longer hard-coded in the binary. All API keys and tokens are stored
// in the macOS Keychain (see Keychain.swift) and entered by the user via the Settings
// window (⌘, from the menu bar). This file intentionally left as a minimal shim so
// existing references keep resolving.
import Foundation

enum Secrets {
    static var anthropicAPIKey: String? { Keychain.anthropicKey }
    static var openAIAPIKey: String? { Keychain.openAIKey }
    static var tavilyAPIKey: String? { Keychain.tavilyKey }
    static var axiomToken: String? { Keychain.axiomToken }
    static var axiomDataset: String { Keychain.axiomDataset ?? "scarabot" }
}
