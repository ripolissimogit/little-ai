import XCTest
@testable import LittleAI

/// Unit tests for the prompt builders. They verify that each action produces a request
/// with the right system prompt, the right user instruction, and the right structural
/// markers (section headings, keywords, quoted selection). Failures here mean the AI is
/// getting a wrong prompt — the single highest-leverage thing to catch.
final class PromptTests: XCTestCase {

    // MARK: - edit(...) path

    func testEditCorrectUsesCorrectionInstruction() {
        let req = Prompt.edit(action: .correct, tone: nil, target: nil,
                              selection: "Ciao come va?", context: nil)
        XCTAssertTrue(req.system.contains("assistente di scrittura"),
                      "editSystem should be used for non-promptify actions")
        XCTAssertTrue(req.user.contains("Correggi grammatica"),
                      "user must carry the 'correct' instruction")
        XCTAssertTrue(req.user.contains("Ciao come va?"),
                      "selection must be embedded in user message")
        XCTAssertTrue(req.images.isEmpty, "plain edit has no images")
    }

    func testEditExtendKeepsSelection() {
        let req = Prompt.edit(action: .extend, tone: nil, target: nil,
                              selection: "Oggi è lunedì.", context: nil)
        XCTAssertTrue(req.user.contains("Estendi il testo"))
        XCTAssertTrue(req.user.contains("Oggi è lunedì."))
    }

    func testEditReduceKeepsSelection() {
        let req = Prompt.edit(action: .reduce, tone: nil, target: nil,
                              selection: "Testo molto lungo da ridurre significativamente.",
                              context: nil)
        XCTAssertTrue(req.user.contains("Riduci il testo"))
        XCTAssertTrue(req.user.contains("Testo molto lungo"))
    }

    func testEditToneUsesProvidedTone() {
        let req = Prompt.edit(action: .tone, tone: .formal, target: nil,
                              selection: "Hey amico!", context: nil)
        XCTAssertTrue(req.user.lowercased().contains("formale"),
                      "tone instruction must reference the chosen tone")
    }

    func testEditToneDefaultsToProfessional() {
        let req = Prompt.edit(action: .tone, tone: nil, target: nil,
                              selection: "Hey amico!", context: nil)
        XCTAssertTrue(req.user.lowercased().contains("professionale"),
                      "missing tone should default to professional")
    }

    func testEditTranslateDescribesItEnBidirectional() {
        let req = Prompt.edit(action: .translate, tone: nil, target: nil,
                              selection: "Buongiorno!", context: nil)
        XCTAssertTrue(req.user.contains("italiano") && req.user.contains("inglese"),
                      "translate instruction must describe the it↔en rule")
    }

    func testEditExplainAsksForConcise() {
        let req = Prompt.edit(action: .explain, tone: nil, target: nil,
                              selection: "SCSI", context: nil)
        XCTAssertTrue(req.user.contains("Spiega"))
        XCTAssertTrue(req.user.contains("2-3 frasi"),
                      "explain must be constrained to 2-3 sentences")
    }

    func testEditEmbedsContextWhenProvided() {
        let req = Prompt.edit(action: .correct, tone: nil, target: nil,
                              selection: "testo",
                              context: "contesto circostante di esempio")
        XCTAssertTrue(req.user.contains("contesto circostante di esempio"))
        XCTAssertTrue(req.user.contains("Contesto circostante"),
                      "must include the section header in Italian")
    }

    func testEditOmitsContextSectionWhenNoContext() {
        let req = Prompt.edit(action: .correct, tone: nil, target: nil,
                              selection: "x", context: nil)
        XCTAssertFalse(req.user.contains("Contesto circostante"),
                       "no context → no context heading")
    }

    // MARK: - promptify by PromptTarget (selection-based)

    func testPromptifyImageTargetContainsImageSpec() {
        let req = Prompt.edit(action: .promptify, tone: nil, target: .image,
                              selection: "un astronauta che beve caffè",
                              context: nil)
        XCTAssertTrue(req.system.contains("senior prompt engineer"),
                      "promptify uses its own dedicated system prompt")
        XCTAssertTrue(req.user.contains("image-generation prompt"),
                      "image spec header must be present")
        XCTAssertTrue(req.user.contains("Negative prompt"),
                      "image spec must request a negative prompt trailer")
        XCTAssertTrue(req.user.contains("Aspect"),
                      "image spec must request the technical trailer")
        XCTAssertTrue(req.user.contains("un astronauta che beve caffè"),
                      "user selection must be embedded verbatim")
    }

    func testPromptifyCodeTargetContainsSectionedSpec() {
        let req = Prompt.edit(action: .promptify, tone: nil, target: .code,
                              selection: "parse JSON safely in Swift",
                              context: nil)
        XCTAssertTrue(req.user.contains("coding prompt"))
        for heading in ["ROLE AND CONTEXT", "GOAL", "INPUTS", "OUTPUTS",
                        "EDGE CASES", "DELIVERABLE FORMAT", "TESTING AND ACCEPTANCE"] {
            XCTAssertTrue(req.user.contains(heading),
                          "code spec must enumerate section: \(heading)")
        }
    }

    func testPromptifyDocumentTargetHasItalianHeadings() {
        let req = Prompt.edit(action: .promptify, tone: nil, target: .document,
                              selection: "email di annuncio promozione",
                              context: nil)
        XCTAssertTrue(req.user.contains("written document"))
        for heading in ["RUOLO", "OBIETTIVO", "DESTINATARI",
                        "FORMATO", "STRUTTURA", "LUNGHEZZA", "TONO"] {
            XCTAssertTrue(req.user.contains(heading),
                          "document spec must include heading: \(heading)")
        }
    }

    func testPromptifyFallsBackToDocumentWhenTargetMissing() {
        // Guard behaviour: if the caller doesn't pass a target for .promptify we default to
        // document — anything else would mis-route the spec. Protects against UI bugs.
        let req = Prompt.edit(action: .promptify, tone: nil, target: nil,
                              selection: "x", context: nil)
        XCTAssertTrue(req.user.contains("written document"))
    }

    // MARK: - promptify from Compose text

    func testPromptifyFromComposeTextReusesTargetSpec() {
        let req = Prompt.promptify(target: .image, text: "cane su skateboard")
        XCTAssertTrue(req.user.contains("image-generation prompt"))
        XCTAssertTrue(req.user.contains("cane su skateboard"))
    }

    // MARK: - promptify from image (vision)

    func testPromptifyFromImageSystemIsVisionOriented() {
        let req = Prompt.promptifyFromImage()
        XCTAssertTrue(req.system.contains("visual analyst"),
                      "vision system prompt must frame the model as a visual analyst")
        XCTAssertTrue(req.system.contains("Subject"),
                      "vision system prompt must enumerate analysis axes")
        XCTAssertTrue(req.system.contains("Lighting"))
        XCTAssertTrue(req.system.contains("Negative prompt"))
        XCTAssertTrue(req.user.contains("attached"),
                      "vision user prompt must refer to the attached reference")
        XCTAssertTrue(req.images.isEmpty,
                      "builder must not pre-populate images — caller attaches them")
    }

    // MARK: - AIRequest shape

    func testAIRequestDefaultsToNoImages() {
        let req = AIRequest(system: "s", user: "u")
        XCTAssertEqual(req.images.count, 0)
    }

    func testAIRequestPropagatesImages() {
        let img = AIImage(data: Data([0x89, 0x50]), mediaType: "image/png")
        let req = AIRequest(system: "s", user: "u", images: [img])
        XCTAssertEqual(req.images.count, 1)
        XCTAssertEqual(req.images.first?.mediaType, "image/png")
    }

    // MARK: - generate(prompt:) path

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
