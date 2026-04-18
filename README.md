# Little AI

Mini barra flottante per la correzione AI on-the-fly su qualsiasi campo di testo macOS — app native (Notes, Mail, Pages, Slack, VSCode, …) e anche dentro i browser. Usa Claude (Anthropic API).

## Stato

v0.1 — scaffolding funzionale. Da firmare e impacchettare per la release.

## Funzioni v1

- **Hotkey globale** `⌥ Spazio` → cattura il testo selezionato nel campo focalizzato
- **Barra flottante** posizionata sul caret con azioni:
  - ✓ Correggi (grammatica/ortografia)
  - ↗ Estendi
  - ↘ Riduci
  - 🎭 Tono (formale, informale, professionale, amichevole, tecnico)
  - 🔍 Toggle "contesto ampio" — invia anche il testo circostante per output più coerente
- **Anteprima** del risultato → Sostituisci / Annulla
- **Menu bar app** (no dock icon)
- API key salvata in Keychain
- Modello configurabile: `claude-sonnet-4-6` (default), `claude-opus-4-7`, `claude-haiku-4-5-20251001`

## Roadmap

- v2: upload file (PDF/immagini), provider OpenAI, shortcut configurabili, cronologia, prompt custom.

## Struttura repo

```
macos-app/      App nativa Swift/SwiftUI (SPM)
shared/         (futuro) prompt e schema condivisi tra macOS/extension/iOS
```

## Setup dev (macOS, Xcode 15+)

```bash
cd macos-app
open Package.swift          # apre in Xcode
# oppure da CLI:
swift build
swift run LittleAI
```

Al primo avvio:
1. macOS chiede il permesso **Accessibilità** → concedi (Impostazioni di Sistema › Privacy e Sicurezza › Accessibilità). Necessario per leggere/scrivere il testo nei campi delle altre app.
2. Clicca l'icona ✨ nella barra dei menu › **Impostazioni…** › incolla la tua **Anthropic API key**.
3. Seleziona del testo in qualsiasi app, premi `⌥ Spazio`, scegli un'azione.

### Note sul permesso Accessibilità in dev

Il TCC database di macOS lega il permesso alla firma del binario. Con build SPM non firmati il permesso può essere chiesto di nuovo a ogni rebuild. Per uno sviluppo più fluido firma ad-hoc:

```bash
codesign --force --sign - .build/debug/LittleAI
```

Per la release useremo la tua firma Developer ID.

## Architettura

```
HotkeyManager  ─trigger─►  Coordinator
                              │
                              ▼
                        AXService (legge selezione + bounds + contesto)
                              │
                              ▼
                  FloatingToolbarController (NSPanel + SwiftUI)
                              │
                       ─azione─►  PromptBuilder ► AnthropicProvider
                              │
                              ▼
                        Anteprima ► AXService.replaceSelection
```

`AIProvider` è un protocollo: aggiungere OpenAI o altri provider in futuro è una sola classe nuova senza toccare il resto.

## Sicurezza

- API key in **Keychain** (mai su disco in chiaro, mai loggata).
- Solo il testo selezionato (e opzionalmente il contesto circostante) lascia il dispositivo, e solo verso l'endpoint Anthropic configurato.
