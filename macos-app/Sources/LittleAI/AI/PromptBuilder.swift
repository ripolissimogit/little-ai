import Foundation

struct AIRequest {
    let system: String
    let user: String
}

enum PromptBuilder {
    private static let editSystem = """
    Sei un assistente di scrittura integrato in un'app desktop. Ricevi una porzione di testo \
    selezionata dall'utente e devi restituire SOLO il testo modificato, senza preamboli, senza \
    commenti, senza markdown di blocco. Mantieni la lingua originale del testo salvo esplicita \
    richiesta di traduzione. Conserva la formattazione (a capo, elenchi, indentazione) salvo \
    richiesta esplicita di modificarla. Non aggiungere virgolette di apertura/chiusura attorno \
    alla risposta.
    """

    private static let generateSystemIT = """
    Sei un assistente di scrittura integrato in un'app desktop. L'utente ti scrive in italiano \
    cosa vuole comunicare e tu produci il testo finale IN ITALIANO da inserire al punto del \
    cursore. Restituisci SOLO il testo, senza preamboli, senza commenti, senza markdown di \
    blocco, senza virgolette di apertura/chiusura.
    """

    private static let generateSystemEN = """
    You are a writing assistant embedded in a desktop app. The user describes in Italian what \
    they want to communicate; you produce the final text IN ENGLISH to be inserted at the \
    cursor. Return ONLY the English text, with no preamble, no commentary, no code fences, and \
    no surrounding quotes.
    """

    static func buildEdit(action: ActionType, tone: Tone?, selection: String) -> AIRequest {
        let instruction: String
        switch action {
        case .correct:
            instruction = "Correggi grammatica, ortografia e punteggiatura. Mantieni stile, tono e significato originali. Apporta solo le modifiche necessarie."
        case .extend:
            instruction = "Estendi il testo aggiungendo dettagli rilevanti, mantenendo lo stesso tono e registro. Non inventare fatti specifici non desumibili dal testo."
        case .reduce:
            instruction = "Riduci il testo mantenendo il messaggio essenziale e lo stesso tono. Elimina ridondanze e parole superflue."
        case .tone:
            let t = tone?.label ?? "Professionale"
            instruction = "Riscrivi il testo adattandolo a un tono \(t.lowercased()), mantenendo intatto il significato."
        case .translate:
            instruction = "Rileva la lingua del testo: se è italiano traducilo in inglese, se è inglese traducilo in italiano. Mantieni registro, tono e formattazione. Restituisci solo la traduzione."
        case .generate:
            instruction = ""
        }
        let user = """
        Istruzione: \(instruction)

        Testo selezionato da modificare:
        \"\"\"
        \(selection)
        \"\"\"
        """
        return AIRequest(system: editSystem, user: user)
    }

    /// Se il prompt inizia con "EN " (case-insensitive) il flag viene rimosso e l'output sarà
    /// in inglese. Altrimenti l'output è in italiano (default).
    static func buildGenerate(prompt: String) -> AIRequest {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("en ") || lowered == "en" {
            let cleaned = String(trimmed.dropFirst(min(3, trimmed.count)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AIRequest(system: generateSystemEN, user: cleaned)
        }
        return AIRequest(system: generateSystemIT, user: trimmed)
    }
}
