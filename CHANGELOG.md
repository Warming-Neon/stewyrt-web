# Changelog

All notable changes to Stewyrt are recorded here.  
Format: `[version or date] — summary`, newest first.

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
