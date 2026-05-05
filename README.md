# Scarabot

Mini barra flottante per editare testo selezionato con AI in qualsiasi app macOS — Notes, Mail, Pages, Word, Slack, VSCode e dentro i browser. Doppio `⇧ Shift`, scegli un'azione (Riduci / Estendi / Correggi / Traduci / Spiega / Tono) o scrivi un prompt libero, anteprima, conferma. Usa Claude (Anthropic) o GPT-4o (OpenAI), opzionalmente con verifica fattuale via Tavily o Anthropic web_search.

## Stato

v0.8 — UI semplificata a barra unica bottom-center. Firmato Developer ID e notarizzato, distribuibile via DMG.

## Funzioni

- **Hotkey globale**: doppio `⇧ Shift` (entro 400 ms) → apre/chiude la barra in basso al centro dello schermo.
- **Cattura selezione**: la barra legge automaticamente il testo selezionato nell'app sorgente. Se la cattura fallisce (Chrome con tab AX dormiente, alcuni Electron), il workaround è `⌘C` poco prima della doppia ⇧.
- **Prompt libero**: il TextField è sempre visibile. Scrivi una richiesta, premi `⏎`, e l'AI inserisce il testo al cursor dell'app sorgente.
- **Azioni sulla selezione**: Riduci, Estendi, Correggi, Traduci, Spiega, Tono (formale/informale/professionale/amichevole/tecnico). Disabilitate quando non c'è una selezione catturata.
- **Verifica fattuale opzionale**: toggle in barra. Motore selezionabile (Tavily o Anthropic `web_search`).
- **Anteprima + Conferma**: l'AI risponde, l'utente vede il risultato, preme `⏎` per applicare o `esc` per annullare. Toggle "Inserisci senza anteprima" nel menu bar per il flusso più diretto.
- **Menu bar app**: icona Scarabot in alto, no dock.
- API key salvate in **Keychain** — niente segreti nel binario.

## Distribuzione

- **DMG firmato e notarizzato**: `macos-app/dist/Scarabot-<version>.dmg`. Apple ticket stapled, apribile offline senza alert Gatekeeper.
- **Installazione**: trascina `Scarabot.app` in `/Applications`. Al primo avvio:
  1. macOS chiede il permesso **Accessibilità** → concedi (Impostazioni di Sistema › Privacy e Sicurezza › Accessibilità). Necessario per leggere/scrivere il testo nei campi delle altre app.
  2. Apri **Impostazioni…** dal menu bar Scarabot → incolla la **Anthropic API key** (e/o OpenAI, Tavily, Axiom).
  3. Seleziona del testo in qualsiasi app, doppio `⇧ Shift`, scegli un'azione.

## Setup dev (macOS, Xcode 15+)

```bash
cd macos-app
swift build              # SPM build (binario in .build/debug/Scarabot)
swift run Scarabot       # esegue il binario direttamente
swift test               # esegue la suite di test
```

Build dell'`.app` bundle:

```bash
./build.sh debug             # build firmato ad-hoc, .app in .build/debug/Scarabot.app
./build.sh release --install # build release, copia in /Applications/Scarabot.app
./build.sh release --dmg     # build release + DMG firmato e notarizzato in dist/
```

`build.sh` rasterizza `icon.png` in `AppIcon.icns` (multi-size) e renderizza `menu-icon.svg` in `MenuIcon.png` (template macOS, glyph nero su trasparente — il sistema lo dipinge bianco/nero secondo il tema della menu bar).

### Note sul permesso Accessibilità in dev

Il TCC database di macOS lega il permesso alla firma del binario. Con build SPM non firmati il permesso può essere chiesto di nuovo a ogni rebuild. Per uno sviluppo più fluido firma ad-hoc:

```bash
codesign --force --sign - .build/debug/Scarabot
```

Per la release `build.sh` usa la firma Developer ID (`Claudio Ripoli — 6T98N5PN3Y`) e, con `--dmg`, notarizza via il keychain profile `littleai-notary` (eredità storica del rebrand; cambialo in `build.sh` se preferisci un alias coerente con il nome).

## Architettura

```
Hotkey (⇧⇧)  ─trigger─►  App.trigger()
                              │
                              ▼
                        AX.captureFocused()  ←─ 5 strategie sequenziali con fallback pasteboard
                              │
                              ▼
                        Toolbar (NSPanel + SwiftUI, bottom-center)
                              │
                       ─azione─►  Prompt.edit / Prompt.generate → Anthropic / OpenAI
                              │                                       ↳ opz. Tavily / web_search
                              │
                              ▼
                        Anteprima  ─►  AX.write (⌘V) o pasteboard-only
```

`AIProvider` è un dispatch sull'enum `Provider` (`anthropic` / `openai`). Per aggiungere un provider: una nuova funzione `complete` e un case nello switch in `App.complete`.

## Sicurezza

- API key in **Keychain** (mai su disco in chiaro, mai loggate). Service: `ai.scarabot.Scarabot`.
- Solo il testo selezionato (e opzionalmente i risultati Tavily) lascia il dispositivo, e solo verso gli endpoint configurati.
- `NSAppleEventsUsageDescription` dichiarato in `Info.plist`: necessario perché alcuni step della cattura selezione usano AppleScript per app Electron / Chromium.

## Identificatori

- Bundle ID: `ai.scarabot.Scarabot`
- Keychain service: `ai.scarabot.Scarabot`
- Log file: `~/Library/Logs/Scarabot/scarabot.log`
- Preferenze: `~/Library/Preferences/ai.scarabot.Scarabot.plist`
