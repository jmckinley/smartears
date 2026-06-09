# SmartEars — User's Guide

**Your AirPods, as a hands-free AI assistant.** SmartEars turns your AirPods into
"smart glasses without a camera" — you talk, it listens, and it answers out loud.
No screen-staring required.

---

## 1. Getting started

1. **Install** the SmartEars build from your TestFlight invite (open the link on
   your iPhone, install TestFlight if prompted, then tap *Install*).
2. **Put in your AirPods** (any model works; AirPods Pro/3 add the best controls).
3. **Open SmartEars** and complete the short onboarding:
   - **Grant Microphone + Speech Recognition** — required, or SmartEars can't hear
     you. (If you tap *Don't Allow* by accident, the app sends you to *Settings*
     to switch them back on.)
   - **Notifications** — optional; only needed for smart alerts.

Once onboarding is done you can talk to SmartEars right away — just **tap the orb**.
Your choices are remembered, so you won't see onboarding again on the next launch.

---

## 2. Talking to SmartEars

**Tap the orb** on the main screen, then speak. That's the one reliable way to
start a request today, and it works the moment your AirPods are connected.

The orb shows what's happening: **calm** = idle, **pulsing** = listening,
**spinning** = thinking, **glowing** = speaking back to you.

> **What about a "Hey SmartEars" wake word?** True always-listening wake words are
> reserved by iOS for Siri — no third-party app can run one in the background. A
> hands-free trigger (and AirPod head-gesture confirmation) is on our roadmap as an
> explicit, opt-in feature; until it ships reliably we'd rather not promise it. For
> now, tap-to-talk is the honest, dependable entry point. You can also **single-tap
> an AirPod** to start a request hands-free while SmartEars is open (see AirPod
> controls).

### Things to try

| You say | SmartEars does |
|---|---|
| "What's the weather?" | Speaks the current conditions for your location |
| "How's Apple stock doing?" | Reads the latest quote and % change |
| "What's the breaking news?" | Reads the top headlines |
| "Ask AI: explain compound interest" | Answers conversationally |
| "Text Mom I'm running late" | Opens a pre-filled message — you tap **Send** |
| "Email Jordan about the Q3 doc" | Opens a pre-filled email — you tap **Send** |

> **Why do I still tap Send?** Apple does not let any third-party app silently
> send texts or emails on your behalf — SmartEars fills everything in, you give
> the final tap. That's a privacy protection, not a bug.

---

## 3. Smart alerts (optional)

When enabled, SmartEars can **chime and read you a short summary** of *important*
incoming messages and emails — so you stay hands-free and heads-up.

- It rates importance from your **VIP list** (people you mark as important),
  urgency words ("urgent", "asap", "deadline"…), and tone.
- Turn it on/off and manage VIPs in **Settings → Alerts**.

> **Note:** iOS doesn't allow apps to read your Messages history. SmartEars surfaces
> what it's permitted to (notifications you route to it, and email via Gmail).

---

## 4. AirPod controls

When SmartEars is open and your AirPods are connected, you can start a request **without touching your phone**:

- **Single-tap** an AirPod (press the stem once) to start talking — SmartEars plays a quick earcon, opens the mic, and starts listening immediately. No wake word needed.
- **Double-tap** while SmartEars is answering to **interrupt** it (barge-in) and stop the reply.

> **Heads up — this takes over your AirPod taps.** To catch a tap the instant you make it, SmartEars has to become your iPhone's "now playing" app while it's open. That means **while SmartEars is in the foreground, an AirPod tap talks to SmartEars instead of play/pausing or skipping your music.** The moment you switch away from SmartEars, your taps go back to controlling music as usual. We don't lower or pause your music just for listening — only an actual request ducks it briefly. Prefer to keep your taps on music? Turn off **Settings → AirPod tap to talk** and use the on-screen orb instead.

> **A note on what iOS allows:** Apple doesn't expose raw AirPod stem-press or squeeze events to apps; the only way to hear a tap is to be the now-playing app and receive it as a media control. That's exactly what SmartEars does while it's open.

---

## 5. Settings

- **API Keys** — paste keys to enable live data and AI (see below). Keys are stored
  in the iOS **Keychain** on your device only — never uploaded, never in iCloud.
- **Alerts** — toggle smart alerting and manage your VIP senders.
- **Sources** — turn individual sources (Weather, Stocks, News, Email, Messages)
  on or off.

Your settings are saved on your device and restored automatically next time you
open the app.

### Enabling live data & AI

Most features work **for free with no setup at all**:

| Feature | Source | Setup |
|---|---|---|
| **Weather** | Open-Meteo | None — just allow Location |
| **Stocks** | Yahoo Finance | None |
| **Breaking news** | Google News | None |
| **Ask-AI / conversation** | Apple on-device AI (iOS 26) | None on iPhone 15 Pro+ |
| **Email (read/important)** | Gmail | Connect Gmail |

On a modern iPhone (15 Pro or newer, iOS 26), **even Ask-AI is free and key-free** —
it runs on Apple's on-device Foundation Models, fully private. On older devices,
paste an Anthropic key in **Settings → AI & Accounts** (get one at
[console.anthropic.com](https://console.anthropic.com)). Either way, weather,
stocks, and news need no setup. Keys live only in your device Keychain.

---

## 6. Privacy

- Speech is transcribed using Apple's on-device speech recognition where available.
- API keys live only in your device Keychain.
- SmartEars never auto-sends messages or email — you always tap Send.
- No analytics or data selling.

---

## 7. Troubleshooting

| Problem | Fix |
|---|---|
| It doesn't hear me | Settings (iOS) → SmartEars → enable **Microphone** + **Speech Recognition**; keep AirPods in and tap the orb before speaking |
| A phone call left it stuck | SmartEars now recovers automatically after calls and Siri; if it still seems stuck, tap the orb again |
| "Needs setup" on a request | Add that feature's API key in **Settings → API Keys** |
| No weather | Enable **Location** for SmartEars; weather needs WeatherKit enabled on the build |
| No alerts | Settings → Alerts → turn on smart alerting and allow Notifications |

---

*Questions or feedback? Reply right in TestFlight — it goes straight to the team.*
