# Releasing SmartEars to TestFlight

A complete, ordered guide to getting SmartEars onto TestFlight. Split into
**one-time setup** (do once, ever) and **every-build steps**.

Project facts used below:
- **Bundle ID:** `com.greatfallsventures.smartears`
- **Team ID:** `44W9XX2XF9`
- **Scheme:** `SmartEars`
- Export compliance is pre-answered (`ITSAppUsesNonExemptEncryption = NO` in
  `project.yml`), so uploads won't prompt for it.

> Always archive from the latest `main` so the build includes the most recent
> fixes.

---

## Part A — One-time setup

### 1. Prerequisites
- Paid **Apple Developer Program** membership.
- In **Xcode → Settings → Accounts**, sign in with `john@greatfallsventures.com`
  (team `44W9XX2XF9`). Required so automatic signing can create the distribution
  provisioning profile. *(This is the one step the CLI can't do for you.)*

### 2. Register the App ID
- Easiest: **skip it** — Xcode auto-registers `com.greatfallsventures.smartears`
  on the first archive.
- Manual: [developer.apple.com](https://developer.apple.com) → Certificates, IDs
  & Profiles → Identifiers → ➕ → App ID → bundle `com.greatfallsventures.smartears`.
- **Optional (live weather):** enable the **WeatherKit** capability on this App ID.
  No other capabilities are required.

### 3. Create the App Store Connect record
- [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps → ➕ →
  New App**
- Platform **iOS**, Name **SmartEars**, Bundle ID
  **`com.greatfallsventures.smartears`**, SKU `smartears`, full access.

### 4. (Optional) App Store Connect API key — for one-command CLI uploads
- App Store Connect → **Users and Access → Integrations → App Store Connect API
  → Generate API Key**, role **App Manager**.
- Download the `.p8` **once** (Apple never shows it again), then:
  ```bash
  mkdir -p ~/.appstoreconnect/private_keys
  mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/
  cp Config/asc.env.example Config/asc.env   # paste ASC_KEY_ID + ASC_ISSUER_ID
  ```
  `Config/asc.env` and `*.p8` are gitignored — they never get committed.

---

## Part B — Build & upload (pick one path)

### Path 1 — Xcode GUI (most reliable)
1. `xcodegen generate && open SmartEars.xcodeproj`
2. Top-bar destination → **Any iOS Device (arm64)** (not a simulator, or Archive
   is greyed out).
3. **Product → Archive** (~1–2 min).
4. Organizer → **Distribute App → App Store Connect → Upload → Next** (keep
   automatic signing) → **Upload**.

### Path 2 — One command (after Part A step 4)
```bash
scripts/testflight.sh release      # archive → sign → export → upload
```
Sub-commands: `scripts/testflight.sh archive` (build a signed `.ipa` only),
`scripts/testflight.sh upload` (upload an already-exported `.ipa`).

> CLI archiving needs your Apple ID in **Xcode → Settings → Accounts** (Part A
> step 1) so signing can mint the profile.

---

## Part C — Turn on testing in TestFlight

1. Wait ~5–15 min for **Processing** to finish (App Store Connect → **TestFlight**
   tab shows the build).
2. **Internal testers** (you + up to 100 team members) — **no Apple review**,
   installs immediately:
   - TestFlight → **Internal Testing** → create/select a group → add testers →
     enable the build.
3. **External testers** (up to 10,000 via email or a public link) — needs a quick
   **Beta App Review** (usually < a day) plus a "What to Test" note and a beta
   description.

---

## Part D — Testers install
- Tester opens the invite → installs the free **TestFlight** app → taps
  **Install** → opens SmartEars → grants mic/speech (and optionally notifications)
  → picks a wake word.
- **Tell testers:** Ask-AI / Stocks / News show "needs setup" until a key is added
  in **Settings → API Keys**; Weather needs the WeatherKit capability (Part A
  step 2). Speech, TTS, wake word, alerts UI, and compose sheets all work with no
  keys. (Full details in `docs/USER_GUIDE.md`.)

---

## Part E — Shipping updates later
1. Bump the build number in `project.yml` → `CURRENT_PROJECT_VERSION` (and
   `MARKETING_VERSION` for a new user-facing version).
2. `xcodegen generate`, then re-archive/upload (Part B).
3. Existing testers automatically get the new build.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No Account for Team "44W9XX2XF9"` | Sign in: Xcode → Settings → Accounts (Part A step 1) |
| `No profiles for '…smartears' were found` | First archive with automatic signing + signed-in account creates it; or add the App ID (Part A step 2) |
| Archive menu greyed out | Set destination to **Any iOS Device**, not a simulator |
| Upload rejected: missing icon | Already handled — `AppIcon` 1024px is in `Assets.xcassets` |
| Export-compliance prompt | Already handled — `ITSAppUsesNonExemptEncryption = NO` |
| Build stuck "Processing" > 1 hr | Usually transient; check email for an Apple rejection notice |

---

## Part F — Automated path (Xcode Cloud + API) — RECOMMENDED

This is how SmartEars actually ships today: **Xcode Cloud signs in the cloud**
(no local signing certificate or Xcode account needed) and delivers to TestFlight
on every push to `main`. You can also trigger and monitor builds entirely from the
command line with the App Store Connect API — no Xcode, no GUI.

### Why this path
The local/GUI path needs a logged-in Xcode account + a distribution certificate.
Command-line `xcodebuild` can't reach the GUI's keychain session (you'll see
`No Account for Team`), so headless local archiving is unreliable. Xcode Cloud
sidesteps all of it — signing happens on Apple's infrastructure.

### One-time setup
1. **App Store Connect API key** (account-wide; the same key works for every app):
   App Store Connect → Users and Access → Integrations → App Store Connect API →
   Generate API Key (role **App Manager** or **Admin**). Download the `.p8` once:
   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
   ```
   Note the **Key ID** and the account **Issuer ID** (UUID at the top of the Keys page).
2. **Connect Xcode Cloud** for the app (once), in Xcode: Product → Xcode Cloud →
   Create Workflow. It needs an `.xcodeproj`/`.xcworkspace` after cloning — ours is
   generated by XcodeGen and gitignored, so **`ci_scripts/ci_post_clone.sh`**
   (already in the repo) runs `xcodegen generate` during the build. Without it the
   cloud build finds no project.
3. **Enable TestFlight delivery** on the workflow's Archive action — set
   **Deployment Preparation → TestFlight (Internal Testing)** (API field
   `buildDistributionAudience = INTERNAL_ONLY`). Without this the build archives
   but never reaches TestFlight.

### Ship a build
- **Easiest:** `git push origin main` — the workflow's branch start condition
  (`main`) auto-builds, cloud-signs, and delivers to TestFlight.
- **On demand (no Xcode):** trigger a build run via the API. The current values:
  - App Store Connect API: `https://api.appstoreconnect.apple.com`
  - Auth: ES256 JWT signed with the `.p8` (`iss`=Issuer ID, `aud`=`appstoreconnect-v1`, `kid`=Key ID, ≤20 min expiry)
  - Discover: `GET /v1/ciProducts` → product `SmartEars`; `GET /v1/ciProducts/{id}/workflows` → `Default`
  - Start a build: `POST /v1/ciBuildRuns` with `relationships.workflow` (+ optional
    `sourceBranchOrTag` → the `main` `scmGitReferences` id)
  - Poll: `GET /v1/ciBuildRuns/{id}` → `executionProgress` / `completionStatus`
  - Verify delivery: `GET /v1/builds?filter[app]={appId}&sort=-uploadedDate`
  - Point a build at testers: `POST /v1/betaGroups/{groupId}/relationships/builds`
    with `{"data":[{"type":"builds","id":"<buildId>"}]}`

### Known IDs (this app)
| Thing | Value |
|---|---|
| App (ASC) | `MySmartEars` · id `6778117624` · bundle `com.greatfallsventures.smartears` |
| Team | `44W9XX2XF9` |
| Xcode Cloud product | `AADE424E-76C1-4906-80B1-97B46D42996C` |
| Xcode Cloud workflow | `Default` · `04DF8957-8C94-4572-BEEC-E25F903441FE` |
| Internal beta group | `SmartEars` · `9b9853a4-0b0a-4fe2-ba08-82a7ef1c6363` |

### Gotchas we already hit (and fixed)
- **iPad orientation validation** — "Preparing build for App Store Connect failed"
  / "All interface orientations must be supported." Fixed by making the app
  **iPhone-only** (`TARGETED_DEVICE_FAMILY: "1"` in `project.yml`).
- **Cloud build of the wrong commit** — a *Rebuild* reuses the old commit; use
  **Start Build** (or push a new commit) to build latest `main`.
- **Reading TestFlight tester lists via API → 403** — depends on the API key's
  role; managing builds/groups still works. Use the App Store Connect UI to view
  testers if needed.
