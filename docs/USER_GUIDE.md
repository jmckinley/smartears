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
   - **Pick your wake word** — the phrase that starts a hands-free request. Default
     is **"Hey SmartEars"**; you can choose a suggestion or type your own.

---

## 2. Talking to SmartEars

There are two ways to start a request:

- **Tap the orb** on the main screen, then speak.
- **Say your wake word** (e.g. *"Hey SmartEars…"*) and then your request.

The orb shows what's happening: **calm** = idle, **pulsing** = listening,
**spinning** = thinking, **glowing** = speaking back to you.

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

- **In-ear detection** — SmartEars knows when your AirPods are in.
- **Press / gesture** — mapped to start a request or confirm an action. Configure
  the mapping in **Settings → Controls**.
- A quick **"yes"/"no"** by voice works anywhere a confirmation is needed.

---

## 5. Settings

- **API Keys** — paste keys to enable live data and AI (see below). Keys are stored
  in the iOS **Keychain** on your device only — never uploaded, never in iCloud.
- **Wake Word** — change your trigger phrase any time.
- **Alerts** — toggle smart alerting and manage your VIP senders.
- **Sources** — turn individual sources (Weather, Stocks, News, Email, Messages)
  on or off.

### Enabling live data & AI

Most features work **for free with no setup at all**:

| Feature | Source | Setup |
|---|---|---|
| **Weather** | Open-Meteo | None — just allow Location |
| **Stocks** | Yahoo Finance | None |
| **Breaking news** | Google News | None |
| **Ask-AI / conversation** | Anthropic | Paste an API key (Settings → AI & Accounts) |
| **Email (read/important)** | Gmail | Connect Gmail |

So weather, stocks, and news answer out of the box. Only **“ask the AI a
question”** needs a key — get one at [console.anthropic.com](https://console.anthropic.com)
and paste it in **Settings → AI & Accounts**. Keys live only in your device
Keychain.

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
| It doesn't hear me | Settings (iOS) → SmartEars → enable **Microphone** + **Speech Recognition** |
| Wake word never triggers | Open the app, re-pick your wake word; keep AirPods in |
| "Needs setup" on a request | Add that feature's API key in **Settings → API Keys** |
| No weather | Enable **Location** for SmartEars; weather needs WeatherKit enabled on the build |
| No alerts | Settings → Alerts → turn on smart alerting and allow Notifications |

---

*Questions or feedback? Reply right in TestFlight — it goes straight to the team.*
