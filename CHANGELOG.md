# Changelog

All notable changes to Stewyrt are recorded here.  
Format: `[version or date] — summary`, newest first.

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
