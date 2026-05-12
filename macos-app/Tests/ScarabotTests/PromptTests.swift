import XCTest
@testable import Scarabot

/// Unit tests for the prompt builders. Each builder must produce a request with the
/// right system prompt and the user content embedded as expected. Failures here mean
/// the AI is getting a wrong prompt — the single highest-leverage thing to catch.
final class PromptTests: XCTestCase {

    // MARK: - editFreeform(instruction:, selection:)

    func testEditFreeformEmbedsInstructionAndSelection() {
        let req = Prompt.editFreeform(
            instruction: "rendi più formale",
            selection: "ciao come va?"
        )
        XCTAssertTrue(req.system.contains("editor di testo"),
                      "edit system prompt should be used")
        XCTAssertTrue(req.user.contains("rendi più formale"),
                      "user instruction must be passed through")
        XCTAssertTrue(req.user.contains("ciao come va?"),
                      "selection must be embedded in user message")
    }

    func testEditFreeformDemandsTextOnlyOutput() {
        let req = Prompt.editFreeform(instruction: "tradurre in inglese", selection: "Buongiorno")
        XCTAssertTrue(req.user.contains("PURO testo finale"),
                      "edit prompts should constrain the model to return only the final text")
        XCTAssertFalse(req.user.contains("JSON"),
                       "inline editing should not ask for JSON: the output is pasted into another app")
        XCTAssertFalse(req.user.contains("diagnostics"),
                       "inline editing should not ask for model commentary by default")
    }

    func testEditFreeformSystemPromptMatchesTextOnlyContract() {
        let req = Prompt.editFreeform(instruction: "correggi", selection: "testo")
        XCTAssertTrue(req.system.contains("niente oggetti strutturati"),
                      "system and user prompts must agree on text-only edit output")
        XCTAssertTrue(req.system.contains("niente commenti"),
                      "system prompt should prevent commentary from entering the pasted text")
    }

    func testEditFreeformPreservesMultilineSelection() {
        let selection = "Riga uno\nRiga due\nRiga tre"
        let req = Prompt.editFreeform(instruction: "riassumi", selection: selection)
        XCTAssertTrue(req.user.contains(selection),
                      "multi-line selection must be embedded verbatim")
    }

    // MARK: - generate(prompt:)

    func testGenerateDefaultsToItalian() {
        let req = Prompt.generate(prompt: "scrivi un saluto")
        XCTAssertTrue(req.system.contains("IN ITALIANO"),
                      "default Italian system prompt should be used")
        XCTAssertEqual(req.user, "scrivi un saluto")
    }

    func testGenerateDetectsLanguagePrefix() {
        let req = Prompt.generate(prompt: "fr écris une salutation")
        XCTAssertTrue(req.system.contains("FRENCH"),
                      "FR prefix should route to a French system prompt")
        XCTAssertEqual(req.user, "écris une salutation",
                       "language prefix should be stripped from the user text")
    }

    func testGenerateIgnoresUnknownPrefix() {
        // "xx" isn't in the ISO table → the whole string stays intact and we fall back
        // to the default Italian system prompt.
        let req = Prompt.generate(prompt: "xx fai qualcosa")
        XCTAssertTrue(req.system.contains("IN ITALIANO"))
        XCTAssertEqual(req.user, "xx fai qualcosa")
    }
}
