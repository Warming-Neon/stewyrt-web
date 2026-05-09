# Stewyrt — Master Context & Project Map

## What This App Is

Stewyrt is an anonymous, audio-only social sentiment platform. Users record short voice responses to poll questions. A Cloud Function transcribes and emotionally analyses the audio via Gemini and writes the result back to Firestore.

**"The Zeitgeist" is an umbrella term** covering all collective-sentiment views. The three named views under it are:

| View | Description |
|------|-------------|
| **The Pulse** | Live feed of incoming responses for the current active question |
| **The Resonance** | 3D WebGL brain visualiser showing the emotional web for a specific question |
| **The Archive** | Library of past/closed questions |

**Platforms:** iOS, Android, Flutter Web  
**Dart SDK:** `^3.11.1`  
**Flutter:** 3.41.4 (stable)

---

## Project File Map

```
stewyrt/
├── lib/
│   ├── main.dart                         — App entry, RootShell, bottom nav
│   ├── firebase_options.dart             — Generated Firebase config
│   │
│   ├── screens/
│   │   ├── pulse_screen.dart             — Tab 1: swipeable polls + live feed (The Pulse)
│   │   ├── zeitgeist_screen.dart         — Tab 2: platform router (loads web or native screen)
│   │   ├── zeitgeist_web_screen.dart     — Tab 2 web: 3D brain (The Resonance) via HtmlElementView iframe
│   │   ├── zeitgeist_native_screen.dart  — Tab 2 iOS/Android: 3D brain (The Resonance) via webview_flutter
│   │   ├── onboarding_screen.dart        — Demographics collection + voice verification
│   │   └── day_one_screen.dart           — Standalone first-question screen
│   │
│   ├── widgets/
│   │   ├── recording_sheet.dart          — Record / preview / submit bottom sheet
│   │   ├── sentiment_stream.dart         — Live scrolling response feed + feed player
│   │   ├── poll_card.dart                — Swipeable poll question card
│   │   ├── audio_player_widget.dart      — Reusable audio player UI
│   │   └── sentiment_expanded_sheet.dart — Expanded detail sheet for a response
│   │
│   ├── services/
│   │   ├── firestore_service.dart        — listenForResult() with timeout + moderation check
│   │   ├── storage_service.dart          — uploadAudioClip(), uploadOnboardingAudio() — uses putData + conditional import for web compat
│   │   ├── upload_bytes_io.dart          — Native impl: File.readAsBytes()
│   │   ├── upload_bytes_web.dart         — Web impl: fetch() + arrayBuffer() via dart:js_interop
│   │   ├── auth_service.dart             — signInAnonymously()
│   │   └── zeitgeist_controller.dart     — Static coordinator: tab switching + focus callbacks
│   │
│   ├── models/
│   │   └── sentiment_data.dart           — Mock/seed sentiment data
│   │
│   ├── theme/
│   │   ├── app_theme.dart                — Light/dark ThemeData, Space Grotesk text theme
│   │   └── theme_notifier.dart           — ChangeNotifier toggle for dark/light mode
│   │
│   └── utils/
│       └── limiter.dart                  — SoftLimiter: dBFS soft-knee compression for waveform display
│
├── web/
│   ├── brain_visualizer.html             — Self-contained Three.js 3D brain (The Resonance)
│   ├── privacy.html                      — Privacy & Ethical Usage Policy (GDPR/UK PECR compliant)
│   ├── terms.html                        — Terms of Service (England & Wales, 18+ gate)
│   ├── index.html                        — Flutter web bootstrap (generated)
│   ├── manifest.json                     — PWA manifest (generated)
│   ├── favicon.png
│   └── icons/                            — PWA icons (generated)
│
├── functions/
│   └── src/index.ts                      — Cloud Function: analyzeAudio (Storage trigger)
│
├── assets/
│   └── icon/stewyrt_icon.png
│
├── pubspec.yaml
├── analysis_options.yaml
└── firebase.json
```

---

## Navigation & Shell

`main.dart` → `RootShell` → `IndexedStack` with two tabs:

| Index | Label | Screen |
|-------|-------|--------|
| 0 | The Pulse | `PulseScreen` |
| 1 | The Zeitgeist | `ZeitgeistScreen` (routes to web or native internally) |

`_screens` uses `const ZeitgeistScreen()` for both platforms. The routing happens inside `zeitgeist_screen.dart` via a conditional import — **not** via `kIsWeb` in `main.dart`.

Bottom nav: centred tab pair + right-side theme toggle icon. Theme state via `ThemeNotifier` (Provider).

`ZeitgeistController` is a static service registered in `_RootShellState.initState()`:
- `registerTabSwitcher(fn)` — called by `RootShell` to allow any screen to switch tabs
- `registerFocus(fn)` / `unregisterFocus()` — called by the active Resonance screen
- `goToZeitgeistAndFocus(tag)` — public API: switches to tab 1 then fires the focus callback

Tapping a Tone/Flavor/Essence chip in the Pulse feed calls `ZeitgeistController.goToZeitgeistAndFocus(word)`, which switches to The Resonance and camera-tweens to that synapse.

---

## Platform Router (`zeitgeist_screen.dart`)

```dart
import 'package:flutter/material.dart';
import 'zeitgeist_native_screen.dart'
    if (dart.library.js_interop) 'zeitgeist_web_screen.dart';

class ZeitgeistScreen extends StatelessWidget {
  const ZeitgeistScreen({super.key});
  @override
  Widget build(BuildContext context) => const ZeitgeistPlatformScreen();
}
```

- Uses `dart.library.js_interop` (TRUE on web, FALSE on iOS/Android) — **not** `dart.library.io` which is TRUE on both native and web in Dart 3.11.
- `zeitgeist_web_screen.dart` declares `typedef ZeitgeistPlatformScreen = ZeitgeistWebScreen;`
- `zeitgeist_native_screen.dart` declares `class ZeitgeistPlatformScreen` directly
- The iOS compiler never sees `dart:js_interop` or `dart:ui_web` imports — they stay inside the web file

---

## Running Flutter Web

Web support must be enabled once per machine:
```
flutter config --enable-web
flutter create --platforms=web .   # scaffolds web/index.html etc. (run once)
```

Run command:
```
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

Open in any browser at `http://localhost:8080`.

**Asset bundling:** `pubspec.yaml` must list `- web/brain_visualizer.html` (not `- web/`) to avoid bundling `web/index.html` as a Flutter asset, which breaks the web bootstrap.

---

## Firebase / Firestore Schema

### `responses` collection
| Field | Type | Notes |
|-------|------|-------|
| `uuid` | String | Upload UUID (filename without extension) |
| `audioPath` | String | `audio_uploads/<uuid>.m4a` |
| `tone` | String | Single emotion word (e.g. "Furious") |
| `flavor` | String | Nuance word (e.g. "Bitter") |
| `essence` | String | Philosophical adjective (e.g. "Resigned") |
| `summary` | String | 3–4 word content headline |
| `analysis_chain` | String | Gemini reasoning chain |
| `anatomicalRegion` | String | Brain region: `Prefrontal` / `Amygdala` / `Nucleus` / `Insula` |
| `toneRegion` | String | Mirror of `anatomicalRegion` — used by Flutter aggregator for tone word |
| `flavorRegion` | String | Mirror of `anatomicalRegion` — used by Flutter aggregator for flavor word |
| `essenceRegion` | String | Mirror of `anatomicalRegion` — used by Flutter aggregator for essence word |
| `question` | String | Poll question text |
| `pollId` | String | Parent poll document ID |
| `language` | String | ISO 639-1 code detected by Gemini (e.g. `"en"`, `"es"`, `"fr"`); defaults to `"en"` |
| `blocked` | Boolean | `true` if content moderation triggered |
| `blockedReason` | String | e.g. `"content_policy"` |
| `createdAt` | Timestamp | Server timestamp |

**Note:** All three `*Region` fields carry the same value as `anatomicalRegion`. The Flutter aggregator votes across many responses per question to find the dominant region for each recurring emotion word.

### `polls` collection
| Field | Type | Notes |
|-------|------|-------|
| `question` | String | Prompt shown to user |
| `category` | String | UI category label |
| `topic` | String | Topic string shown in live feed header |
| `isActive` | Boolean | Only active polls appear in swiper |
| `createdAt` | Timestamp | For ordering |
| `total_submissions` | Number | Incremented on each response |
| `counts.tone.*` | Number | Per-word tone counts |
| `counts.flavor.*` | Number | Per-word flavor counts |
| `counts.essence.*` | Number | Per-word essence counts |

### `users` collection (onboarding verification)
| Field | Type | Notes |
|-------|------|-------|
| `claimedAge/Gender/Ethnicity/Region` | String | Self-reported demographics |
| `confidenceScore` | Number | 0–100 acoustic match score |
| `isFlagged` | Boolean | True if Gemini suspects bot/mismatch |
| `verificationNote` | String | 1-sentence Gemini explanation |
| `verifiedAt` | Timestamp | |

### Storage paths
- `audio_uploads/<uuid>.m4a` — poll responses
- `audio_uploads/onboarding_<uuid>.m4a` — verification clips (deleted after processing)

---

## Firestore Query Rules (STRICT)

**The Resonance query MUST always be scoped to a specific poll. Never query `responses` globally.**

```dart
FirebaseFirestore.instance
  .collection('responses')
  .where('pollId', isEqualTo: currentPollId)
  .orderBy('createdAt', descending: true)
  .limit(300)
  .snapshots()
```

The live feed (The Pulse) uses limit 30 without a `pollId` filter (it shows the global stream). The Resonance always uses limit 300 with a `pollId` filter.

---

## Co-occurrence Data Engine (The Resonance)

The Flutter aggregator (`_processSnapshot`) produces two outputs from the scoped `responses` query:

**Nodes** — one entry per unique emotion word seen across all docs:
```dart
{ 'name': word, 'percent': (count / totalTags * 100), 'region': dominantRegion }
```

**Edges** — co-occurrence pairs only. An edge exists **only** if two sentiment words appeared in the exact same Firestore response document (e.g. Tone "Furious" and Flavor "Bitter" in the same doc). The edge weight is the number of documents where that pair co-occurred.

```dart
// For each doc, collect the 2–3 words (tone, flavor, essence).
// For every unique pair in that doc, increment edgeWeights['wordA|wordB'].
final pair = [words[i], words[j]]..sort();
edgeWeights['${pair[0]}|${pair[1]}'] = (edgeWeights[key] ?? 0) + 1;
```

**Payload sent to Three.js:**
```json
{
  "nodes": [{ "name": "Furious", "percent": 8.5, "region": "Amygdala" }],
  "edges": [{ "source": "Furious", "target": "Bitter", "weight": 12 }]
}
```

Three.js draws `CatmullRomCurve3` paths **only** from the explicit `edges` array. There is no proximity-based or random connection logic.

---

## Cloud Function: `analyzeAudio` (`functions/src/index.ts`)

**Trigger:** `onObjectFinalized` on `audio_uploads/` in `stewyrt-11.firebasestorage.app`

**Routing on filename prefix:**
- `onboarding_*` → Demographic Acoustic Verification flow
- Everything else → Sentiment Analysis flow

**Sentiment flow:**
1. Download file to `/tmp/`
2. Base64-encode and send to `gemini-2.5-flash` with a structured prompt
3. Content moderation check first — if `blocked: true` returned, write `{ blocked: true, blockedReason: "content_policy" }` to `responses/{responseId}` and exit
4. Otherwise, run transaction: write full analysis to `responses/{responseId}` + increment `polls/{pollId}` counters
5. Delete temp file

**Gemini prompt steps (sentiment):**
1. `tone` — single-word overarching emotional state
2. `flavor` — single-word nuance of that tone
3. `essence` — single-word philosophical adjective
4. `summary` — 3–4 word content headline (what they argued, not how they felt)
5. `anatomicalRegion` — exactly one of `"Prefrontal"` / `"Amygdala"` / `"Nucleus"` / `"Insula"`:
   - **Prefrontal:** complex, societal, reflective thought — irony, disillusionment, curiosity, conflict
   - **Amygdala:** primal, intense emotions — fury, panic, fear, defeat, desperation
   - **Nucleus:** reward, hope, joy, inspiration, gratitude, positive motivation
   - **Insula:** disgust, numbness, deep melancholy, alienation, visceral unease

**Expected JSON from Gemini:**
```json
{ "tone": "Word", "flavor": "Word", "essence": "Word", "summary": "Content headline", "anatomicalRegion": "Region" }
```

**Verification flow:**
1. Same audio ingest
2. Gemini acoustic check against claimed age/gender
3. Delete audio from bucket immediately (consent promise)
4. Write `{ confidenceScore, isFlagged, verificationNote, ... }` to `users/{uuid}`

**Secret:** `GEMINI_API_KEY` in Google Cloud Secret Manager

---

## Recording Sheet State Machine (`recording_sheet.dart`)

```
idle → recording → previewing → waiting → results
                                        ↓
                                     blocked
```

- **idle:** press-and-hold button
- **recording:** live waveform (`_LiveWaveformPainter`, 60 bars, 50ms amplitude polling), 30s hard cutoff, `SoftLimiter` applied to each dBFS sample
- **previewing:** playback player with `_PlaybackWaveformPainter`, re-record / submit
- **waiting:** rotating story phrases (4 acts × random lines), `_phraseTimer` at 800ms
- **results:** staggered `AnimatedOpacity` reveal — tone (0ms), flavor (400ms), essence (800ms), summary (1400ms), Done button (1900ms)
- **blocked:** moderation rejection with community guidelines text

**Production toggle:** `_kProductionMode` (currently `false`). When `true`: one response per user per poll, old doc deleted before listener attaches to prevent stale-result bug.

---

## Boot Router (`boot_router.dart`)

Shown on app launch. Calls `AuthService.signInAnonymously()` then reads `SharedPreferences` to route:

| State | Destination |
|-------|-------------|
| `hasPassedBouncer = false` | `OnboardingScreen` |
| `hasPassedBouncer = true`, `hasCompletedDayOne = false` | `DayOneScreen` |
| Both true | `RootShell` |

On web, a compliance `SnackBar` is shown via `addPostFrameCallback` — summarises mindful usage, AI fallibility, and cookie notice. The entire `_init()` is wrapped in try/catch; a connection-error snackbar is shown if Firebase init fails.

---

## Onboarding Screen (`onboarding_screen.dart`)

Demographics collection + voice verification. Age gate: **18 years or older**.

Consent checkboxes use `InlineSpan` labels (`_SharpCheckbox` takes `InlineSpan`, not `String`). The Terms of Service and Privacy Policy labels are tappable links — `TapGestureRecognizer` opens `stewyrt.com/terms.html` and `stewyrt.com/privacy.html` via `url_launcher`. Recognizers are disposed in `dispose()`.

Audio path: `kIsWeb ? '' : getTemporaryDirectory().path/onboarding_<ts>.m4a`. Web uses the empty-path fetch path in `upload_bytes_web.dart`.

---

## Firestore Service (`firestore_service.dart`)

`FirestoreService.listenForResult(responseId, onResult, { onBlocked, onTimeout })`:
- Attaches a doc snapshot listener on `responses/{responseId}`
- Starts a `Timer` (default 120s) — calls `onTimeout` if Cloud Function never responds
- Waits until all four fields (`tone`, `flavor`, `essence`, `summary`) are present
- Checks `blocked` field first; if true, calls `onBlocked(reason)`
- Cancels timer on success or block

---

## Storage Service (`storage_service.dart`)

**Platform-safe upload:** Both methods use `readPathAsBytes(path)` from a conditional import (`upload_bytes_io.dart` on native, `upload_bytes_web.dart` on web) and call `ref.putData(bytes)`. This replaces the previous `dart:io File` + `ref.putFile()` approach which did not compile on web. On web, `localFilePath` is an empty string and bytes are fetched via `window.fetch()`.

**`uploadAudioClip(localPath, uuid, question, pollId, responseId)`**
- Uploads to `audio_uploads/<uuid>.m4a` as `audio/mp4`
- Metadata: `question`, `pollId`, `responseId` + optional extras
- Logs progress every 25%
- Returns download URL

**`uploadOnboardingAudio(localPath, uuid, { claimedAge, claimedGender, claimedEthnicity, claimedRegion })`**
- Uploads to `audio_uploads/onboarding_<uuid>.m4a`
- No download URL returned (file deleted by Cloud Function after verification)

---

## The Resonance — 3D Brain (All Platforms)

All platforms render The Resonance using `web/brain_visualizer.html` — a self-contained Three.js app.

**Web** (`zeitgeist_web_screen.dart`): loaded inside an `HTMLIFrameElement` registered as a Flutter platform view (`HtmlElementView`). Flutter posts data via `iframe.contentWindow.postMessage`.

**iOS/Android** (`zeitgeist_native_screen.dart`): loaded via `webview_flutter` (`WebViewController.loadFlutterAsset('web/brain_visualizer.html')`). Flutter injects data via `runJavaScript("updateBrainDataNative(...)")`.

### Web Screen Key Details

**Key statics** (survive hot-reload and state recreation):
- `_viewRegistered` — prevents double-registration of the `'brain-view'` factory
- `_iframe` — direct reference to the `HTMLIFrameElement`
- `_pendingPayload` — last serialised JSON; replayed on iframe `'load'` event
- `_pendingFocusTag` / `_iframeLoaded` / `_focusFired` — focus delivery coordination

**Timing:** Firestore resolves in <1s; Three.js CDN loads in 2–5s. The `'load'` event on the iframe replays `_pendingPayload` so nodes always appear even when Firestore wins the race.

### Native Screen Key Details

- `_pageLoaded` is set **only** when `BrainChannel.postMessage('ready')` fires from JS — not on `onPageFinished`, which fires before Three.js CDN imports complete.
- `_pendingJson` and `_pendingFocusTag` buffer data that arrives before the page is ready.
- `setOnConsoleMessage` mirrors all `[BRAIN]` console logs to Flutter's debug console.
- `addJavaScriptChannel('BrainChannel', ...)` must be registered **before** `loadFlutterAsset`.

```dart
void _inject(String jsonString) {
  _controller.runJavaScript(
    "if (typeof updateBrainDataNative === 'function') {"
    "updateBrainDataNative(${jsonEncode(jsonString)});"
    "}",
  );
}
```

---

## brain_visualizer.html — Three.js WebGL (The Resonance)

**Tech:** Three.js r0.161.0 via importmap, `EffectComposer`, `UnrealBloomPass`, `OrbitControls`

**Nodes are fully dynamic — none are hardcoded.** All emotion synapse nodes are created at runtime from the Flutter message bridge.

**120 filler synapse nodes** are created on load at low emissive intensity to give the scene volume before data arrives.

### Node Anatomy (Organic Synapses)

Each emotion node is a `THREE.Group` at world-space position containing two meshes:

- **Core** — `IcosahedronGeometry` at 40% of the node radius. `MeshBasicMaterial({ color: 0xffffff })` — pure white, punches through bloom as a blinding glowing centre.
- **Membrane** — `IcosahedronGeometry` at full radius, vertices randomly displaced ±6% for organic deformation. `MeshStandardMaterial` with the region's hue, `transparent: true`, `opacity: 0.55`. `emissiveIntensity` starts at 1.5 (birth flash) and decays to 0.2 baseline over ~1s.

Scale encodes percentage: `pct 0–50 → group scale 0.7–3.0`.

### State Maps

- `nodeMeshes` — membrane `THREE.Mesh[]` for raycaster + animation loop
- `nodeDataMap` — `mesh.uuid → emotion data` (both core and membrane registered for raycasting)
- `nodesByName` — `name → emotion data` for O(1) existence check
- `pathObjects` — `{ curve, line, activePulses[] }[]` for animation loop

### Region Coordinate Bounds

| Region | X | Y | Z |
|--------|---|---|---|
| Prefrontal | −8 → +8 | −1 → +8 | +2 → +12 |
| Amygdala | −6 → +6 | −8 → −2 | −8 → +2 |
| Nucleus | −6 → +6 | 0 → +8 | −6 → +4 |
| Insula | ±8 → ±16 (alternates sides) | −5 → +5 | −5 → +5 |

### Region Hue Palette (THREE.Color HSL)

| Region | Hue range | Colours |
|--------|-----------|---------|
| Prefrontal | 0.61–0.78 | Blues → purples |
| Amygdala | 0.00–0.10 | Reds → oranges |
| Nucleus | 0.19–0.36 | Yellows → greens |
| Insula | 0.44–0.56 | Teals → cyans |

### On New Emotion

1. `createNode(name, pct, region)` — picks random collision-checked position in region bounds, builds Group (core + membrane), registers in all three maps
2. `updateCameraAnchor()` — recentres OrbitControls target on the centroid of all nodes

### On Existing Emotion Update

- Rescale group (`pct 0–50 → scale 0.7–3.0`)
- Spike membrane `emissiveIntensity` to 1.5, reset `_flashTime` to 0

### Paths & Speedy Fuses

Paths are **only** created from the explicit `edges` array in the Flutter payload. There is no proximity-based or random connection logic.

Each edge becomes a `CatmullRomCurve3` with a random midpoint offset, rendered as a dim `LineBasicMaterial` line (`opacity` scales with edge weight: `w=1 → 0.10`, `w=10 → 0.41`, max 0.55).

**Speedy Fuses:** Each path fires a cluster of 1–3 fast comets at random intervals (2–8s). Comets traverse the full path in ~0.8–1.6s (`emissiveIntensity: 4.0`). `clearPaths()` removes all lines and active comets from the scene before rebuilding from a new payload.

### Message Bridge

Two entry points — both call the shared `processBrainData(data)` function:

```javascript
// Native: called via runJavaScript()
window.updateBrainDataNative = function(jsonString) { processBrainData(JSON.parse(jsonString)); };

// Web: called via postMessage from Flutter iframe host
window.addEventListener('message', e => { processBrainData(typeof e.data === 'string' ? JSON.parse(e.data) : e.data); });
```

`processBrainData` handles two payload shapes:
- `{ focus: 'NodeName' }` → camera tween to that node, show tooltip
- `{ nodes: [...], edges: [...] }` → create/update nodes, rebuild edges

**Ready signal:** `if (typeof BrainChannel !== 'undefined') BrainChannel.postMessage('ready')` fires at the end of the module script. This is a no-op in a browser; in `webview_flutter` it signals Flutter that Three.js is fully initialised.

### Interaction

- `Raycaster` click on membrane or core → `#tooltip` div (black bg, off-white Space Grotesk, 1px white border)
- `focusOnNode(name)` — programmatic camera tween (`_focusTween` state, 1.2s cubic ease-in-out), opens tooltip at tween end
- Clicking empty space hides tooltip

---

## Theme System (`app_theme.dart`)

| Token | Dark | Light |
|-------|------|-------|
| Background | `#000000` | `#FFFFFF` |
| Surface | `#0A0A0A` | `#F5F5F5` |
| Primary text | `#F5F5F5` | `#000000` |
| Subtext | `#AAAAAA` | `#555555` |
| Border/divider | `#1A1A1A` | `#EEEEEE` |

**Font:** `GoogleFonts.spaceGrotesk` at all weights. `TextTheme` defines `displayLarge` (32/700), `displayMedium` (24/600), `bodyLarge` (16/400), `bodyMedium` (14/400 secondary), `labelLarge` (14/600).

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `cloud_firestore ^5.0.0` | Realtime data |
| `firebase_auth ^5.0.0` | Anonymous auth |
| `firebase_storage ^12.0.0` | Audio upload |
| `firebase_core ^3.0.0` | Init |
| `record ^5.1.2` | Mic recording (AAC-LC, 128kbps, 44.1kHz mono) |
| `just_audio ^0.9.40` | Playback |
| `google_fonts ^6.2.1` | Space Grotesk |
| `appinio_swiper ^2.0.1` | Poll card swiper |
| `provider ^6.1.2` | ThemeNotifier |
| `uuid ^4.5.1` | Response/upload IDs |
| `path_provider ^2.1.4` | Temp directory for recordings |
| `web ^1.1.1` | Modern Flutter web DOM interop |
| `webview_flutter ^4.13.1` | Native WebView for The Resonance on iOS/Android |
| `url_launcher ^6.3.0` | Opens Terms/Privacy links from onboarding checkboxes |

**Web interop:** Use `package:web` + `dart:js_interop` (not deprecated `dart:html`). `dart:ui_web` for `platformViewRegistry`.

---

## SoftLimiter (`utils/limiter.dart`)

Soft-knee dBFS compressor applied only to waveform display, not the audio file.
- Threshold: -6 dBFS, Ratio: 8:1, Knee: 4 dB, Noise floor: -60 dBFS
- `process(rawDb)` → linear 0.0–1.0 bar height
- Does NOT modify audio on disk — OS-level AGC handles that

---

## Patterns & Conventions

**Color resolution in widgets:**
```dart
final isDark = Theme.of(context).brightness == Brightness.dark;
final fg  = isDark ? const Color(0xFFF5F5F5) : const Color(0xFF000000);
final sub = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
final bg  = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
```

**Buttons:** `_OutlineButton` (border, transparent bg) and `_FilledButton` (solid bg). Always `GestureDetector` + `HapticFeedback.lightImpact()`.

**Chips:** `_TagChip` / `_Chip` — small allcaps label + larger value, rounded 12px container.

**StreamSubscription lifecycle:** always assigned to a field, cancelled in `dispose()`. Use a local `sub` variable when there is a self-reference race risk (see `RecordingSheet._onSubmit`).

**Firestore queries:**
- The Resonance: `responses` scoped to `pollId`, limit 300, `createdAt` descending. **Never query globally.**
- The Pulse (live feed): `responses`, limit 30, `createdAt` descending.

**Audio path resolution priority (ResponseItem):**
1. `audioPath` field
2. `uuid` field → `audio_uploads/<uuid>.m4a`
3. Doc ID (36-char UUID) → `audio_uploads/<docId>.m4a`
