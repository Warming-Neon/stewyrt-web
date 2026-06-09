# Changelog

All notable changes to Stewyrt are recorded here.  
Format: `[version or date] — summary`, newest first.

---

## [2026-06-09] — Rebuild report/block system as personal content filter

- **`functions/src/index.ts`**:
  - Replaced the entire `submitContentReport` function to enforce personal blocks for all report reasons except `child_safety`.
  - Rate limiting now counts documents in `user_blocks/{uid}/reports` instead of `moderation_queue`.
  - `child_safety` reports still trigger auto-approved global blocks, strike increments in `user_strikes`, and bulk-blocking when 3 strikes are reached.
  - All other report reasons write to `user_blocks/{reporterUid}/blocked_responses/{responseId}` to filter content personally, leaving the response document untouched, adding no strikes, and bypassing the `moderation_queue`.
  - Created a new admin-only `restoreResponse` callable Cloud Function that resets blocked/deleted states on response documents, removes the respective strike from history, decrements the strike count (deleting the `user_strikes` doc if it hits 0), and updates all related `moderation_queue` entries to a `"restored"` status.
- **`lib/widgets/sentiment_stream.dart`**:
  - Subscribed to a real-time Firestore listener on the user's personal block list (`user_blocks/{currentUid}/blocked_responses`) in `initState`, storing the subscription as `_blocklistSub` and cancelling it in `dispose()`.
  - Added an additional filter on the live stream items to exclude personally blocked response IDs.
  - Updated `_showReportSheet` and `_ReportSheetState._submit` to immediately append a blocked response ID to `_personallyBlocked` and remove it from the feed immediately if the Cloud Function returns `personalBlock: true`. Added diagnostic `debugPrint` logs to verify propagation of values.
- **`firestore.indexes.json`**:
  - Added a composite index for `blocked_responses` on `blockedAt` DESCENDING.

---

## [2026-06-09] — UGC safety compliance

- **`lib/widgets/sentiment_stream.dart`**:
  - Updated in-app content reporting reasons to exactly match server-side keys (`harassment`, `hate_speech`, `spam`, `other`). Added display mappings to preserve user-friendly UI text.
  - Implemented per-response self-deletion ('Remove my response') for items created by the currently authenticated user.
  - Set up a real-time Firestore document listener in the feed player sheet to automatically stop playback and pop the sheet with a smooth 800ms fade-out animation if the playing item gets blocked.
  - Converted the live feed from a standard list to an `AnimatedList` with real-time diff-based synchronization and 600ms fade-out item exits.
- **`functions/src/index.ts`**:
  - Rewrote `submitContentReport` with a 3-strikes automated moderation system. If a response is reported for hate speech or harassment, it is instantly blocked, a strike is logged in `user_strikes`, and reaching 3 strikes places the user in `blocked_uids` and bulk-blocks all their posts.
  - Updated `analyzeAudio` to check `blocked_uids` at start and silently exit/delete the storage file.
  - Created admin moderation Cloud Functions: `approveModerationReport` and `dismissModerationReport`.
  - Created `deleteOwnResponse` to let users hide/delete their own responses without penalty.
- **`web/terms.html`**:
  - Added Zero Tolerance Policy highlight box and Section 6a Content Removal Rights.
- **`web/support.html`**:
  - Built a new Help Center & FAQ page matching the design language of `child-safety.html`.

---

## [2026-06-03] — Chore: add ITSAppUsesNonExemptEncryption to Info.plist

- **`ios/Runner/Info.plist`**: Added `ITSAppUsesNonExemptEncryption` set to `false` to declare standard OS encryption usage to Apple.

---

## [2026-06-03] — Chore: remove mic permission debug logging

- **`lib/screens/onboarding_screen.dart`**: Removed temporary `debugPrint` statements added for mic permission diagnostics.

---

## [2026-06-03] — Debug: add mic permission logging to onboarding screen

- **`lib/screens/onboarding_screen.dart`**: Added temporary `debugPrint` statements to `initState`, `_checkMicPermission`, and `didChangeAppLifecycleState` to trace microphone permission status and state transitions.

---

## [2026-06-03] — Fix: use isGranted check for mic permission banner

- **`lib/screens/onboarding_screen.dart`**, **`lib/screens/day_one_screen.dart`**, **`lib/widgets/recording_sheet.dart`**: Updated `_checkMicPermission` to use `!status.isGranted` instead of checking for explicit denial. This ensures the permission banner correctly reflects the state on iOS when permission is undetermined or limited, and prevents stale status display after resuming the app from Settings.

---

## [2026-06-03] — Chore: clean slate responses and polls

- **Firestore**: Deleted all documents in the `responses` collection to reset sentiment data.
- **Firestore**: Deleted all `polls` documents except for `ice_breaker_v1`.
- **Firestore**: Restarted question rotation for 2026-06-03 by manually triggering poll activation for today's Pulse and Horizon questions.

---

## [2026-06-03] — Fix: add intentionality check to sentiment analysis

- **`functions/src/index.ts`**: Added an `INTENTIONALITY CHECK` to the Gemini sentiment analysis prompt. This filters out accidental recordings, silence, and ambient noise (traffic, wind, room tone) before processing, ensuring only purposeful audio content is analyzed and stored.

---

## [2026-06-02] — Fix: UI improvements and navigation safety

- **`lib/main.dart`**: Removed duplicate theme toggles from mobile toolbar and wide navigation bar to centralize control in Settings.
- **`lib/main.dart`**: Raised `subColor` contrast to meet WCAG standards (#555555 -> #888888 in dark mode; #AAAAAA -> #666666 in light mode).
- **`lib/screens/settings_screen.dart`**: Added confirmation dialog to `_openUrl` before launching external browser links for legal and support pages.

---

## [2026-05-25] — Feat: add recording preview to Day One ice breaker screen

### Flutter Client
- **`lib/screens/day_one_screen.dart`**: Implemented a recording preview state matching the `RecordingSheet` pattern. Users can now play back their ice breaker recording, re-record if needed, or confirm and submit. Added `just_audio` integration, playback waveform visualization, and a dedicated preview UI.

---

## [2026-05-25] — Fix: skip rate limit on missing auth context, add sentiment error handling to prevent client hang

### Cloud Functions (`functions/src/index.ts`)
- **FIX 1 — Rate limiting fallback**: Storage triggers carry no auth context, so `event.auth` is always null. The previous code wrote `blocked: unauthenticated` and returned for every submission that could not derive a UID from `responseId`. Changed so that when `rateUid` is null, rate limiting is skipped entirely (with a `console.warn`) and analysis proceeds normally. The rate-limit Firestore query is now wrapped in an `if (rateUid)` guard.
- **FIX 2 — Sentiment analysis error handling**: The `catch` block in the Gemini analysis path previously returned silently, leaving no Firestore document for the client to observe, causing the app to hang indefinitely. The catch block now writes `{ blocked: true, blockedReason: "analysis_error", error: true, createdAt: … }` to `responses/{trustedResponseId}` before returning.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: switch Gemini SDK to Vertex AI billing via service account, remove AI Studio API key dependency

### Cloud Functions (`functions/src/index.ts`)
- Removed `defineSecret("GEMINI_API_KEY")` and the `secrets: [geminiApiKey]` binding from `analyzeAudio` — the AI Studio API key is no longer passed to the SDK.
- Both `GoogleGenAI` initialisations (bot-detection flow and sentiment analysis flow) switched from `{ apiKey: geminiApiKey.value() }` to `{ vertexai: true, project: "stewyrt-11", location: "us-central1" }`.
- Removed unused `import { defineSecret } from "firebase-functions/params"`.
- The `GEMINI_API_KEY` secret is retained in Secret Manager but is no longer consumed by the function.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: correct web amplitude gate threshold for 0.0–1.0 compensated range

### Flutter Client
- **`lib/screens/day_one_screen.dart`**, **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**: Gate threshold is now platform-aware. On web, `avgAmp` is 0.0–1.0 from `SoftLimiter.webProcess()`, so the silent-recording check now uses `kIsWeb ? avgAmp < 0.05 : avgAmp < -50.0`. Previously comparing a 0.0–1.0 value against -50.0 meant the gate never fired on web, allowing silent recordings through.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: Tighten rate limits, fix verification inconsistency, enforce beta mode rate limiting

### Cloud Functions (`functions/src/index.ts`)
- **Sentiment Analysis Rate Limit**: Dropped threshold from 30 to 5 responses per rolling hour per user.
- **Verification Rate Limit**: Fixed inconsistency where logic allowed 5 attempts while comments/UI specified 3; now strictly enforced at 3 attempts per 24 hours.
- **Beta Mode Rate Limiting**: Previously skipped for UUID v4 response IDs (beta mode). Now derives UID from Firebase Auth context (`event.auth.uid`) to apply the same 5-per-hour limit. Submissions without a valid auth context are now blocked entirely.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Feat: Daily question activation system

### Cloud Functions (`functions/src/index.ts`)
- **`activateDailyQuestion`** (scheduled, 00:01 UTC daily): reads `question_schedule/{today}`, creates a new active pulse poll, deactivates the previous active pulse poll, and writes `times_used` / `last_used_date` / `first_used_date` back to the question document. On Mondays, does the same for the horizon tier.
- **`activateDailyQuestionManual`** (onCall): identical logic, callable for immediate manual trigger. Returns full `ActivationSummary`.
- **`updateQuestionUsage`** (internal helper): increments `times_used`, sets `last_used_date`, sets `first_used_date` only on first activation. Called exclusively by `runDailyActivation`.
- **`DAY_CATEGORY`**: added `saturday: "retrospective"` — was missing, causing the scheduler to log a gap warning every Saturday.
- **UID on response writes**: storage triggers have no auth context. UID is derived server-side from production-format `responseId` (`{uid}_{pollId}`) and written as the `uid` field. Beta-mode responses (UUID v4 `responseId`) carry no `uid` field — documented in code comment. Gap accepted; `deleteUserData` only covers production-mode responses.

### Scripts
- **`scripts/cleanup_placeholder_polls.js`**: deletes all responses referencing `SDIQeGRTg9DdXu8PUzD7` (placeholder pulse) and `vAFqqAiBhGfYAEN7OPtl` (placeholder horizon), then deletes the poll documents. Idempotent. Ran: 32 responses deleted, 2 polls deleted.
- **`scripts/seed_first_live_polls.js`**: creates `polls/pulse_live_v1` and `polls/horizon_live_v1` with hardcoded content. Idempotent (skips if doc exists). Ran: both created, then correctly deactivated by the first activation run.

### Deployment
- All 10 Cloud Functions deployed to `stewyrt-11` (us-central1). First live activation ran 2026-05-25 (Monday): pulse and horizon both activated from `question_schedule/2026-05-25`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Feat: Silent/muted recording guardrails across three layers

- **Layer 1 (Client-side gate)**:
  - **`lib/widgets/recording_sheet.dart`**, **`lib/screens/onboarding_screen.dart`**, **`lib/screens/day_one_screen.dart`**: Implemented duration and amplitude checks before upload. Recordings under 2 seconds or with an average amplitude below -50dB are now rejected immediately with a user-friendly message.
- **Layer 2 (Cloud Function validation)**:
  - **`functions/src/index.ts`**: Added server-side re-validation of Gemini's bot detection response. `verifiedAsHuman` is now strictly `false` if `durationSeconds < 2`, ensuring short/silent bypasses are caught even if Gemini misclassifies them.
- **Layer 3 (Bot detection prompt hardening)**:
  - **`functions/src/index.ts`**: Hardened the Gemini bot detection system instruction with explicit rules for silence, noise, synthetic voices, and recordings of recordings.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Feat: Child Safety Policy link; Firebase Hosting static rewrites

- **`lib/screens/settings_screen.dart`**: Added "Child Safety Policy" link to the LEGAL section, pointing to `https://stewyrt.com/child-safety.html`.
- **`firebase.json`**: Added static rewrites for `/privacy`, `/terms`, and `/child-safety` to serve their respective HTML files directly, bypassing the Flutter index.html.
- **Verification**: Confirmed `web/privacy.html`, `web/terms.html`, and `web/child-safety.html` exist in the project.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Docs: Updated CONTEXT_MAP.md for codebase parity; bumped version

- **`CONTEXT_MAP.md`**: Updated the project file map to include missing files (`verification_timeout_widget.dart` and `child-safety.html`) ensuring the map reflects the actual state of the codebase.
- **`pubspec.yaml`**: Bumped version to `1.0.1+2`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-18] — Security: Android release signing; Privacy compliance; Site rebuild

### Android Release Signing
- **`android/app/build.gradle.kts`**: Configured release signing to load credentials from `key.properties`. Updated build configuration to use `release` signing config instead of debug.
- **`android/key.properties`**: (Local only) Added release keystore path and passwords.
- **`android/.gitignore`**: Ensured `key.properties` is explicitly ignored.

### Compliance & Security
- **`web/privacy.html`**: Added "How to Delete Your Data" section to comply with app store requirements.
- **`.geminiignore`**: Added project-level ignore file to exclude sensitive paths (e.g., `.git`, `functions/node_modules`) from Gemini analysis.

### Resonance auto-spin screensaver
- **`web/brain_visualizer.html`**: Added auto-rotation mode via `#spin-button`. Rebuilt warmingneon.com integration. Calculates a dynamic orbit radius based on the node cluster's bounding sphere to ensure the "brain" remains perfectly framed. Any user interaction (tap/drag) cancels the spin.
- **`lib/services/resonance_controller.dart`**: Added `stopSpin()` / `registerSpinStopper()` coordination.
- **`lib/main.dart`**: `RootShell` calls `stopSpin()` when switching tabs away from The Resonance.

### UI & Compliance
- **`lib/widgets/poll_card.dart`**: Question text now uses `FittedBox` + `Center` + `Expanded` to prevent layout overflow on long questions.
- **`web/privacy.html`**: Updated ICO Registration Reference to `ZC142846`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-15] — Fix: Resonance camera focus race conditions; brain visualiser node stability; web app icon

### Resonance focus — race condition fix (native + web)
- **Root cause:** `focusOnNode` was fired as a separate `runJavaScript`/`postMessage` call before nodes were built in JS, so `nodesByName.get(tag)` always returned `undefined` and the tween silently no-opped.
- **Native (`resonance_native_screen.dart`):** `_focusNode` now always stores tag as `_pendingFocusTag`; fires immediately only when `_pendingJson != null` (nodes confirmed built). `_inject` accepts optional `focusTag` and embeds it in the JSON payload so `processBrainData` calls `focusOnNode` **after** nodes are populated in the same synchronous call.
- **Web (`resonance_web_screen.dart`):** Added `_nodesReady` static flag (reset on every `_changePollScope`, set after first successful `_post`). Focus callback now gates on `_nodesReady` rather than `_pendingPayload != null` — preventing stale-payload false positives across question changes. `_sendDataToBrain` embeds focus in the payload. Removed `_triggerFocus` + 600ms `Future.delayed` hack.
- **`resonance_controller.dart`:** No logic change — ordering was correct; fix was in the screens.

### brain_visualizer.html — node stability + region label colours
- **Node stability fix:** replaced blanket `clearNodes()` before every data update with a selective removal loop that only tears down nodes absent from the incoming payload. Existing nodes now update in place (scale + emissive flash) rather than being re-created with a new random position each Firestore tick.
- **`processBrainData` focus ordering:** pure-focus messages (`{focus}` only) still early-return; combined payloads (`{nodes, focus}`) now call `focusOnNode` at the end, after nodes are built.
- **Region label colours:** `makeRegionSprite` now calls `regionLabelColor()` — Amygdala→red-pink, Nucleus→gold, Insula→teal, Prefrontal→violet — matching the node geometry palette.

### Web app icon
- All four PWA manifest icons (`icons/Icon-{192,512,maskable-192,maskable-512}.png`) regenerated from `stew_iconn.png` (were still Flutter default blue).
- `favicon.png` replaced with correctly-sized 32×32 version; `apple-touch-icon.png` generated at 180×180.
- `index.html` updated to reference sized icons. `manifest.json` theme/background colours updated from Flutter default blue to `#030420`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-15] — Feat: pollId deep-link from feed chips; back-button fixes; debug print cleanup

### Feed chip → Resonance deep-link
- **`lib/widgets/sentiment_stream.dart`**: `_FeedPlayerSheet` now receives `pollId`; chip taps (`TONE`, `FLAVOR`, `ESSENCE`) call `ResonanceController.goToResonanceAndFocus(tag, pollId: pollId)`, which pushes a new `ResonanceScreen` instance scoped to that poll rather than tab-switching to the current poll.
- **`lib/services/resonance_controller.dart`**: `registerTabSwitcher` now accepts a `BuildContext`; `goToResonanceAndFocus` pushes a fade-transition route when `pollId` is provided; `resonanceScreenBuilder` callback avoids circular imports.
- **`lib/main.dart`**: passes `context` to `registerTabSwitcher` and sets `ResonanceController.resonanceScreenBuilder` at root-shell init.

### Back button improvements
- **`resonance_web_screen.dart`**: back button changed from `GestureDetector`/`Container` to `TextButton` (proper hit-testing, `CircleBorder` shape).
- **`resonance_native_screen.dart`**: back tap guards with `canPop()` before calling `pop()`.

### Debug print cleanup
Removed 7 temporary `debugPrint` statements (`[FEED CHIP TAP]`, `[RECORDING]`, `[TAG TAP]`, `[RESONANCE]`) from `sentiment_stream.dart`, `recording_sheet.dart`, `resonance_web_screen.dart`, and `resonance_native_screen.dart`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-14] — The Resonance UI overhaul (Phases 1–6): cosmic nebula, no bloom, brain outline, always-on labels, perf tier, warm colours

All changes confined to `web/brain_visualizer.html`.

- **Phase 1 — Cosmic nebula background:** scene background `#030420`, fog `#0a0820` density `0.012`. Nebula upgraded to 1200 soft-circle particles via `ShaderMaterial` (`gl_PointCoord` discard) across ±200 units; palette of deep purples/indigo/dark magenta/teal with 7% violet accent `#6a0aff`. Filler depth orb palette shifted to near-black indigo/purple; emissive `0.4→0.25`.
- **Phase 2 — Bloom removed:** `EffectComposer`, `RenderPass`, `UnrealBloomPass` imports deleted entirely. Render loop uses `renderer.render(scene, camera)` directly. Core mesh changed from `MeshBasicMaterial` to `MeshStandardMaterial` with white colour + node-colour emissive at 1.2 to compensate. Membrane birth flash `1.5→2.5`, decay baseline `0.2→0.4`. Comet emissive `4.0→2.0`.
- **Phase 3 — Brain ghost outline + region labels:** four `CatmullRomCurve3` `THREE.Line` arcs (left/right hemispheres, corpus callosum hint, cerebellum suggestion) at `#2a1a4e` opacity 0.22–0.35. Five `THREE.Sprite` region labels (`Prefrontal`, `Amygdala`, `Nucleus`, `Insula` ×2) at `#6a4aff` opacity 0.5; fade to 0.2 when a data node is within 3 world units.
- **Phase 4 — Always-on node labels + tap shows % only:** every emotion node gets a billboarded `THREE.Sprite` label (bold 14px white, 128×32 canvas) 1.5 units above centre. Opacity 0.6–1.0 by node radius; fades to 0 when camera < 8 units; fades to 0.3 when screen-overlapped by a larger node. Tooltip on tap now shows percentage only (`"24.6%"` centred) — emotion word removed from tooltip (already on the always-on label).
- **Phase 5 — Performance tier:** `detectPerformanceTier()` reads `WEBGL_debug_renderer_info` GPU string and `navigator.deviceMemory`. `low` tier: nebula 400 pts + `PointsMaterial` (no shader compile), filler 50 nodes, comets capped at 1 per path, icosahedron detail 1, pixel ratio capped at 1.5. `high` tier: 1200 pts + `ShaderMaterial`, 120 fillers, 1–3 comets, detail 2, pixel ratio ≤ 2.
- **Phase 6 — Warmer node colours:** `regionColor()` replaces `regionHue()`, returning `{h,s,l}`. Prefrontal `0.70–0.82`/sat `0.85–1.0`; Amygdala `0.95–1.08` (wraps through pink/crimson)/sat `0.9–1.0`; Nucleus `0.12–0.28` (amber/warm green); Insula `0.48–0.58`. Membrane roughness `0.8→0.4`. Point lights shifted to violet palette: `#5566ff→#8855ff`, `#ff3366→#ff2266`, `#00ffaa→#aa44ff`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-14] — Fix: phrase timing, preview duration, pollId routing to Resonance

### Fix 1 — Phrase cycling slowed: 800ms → 1200ms
- **`lib/screens/day_one_screen.dart`**: `_phraseTimer` interval changed from `Duration(milliseconds: 800)` to `Duration(milliseconds: 1200)` in `_submit()`.
- **`lib/widgets/recording_sheet.dart`**: same change in the waiting-room `_phraseTimer` inside `_onSubmit()`.
- `lib/screens/onboarding_screen.dart` left unchanged — its verifying-spinner uses 1500ms, a separate timer with a different purpose.

### Fix 2 — Preview duration counter stuck at 0:00 (web)
- **`lib/widgets/recording_sheet.dart`**: removed the `durationStream.firstWhere(...).timeout(5s)` await from `_setupPlayer()`. Even after the await resolved, `_player.duration` was returning `null` (the stream value and the getter are not in sync at the point of read), leaving `_playTotal` as `Duration.zero`.
- Right-side duration `Text` in `_buildPreviewing()` replaced with a `StreamBuilder<Duration?>` that subscribes to `_player.durationStream` directly, updating live as the browser resolves `loadedmetadata` for the `blob://` URL. Left-side position counter and progress calculation left unchanged.

### Fix 3 — Tag chip navigated to wrong Resonance (pollId routing)
- **`lib/screens/pulse_screen.dart`**: `_openRecording` call site in the PageView `itemBuilder` changed from `poll.question / poll.id` to `currentPoll.question / currentPoll.id`. The per-card `poll` variable (from the `itemBuilder` index parameter) and the active-card `currentPoll` variable are logically the same in normal use, but differ if a tap fires during a mid-swipe transition (`index != activeIdx`). Using `currentPoll` guarantees the actually-visible card's pollId reaches `RecordingSheet.widget.pollId`, which `_onTagTap` then forwards to `ResonanceScreen(pollId:)`.
- **`lib/widgets/recording_sheet.dart`**: `_onTagTap` already passes `widget.pollId` to `ResonanceScreen` — no change needed.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-14] — Debug Session 3: six-bug post-deploy fixes

### Bug 1 — Chrome mobile web: nav icons centred, covering all content, taps non-functional
- **`lib/main.dart`**: replaced `AppBar(toolbarHeight: 40)` with `PreferredSize(Size.fromHeight(40))` so Scaffold calculates body height correctly on web. Moved settings + theme-toggle icons into the `PreferredSize` appBar (narrow) and `Stack` bottomNav (wide). Changed bottomNav `Center(child: tabs)` → bare `tabs` `Row` with `mainAxisAlignment: center` — the `Center` wrapper was expanding to fill the unconstrained bottomNav height, collapsing the layout.

### Bug 2 — Responses invisible: flash then vanish, "Be the first" shown despite Firestore data
- **`lib/widgets/sentiment_stream.dart`**: `.where('blocked', isNotEqualTo: true)` → `.where('blocked', isEqualTo: false)`. The `isNotEqualTo` range filter has reconciliation lag on real-time listeners after a secondary-index update, causing the flash-then-vanish symptom.
- **`lib/screens/resonance_native_screen.dart`** + **`lib/screens/resonance_web_screen.dart`**: same query fix at both Firestore subscription sites in each file (4 call sites total, `replace_all`). Existing composite index `(pollId ASC, blocked ASC, createdAt DESC)` covers `isEqualTo: false` — no new index needed.

### Bug 3 — Preview player shows 0:00 / 0:00 on web after recording
- **`lib/widgets/recording_sheet.dart`**: `_setupPlayer()` now awaits `_player.durationStream.firstWhere((d) => d != null).timeout(5s)` before reading `_player.duration`. The browser fires `loadedmetadata` asynchronously for `blob://` URLs so `duration` is `null` synchronously after `setUrl()`.

### Bug 4 — Resonance back button overlaps header text; `canPop()` gate broken on web
- **`lib/screens/resonance_native_screen.dart`** + **`lib/screens/resonance_web_screen.dart`**: `crossAxisAlignment: CrossAxisAlignment.start` → `center`; `textAlign: TextAlign.center` added to both header `Text` widgets. `Navigator.of(context).canPop()` condition replaced with `widget.showBackButton` bool; `Navigator.pop()` replaced with `Navigator.maybePop(context)`.
- **`lib/screens/resonance_screen.dart`**: forwarded new `showBackButton` param to `ResonancePlatformScreen`.
- **`lib/screens/pulse_screen.dart`**: `_viewResonance()` passes `showBackButton: true`.
- **`lib/widgets/recording_sheet.dart`**: `_onTagTap()` `ResonanceScreen` push passes `showBackButton: true`.

### Bug 5 — No way to skip Ice Breaker from Day One screen
- **`lib/screens/day_one_screen.dart`**: Added "Maybe later" `TextButton` below the hold button in `_buildIdle()`. Sets `SharedPreferences('hasCompletedDayOne', true)` and `Navigator.pushReplacement` to `RootShell`.

### Bug 6 — Mobile web nav bar overlap (resolved by Bug 1 fix)
- Already resolved: the `isWide` responsive branch added in Bug 1 correctly routes settings/theme icons to the appBar on narrow viewports and leaves the Stack layout untouched on wide viewports. No additional changes required.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-14] — Debug pass: post-deploy smoke test fixes (Bugs 1–6)

### Bug 1 — Android crash on Day One completion (`String not subtype of num?`)
- **`lib/screens/archive_screen.dart`**: replaced hard `as num?` / `as Timestamp` casts in `_ArchivePoll.fromDoc()` with `is`-guarded checks and `int.tryParse` fallback. Firestore Console can write `total_submissions` as a String; the cast threw on `IndexedStack` mount.

### Bug 2 — Waveform broken on web (Safari: invisible, Chrome: dots only)
- **`lib/utils/limiter.dart`**: added `SoftLimiter.webProcess(db)` — linearly maps the `record` package's web `AnalyserNode.getFloatFrequencyData()` range (−60 to −5 dBFS) to 0.0–1.0, bypassing the native soft-knee compressor calibrated for −10 to −3 dBFS.
- **`lib/screens/day_one_screen.dart`**, **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**: amplitude listener uses `SoftLimiter.webProcess` on `kIsWeb`, `SoftLimiter.process` on native.
- **`lib/screens/day_one_screen.dart`**: added `const String _iceBreakerId = 'ice_breaker_v1'` and wired it as the `pollId` arg in the `uploadAudioClip` call — was previously passed as `''`, causing CF to store `pollId: ""` on all Ice Breaker responses.
- **`scripts/fix_ice_breaker_poll_ids.js`** (new): idempotent backfill — finds `responses` with `pollId == ""` and question matching Ice Breaker text, batch-updates to `pollId: 'ice_breaker_v1'`; also corrects `polls/ice_breaker_v1.total_submissions` if stored as a String.

### Bug 3 — Safari cannot swipe between question cards
- **`lib/screens/pulse_screen.dart`**: `PageView.physics` set to `PageScrollPhysics()` on web (`ClampingScrollPhysics` doesn't snap via mouse/touch on WebKit).
- **`lib/main.dart`**: added `dragDevices` override to `_BouncingScrollBehavior` — base `ScrollBehavior` excludes `PointerDeviceKind.mouse`; override adds mouse/stylus/unknown on web so Safari trackpad/click-drag swipe works.

### Bug 4 — Recording hangs on web after release
- **`lib/widgets/recording_sheet.dart`**: `_setupPlayer()` uses `player.setUrl(path)` on web (`record` returns a `blob://` URL; `setFilePath()` calls `Uri.file()` which corrupts `blob://` schemes), `setFilePath()` on native as before.

### Bug 5 — Compliance banner not shown after account deletion
- **`lib/screens/settings_screen.dart`**: post-deletion navigation changed from `OnboardingScreen` to `BootRouter`. `prefs.clear()` already clears all keys (`hasSeenComplianceBanner`, `hasPassedBouncer`, `hasCompletedDayOne`); routing through `BootRouter` re-runs `_init()` which evaluates `hasSeenComplianceBanner` and shows the compliance banner for that session.

### Bug 6 — Mobile web nav bar icons overlapping tabs
- **`lib/main.dart`**: `_RootShellState.build()` is now responsive on `MediaQuery.of(context).size.width >= 600`. Narrow (< 600px): adds a slim 40px `AppBar` housing settings (leading) and theme toggle (actions); bottom nav shows three tabs only with no `Stack`/`Positioned` elements. Wide (≥ 600px): previous Stack layout with positioned utility icons unchanged. Tab `Row` extracted as a local `tabs` variable to eliminate duplication.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-13] — Kitchen-Cuppa: deferred items (Phases 4–8)

### Phase 4 — Microphone permission denied recovery
- **`pubspec.yaml`**: added `permission_handler: ^11.0.0` and `package_info_plus: ^4.0.0`.
- **`lib/widgets/mic_permission_banner.dart`** (new): amber banner with `mic_off_outlined` icon. Taps open system app settings via `openAppSettings()` (guarded by `kIsWeb`).
- **`lib/screens/onboarding_screen.dart`**: added `WidgetsBindingObserver` mixin; `_checkMicPermission()` on init and on `AppLifecycleState.resumed`; `_micPermissionDenied` replaces the old SnackBar path; banner injected above hold-button when denied.
- **`lib/screens/day_one_screen.dart`**: same observer + `_micPermissionDenied` pattern; banner shown above `Listener` in `_buildIdle()`.
- **`lib/widgets/recording_sheet.dart`**: same observer + banner pattern.

### Phase 5 — Verification prompts from Firestore
- **`scripts/seed_verification_prompts.js`** (new): seeds 18 prompts (doc IDs `prompt_01`–`prompt_18`) to `verification_prompts` collection; idempotent `batch.set`.
- **`lib/screens/onboarding_screen.dart`**: `_fetchVerificationPrompt()` fetches `verification_prompts` where `active==true` on init, picks a random doc, updates `_verificationPrompt` state (hardcoded fallback if fetch fails).
- **`firestore.rules`**: added `verification_prompts/{promptId}` — authenticated read, no write.

### Phase 6 — Waiting-phrase library from Firestore
- **`scripts/seed_waiting_phrases.js`** (new): 42 phrases across four acts (setup × 12, observation × 10, empathy × 10, technical × 10) written to `waiting_phrases` collection; deterministic IDs, batched.
- **`lib/services/phrase_service.dart`** (new): singleton `PhraseService.instance`. `prefetch()` is idempotent (guarded by `_fetchStarted`); loads phrases from Firestore grouped by `act`, falls back to hardcoded arrays. `generateStory()` picks one random phrase per act.
- **`lib/screens/day_one_screen.dart`** + **`lib/widgets/recording_sheet.dart`**: removed four `static const _act*` phrase arrays; `_generateNewStory()` delegates to `PhraseService.instance.generateStory()`; `initState` calls `PhraseService.instance.prefetch()`.
- **`firestore.rules`**: added `waiting_phrases/{phraseId}` — authenticated read, no write.

### Phase 7 — Settings screen, FAQ, delete-my-data
- **`lib/screens/settings_screen.dart`** (new): 5 sections (Appearance, Legal, Support, About, Account). Settings icon opens via `Navigator.push` from nav bar. Dark-mode toggle uses existing `ThemeNotifier`. "Delete My Data" shows confirmation dialog then calls `deleteUserData` callable, clears `SharedPreferences`, signs out, and pushes `OnboardingScreen`. Captures `Navigator.of(context)` and `ScaffoldMessenger.of(context)` before first `await` to avoid BuildContext-across-async-gap lint.
- **`lib/screens/faq_screen.dart`** (new): 7 Q&A items in theme-aware `ListView.separated` with `Divider`.
- **`functions/src/index.ts`**: added `deleteUserData` callable. Deletes: (1) `responses` where `uid==caller`, (2) `users/{uid}`, (3) `audio_uploads/onboarding_{uid}.m4a` (defensive — normally already gone). Sentiment audio not enumerable by uid; 120-day purge handles it.
- **`lib/main.dart`**: added `Positioned` settings icon (left side of nav bar); taps push `SettingsScreen`.
- **`firestore.rules`**: added comment to `users/{uid}` block noting `deleteUserData` uses Admin SDK.

### Phase 8 — Report content button
- **`lib/widgets/sentiment_stream.dart`**: added `onLongPress` to feed item `GestureDetector` calling `_showReportSheet(context, item.id)`; added `_showReportSheet()` method; added `_ReportSheet` stateful widget (two-step flow: initial options list → reason picker, plus submitting / submitted states); added `_SheetRow` helper. `_submit()` captures `nav` before the `await`, auto-pops 900ms after success.
- **`functions/src/index.ts`**: added `submitContentReport` callable. Validates `responseId` (UUID v4 regex) and `reason` (allowlist: harassment / hate_speech / spam / misinformation / other). Rate-limits to 10 reports per user per rolling hour. Verifies `responses/{responseId}` exists. Writes `{ responseId, reason, reportedBy, reportedAt, reviewed: false }` to `content_reports/{autoId}`.
- **`firestore.rules`**: added `content_reports/{reportId}` — all access denied from clients (CF uses Admin SDK).

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-12] — Kitchen-Cuppa: pre-launch QOL pass (Phases 1–6)

### Phase 1 — Cleanup & Splash
- **`pubspec.yaml`**: removed unused `appinio_swiper` dependency. Added `flutter_native_splash: ^2.4.0` to dev_dependencies.
- **Deleted orphaned files**: `lib/screens/global_thread_screen.dart`, `lib/widgets/sentiment_expanded_sheet.dart`, `lib/widgets/audio_player_widget.dart`, `lib/models/sentiment_data.dart` — all were unused after previous refactors.
- **`android/app/src/main/AndroidManifest.xml`**: explicit `INTERNET` permission added.
- **`flutter_native_splash.yaml`** (new): pure black splash — `color: "#000000"` for both default and Android 12.
- **`lib/screens/boot_router.dart`**: replaced empty black scaffold with a centered "stewyrt" wordmark in Space Grotesk Bold 32px white, with a 300ms `FadeTransition` on mount.
- **`lib/widgets/poll_card.dart`**: `onTap` made nullable (required removed); "Press to respond" button gated on `onTap != null`; tier value corrected from `'icebreaker'` → `'ice_breaker'`.

### Phase 2 — PageView rotation + Ice Breaker
- **`lib/screens/pulse_screen.dart`** (full rewrite): replaced `AppinioSwiper` with a 3-card fixed-slot `PageView` (Pulse → Horizon → Ice Breaker). `_buildRotationStream()` is an `async*` generator — fetches Ice Breaker once then streams Pulse/Horizon live. Null tiers yield `PollData.placeholder(tier)` at 40% opacity, no onTap. `_activeIndex` derived from `_pageController.page?.round()` via a scroll listener, eliminating dot-indicator desync.
- **`firestore.indexes.json`**: added `polls(tier ASC, isActive ASC, createdAt DESC)` composite index for the rotation stream query.
- **`scripts/seed_ice_breaker.js`** (new): one-shot seed that creates `polls/ice_breaker_v1`; uses `path.join(__dirname, '../functions/node_modules/firebase-admin')` for CWD-independent resolution. Successfully seeded.

### Phase 3 — Poll-scoped sentiment feed
- **`lib/widgets/sentiment_stream.dart`**: converted from `StatelessWidget` to `StatefulWidget`. Added `required String pollId` prop. `_buildStream()` adds `.where('pollId', isEqualTo: widget.pollId)` — feed now shows only responses for the currently visible card. `didUpdateWidget` rebuilds the stream only when `pollId` changes, avoiding churn on scroll.

### Phase 4 — Back button on Resonance
- **`lib/screens/resonance_native_screen.dart`** + **`lib/screens/resonance_web_screen.dart`**: added conditional back button overlay (`Navigator.canPop()` guard) — shows a translucent circle back arrow when the screen is pushed as a route (e.g. from the recording results tap-to-explore flow), hidden when viewed as a tab.

### Phase 5 — Soft-block UI + moderation review
- **`functions/src/index.ts`**: added `submitModerationReview` callable. Validates the caller is authenticated, checks the `responseId` exists and is blocked, then writes a doc to `moderation_review/{autoId}` with review fields defaulting to `null`.
- **`firestore.rules`**: added `moderation_review/{reviewId}` match block — clients may `create` (authenticated), never read or update.
- **`lib/widgets/recording_sheet.dart`** + **`lib/screens/day_one_screen.dart`**: replaced harsh red-block UI with a soft-block: amber `headset_off_outlined` icon, "We couldn't share this one" headline, "Our AI flagged this response…" body, two-button row — "Try again" (outline) + "Request review" (amber filled). "Request review" calls `submitModerationReview` with the captured `_blockedResponseId`.

### Phase 6 — Empty states
- **`lib/widgets/sentiment_stream.dart`**: upgraded existing plain-text empty state to icon (`mic_none_outlined` 32px at 50% opacity) + "Be the first to share what you really think." (15px w500) + "Press and hold to record." (12px subtext).
- **`lib/screens/archive_screen.dart`**: upgraded single-line empty state to icon (`search_off_outlined`) + "Nothing here yet." + "Try a different filter."
- **`lib/screens/resonance_native_screen.dart`** + **`lib/screens/resonance_web_screen.dart`**: added `_hasData` flag set on first non-zero Firestore snapshot; bottom-centre `AnimatedOpacity` overlay shows "No voices yet. Be the first." (14px white 70% opacity) and fades out in 600ms once data arrives.

### Firestore indexes
- `polls(isActive ASC, createdAt DESC)` and `responses(pollId ASC, createdAt DESC)` auto-created by Firestore; now codified in `firestore.indexes.json`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-09] — UI polish: nav 'S' logo, card tier labels, teal live dot, debug overlay removed

### Flutter client
- **`lib/main.dart`**: first nav tab icon replaced with a Space Grotesk bold 'S'; label changed from 'The Pulse' to 'Stewyrt'. `_NavItem` accepts optional `iconWidget` that overrides the `Icon` when provided.
- **`lib/screens/pulse_screen.dart`**: `PollData` gains a `tier` field (read from `polls/{id}['tier']`, defaults to `'pulse'`). Passed through to `PollCard`.
- **`lib/widgets/poll_card.dart`**: `tier` parameter added; card header label derived from tier — `horizon` → **HORIZON**, `icebreaker` → **ICE BREAKER**, anything else → **THE PULSE**. `category` field still stored but no longer shown on the card.
- **`lib/widgets/sentiment_stream.dart`**: live indicator dot colour changed from red `#FF3B30` to teal `#00BFA5`. Dot is static (always on while the feed panel is visible — no real-time activity signal wired yet).

### Brain visualiser
- **`web/brain_visualizer.html`**: removed on-screen debug overlay entirely — `#dbg` CSS block, `<div id="dbg">` element, `_dbgEl`/`_dbgLines` variables and overlay-update code all deleted. `dbg()` now forwards to `console.log` only (intentional — native WebView mirrors `[BRAIN]` logs to Flutter debug console via `setOnConsoleMessage`).

### Firestore — manual actions required
- Existing horizon poll doc: add `tier: "horizon"` field so the card shows **HORIZON**.
- Filler question: add new `polls` doc — `{ question: "What harmless things do you do that are bad but make you feel good?", category: "confessional", topic: "harmless pleasures", tier: "pulse", isActive: true, total_submissions: 0 }`.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-09] — Week 1–4 question library, question scheduler deployed

### Scripts
- **`scripts/seed_questions.js`**: appended 26 new curated questions (Weeks 1–4 + 2 Horizon), covering categories rebellion, reflective, confessional, provocative, whimsical, retrospective, anticipatory, existential. 32 questions now live in Firestore `questions` collection.
- **Bug fix:** `require` path corrected from `./functions/node_modules/firebase-admin` to `../functions/node_modules/firebase-admin` — path resolves relative to the file, not `process.cwd()`. The seed had never previously run successfully.
- **`.gitignore`**: added `*-sa-key.json` pattern to cover `stewyrt-sa-key.json` (existing `service-account*.json` pattern did not match this filename).

### Cloud Functions (`functions/src/index.ts`)
- **`scheduleUpcomingQuestions`** (new): `onSchedule("0 2 * * 0")` — fires every Sunday at 02:00 UTC. Fills the next 14 days of `question_schedule`, one pulse + one horizon question per day. Skips already-locked dates. Logs run summary to `scheduling_log/{ISO-datetime}`.
- **`scheduleUpcomingQuestionsManual`** (new): `onCall` — on-demand admin trigger for the same `runScheduler()` core. Requires Firebase Auth. Returns `SchedulerSummary` directly.
- Scheduling logic: day-of-week category rotation (Mon=rebellion, Tue=reflective, Wed=confessional, Thu=provocative, Fri=whimsical, Sun=existential); Saturday alternates retrospective/anticipatory by ISO week parity. Priority: day_affinity match → emotional balance (avoids 3+ consecutive heavy) → fewest `times_used`.

### Firestore
- **`questions` collection**: 32 approved questions seeded (6 original + 26 new). New composite index on `(tier ASC, status ASC)` deployed.
- **`question_schedule` collection**: created and populated by scheduler (doc per date, keys: `pulse_question_id`, `horizon_question_id`, `pulse_locked`, `horizon_locked`).
- **`scheduling_log` collection**: written per scheduler run.

### Deployment
- `firebase deploy --only firestore:rules,firestore:indexes` — rules + 6 indexes deployed. Note: 2 indexes exist in project but not in `firestore.indexes.json`; left in place (not force-deleted).
- `cd functions && npm run deploy` — all 5 functions deployed cleanly.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-09] — Cost & security hardening: verification rate limiting, metadata trust removal

### Cloud Functions (`functions/src/index.ts`)
- **Verification rate limit (FIX 1):** `analyzeAudio` now enforces 3 verification attempts per 24h per UID before invoking Gemini. Reads `verificationWindowStart` + `verificationAttempts` from `users/{uid}`; blocks and deletes audio without a Gemini call if limit is exceeded. Writes `{ verifiedAsHuman: false, verificationNote: "Rate limit exceeded..." }` and logs a `system_logs` entry with `type: "verification_rate_limit"`. Both success and error write paths now persist the counter fields, advancing the window on each real attempt.
- **Remove `metadata["owner"]` trust surface (FIX 2):** `extractUidForRateLimit` no longer accepts or trusts client-supplied `metadata["owner"]` as a UID source. UID is derived server-side from `responseId` in production mode only; client metadata is never trusted for routing. Documented with an explicit comment.

### Storage (`storage.rules`)
- **Comment update (FIX 3):** Added bandwidth-risk + App Check mitigation comment above the `audio_uploads/` read rule per audit recommendation.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-09] — Security migration: locked rules, bot detection, 120-day audio purge

### Security & Rules
- **Firestore rules** (`firestore.rules`): all client writes denied; reads scoped to authenticated users with `blocked != true`; `polls`, `responses`, `users`, `system_logs` collections explicitly locked; catch-all deny
- **Storage rules** (`storage.rules`): `audio_uploads/` restricted to authenticated writes of `audio/*` ≤ 5MB; catch-all deny
- **Firestore indexes** (`firestore.indexes.json`): 5 composite indexes for `responses` covering Pulse, Resonance, and Global Thread queries with `blocked` filter
- **Backfill**: `scripts/backfill_blocked_field.ts` created and run — 12 existing approved response docs stamped with `blocked: false` so `isNotEqualTo: true` queries don't exclude them

### Cloud Functions (`functions/src/index.ts`)
- **`analyzeAudio`**: all client writes moved to Admin SDK; `blocked: false` written explicitly on every approved response; UUID v4 validation of `responseId`; `pollId` existence check; rate limiting via `count()` aggregation (5 responses/user/hour)
- **Verification flow** overhauled: Gemini prompt changed from demographic acoustic matching to bot detection (continuous human speech check only); output fields changed from `confidenceScore/isFlagged` to `verifiedAsHuman/isContinuousSpeech/durationSeconds/verificationNote`; demographic data no longer inferred from voice
- **`purgeOldSentimentAudio`** (new): `onSchedule("0 3 * * *")`; deletes `audio_uploads/` files older than 120 days; skips `onboarding_*`; writes audit summary to `system_logs/{YYYY-MM-DD}`
- **`submitSelfReportedDemographics`** (new): `onCall`; validates age/gender/ethnicity/region against constrained ALLOWED arrays (UN subregions); writes with `merge: true` to `users/{uid}`

### Flutter Client
- All `responses` queries updated with `.where('blocked', isNotEqualTo: true)`: `sentiment_stream.dart`, `resonance_web_screen.dart`, `resonance_native_screen.dart`, `global_thread_screen.dart` (compound `Filter.and`)
- `recording_sheet.dart`: removed client-side Firestore `cloud_firestore` import and `.delete()` call — CF uses `tx.set()` atomically
- `storage_service.dart`: `uploadOnboardingAudio` — removed 4 demographic named params; metadata simplified to `contentType: audio/mp4` only
- `firestore_service.dart`: `listenForVerification` check updated from `isFlagged == true` → `verifiedAsHuman == false`
- `onboarding_screen.dart`: rewritten — bot detection flow (hold button, say anything); self-reported demographics collected separately; fire-and-forget `submitSelfReportedDemographics` callable after verification; consent copy updated to reflect no demographic inference from voice
- `pubspec.yaml`: added `cloud_functions: ^5.0.0`

### Privacy Policy
- `web/privacy.html`: audio lifecycle section rewritten to distinguish verification (immediate delete, bot detection only) from sentiment audio (120-day retention); GDPR Art. 17 right to early deletion added; Art. 22 automated decision-making section updated — removed demographic AI classification, now discloses bot detection + sentiment classification; contact email updated to `privacy@stewyrt.com`

### Config & Housekeeping
- `firebase.json`: added `firestore` and `storage` sections referencing new rules/indexes files
- `.gitignore`: added `functions/lib/`, `.firebase/`, `.env`/`*.env`/`functions/.env`, `service-account*.json`, `*.keystore`, `ios/Pods/`

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-09] — Legal overhaul, web platform compatibility, security patches

### Legal & Compliance
- **Privacy Policy** (`web/privacy.html`) rewritten to UK GDPR / PECR standard:
  - GDPR Article 13 disclosures: data controller (Warming Neon Ltd, Co. 16891563), lawful basis per activity, sub-processors (Google Cloud, Firebase, Gemini), international transfer via Standard Contractual Clauses
  - Article 9 explicit consent treatment for biometric voice analysis (special category data)
  - Article 22 automated decision-making disclosure for Gemini demographic classification
  - Full user rights enumeration with ICO contact (ico.org.uk / 0303 123 1113)
  - PECR-compliant cookie disclosure: `stewyrt_session` named, duration and classification stated
  - Data breach notification commitment (72hr ICO window + user notification)
  - Retention periods stated per data type
- **Terms of Service** (`web/terms.html`) overhauled:
  - Duplicate Section 3 numbering fixed; sections now 1–12
  - Data monetisation recipients tightened from "commercial partners" to specific named categories (academic, public health, journalism, research)
  - Content removal / right to erasure mechanism added
  - Governing law clause added: England & Wales, exclusive jurisdiction, £100 liability cap
  - Anonymised vs pseudonymised distinction made explicit
  - Data breach notification commitment added
- `Warming Neon` → `Warming Neon Ltd` throughout both documents
- Age gate raised from **16 to 18** across ToS, Privacy Policy, and onboarding checkbox

### Web Platform Compatibility
- `StorageService`: replaced `dart:io File` + `ref.putFile()` with `ref.putData(bytes)` and conditional import pattern (`upload_bytes_io.dart` / `upload_bytes_web.dart`) — audio upload now works on web
- `boot_router.dart`, `day_one_screen.dart`, `recording_sheet.dart`, `onboarding_screen.dart`: `kIsWeb` guard on `getTemporaryDirectory()` — web uses empty path, native uses temp dir

### UX
- **Boot router**: compliance `SnackBar` shown on web launch; `_init()` wrapped in try/catch with connection-error snackbar
- **Onboarding**: Terms of Service and Privacy Policy labels are now tappable links (`url_launcher`); `_SharpCheckbox` refactored to accept `InlineSpan` instead of `String`
- **Onboarding**: null-safe `FirebaseAuth.currentUser` check before upload

### Bug Fixes
- `pulse_screen.dart`: polls ordered `descending: true` by `createdAt` (was ascending)
- `day_one_screen.dart`: `_TagChip` construction fixed — was using a broken `.map()` loop, now explicit

### Dependencies
- Added `url_launcher ^6.3.0`
- `functions/node_modules` removed from git tracking; `.gitignore` updated — `package-lock.json` is now source of truth

### Security
- `npm audit fix` on `functions/`: patched `protobufjs` (critical — arbitrary code execution), `fast-xml-builder` (high — attribute injection), `fast-xml-parser` (moderate — XML/CDATA injection)
- 9 low-severity `@tootallnate/once` vulns remain; fix requires downgrading `firebase-admin` to v10 (breaking) — deferred

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-25] — Fix: use compensated amplitude for web recording gate

### Flutter Client
- **`lib/screens/onboarding_screen.dart`**, **`lib/widgets/recording_sheet.dart`**, **`lib/screens/day_one_screen.dart`**: Updated the `onAmplitudeChanged` listener to apply `SoftLimiter.webProcess(amp.current)` to `_rawAmplitudes` when running on the web (`kIsWeb`). This fixes a bug where the uncompensated Web Audio API frequency-domain dBFS values would incorrectly trigger the -50.0 dB gate even for valid speech.

---

## [2026-05-25] — Fix: update About copy to clarify data policy and add Google for Startups credit

### Flutter Client
- **`lib/screens/settings_screen.dart`**: Updated the "About Stewyrt" dialog content to more clearly articulate the anonymous data sharing policy and acknowledge support from Google for Startups.

---

## [2026-05-08] — Initial production web release

- Initial commit: Flutter web build deployed to Firebase Hosting
- Cloud Function `analyzeAudio` live: sentiment analysis and demographic verification via Gemini
- Two-tab shell: The Pulse + The Zeitgeist (3D brain visualiser)
- Anonymous auth, Firestore, Firebase Storage wired up
