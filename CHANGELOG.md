# Changelog

All notable changes to Stewyrt are recorded here.  
Format: `[version or date] — summary`, newest first.

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

## [2026-05-09] — Cost & security hardening: verification rate limiting, metadata trust removal

### Cloud Functions (`functions/src/index.ts`)
- **Verification rate limit (FIX 1):** `analyzeAudio` now enforces 3 verification attempts per 24h per UID before invoking Gemini. Reads `verificationWindowStart` + `verificationAttempts` from `users/{uid}`; blocks and deletes audio without a Gemini call if limit is exceeded. Writes `{ verifiedAsHuman: false, verificationNote: "Rate limit exceeded..." }` and logs a `system_logs` entry with `type: "verification_rate_limit"`. Both success and error write paths now persist the counter fields, advancing the window on each real attempt.
- **Remove `metadata["owner"]` trust surface (FIX 2):** `extractUidForRateLimit` no longer accepts or trusts client-supplied `metadata["owner"]` as a UID source. UID is derived server-side from `responseId` in production mode only; client metadata is never trusted for routing. Documented with an explicit comment.

### Storage (`storage.rules`)
- **Comment update (FIX 3):** Added bandwidth-risk + App Check mitigation comment above the `audio_uploads/` read rule per audit recommendation.

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

## [2026-05-08] — Initial production web release

- Initial commit: Flutter web build deployed to Firebase Hosting
- Cloud Function `analyzeAudio` live: sentiment analysis and demographic verification via Gemini
- Two-tab shell: The Pulse + The Zeitgeist (3D brain visualiser)
- Anonymous auth, Firestore, Firebase Storage wired up
