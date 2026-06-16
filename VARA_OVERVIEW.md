# Vara — funktioner, settings & UI

> Samlet kortlægning af Vara: arkitektur, kernefunktioner, alle settings, dictation-modes, STT-backends, LLM-providers, CLI og hvad brugeren ser i hver UI-flade.
> Genereret med udgangspunkt i graphify-grafen + kildefilerne. Senest opdateret 2026-06-16 — inkl. OpenAI realtime-fix (`?intent=transcription`), custom-vocabulary-bias på tværs af backends, og OpenAI-realtime mikrofon-profil (`noise_reduction`).

---

## Arkitektur (3 moduler)

| Modul | Sti | Rolle |
|---|---|---|
| **VaraCore** | `Sources/VaraCore/` | STT-backends, LLM-klienter, transcript-cleanup, dictation-session, modeller |
| **VaraCLI** | `Sources/VaraCLI/` | Terminal-værktøjet `vara` |
| **App** | `App/` | macOS menubar-app: AppState, HUD, Settings, Onboarding, Dashboard |

Appen er en **menubar-app** (ingen dock-ikon). UI'et er tosproget (da/en) via `App/Localizable.xcstrings`. Bundle-id: `dk.56n.vara`.

---

## Kernefunktioner

- **Push-to-talk diktering** — hold genvejstast → optag → slip → transskriber → indsæt (`App/AppState+Dictation.swift`). Auto-paste eller læg på clipboard.
- **Diktér fra menu / klik** — start/stop fra menubar i stedet for tasten.
- **Mode-system** — afgør hvad der sker med transskriptionen før indsættelse (rå / omskriv / svar). Indbyggede + brugerdefinerede (`Sources/VaraCore/Intelligence/DictationMode.swift`).
- **Tal-override 1–9** — tryk et ciffer under optagelse for at vælge mode ad hoc (vinder over en app-regel).
- **Per-app mode-regler** — "når jeg dikterer i app X, brug mode Y" (`App/Settings/AppModeRule.swift`).
- **Recording-HUD** — flydende overlay ved markøren med live waveform/status (`App/HUD/RecordingHUDView.swift`).
- **Historik** — gemmer seneste transskriptioner med statistik, søgning og gruppering pr. app.
- **Onboarding** — guidet opsætning i 8 trin ved første start (vælg motor → routed setup → tekst-cleaner → cleanup-AI → prøv-det).
- **Lydfeedback** — start/stop-lyde.
- **CLI** — `vara` som selvstændigt værktøj (`Sources/VaraCLI/Vara.swift`).
- **Credential-håndtering** — Keychain + `~/.vara/.env`-fallback.

---

## Settings — 6 sektioner

Sidebar-sektioner (`App/Settings/SettingsEnums.swift`): **Dictation · Engine · Intelligence · Advanced · Privacy · About**.
Alle felter bor i `VaraAppSettings` (`App/Settings/SettingsModel.swift`) og persisteres i UserDefaults (`App/Settings/SettingsStore.swift`).

### 🎙 Dictation
| Setting | Felt | Default |
|---|---|---|
| Genvejstast | `shortcut` | Right Command |
| Sprog | `language` | Automatic (da/en) |
| Indsæt automatisk | `pasteAutomatically` | true |
| Vis HUD | `showHUD` | true |
| Afspil lyde | `playSounds` | true |
| Valgt mode | `selectedModeID` | Raw |
| Ordforråd (stave-bias) | `vocabulary` | tom |

**Genvejsvalg** (9 stk): højre/venstre ⌘, højre/venstre ⌥, fn, samt 4 kombinationer ⌘+⌥.

> **Custom vocabulary** (`vocabulary`, "Ord Vara skal ramme rigtigt") biaser den **rå** transskription pr. backend: Whisper `prompt` (Groq, OpenAI batch), ElevenLabs `keyterms` (≤20 tegn × max 50). OpenAI Realtime (`gpt-realtime-whisper`) og lokal WhisperKit understøtter det ikke endnu (sidstnævnte pga. WhisperKit#372).

### ⚙️ Engine (tale-til-tekst)
- **Speech backend** (`speechBackend`) — 7 valg (se nedenfor)
- **WhisperKit-model** (`whisperKitModel`) + download-UI
- **Local Hviske**-sektion (Python-backend setup)
- **Custom endpoints** (OpenAI-kompatible)
- **API-nøgler** pr. provider (gemmes i Keychain)
- **Mikrofon-profil** (`microphoneProfile`, near/far-field → OpenAI Realtime `noise_reduction`) — vises kun når OpenAI Realtime er valgt

### ✨ Intelligence (LLM-cleanup)
- **Default LLM** (`defaultLLM`) — provider + model
- **Modes** (`modes`) — opret/redigér, vælg behavior, systemprompt, evt. egen LLM pr. mode
- **API-nøgler** for valgt LLM-provider

### 🎚 Advanced
- **Behold seneste transskript** (`keepRecentTranscript`)
- **Historik-grænse** (`historyLimit`, 10–200, default 100)
- **App-regler** (`appModeRules`)
- **Custom LLM-endpoints** (`customEndpoints`)

### 🔒 Privacy
- Viser **hvor lyd behandles** pr. backend (lokalt på Mac vs. netværk via Groq/OpenAI/ElevenLabs).

### ℹ️ About
- Version/info.

---

## Dictation modes (5 indbyggede + custom)

Tre behaviors: `insertRaw`, `rewrite`, `answer`.

| Mode | Ikon | Behavior | Hvad den gør |
|---|---|---|---|
| **Raw** | waveform | insertRaw | Indsætter ordret, ingen LLM |
| **Clean text** | sparkles | rewrite | Tegnsætning, fjerner fyldord ("øh"), default når LLM er sat op |
| **Professional** | briefcase | rewrite | Poleret forretningstone |
| **VibeCode** | code | rewrite | Omdanner tale til prompt for AI-kodeagent |
| **Ask AI** | questionmark.bubble | answer | Behandler tale som spørgsmål, indsætter svaret |

Alle systemprompts er prompt-injection-hærdede (transskriptionen pakkes i en TRANSCRIPT-fence og behandles aldrig som instruktioner).

---

## STT-backends (7)

| Backend | Type |
|---|---|
| `elevenLabsScribe` — ElevenLabs Scribe | Netværk (realtime) |
| `groqWhisper` — Groq Whisper Large v3 | Netværk · **default, gratis** |
| `openAIRealtimeWhisper` — OpenAI GPT Realtime Whisper | Netværk (realtime, forbindes med `?intent=transcription`) |
| `openAIGPT4OTranscribe` — OpenAI GPT-4o Transcribe | Netværk |
| `openAIGPT4OMiniTranscribe20251215` — GPT-4o Mini Transcribe | Netværk |
| `localHviske` — Local Hviske v5.3 | Lokal (Python) |
| `localWhisperKit` — Local WhisperKit (large-v3 turbo) | Lokal |

## LLM-providers (cleanup-laget) — 9 cases

`LLMProvider` (`Sources/VaraCore/Intelligence/DictationMode.swift`). API-providere kræver nøgle (Keychain → `~/.vara/.env`); CLI-providere kører på din egen abonnement uden nøgle.

**API-providere**

| Provider | Default model | Note |
|---|---|---|
| `groq` | llama-3.3-70b-versatile | **Default** · zero-cost · *Recommended* |
| `openAI` | gpt-4o-mini | *Recommended* |
| `anthropic` | claude-haiku-4-5-20251001 | *Advanced* |
| `gemini` | gemini-2.5-flash | Google OpenAI-kompatibel endpoint (`GEMINI_API_KEY`) · *Advanced* |
| `ollama` | gemma3 | Lokal (localhost:11434) · *Advanced* |
| `custom` | — | Egen OpenAI-kompatibel endpoint (LM Studio/vLLM/DGX) · *Advanced* |

**CLI-providere** (`Sources/VaraCore/Intelligence/CLIChatClient.swift`) — shell-out til allerede installerede & autentificerede kode-CLI'er. **Ingen API-nøgle** (bruger dit eget abonnement). Reasoning tvinges lavt pr. kald; ~6–16 s latency (vs. ~1 s for API) → cleanup-timeout hævet til 60 s med fallback til rå transskript. Vises kun i UI hvis binæren findes på PATH.

| Provider | Binær | Default model |
|---|---|---|
| `claudeCLI` — Claude Code (CLI) | `claude` | haiku |
| `codexCLI` — Codex (CLI) | `codex` | gpt-5.5 |
| `geminiCLI` — Gemini CLI | `gemini` | gemini-2.5-flash |

> Groq er zero-cost default for **begge** lag: én gratis nøgle fra console.groq.com låser både Whisper (STT) og Llama 3.3 (cleanup). Mode bliver Raw indtil en LLM findes; onboarding opgraderer til Clean text når en LLM er konfigureret.

**Credential-providere** (`App/Settings/KeychainCredentialStore.swift`): `elevenLabs`, `groq`, `openAI`, `anthropic`, `gemini` → env-navne `ELEVENLABS_API_KEY`, `GROQ_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`.

**Tiers** (`App/Settings/BackendMetadata.swift`) — handler om last-mile setup, ikke lokal-vs-cloud:
- *STT Recommended*: Groq + alle OpenAI-varianter · *Advanced*: ElevenLabs, Hviske, WhisperKit
- *LLM Recommended*: Groq, OpenAI · *Advanced*: Anthropic, Gemini, Ollama, custom, alle 3 CLI'er

---

## CLI (`vara`) — `Sources/VaraCLI/Vara.swift`

| Kommando | Funktion |
|---|---|
| `vara transcribe <fil>` | Transskriber lydfil. Flags: `--backend` (scribe/scribe-batch), `--language`, `--remove-fillers`, `--tag-audio-events`, `--diarize` |
| `vara dictate` | Hold Right Option → optag, slip → transskriber, Ctrl+C for at stoppe |

---

## Hvad ser brugeren i UI'et?

### 1. Menubar-ikonet
Et mikrofon-ikon i menulinjen. Skifter til `mic.fill` + label "Vara •" under optagelse — ellers "Vara" (`App/VaraApp.swift`).

### 2. Menubar-popover (348 px bred) — `App/MenuBarContent.swift`
- **Status-header** — farvet prik (grå=idle, ember=optager, gylden=forging) + "Vara" + statustekst
- **Mode quick-switch** — én ikon-knap pr. mode; valgt highlightes; modes uden nøgle viser `key.slash` (klik → Settings). Aktiv modes navn til højre
- **Stor Start/Stop-knap** — "Start dictation" / "Stop dictation"
- **Latest** — seneste transskript med kopi-knap (kun hvis "behold seneste" er slået til)
- **Recent** — de 3 nyeste fra historikken, med kopi + geninsæt ved hover
- **Fejlbesked** (rød, hvis noget gik galt)
- **Footer** — "Brokk & Sindre"-link, *Open Vara*, *Settings*, *Diagnostics*, *Quit* (⌘Q)

### 3. Det flydende HUD — `App/HUD/RecordingHUDView.swift`
Lille lyst glaspanel (312×96) ved markøren. Altid lyst (matcher vara.dk), uanset system-tema.

| Fase | Hvad brugeren ser |
|---|---|
| **Optager** | "Vara is listening …", live waveform, pulserende prik, medløbende timer (0:07), mode-chip, hint **"Release · Esc · 1–9"**, luk-kryds |
| **Forging** | "Vara is forging the text …", frosset waveform + spinner, hammer-ikon, hint **"Esc · cancel"** |
| **Indsat** | "N words inserted" + grønt flueben + preview af teksten |
| **Hørte intet** | "Vara heard nothing" + måne-ikon + hint |
| **Annulleret** | "Cancelled" |
| **Fejl** | "Vara hit a snag" + advarselstrekant + besked |

### 4. Hovedvinduet (860×620)
Første gang: **onboarding** (`App/Onboarding/OnboardingView.swift`, `VaraOnboarding.swift`) — et guidet flow på 8 trin:

1. **Welcome** — staged reveal + breathing-medaljon
2. **Permissions** — mikrofon + accessibility
3. **Engine** — privacy-first motor-vælger; WhisperKit er forvalgt (lokal, offline, ingen nøgle), derefter Hviske, Groq (gratis), OpenAI, ElevenLabs
4. **Setup** — viser KUN den valgte motors opsætning (WhisperKit-download / Hviske-kommando / inline nøglefelt + get-key-link)
5. **Mode** — tekst-cleaner-vælger med før→efter-eksempler under Clean text, Professional og VibeCode (Clean text anbefalet, adaptivt → Raw hvis ingen LLM)
6. **AI** — cleanup-AI-vælger; vises kun når en AI-mode er valgt OG motoren ikke selv har en LLM. Privacy-first orden (Ollama hvis nåbar → custom → installerede CLI'er → Groq/OpenAI/Anthropic/Gemini), CLI + ekstra-cloud bag "More options"
7. **Ready** — recap med "Runs entirely on this Mac"-badge når STT + cleanup er fuldt lokal
8. **Try it** — afprøv en rigtig diktering (success registreres kun ved faktisk diktering, ikke ved at skrive)

Skip er tilgængelig på hvert trin; gating er motor-bevidst (cloud-nøgle gemt / WhisperKit-model hentet / Hviske klar / Raw).

Bagefter: **Dashboardet** (`App/VaraDashboardView.swift`):

- **Hero** — status-orb, "Vara", statustekst, genvejstaster som key caps + "Hold — speak — release"
- **Advarsler** — vises kun når noget mangler: mikrofon-adgang, accessibility-adgang (knapper åbner Systemindstillinger / beder om adgang), fejl
- **Mode-vælger** — chips med numre 1–9 + tip om ciffer-override under diktering
- **Stats** — 4 kort: *Words today*, *This week*, *Time saved*, *Avg. per dictation*
- **Try it** — scratchpad-tekstboks til at afprøve diktering med det samme
- **History** — søgefelt + ryd-knap, grupperet pr. mål-app (foldbar), rækker kan foldes ud (rå vs. renset tekst) med kopi / geninsæt / slet ved hover
- **Footer** — "Forged by Brokk & Sindre"

### 5. Settings-vinduet — `App/Settings/VaraSettingsView.swift`
Sidebar med 6 sektioner: **Dictation · Engine · Intelligence · Advanced · Privacy · About** (detaljer ovenfor).

### 6. Diagnostics-vinduet (640×420)
Separat fejlsøgningsvindue (`App/DiagnosticsView.swift`), åbnes fra menubar-footeren.

---

## Nøglefiler (hurtig reference)

| Område | Fil |
|---|---|
| App-entry / vinduer | `App/VaraApp.swift` |
| Tilstand & diktering | `App/AppState.swift`, `App/AppState+Dictation.swift`, `App/AppState+Hotkey.swift`, `App/AppState+History.swift` |
| Settings-model | `App/Settings/SettingsModel.swift`, `SettingsEnums.swift`, `SettingsStore.swift` |
| Settings-UI | `App/Settings/VaraSettingsView.swift` (+ `EngineCard`, `ModeEditorView`, `AppRulesSection`, `CustomEndpointsSection`, `LocalHviskeSection`, `WhisperKitModelSection`) |
| Modes & LLM-providere | `Sources/VaraCore/Intelligence/DictationMode.swift` |
| Chat-klienter | `Intelligence/{OpenAICompatibleChatClient,AnthropicChatClient,CLIChatClient}.swift`, `Process/Subprocess.swift` |
| Engine/provider-metadata & tiers | `App/Settings/BackendMetadata.swift` |
| Credentials | `App/Settings/KeychainCredentialStore.swift` (Keychain + `~/.vara/.env`) |
| Cleanup | `Sources/VaraCore/TranscriptCleanup/` |
| HUD | `App/HUD/RecordingHUDView.swift`, `RecordingHUDWindowController.swift` |
| Dashboard | `App/VaraDashboardView.swift` |
| Onboarding | `App/Onboarding/OnboardingView.swift`, `VaraOnboarding.swift` |
| CLI | `Sources/VaraCLI/Vara.swift` |

> Dybere navigation: se `graphify-out/wiki/index.md` (78 artikler) eller kør `graphify query "<spørgsmål>"`.
