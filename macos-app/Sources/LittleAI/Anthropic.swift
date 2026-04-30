import Foundation

enum Action: String, CaseIterable, Identifiable {
    case correct, extend, reduce, tone, translate, explain, promptify
    var id: String { rawValue }
}

enum Tone: String, CaseIterable, Identifiable {
    case formal, informal, professional, friendly, technical
    var id: String { rawValue }
    var label: String {
        switch self {
        case .formal: return "Formale"
        case .informal: return "Informale"
        case .professional: return "Professionale"
        case .friendly: return "Amichevole"
        case .technical: return "Tecnico"
        }
    }
}

/// Target for the `.promptify` action: determines the shape and vocabulary of the
/// optimized prompt the model will produce from the user's selection.
enum PromptTarget: String, CaseIterable, Identifiable {
    case image, code, document
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return "Immagine"
        case .code: return "Codice"
        case .document: return "Documento"
        }
    }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text"
        }
    }
}

struct AIImage {
    let data: Data        // raw bytes of the encoded image
    let mediaType: String // "image/png", "image/jpeg", etc.
}

struct AIRequest {
    let system: String
    let user: String
    let images: [AIImage]

    init(system: String, user: String, images: [AIImage] = []) {
        self.system = system
        self.user = user
        self.images = images
    }
}

enum Prompt {
    private static let editSystem = """
    Sei un assistente di scrittura integrato in un'app desktop. Ricevi una porzione di testo \
    selezionata dall'utente e devi restituire SOLO il testo modificato, senza preamboli, senza \
    commenti, senza markdown di blocco. Mantieni la lingua originale del testo salvo esplicita \
    richiesta di traduzione. Conserva la formattazione (a capo, elenchi, indentazione) salvo \
    richiesta esplicita di modificarla. Non aggiungere virgolette di apertura/chiusura attorno \
    alla risposta.
    """

    /// System prompt used exclusively for the `.promptify` action. Heavier, more opinionated:
    /// the model must act as an expert prompt engineer and produce a rich, sectioned prompt
    /// ready to be pasted into an image/code/document AI.
    private static let promptifySystem = """
    You are a senior prompt engineer. Your job is to transform a user-selected piece of text \
    (which may be a rough idea, a one-liner, a loose description, a brief, or existing prose) \
    into a precise, densely specified, production-grade prompt that will be pasted into another \
    AI system. Think hard about the user's actual intent and reconstruct every missing detail \
    that a professional in the target domain would always specify.

    Hard rules for your output:
    - Return ONLY the final prompt text, with no preamble, no commentary, no meta-explanation, \
    no "Here is your prompt:" wrapper, no code fences, no surrounding quotes.
    - Do not ask clarifying questions. Make decisive, high-taste assumptions and state them \
    inside the prompt as explicit parameters. Be specific rather than generic.
    - Do not summarize the input. Expand it into a complete, unambiguous brief.
    - Use every relevant piece of information from the user's selection; never contradict it.
    - Aim for depth and exhaustiveness over brevity. Prompts that are too short underperform.
    - Never invent private facts about real people, brands, or private data. For everything \
    else, make confident creative/technical choices.
    """

    private static let generateIT = """
    Sei un assistente di scrittura integrato in un'app desktop. L'utente ti scrive in italiano \
    cosa vuole comunicare e tu produci il testo finale IN ITALIANO da inserire al punto del \
    cursore. Restituisci SOLO il testo, senza preamboli, senza commenti, senza markdown di \
    blocco, senza virgolette di apertura/chiusura.
    """

    /// ISO 639-1 codes → English language name. The user prefixes their prompt with one of
    /// these codes (e.g. "fr Puoi scrivere...") and the system prompt instructs Claude to
    /// produce the final text in that language.
    private static let languageNames: [String: String] = [
        "en": "English", "fr": "French", "es": "Spanish", "de": "German",
        "pt": "Portuguese", "it": "Italian", "nl": "Dutch", "sv": "Swedish",
        "no": "Norwegian", "da": "Danish", "fi": "Finnish", "pl": "Polish",
        "cs": "Czech", "ro": "Romanian", "hu": "Hungarian", "el": "Greek",
        "tr": "Turkish", "ru": "Russian", "uk": "Ukrainian", "ar": "Arabic",
        "he": "Hebrew", "hi": "Hindi", "ja": "Japanese", "ko": "Korean",
        "zh": "Chinese", "th": "Thai", "vi": "Vietnamese", "id": "Indonesian",
    ]

    private static func generateSystemFor(language: String) -> String {
        """
        You are a writing assistant embedded in a desktop app. The user describes (typically \
        in Italian) what they want to communicate; you produce the final text IN \(language.uppercased()) \
        to be inserted at the cursor. Return ONLY the text in \(language), with no preamble, \
        no commentary, no code fences, and no surrounding quotes.
        """
    }

    static func edit(action: Action, tone: Tone?, target: PromptTarget?, selection: String, context: String?) -> AIRequest {
        if action == .promptify {
            return promptify(target: target ?? .document, selection: selection, context: context)
        }
        let instruction: String
        switch action {
        case .correct:
            instruction = "Correggi grammatica, ortografia e punteggiatura. Mantieni stile, tono e significato originali. Apporta solo le modifiche necessarie."
        case .extend:
            instruction = "Estendi il testo aggiungendo dettagli rilevanti, mantenendo lo stesso tono e registro. Non inventare fatti specifici non desumibili dal testo."
        case .reduce:
            instruction = "Riduci il testo mantenendo il messaggio essenziale e lo stesso tono. Elimina ridondanze e parole superflue."
        case .tone:
            let t = (tone ?? .professional).label.lowercased()
            instruction = "Riscrivi il testo adattandolo a un tono \(t), mantenendo intatto il significato."
        case .translate:
            instruction = "Rileva la lingua del testo: se è italiano traducilo in inglese, se è inglese traducilo in italiano. Mantieni registro, tono e formattazione. Restituisci solo la traduzione."
        case .explain:
            instruction = "Spiega in italiano cosa significa o cosa implica il testo. Sii conciso: 2-3 frasi. Non riformulare il testo, spiegalo. Restituisci solo la spiegazione."
        case .promptify:
            // Handled above.
            instruction = ""
        }
        var user = """
        Istruzione: \(instruction)

        Testo selezionato da modificare:
        \"\"\"
        \(selection)
        \"\"\"
        """
        if let context, !context.isEmpty {
            user += """


            Contesto circostante (solo per orientarti sul tono/stile/lingua — NON modificarlo, NON includerlo nella risposta):
            \"\"\"
            \(context)
            \"\"\"
            """
        }
        return AIRequest(system: editSystem, user: user)
    }

    /// Compose-mode entry point: user typed a rough idea in the toolbar text field and wants
    /// it turned into an optimized prompt. No surrounding-context because Compose is used
    /// when there is no selection to anchor to.
    static func promptify(target: PromptTarget, text: String) -> AIRequest {
        return promptify(target: target, selection: text, context: nil)
    }

    /// System + user prompt for `Image → image-gen prompt` analysis. The user supplies a
    /// reference image (attached to the request as an `AIImage`); the model inspects it and
    /// emits a detailed text-to-image prompt that would reproduce the *style* of the
    /// reference on a new subject/scene. The image itself is attached by the caller.
    static func promptifyFromImage() -> AIRequest {
        let system = """
        You are a senior prompt engineer and visual analyst. The user gives you a reference \
        image. Your job is to inspect it in depth and produce a single, densely specified, \
        production-grade text-to-image prompt that a modern image model (Midjourney, DALL·E, \
        Stable Diffusion / Flux / Imagen / Ideogram) can use to generate a NEW image that \
        matches the reference's style, genre, medium, aesthetic and technical feel — not a \
        literal copy.

        Before writing, analyse the reference along every axis below and integrate your \
        findings into the final prompt:
        1. Subject — who/what is depicted: species, count, age range if relevant, expression, \
        pose, action, attire, props, relationships between subjects.
        2. Setting & environment — location, era / time period, interior vs exterior, \
        background elements, weather, season, time of day.
        3. Composition — shot type (extreme close-up, close-up, medium, full, wide, \
        establishing), camera angle (eye-level, low-angle, high-angle, Dutch, top-down), \
        framing, symmetry / rule of thirds / leading lines, depth layering (fg / mg / bg).
        4. Camera & lens — inferred camera body class when photographic, lens focal length \
        (e.g. 35mm, 50mm, 85mm, 200mm macro), aperture and depth of field, bokeh, motion \
        blur, shutter feel.
        5. Lighting — direction, quality (soft / hard / diffused), key / fill / rim, \
        practicals, color temperature, golden hour / blue hour / overcast / studio / neon, \
        volumetrics, caustics, contrast ratio.
        6. Color & mood — dominant palette (name specific hues — e.g. "burnt sienna, bone \
        white, deep teal"), saturation, contrast, overall mood adjectives.
        7. Style & medium — photography (editorial, documentary, fashion, street, portrait, \
        product), illustration, oil/gouache/watercolor painting, ink wash, 3D render \
        (Octane/Redshift/Unreal), pixel art, low-poly, cel-shaded anime with specific \
        sub-style, etc. Mention movements/eras (Bauhaus, art nouveau, cyberpunk, solarpunk, \
        vaporwave). Reference 1–2 artists/studios only if clearly and unambiguously evident \
        and safe to name.
        8. Texture & material — fabric types, skin texture, surface finish (matte, glossy, \
        brushed metal), grain structure, film stock (Portra 400, Cinestill 800T, Tri-X) \
        when the reference reads photographic.
        9. Rendering & detail cues — "hyper-detailed", "subsurface scattering", \
        "physically-based rendering", "sharp focus on eyes", "fine micro-texture", used \
        only when they reinforce the reference.
        10. Aspect ratio — infer from the reference's proportions (1:1, 3:2, 4:5, 16:9, 2.35:1).

        HARD RULES FOR YOUR OUTPUT:
        - Output ONLY the final prompt. No preamble, no "Here is the prompt:", no \
        meta-commentary, no code fences, no surrounding quotes, no headings, no bullet \
        lists inside the paragraph.
        - Write in ENGLISH regardless of anything else. Image models are overwhelmingly \
        trained on English captions.
        - Structure: ONE dense natural-language paragraph of ~80–180 words that packs every \
        relevant axis above. Then, on new lines, a compact technical trailer formatted as \
        "Aspect: X:Y | Style: ... | Quality: ultra-detailed, 8k", then a single line \
        starting exactly with "Negative prompt:" listing what to exclude (deformed anatomy, \
        extra fingers, watermark, text, logo, low-res, oversaturated, etc., tailored to the \
        scene).
        - Describe SCENE and STYLE, not a request. No "please generate", no "create an \
        image of" — write as a descriptive caption.
        - The new image should share style, medium, lighting, palette and mood with the \
        reference, but depict a different specific scene/subject. If the reference is \
        abstract or generic, generate a concrete variation in the same aesthetic.
        - Do NOT identify or name real people, real brands, or real copyrighted characters \
        visible in the reference. If the reference is clearly a specific real person, \
        describe them by physical type and styling without naming them.
        - Do NOT include any disclaimers, moral hedging, or "as an AI" phrasing. Be \
        decisive.
        """
        let user = """
        Analyse the reference image attached above and produce the optimized text-to-image \
        prompt that will generate a NEW image in the same style, medium, lighting, palette \
        and overall aesthetic, depicting a different specific scene or subject of your \
        choice that plausibly belongs to the same series. Follow the output rules exactly. \
        Return ONLY the prompt.
        """
        return AIRequest(system: system, user: user)
    }

    /// Builds the user message for `.promptify`. Per-target specs are intentionally long and
    /// concrete: they enumerate every axis a professional would always specify for that kind
    /// of prompt, so the model cannot default to a vague one-paragraph output.
    private static func promptify(target: PromptTarget, selection: String, context: String?) -> AIRequest {
        let spec: String
        switch target {
        case .image:
            spec = """
            TARGET: an image-generation prompt for a modern text-to-image model \
            (Midjourney, DALL·E, Stable Diffusion / Flux / Imagen / Ideogram).

            OUTPUT LANGUAGE: English, regardless of the input language. Image models are \
            overwhelmingly trained on English captions.

            OUTPUT STRUCTURE: a single dense paragraph (no bullet lists, no headings, no \
            numbered sections) of roughly 80–180 words, followed — on new lines — by a compact \
            key=value block of technical parameters, then a "Negative prompt:" line. The \
            paragraph must flow naturally but pack every axis below. Do not label the \
            paragraph.

            AXES YOU MUST RESOLVE AND INCLUDE (make confident choices if the selection is silent):
            1. Subject — who/what, count, age, gender, ethnicity (only if non-sensitive and \
            implied), clothing, expression, pose, action.
            2. Setting — location, environment, background elements, props, era/time period, \
            weather, season, time of day.
            3. Composition — shot type (extreme close-up, close-up, medium, full body, wide, \
            establishing), camera angle (eye-level, low-angle, high-angle, Dutch, top-down, \
            worm's-eye), framing, rule-of-thirds / symmetry / leading lines, depth layers \
            (foreground / midground / background).
            4. Camera & lens — camera body hint (e.g. Hasselblad, ARRI, Sony A7R), lens \
            (focal length like 35mm / 85mm / 200mm macro), aperture (f/1.4, f/8), depth of \
            field (shallow/deep), bokeh, motion blur, shutter speed feel.
            5. Lighting — key light direction and quality (soft / hard / diffused / harsh), \
            fill, rim, practicals, color temperature, golden hour / blue hour / overcast / \
            studio strobe / neon, volumetrics, god rays, caustics, contrast ratio.
            6. Color & mood — palette (specific named colors or references like "Pantone \
            Classic Blue, burnt sienna, bone white"), saturation, contrast, overall mood \
            (serene, menacing, wistful, euphoric).
            7. Style & medium — photorealistic, cinematic still, oil painting, gouache, ink \
            wash, 3D render (Octane/Redshift/Unreal), pixel art, low-poly, anime (specify \
            sub-style), studio photography, editorial fashion, etc. Reference 1–2 artists or \
            studios only if clearly relevant and safe to name.
            8. Texture & material — fabric types, skin texture, surface finish (matte, glossy, \
            brushed metal), grain, film stock (Portra 400, Cinestill 800T) when photographic.
            9. Detail density & rendering cues — "hyper-detailed", "subsurface scattering", \
            "physically based rendering", "sharp focus on eyes", "fine micro-detail", etc. \
            Use sparingly but purposefully.
            10. Technical trailer — aspect ratio, resolution hint, quality flags. Format as: \
            "Aspect: 16:9 | Style: cinematic photoreal | Quality: ultra-detailed, 8k".
            11. Negative prompt line — what to exclude (extra fingers, deformed anatomy, \
            watermark, text, logo, low-res, oversaturated, blurry) tailored to the scene.

            HARD CONSTRAINTS:
            - Do not use the second person or instructions ("please generate", "create an \
            image of"). Write the prompt as a descriptive scene, not a request.
            - Use comma-chained descriptors where appropriate, but prefer natural phrasing \
            over keyword soup.
            - No moral disclaimers, no "as an AI" hedging.
            """
        case .code:
            spec = """
            TARGET: a coding prompt for a capable code-generation assistant (Claude, GPT, \
            Gemini, Cursor, Copilot chat).

            OUTPUT LANGUAGE: English (standard for coding prompts and library docs).

            OUTPUT STRUCTURE: a structured prompt with the following top-level sections, in \
            this exact order, each introduced by a bold-style plain-text heading followed by \
            a colon on its own line. Do NOT use markdown syntax characters (#, **, backticks) \
            for the headings themselves; just capitalized labels. Under each heading use \
            concise bullet lines starting with "- ". Keep it scannable but exhaustive.

            SECTIONS (all required; if a section is truly not applicable, write "n/a" rather \
            than omitting it):

            ROLE AND CONTEXT: one short paragraph framing the assistant's role (e.g. "You \
            are a senior Rust engineer working on a high-throughput ingestion service.") and \
            the surrounding project context inferred from the selection.

            GOAL: one sentence stating the concrete outcome. Make it unambiguous and testable.

            LANGUAGE AND STACK: language + version, framework + version, key libraries \
            with versions, build tool, target runtime (Node 20, Python 3.12, Swift 6, \
            browser ES2022, etc.). Pick sensible defaults when the selection is silent.

            INPUTS: every input with name, type, shape, constraints, and a realistic example. \
            Cover both happy-path and malformed inputs.

            OUTPUTS: the return type / response shape / side effects, with a realistic \
            example. Specify error shape too.

            BEHAVIOR AND ALGORITHM: the step-by-step approach the implementation must follow, \
            at enough granularity to remove ambiguity without dictating every line. Call out \
            concurrency model, ordering guarantees, idempotency, retries.

            CONSTRAINTS: performance targets (latency, throughput, memory), style (naming, \
            formatter, lint rules), dependency policy (stdlib-only? add-only if justified?), \
            security (input validation, secret handling), accessibility/i18n when UI.

            EDGE CASES: enumerate at least 5 concrete edge cases the implementation MUST \
            handle (empty input, oversized input, duplicates, unicode/emoji, timezone/DST, \
            network failure, auth expiry, concurrent writers, etc. — pick the ones relevant \
            to the task).

            NON-GOALS: what is explicitly out of scope. This prevents over-building.

            DELIVERABLE FORMAT: exactly what the assistant should return — e.g. "a single \
            self-contained TypeScript module", "a unified diff against the existing file X", \
            "a function plus its unit tests in the same file", "only the changed lines, no \
            commentary". Specify whether comments/docstrings are wanted.

            TESTING AND ACCEPTANCE: the tests or assertions that must pass. Prefer concrete \
            input→output pairs. Mention the testing framework.

            HARD CONSTRAINTS:
            - No markdown code fences anywhere in the output.
            - Do not write any code yourself; write the prompt that will elicit the code.
            - Stay decisive; do not add "if possible" or "optionally". Every item is required.
            """
        case .document:
            spec = """
            TARGET: a prompt to produce a written document (article, report, email, spec, \
            pitch, blog post, memo, press release, whitepaper, landing-page copy, etc.) from \
            an AI writing assistant.

            OUTPUT LANGUAGE: match the dominant language of the user's selection. If the \
            selection is in Italian write the prompt in Italian; if in English write it in \
            English; otherwise mirror the selection's language. The generated document will \
            be in that same language.

            OUTPUT STRUCTURE: a structured brief with the following headings, each on its \
            own line, followed by a colon and then the content. Use plain-text headings (no \
            markdown symbols). Under each, use "- " bullets where a list fits, otherwise a \
            short paragraph. Every heading is required.

            REQUIRED HEADINGS (in order):

            RUOLO / ROLE: the persona the writer should adopt (e.g. "Direttore editoriale \
            di una rivista di design industriale" / "Senior product marketer at a B2B SaaS \
            startup"). Be specific.

            OBIETTIVO / GOAL: the single outcome the document must achieve (inform, persuade, \
            convert, onboard, apologize, announce, benchmark, etc.) plus the measurable \
            effect on the reader.

            DESTINATARI / AUDIENCE: who reads it — role, seniority, expertise level, prior \
            knowledge, emotional state, what they care about, objections they'll raise.

            FORMATO / FORMAT: document type, delivery medium (email body, PDF, blog post, \
            Slack message, LinkedIn post, internal memo), and any formatting system (plain \
            text, markdown, HTML, structured sections with numbered headings).

            STRUTTURA / STRUCTURE: the exact sections or narrative arc the document must \
            follow, in order, each with a one-line description of what goes inside. Include \
            opening hook, body, and closing/CTA when relevant.

            LUNGHEZZA / LENGTH: target word count OR reading time, plus max length. Be concrete.

            TONO E REGISTRO / TONE AND VOICE: tone adjectives (autorevole, caldo, diretto, \
            ironico, sobrio, tecnico), register (formal/informal), person (first plural, \
            second person), sentence rhythm, vocabulary level.

            PUNTI CHIAVE / KEY POINTS: the specific facts, arguments, data, anecdotes, or \
            examples that MUST appear. Prioritize them.

            VINCOLI / CONSTRAINTS: things to avoid (jargon, clichés, specific words, \
            competitors' names), mandatory inclusions (CTA text, links, disclaimers, \
            legal lines), SEO keywords if any.

            CRITERI DI QUALITÀ / QUALITY CRITERIA: the checklist a reviewer will apply to \
            judge the final document (clarity, concreteness, absence of filler, original \
            angle, ready-to-publish polish). At least 4 concrete criteria.

            OUTPUT ATTESO / EXPECTED OUTPUT: one line specifying exactly what the assistant \
            should return (e.g. "solo il testo finale del documento, senza commenti né \
            intestazioni aggiuntive").

            HARD CONSTRAINTS:
            - No meta-commentary, no "Ecco il prompt:" wrapper.
            - Do not write the document itself; write the brief that will elicit it.
            - Keep headings in the chosen language consistently throughout.
            """
        }

        var user = """
        Transform the user's selected text below into an optimized prompt following the \
        specification for the chosen target.

        \(spec)

        === USER SELECTION (the raw material to transform) ===
        \"\"\"
        \(selection)
        \"\"\"
        """
        if let context, !context.isEmpty {
            user += """


            === SURROUNDING CONTEXT (background only — do NOT copy it into the prompt, use \
            it only to disambiguate intent, domain, and audience) ===
            \"\"\"
            \(context)
            \"\"\"
            """
        }
        user += """


        Produce the optimized prompt now. Output ONLY the prompt itself, ready to paste.
        """
        return AIRequest(system: promptifySystem, user: user)
    }

    /// If the prompt starts with a 2-letter ISO 639-1 language code followed by a space
    /// (e.g. "fr ...", "ja ...", "es ..."), the output is produced in that language and
    /// the code is stripped from the user text. Otherwise the default is Italian.
    static func generate(prompt: String) -> AIRequest {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            let head = trimmed[..<spaceIdx].lowercased()
            if let language = languageNames[head] {
                let rest = String(trimmed[trimmed.index(after: spaceIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    return AIRequest(system: generateSystemFor(language: language), user: rest)
                }
            }
        }
        return AIRequest(system: generateIT, user: trimmed)
    }
}

enum Anthropic {
    static let model = "claude-sonnet-4-6"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { "HTTP \(status): \(message)" }
    }

    static func complete(_ request: AIRequest) async throws -> String {
        guard let apiKey = Secrets.anthropicAPIKey else {
            throw APIError(status: 0, message: "API key Anthropic mancante. Apri Impostazioni (⌘,) dal menu bar.")
        }
        let keyPreview = maskKey(apiKey)
        Log.info("request model=\(model) systemLen=\(request.system.count) userLen=\(request.user.count) images=\(request.images.count) key=\(keyPreview)", tag: "ai")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Build the user content. Text-only requests stay as a plain string (smaller body,
        // same behavior as before). Requests with images switch to Anthropic's content-block
        // array: images first, then the user text prompt.
        let userContent: Any
        if request.images.isEmpty {
            userContent = request.user
        } else {
            var blocks: [[String: Any]] = request.images.map { img in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": img.mediaType,
                        "data": img.data.base64EncodedString(),
                    ],
                ]
            }
            blocks.append(["type": "text", "text": request.user])
            userContent = blocks
        }

        let bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": request.system,
            "messages": [["role": "user", "content": userContent]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
        Log.debug("request bodyBytes=\(req.httpBody?.count ?? 0)", tag: "ai")

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            Log.error("URLSession failed: \(error)", tag: "ai")
            throw error
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            Log.error("response not HTTPURLResponse: \(type(of: response))", tag: "ai")
            throw APIError(status: 0, message: "Risposta non valida")
        }
        Log.info("response status=\(http.statusCode) bytes=\(data.count) elapsed=\(String(format: "%.2f", elapsed))s", tag: "ai")

        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? raw
            Log.error("HTTP \(http.statusCode) body=\(raw.prefix(500))", tag: "ai")
            throw APIError(status: http.statusCode, message: message)
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Log.error("decode failed: \(error) body=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "")", tag: "ai")
            throw error
        }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("parsed resultLen=\(result.count) blocks=\(decoded.content.count)", tag: "ai")
        return result
    }

    private static func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return "***" }
        return "\(key.prefix(10))…\(key.suffix(4))"
    }

    private struct Response: Decodable {
        struct Content: Decodable { let type: String; let text: String? }
        let content: [Content]
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
