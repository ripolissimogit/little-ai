import Foundation

struct AIRequest {
    let system: String
    let user: String
}

enum PromptBuilder {
    private static let baseSystem = """
    Sei un assistente di scrittura integrato in un'app desktop. Ricevi una porzione di testo \
    selezionata dall'utente e devi restituire SOLO il testo modificato, senza preamboli, senza \
    commenti, senza markdown di blocco. Mantieni la lingua originale del testo. Conserva la \
    formattazione (a capo, elenchi, indentazione) salvo richiesta esplicita di modificarla. \
    Non aggiungere virgolette di apertura/chiusura attorno alla risposta.
    """

    static func build(action: ActionType, tone: Tone?, selection: String, broaderContext: String?) -> AIRequest {
        let instruction: String
        switch action {
        case .correct:
            instruction = "Correggi grammatica, ortografia e punteggiatura. Mantieni stile, tono e significato originali. Apporta solo le modifiche necessarie."
        case .extend:
            instruction = "Estendi il testo aggiungendo dettagli rilevanti, mantenendo lo stesso tono e registro. Non inventare fatti specifici non desumibili dal testo o dal contesto."
        case .reduce:
            instruction = "Riduci il testo mantenendo il messaggio essenziale e lo stesso tono. Elimina ridondanze e parole superflue."
        case .tone:
            let t = tone?.label ?? "Professionale"
            instruction = "Riscrivi il testo adattandolo a un tono \(t.lowercased()), mantenendo intatto il significato."
        }

        var user = "Istruzione: \(instruction)\n\n"
        if let ctx = broaderContext, !ctx.isEmpty, ctx != selection {
            user += "Contesto circostante (solo per coerenza, NON riscriverlo):\n\"\"\"\n\(ctx)\n\"\"\"\n\n"
        }
        user += "Testo selezionato da modificare:\n\"\"\"\n\(selection)\n\"\"\""

        return AIRequest(system: baseSystem, user: user)
    }
}
