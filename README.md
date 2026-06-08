# SmartEars

**An audio-first, voice-first iOS assistant that treats your AirPods as the wearable — like smart glasses without a camera or a display.**

You talk; SmartEars listens, thinks, and speaks back. The screen is secondary (setup, history, settings). The primary interface is your voice and your ears: a wake word, a spoken question, a spoken answer, and contextual follow-ups without re-triggering the wake word.

---

## The concept

- **Wear-and-forget.** AirPods become a hands-free assistant. Ask about the weather, a stock, the news, or have a quick conversation.
- **Always-listening pipeline.** `wake-word → STT → intent → tool → TTS`, with stop-on-silence, a max-utterance cap, and a follow-up window (Meta/Gemini-style) so you can keep talking without saying the wake word again.
- **Audible alerts.** Important messages/emails surface as an importance-scaled chime plus a short spoken summary.
- **Hands-free confirmation.** Before anything is sent, SmartEars reads it back and waits for "yes / no / change" — by voice or by an AirPods head **nod/shake**.
- **Runs with zero secrets.** Every external provider sits behind a protocol with a realistic **Mock** implementation, so the app compiles and runs immediately. Real network services switch on only when a credential resolves.

---

## Module map

| Module | Folder | Responsibility |
|---|---|---|
| **App** | `SmartEars/App` | Entry point, root SwiftUI scene, dependency wiring (`AppEnvironment`), config load, BGTask/audio-session setup. |
| **Models** | `SmartEars/Models` | **Single source of truth** for all cross-module types and service protocols (`Models.swift`). No other module redefines these. |
| **DesignSystem** | `SmartEars/DesignSystem` | Colors, typography, and the signature `AudioWaveformView` listening indicator. |
| **Voice** | `SmartEars/Services/Voice` | Wake word, STT, TTS, chimes, and the `VoiceSessionCoordinator` state machine. |
| **Gestures** | `SmartEars/Services/Gestures` | AirPods input via `MPRemoteCommandCenter`, audio route/port changes, and `CMHeadphoneMotionManager`. |
| **Assistant** | `SmartEars/Services/Assistant` | `IntentParser`, `ToolRouter`, `AssistantEngine`, conversation context, and the LLM service. |
| **Comms** | `SmartEars/Services/Comms` | Messaging (compose-only) and Gmail-backed email. |
| **Info** | `SmartEars/Services/Info` | Weather, stocks, news providers. |
| **Alerting** | `SmartEars/Services/Alerting` | Trigger evaluation → audible chime + spoken summary. |

> Only the **App**, **Models**, and **DesignSystem** modules plus the project scaffold ship in this foundation commit. The service modules conform to the protocols in `Models.swift`; until their live implementations land, `AppEnvironment` wires bundled stubs/mocks.

---

## How to build

This project uses [XcodeGen](https://github.com/yonyz/XcodeGen) — the `.xcodeproj` is generated from `project.yml` and is **gitignored**.

```bash
# 1. Install XcodeGen if needed
brew install xcodegen

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open and run
open SmartEars.xcodeproj
```

- **Deployment target:** iOS 17.0
- **Swift:** 5 with Swift Concurrency (targeted strict concurrency)
- Run on a device for real microphone/AirPods behavior; the simulator works for the UI and the mock pipeline (there's a "Tap to ask (simulated)" button that runs a full mock turn).

---

## Real vs. stubbed integrations

Every provider is behind a protocol in `Models.swift`. With **no credentials** present, the app uses the **Mock/Stub** implementations wired in `AppEnvironment.swift` (look for the `MOCK` badge in the top bar). When a credential resolves, a `ServiceFactory` swaps in the real network implementation — **without changing any call site**.

| Capability | Protocol | Status today | Real path |
|---|---|---|---|
| Conversation / intent fallback | `LLMService` | **Stub** (canned replies) | HTTP via `URLSession` (`SE_LLM_API_KEY`) |
| Weather | `WeatherService` | **Stub** sample | HTTP (`SE_WEATHER_API_KEY`) + CoreLocation |
| Stocks | `StockService` | **Stub** sample | HTTP (`SE_STOCKS_API_KEY`) |
| News | `NewsService` | **Stub** sample | HTTP (`SE_NEWS_API_KEY`) |
| Email read/send | `EmailService` | **Stub** sample | **Gmail REST API + OAuth** (`SE_GMAIL_CLIENT_ID`) |
| Send SMS/iMessage | `MessageComposeService` | **Compose-only** | `MFMessageComposeViewController` (user taps Send) |
| Inbound messages | `MessageInboxService` | **Stub** sample | Notifications you route + Gmail + share |
| Speech-to-text | `SpeechRecognizing` | **Stub** | `SFSpeechRecognizer` |
| Text-to-speech | `SpeechSynthesizing` | **Stub** (no-op) | `AVSpeechSynthesizer` |
| Wake word | `WakeWordEngine` | **Stub** | `SFSpeechRecognizer` phrase-match / bundled KWS |
| AirPods gestures | `GestureService` | **Stub** | `MPRemoteCommandCenter` / route changes / `CMHeadphoneMotionManager` |
| Chimes | `ChimeService` | **Stub** (no-op) | Bundled audio |
| Contacts | `ContactResolving` | **Stub** | `CNContactStore` |

### Honest Apple-platform limitations (baked into the types and comments)

- **Third-party apps cannot read the system Messages (SMS/iMessage) database** or arbitrary Mail.app content — there is no public API. Inbound provenance is modeled explicitly by `InboundMessageSource` (`gmailAPI` / `userNotification` / `manualShare` / `simulated`).
- **Outbound SMS/iMessage and Apple Mail are compose-only.** The user must tap **Send** in the system sheet; this is surfaced as `SmartEarsError.userActionRequired`. The app can never silently auto-send those.
- **Gmail** (REST API + OAuth) is the only third-party channel with full inbound email bodies.
- **Raw AirPods stem-press events are not exposed.** Gestures are reconstructed realistically from transport commands, audio route changes, and head-motion — head nod/shake works only on supported AirPods.
- **Fully-custom, always-on, on-device keyword spotting** is limited for third parties on iOS; the wake word is a phrase-match approximation, not a first-party "Hey Siri"-class model.

---

## Where API keys go (no secrets in source)

1. Create a **gitignored** xcconfig (e.g. `Config/Secrets.xcconfig`) — it is **not** committed.
2. Add your keys:
   ```
   SE_LLM_API_KEY     = your_llm_key
   SE_WEATHER_API_KEY = your_weather_key
   SE_STOCKS_API_KEY  = your_stocks_key
   SE_NEWS_API_KEY    = your_news_key
   SE_GMAIL_CLIENT_ID = your_gmail_oauth_client_id
   ```
3. Uncomment the `configs:` block in `project.yml` so the xcconfig is applied, then re-run `xcodegen generate`.

These flow into `Info.plist` placeholder keys (`$(SE_LLM_API_KEY)` …). At runtime, `AppConfig.load()` reads them; **empty or unresolved `$(...)` values are treated as absent**, so the app cleanly falls back to Mock services. Keys are never hardcoded in source, and runtime secrets belong in the **Keychain**.

> `.gitignore` already excludes the generated `SmartEars.xcodeproj/`, `*.env`, and `Secrets.plist`. Keep your real `Config/Secrets.xcconfig` gitignored too.
