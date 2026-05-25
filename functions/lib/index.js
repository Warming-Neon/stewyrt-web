"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.activateDailyQuestionManual = exports.activateDailyQuestion = exports.submitContentReport = exports.deleteUserData = exports.submitModerationReview = exports.scheduleUpcomingQuestionsManual = exports.scheduleUpcomingQuestions = exports.submitSelfReportedDemographics = exports.purgeOldSentimentAudio = exports.analyzeAudio = void 0;
const admin = require("firebase-admin");
const fs = require("fs");
const os = require("os");
const path = require("path");
const storage_1 = require("firebase-functions/v2/storage");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const https_1 = require("firebase-functions/v2/https");
const params_1 = require("firebase-functions/params");
const genai_1 = require("@google/genai");
admin.initializeApp();
// Store your Gemini API key in Google Cloud Secret Manager:
//   firebase functions:secrets:set GEMINI_API_KEY
const geminiApiKey = (0, params_1.defineSecret)("GEMINI_API_KEY");
// Used to validate whether a client-supplied responseId can be trusted.
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const safetySettings = [
    { category: genai_1.HarmCategory.HARM_CATEGORY_HARASSMENT, threshold: genai_1.HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
    { category: genai_1.HarmCategory.HARM_CATEGORY_HATE_SPEECH, threshold: genai_1.HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
    { category: genai_1.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT, threshold: genai_1.HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
    { category: genai_1.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold: genai_1.HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
];
// Constrained enums for submitSelfReportedDemographics.
const ALLOWED_AGES = ["18-24", "25-34", "35-44", "45-54", "55-64", "65+", "Prefer not to say"];
const ALLOWED_GENDERS = ["Male", "Female", "Non-Binary", "Prefer not to say"];
const ALLOWED_ETHNICITY_CODES = [
    "White_British", "White_Irish", "White_Gypsy_Irish_Traveller", "White_Roma", "White_Other",
    "Mixed_White_Black_Caribbean", "Mixed_White_Black_African", "Mixed_White_Asian", "Mixed_Other",
    "Asian_Indian", "Asian_Pakistani", "Asian_Bangladeshi", "Asian_Chinese", "Asian_Other",
    "Black_African", "Black_Caribbean", "Black_Other",
    "Other_Arab", "Other_Other",
    "prefer_not_to_say", "other_unlisted",
];
const ALLOWED_REGIONS = ["Northern Europe", "Western Europe", "Southern Europe", "Eastern Europe", "North America", "Latin America", "Middle East & North Africa", "Sub-Saharan Africa", "South Asia", "East Asia", "Southeast Asia", "Oceania", "Prefer not to say"];
// ── analyzeAudio ──────────────────────────────────────────────────────────────
// Storage trigger: processes every file uploaded to audio_uploads/.
// Routes on filename prefix:
//   onboarding_* → bot-detection verification flow
//   everything else → sentiment analysis flow
exports.analyzeAudio = (0, storage_1.onObjectFinalized)({ secrets: [geminiApiKey], bucket: "stewyrt-11.firebasestorage.app" }, async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const filePath = event.data.name;
    // Only process uploads into audio_uploads/
    if (!filePath || !filePath.startsWith("audio_uploads/"))
        return;
    const fileName = path.basename(filePath);
    const storageBucket = admin.storage().bucket(event.data.bucket);
    const tempFilePath = path.join(os.tmpdir(), fileName);
    const metadata = (_a = event.data.metadata) !== null && _a !== void 0 ? _a : {};
    const db = admin.firestore();
    await storageBucket.file(filePath).download({ destination: tempFilePath });
    // ── Route: onboarding_ prefix → Verification, otherwise → Sentiment ──────
    if (fileName.startsWith("onboarding_")) {
        // ── BOT-DETECTION VERIFICATION FLOW ─────────────────────────────────────
        // Filename format: onboarding_<uuid>.m4a  (uuid == Firebase Auth UID)
        // Demographic fields are no longer read from metadata — they are collected
        // separately via submitSelfReportedDemographics and never used for inference.
        const uuid = fileName.replace(/^onboarding_/, "").replace(/\.m4a$/, "");
        // ── Verification rate limit: 3 attempts per 24 hours per UID ────────────
        const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
        const userSnap = await db.collection("users").doc(uuid).get();
        let attemptCount = 0;
        let windowStart = null;
        if (userSnap.exists) {
            const d = userSnap.data();
            const prevWin = d["verificationWindowStart"];
            if (prevWin && prevWin.toDate() > twentyFourHoursAgo) {
                attemptCount = (_b = d["verificationAttempts"]) !== null && _b !== void 0 ? _b : 0;
                windowStart = prevWin;
            }
        }
        if (attemptCount >= 5) {
            console.warn(`[STEWYRT] Verification rate limit hit for uid: ${uuid}`);
            if (fs.existsSync(tempFilePath))
                fs.unlinkSync(tempFilePath);
            await storageBucket.file(filePath).delete();
            await db.collection("users").doc(uuid).set({
                verifiedAsHuman: false,
                verificationNote: "Rate limit exceeded (3 attempts per 24h)",
                verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
                verificationAttempts: attemptCount,
                verificationWindowStart: windowStart,
            }, { merge: true });
            await db.collection("system_logs").doc().set({
                type: "verification_rate_limit",
                uid: uuid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            return;
        }
        const newAttemptCount = attemptCount + 1;
        const newWindowStart = windowStart !== null && windowStart !== void 0 ? windowStart : admin.firestore.Timestamp.now();
        let detection = null;
        try {
            const base64Audio = fs.readFileSync(tempFilePath).toString("base64");
            const ai = new genai_1.GoogleGenAI({ apiKey: geminiApiKey.value() });
            const result = await ai.models.generateContent({
                model: "gemini-2.5-flash",
                contents: [
                    {
                        role: "user",
                        parts: [
                            { inlineData: { mimeType: "audio/mp4", data: base64Audio } },
                            { text: "Analyse this audio for humanness." },
                        ],
                    },
                ],
                config: {
                    systemInstruction: `Listen to this audio. Respond with ONLY a JSON object: ` +
                        `{ "isHuman": true|false, "isContinuousSpeech": true|false, "durationSeconds": number, "note": string }. ` +
                        `RULES: ` +
                        `1. isHuman is true ONLY if this is a real, live human voice. ` +
                        `2. Silence, music, or ambient noise MUST return isHuman: false. ` +
                        `3. Synthetic or TTS (Text-to-Speech) voices MUST return isHuman: false. ` +
                        `4. Recording of a recording (playback) MUST return isHuman: false and isContinuousSpeech: false. ` +
                        `5. Audio under 2 seconds MUST return isHuman: false regardless of content. ` +
                        `6. isContinuousSpeech is true if the speech is natural and continuous. ` +
                        `7. note is a brief sentence explaining the assessment.`,
                    responseMimeType: "application/json",
                    safetySettings,
                },
            });
            const raw = ((_c = result.text) !== null && _c !== void 0 ? _c : "").trim();
            const json = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
            detection = JSON.parse(json);
        }
        catch (err) {
            console.error("[STEWYRT] Verification Gemini call failed:", err);
            await db.collection("users").doc(uuid).set({
                verifiedAsHuman: false,
                verificationNote: "Voice verification failed due to server error. Please try again.",
                error: true,
                verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
                verificationAttempts: newAttemptCount,
                verificationWindowStart: newWindowStart,
            });
        }
        finally {
            // Per our consent promise: destroy audio NO MATTER WHAT — crash, error, or success.
            if (fs.existsSync(tempFilePath))
                fs.unlinkSync(tempFilePath);
            await storageBucket.file(filePath).delete();
        }
        // Write the verified profile only on Gemini success.
        if (detection !== null) {
            // LAYER 2 — Cloud Function validation
            // durationSeconds < 2 OR isHuman === false: write verifiedAsHuman: false
            // Do not trust Gemini's response if durationSeconds is missing or null
            const isDurationValid = typeof detection.durationSeconds === "number" && detection.durationSeconds >= 2;
            const verifiedAsHuman = isDurationValid && (detection.isHuman === true);
            await db.collection("users").doc(uuid).set({
                verifiedAsHuman: verifiedAsHuman,
                isContinuousSpeech: (_d = detection.isContinuousSpeech) !== null && _d !== void 0 ? _d : false,
                durationSeconds: (_e = detection.durationSeconds) !== null && _e !== void 0 ? _e : 0,
                verificationNote: (_f = detection.note) !== null && _f !== void 0 ? _f : "",
                verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
                verificationAttempts: newAttemptCount,
                verificationWindowStart: newWindowStart,
            });
        }
    }
    else {
        // ── SENTIMENT ANALYSIS FLOW ──────────────────────────────────────────────
        const uuid = fileName.replace(/\.m4a$/, "");
        const question = (_g = metadata["question"]) !== null && _g !== void 0 ? _g : "What is on your mind right now?";
        const rawResponseId = (_h = metadata["responseId"]) !== null && _h !== void 0 ? _h : "";
        const rawPollId = (_j = metadata["pollId"]) !== null && _j !== void 0 ? _j : "";
        // 1.2 — Derive a server-trusted responseId.
        // Trust only if it matches UUID v4; otherwise fall back to the storage filename UUID.
        const trustedResponseId = UUID_V4_RE.test(rawResponseId) ? rawResponseId : uuid;
        // 1.5 — Rate limiting: attempt to derive UID from available signals.
        // "owner" metadata is not currently set by the client. In production mode,
        // responseId = {uid}_{pollId}, from which the UID can be extracted.
        // Falls back to null in beta mode (UUID v4 responseId) — rate limiting is skipped.
        const rateUid = extractUidForRateLimit(rawResponseId);
        if (rateUid) {
            const oneHourAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 60 * 1000));
            const countSnap = await db
                .collection("responses")
                .where("uid", "==", rateUid)
                .where("createdAt", ">", oneHourAgo)
                .count()
                .get();
            if (countSnap.data().count >= 30) {
                console.warn(`[STEWYRT] Rate limit hit for uid: ${rateUid}`);
                if (fs.existsSync(tempFilePath))
                    fs.unlinkSync(tempFilePath);
                await db.collection("responses").doc(trustedResponseId).set({
                    blocked: true,
                    blockedReason: "rate_limit",
                    uid: rateUid,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                return;
            }
        }
        // 1.2 — Validate pollId: confirm the referenced poll document exists
        // before trusting it for counter increments.
        // Graceful fallback: if poll is missing, write the response with pollId=null
        // and skip counter update rather than failing the entire write.
        let trustedPollId = rawPollId || null;
        if (trustedPollId) {
            const pollSnap = await db.collection("polls").doc(trustedPollId).get();
            if (!pollSnap.exists) {
                console.warn(`[STEWYRT] pollId '${trustedPollId}' not found in polls — omitting poll counter update`);
                trustedPollId = null;
            }
        }
        // Definite assignment: TypeScript is told analysis will be set before use.
        let analysis;
        try {
            const base64Audio = fs.readFileSync(tempFilePath).toString("base64");
            const ai = new genai_1.GoogleGenAI({ apiKey: geminiApiKey.value() });
            const result = await ai.models.generateContent({
                model: "gemini-2.5-flash",
                contents: [
                    {
                        role: "user",
                        parts: [
                            { inlineData: { mimeType: "audio/mp4", data: base64Audio } },
                            { text: "Analyze this audio recording." },
                        ],
                    },
                ],
                config: {
                    systemInstruction: `You are the analysis engine for Stewyrt, an anonymous audio sentiment platform. ` +
                        `CONTENT MODERATION STEP (evaluate first, before anything else): ` +
                        `If the audio contains ANY of the following, you MUST return ONLY ` +
                        `{ "blocked": true } and nothing else: ` +
                        `- Direct threats of violence or death against any person or group ` +
                        `- Incitement to violence, murder, or self-harm ` +
                        `- Hate speech targeting protected characteristics (race, religion, gender, sexuality, etc.) ` +
                        `- Sexual content involving minors ` +
                        `- Content that glorifies or promotes terrorism or mass violence ` +
                        `If the audio passes moderation, proceed with analysis. ` +
                        `The user is responding to this specific prompt: "${question}". Analyze the raw audio's ` +
                        `semantic meaning AND acoustic delivery in the direct context of ` +
                        `this question. ` +
                        `Step 1: Generate a single-word 'tone' (the overarching emotional state). ` +
                        `Step 2: Generate a single-word 'flavor' (the specific nuance of that tone). ` +
                        `Step 3: Generate a single-word 'essence' (a profound adjective describing the philosophical weight). ` +
                        `Step 4: Write a 3-to-4 word summary that captures the CORE MESSAGE — ` +
                        `the actual substance of what the person said, not how they felt saying it. ` +
                        `The tone, flavor, and essence fields already carry the emotional layer. ` +
                        `The summary must answer: what did this person actually argue, claim, or call for? ` +
                        `Write it as a tight, specific news headline. ` +
                        `BAD examples (too emotional, no content): "Drowning in silent rage", "Heavy heart speaking". ` +
                        `GOOD examples (content-first): "Leaders ignoring climate reality", "Loneliness epidemic ignored", ` +
                        `"Wealth gap destroying communities", "Education system failing children". ` +
                        `Step 5: Assign an 'anatomicalRegion' — the brain region where the overall sentiment of this audio ` +
                        `is primarily processed. You MUST choose exactly ONE of these four strings: ` +
                        `"Prefrontal" (for complex, societal, or reflective thought — irony, disillusionment, curiosity, conflict), ` +
                        `"Amygdala" (for primal, intense emotions — fury, panic, fear, defeat, desperation), ` +
                        `"Nucleus" (for reward, hope, joy, inspiration, gratitude, and positive motivation), ` +
                        `"Insula" (for disgust, numbness, deep melancholy, alienation, or visceral unease). ` +
                        `Step 6: Identify the language the speaker used and output its 2-letter ISO 639-1 code as 'language' (e.g. "en", "es", "ja", "fr"). ` +
                        `IMPORTANT LANGUAGE RULES: The speaker may speak in ANY language. ` +
                        `You MUST output tone, flavor, and essence STRICTLY IN ENGLISH regardless of the audio language. ` +
                        `You MUST write the summary in the speaker's original native language (the language identified in Step 6). ` +
                        `Output ONLY a JSON object with this schema: ` +
                        `{ "tone": "Word", "flavor": "Word", "essence": "Word", "summary": "Content headline in speaker's language", "anatomicalRegion": "Region", "language": "xx" }.`,
                    responseMimeType: "application/json",
                    safetySettings,
                },
            });
            const raw = ((_k = result.text) !== null && _k !== void 0 ? _k : "").trim();
            const json = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
            analysis = JSON.parse(json);
            if (analysis.blocked === true) {
                console.warn(`[STEWYRT] Content moderation blocked — responseId: ${trustedResponseId}`);
                if (fs.existsSync(tempFilePath))
                    fs.unlinkSync(tempFilePath);
                await db.collection("responses").doc(trustedResponseId).set({
                    blocked: true,
                    blockedReason: "content_policy",
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                return;
            }
        }
        catch (err) {
            console.error("Content blocked or Gemini analysis failed:", err);
            if (fs.existsSync(tempFilePath))
                fs.unlinkSync(tempFilePath);
            return;
        }
        if (fs.existsSync(tempFilePath))
            fs.unlinkSync(tempFilePath);
        // ── Atomic Firestore writes ─────────────────────────────────────────────
        const responseRef = db.collection("responses").doc(trustedResponseId);
        const pollRef = trustedPollId ? db.collection("polls").doc(trustedPollId) : null;
        await db.runTransaction(async (tx) => {
            var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const doc = {
                uuid,
                audioPath: filePath,
                tone: (_a = analysis.tone) !== null && _a !== void 0 ? _a : "",
                flavor: (_b = analysis.flavor) !== null && _b !== void 0 ? _b : "",
                essence: (_c = analysis.essence) !== null && _c !== void 0 ? _c : "",
                summary: (_d = analysis.summary) !== null && _d !== void 0 ? _d : "",
                analysis_chain: (_e = analysis.analysis_chain) !== null && _e !== void 0 ? _e : "",
                anatomicalRegion: (_f = analysis.anatomicalRegion) !== null && _f !== void 0 ? _f : "Prefrontal",
                // Per-field region mirrors for the Flutter → Three.js bridge.
                // All three tags share the same overall region for this response.
                toneRegion: (_g = analysis.anatomicalRegion) !== null && _g !== void 0 ? _g : "Prefrontal",
                flavorRegion: (_h = analysis.anatomicalRegion) !== null && _h !== void 0 ? _h : "Prefrontal",
                essenceRegion: (_j = analysis.anatomicalRegion) !== null && _j !== void 0 ? _j : "Prefrontal",
                language: (_k = analysis.language) !== null && _k !== void 0 ? _k : "en",
                question,
                pollId: trustedPollId !== null && trustedPollId !== void 0 ? trustedPollId : "",
                // 1.1: explicit false is required for collection queries scoped with
                // .where('blocked', isNotEqualTo: true) to match this document.
                // Omitting the field causes those queries to skip the document.
                blocked: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            };
            // UID derivation: storage triggers have no auth context. UID is parsed
            // from responseId when it is in production format ({uid}_{pollId}).
            // In beta mode (UUID v4 responseId) UID is unavailable — no uid field
            // is written. Beta-mode responses are excluded from GDPR erasure via
            // deleteUserData; the 120-day audio purge is their only erasure path.
            if (rateUid)
                doc["uid"] = rateUid;
            tx.set(responseRef, doc);
            if (pollRef) {
                tx.update(pollRef, {
                    total_submissions: admin.firestore.FieldValue.increment(1),
                    [`counts.tone.${analysis.tone}`]: admin.firestore.FieldValue.increment(1),
                    [`counts.flavor.${analysis.flavor}`]: admin.firestore.FieldValue.increment(1),
                    [`counts.essence.${analysis.essence}`]: admin.firestore.FieldValue.increment(1),
                });
            }
        });
    }
});
// In production mode, UID is derived server-side from responseId ({uid}_{pollId}).
// In beta mode, rate limiting is disabled. Client-supplied metadata is never trusted.
function extractUidForRateLimit(responseId) {
    if (!UUID_V4_RE.test(responseId)) {
        const idx = responseId.indexOf("_");
        if (idx > 10)
            return responseId.substring(0, idx);
    }
    return null;
}
// ── purgeOldSentimentAudio ────────────────────────────────────────────────────
// Deletes sentiment audio files older than 120 days from Storage.
// Runs daily at 03:00 UTC. Does NOT touch Firestore response documents.
// Idempotent: the system_logs doc is overwritten on repeat runs within the same day.
exports.purgeOldSentimentAudio = (0, scheduler_1.onSchedule)({ schedule: "0 3 * * *", timeZone: "UTC" }, async () => {
    var _a;
    const bucket = admin.storage().bucket("stewyrt-11.firebasestorage.app");
    const db = admin.firestore();
    const cutoffMs = Date.now() - 120 * 24 * 60 * 60 * 1000;
    const todayKey = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
    let filesDeleted = 0;
    let bytesFreed = 0;
    const errors = [];
    const [files] = await bucket.getFiles({ prefix: "audio_uploads/" });
    const targets = files.filter((f) => {
        var _a;
        // Never purge verification audio — it should already be deleted immediately
        // after processing, but exclude it here as a safety net.
        if (path.basename(f.name).startsWith("onboarding_"))
            return false;
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const created = (_a = f.metadata) === null || _a === void 0 ? void 0 : _a.timeCreated;
        if (!created)
            return false;
        return new Date(created).getTime() < cutoffMs;
    });
    for (const file of targets) {
        try {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const sizeRaw = (_a = file.metadata) === null || _a === void 0 ? void 0 : _a.size;
            const size = typeof sizeRaw === "number" ? sizeRaw
                : typeof sizeRaw === "string" ? parseInt(sizeRaw, 10)
                    : 0;
            await file.delete();
            filesDeleted++;
            bytesFreed += isNaN(size) ? 0 : size;
        }
        catch (err) {
            const msg = `${file.name}: ${String(err)}`;
            console.error(`[STEWYRT] Purge error — ${msg}`);
            errors.push(msg);
        }
    }
    console.log(`[STEWYRT] Audio purge complete — ${filesDeleted} files deleted, ` +
        `${bytesFreed} bytes freed, ${errors.length} errors`);
    await db.collection("system_logs").doc(todayKey).set({
        type: "audio_purge",
        filesDeleted,
        bytesFreed,
        errors,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
});
// ── submitSelfReportedDemographics ────────────────────────────────────────────
// Callable: client submits self-reported demographics after onboarding.
// These are stored separately from the bot-detection verification result and
// are never used for acoustic inference.
exports.submitSelfReportedDemographics = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const { age, gender, ethnicity, ethnicityCode, region } = request.data;
    if (!age || !ALLOWED_AGES.includes(age))
        throw new https_1.HttpsError("invalid-argument", `Invalid age value: ${age}`);
    if (!gender || !ALLOWED_GENDERS.includes(gender))
        throw new https_1.HttpsError("invalid-argument", `Invalid gender value: ${gender}`);
    if (!ethnicity || typeof ethnicity !== "string" || !ethnicity.trim())
        throw new https_1.HttpsError("invalid-argument", "ethnicity is required.");
    if (!ethnicityCode || !ALLOWED_ETHNICITY_CODES.includes(ethnicityCode))
        throw new https_1.HttpsError("invalid-argument", `Invalid ethnicityCode value: ${ethnicityCode}`);
    if (!region || !ALLOWED_REGIONS.includes(region))
        throw new https_1.HttpsError("invalid-argument", `Invalid region value: ${region}`);
    const uid = request.auth.uid;
    const db = admin.firestore();
    // merge: true preserves verifiedAsHuman and other verification fields.
    await db.collection("users").doc(uid).set({
        selfReportedAge: age,
        selfReportedGender: gender,
        selfReportedEthnicity: ethnicity,
        selfReportedEthnicityCode: ethnicityCode,
        selfReportedRegion: region,
        selfReportedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { success: true };
});
// ── updateQuestionUsage ───────────────────────────────────────────────────────
// Increments times_used, sets last_used_date, and sets first_used_date only on
// first use. Called by runDailyActivation when a question goes live.
async function updateQuestionUsage(db, questionId, isFirstUse) {
    const ref = db.collection("questions").doc(questionId);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const update = {
        times_used: admin.firestore.FieldValue.increment(1),
        last_used_date: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (isFirstUse) {
        update["first_used_date"] = admin.firestore.FieldValue.serverTimestamp();
    }
    await ref.update(update);
}
const WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
// Required pulse category per day-of-week. Saturday handled separately (alternates by week parity).
const DAY_CATEGORY = {
    monday: "rebellion",
    tuesday: "reflective",
    wednesday: "confessional",
    thursday: "provocative",
    friday: "whimsical",
    saturday: "retrospective",
    sunday: "existential",
};
function utcDateStr(d) {
    return d.toISOString().slice(0, 10);
}
function addUTCDays(d, n) {
    const r = new Date(d);
    r.setUTCDate(r.getUTCDate() + n);
    return r;
}
// ISO week number (1–53). Week starts Monday.
function isoWeekNumber(d) {
    const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
    t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
    const jan1 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
    return Math.ceil(((t.getTime() - jan1.getTime()) / 86400000 + 1) / 7);
}
// Returns the Monday (UTC midnight) of the week containing d.
function mondayOf(d) {
    const day = d.getUTCDay(); // 0 = Sunday
    return addUTCDays(d, day === 0 ? -6 : 1 - day);
}
function cooldownOk(q, nowMs) {
    if (!q.last_used_date)
        return true;
    return nowMs - q.last_used_date.toDate().getTime() > q.cooldown_days * 86400000;
}
// Returns the required category/categories for a given day.
// odd ISO week = retrospective, even = anticipatory (Saturday alternation).
function requiredCategories(dayName, week) {
    if (dayName === "saturday") {
        return [week % 2 === 1 ? "retrospective" : "anticipatory"];
    }
    const cat = DAY_CATEGORY[dayName];
    return cat ? [cat] : [];
}
// Sorts candidates in preference order and returns the best pick.
// Priority: (1) day_affinity match, (2) emotional balance, (3) fewest uses.
function pickBest(candidates, dayName, recentWeights) {
    // Deprioritise heavy questions only when the preceding 2 days were both heavy.
    const precedingBothHeavy = recentWeights.length >= 2 &&
        recentWeights[recentWeights.length - 1] === "heavy" &&
        recentWeights[recentWeights.length - 2] === "heavy";
    return [...candidates].sort((a, b) => {
        const afA = a.day_affinity === dayName ? 0 : 1;
        const afB = b.day_affinity === dayName ? 0 : 1;
        if (afA !== afB)
            return afA - afB;
        if (precedingBothHeavy) {
            const hvA = a.emotional_weight === "heavy" ? 1 : 0;
            const hvB = b.emotional_weight === "heavy" ? 1 : 0;
            if (hvA !== hvB)
                return hvA - hvB;
        }
        return a.times_used - b.times_used;
    })[0];
}
async function runScheduler(db) {
    var _a, _b, _c, _d;
    const now = new Date();
    const nowMs = now.getTime();
    const summary = {
        run_at: now.toISOString(),
        dates_processed: [],
        assignments: {},
        warnings: [],
        horizon_updated: false,
        horizon_question_id: null,
    };
    // ── 1. 14-day scheduling window (tomorrow → day 14) ───────────────────────
    const dates = [];
    for (let i = 1; i <= 14; i++)
        dates.push(utcDateStr(addUTCDays(now, i)));
    // ── 2. Fetch all approved questions (both tiers) ──────────────────────────
    const [pulseSnap, horizonSnap] = await Promise.all([
        db.collection("questions").where("tier", "==", "pulse").where("status", "==", "approved").get(),
        db.collection("questions").where("tier", "==", "horizon").where("status", "==", "approved").get(),
    ]);
    const pulseQ = pulseSnap.docs.map((d) => ({
        id: d.id, ...d.data(),
    }));
    const horizonQ = horizonSnap.docs.map((d) => ({
        id: d.id, ...d.data(),
    }));
    // ── 3. Fetch schedule context: 7 days prior + full 14-day window ──────────
    // Used for: prior emotional context, previous horizon ID, and locked entries.
    const contextStart = utcDateStr(addUTCDays(now, -7));
    const windowEnd = dates[dates.length - 1];
    const schedSnap = await db.collection("question_schedule")
        .where(admin.firestore.FieldPath.documentId(), ">=", contextStart)
        .where(admin.firestore.FieldPath.documentId(), "<=", windowEnd)
        .get();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const existing = {};
    for (const doc of schedSnap.docs)
        existing[doc.id] = doc.data();
    // ── 4. Seed the assigned-IDs set with already-locked pulse IDs ───────────
    // Prevents double-booking: a question locked on date A can't be picked for B.
    const assignedIds = new Set();
    for (const date of dates) {
        const e = existing[date];
        if ((e === null || e === void 0 ? void 0 : e.pulse_locked) && (e === null || e === void 0 ? void 0 : e.pulse_question_id))
            assignedIds.add(e.pulse_question_id);
    }
    // ── 5. Prime emotional-weight context from the 2 days before the window ───
    const recentWeights = [];
    for (let offset = -2; offset <= -1; offset++) {
        const pid = (_a = existing[utcDateStr(addUTCDays(now, offset))]) === null || _a === void 0 ? void 0 : _a.pulse_question_id;
        if (pid) {
            const q = pulseQ.find((q) => q.id === pid);
            if (q)
                recentWeights.push(q.emotional_weight);
        }
    }
    // ── 6. Horizon selection — one per Monday-to-Sunday calendar week ─────────
    // Group the 14 dates by their Monday.
    const weekGroups = new Map();
    for (const date of dates) {
        const monday = utcDateStr(mondayOf(new Date(date + "T00:00:00Z")));
        if (!weekGroups.has(monday))
            weekGroups.set(monday, []);
        weekGroups.get(monday).push(date);
    }
    // Find the most recent horizon set before this scheduling window.
    let prevHorizonId = null;
    for (const d of Object.keys(existing).filter((d) => d < dates[0]).sort().reverse()) {
        const hid = (_b = existing[d]) === null || _b === void 0 ? void 0 : _b.horizon_question_id;
        if (hid) {
            prevHorizonId = hid;
            break;
        }
    }
    const weekHorizonIds = new Map();
    for (const [monday, weekDates] of weekGroups) {
        // If any window-day in this week is horizon-locked, use that ID for all days.
        let lockedId = null;
        for (const date of weekDates) {
            const e = existing[date];
            if ((e === null || e === void 0 ? void 0 : e.horizon_locked) && (e === null || e === void 0 ? void 0 : e.horizon_question_id)) {
                lockedId = e.horizon_question_id;
                break;
            }
        }
        if (lockedId) {
            weekHorizonIds.set(monday, lockedId);
            continue;
        }
        // A prior scheduler run may have already assigned a horizon for this week
        // (on days that fall within our 7-day context window).
        let priorId = null;
        const weekStart = new Date(monday + "T00:00:00Z");
        for (let i = 0; i < 7 && !priorId; i++) {
            const hid = (_c = existing[utcDateStr(addUTCDays(weekStart, i))]) === null || _c === void 0 ? void 0 : _c.horizon_question_id;
            if (hid)
                priorId = hid;
        }
        if (priorId) {
            weekHorizonIds.set(monday, priorId);
            continue;
        }
        // Select a new horizon: eligible = cooldown OK and not the immediately prior one.
        const eligible = [...horizonQ]
            .filter((q) => cooldownOk(q, nowMs) && q.id !== prevHorizonId)
            .sort((a, b) => a.times_used !== b.times_used ? a.times_used - b.times_used : Math.random() - 0.5);
        if (eligible.length === 0) {
            const warn = `No eligible horizon question for week of ${monday}`;
            console.warn(`[SCHEDULER] ${warn}`);
            summary.warnings.push(warn);
            weekHorizonIds.set(monday, null);
            continue;
        }
        const chosen = eligible[0];
        weekHorizonIds.set(monday, chosen.id);
        prevHorizonId = chosen.id; // used as exclusion for the next week in this same run
        summary.horizon_updated = true;
        summary.horizon_question_id = chosen.id;
        console.log(`[SCHEDULER] Horizon for week of ${monday}: "${chosen.text.slice(0, 60)}"`);
    }
    // ── 7. Assign pulse for each date and commit via batch ────────────────────
    const batch = db.batch();
    for (const date of dates) {
        const e = existing[date];
        const pulseLocked = (e === null || e === void 0 ? void 0 : e.pulse_locked) === true;
        const horizonLocked = (e === null || e === void 0 ? void 0 : e.horizon_locked) === true;
        const d = new Date(date + "T00:00:00Z");
        const dayName = WEEKDAY_NAMES[d.getUTCDay()];
        const week = isoWeekNumber(d);
        const monday = utcDateStr(mondayOf(d));
        let pulseId = null;
        if (pulseLocked) {
            pulseId = e.pulse_question_id;
            // Keep emotional-weight context current even for locked days.
            const q = pulseQ.find((q) => q.id === pulseId);
            if (q) {
                recentWeights.push(q.emotional_weight);
                if (recentWeights.length > 2)
                    recentWeights.shift();
            }
        }
        else {
            const cats = requiredCategories(dayName, week);
            const candidates = pulseQ.filter((q) => cats.includes(q.category) && cooldownOk(q, nowMs) && !assignedIds.has(q.id));
            if (candidates.length === 0) {
                // No valid candidate — leave a gap rather than pick the wrong category.
                const warn = `No pulse candidate for ${date} (${dayName}, ${cats.join("/")}) — needs_question`;
                console.warn(`[SCHEDULER] ${warn}`);
                summary.warnings.push(warn);
                // pulseId remains null; docData.status will be set to "needs_question" below.
            }
            else {
                const best = pickBest(candidates, dayName, recentWeights);
                pulseId = best.id;
                assignedIds.add(best.id);
                recentWeights.push(best.emotional_weight);
                if (recentWeights.length > 2)
                    recentWeights.shift();
                console.log(`[SCHEDULER] Pulse for ${date} (${dayName}): "${best.text.slice(0, 50)}"`);
            }
        }
        const horizonId = horizonLocked
            ? e.horizon_question_id
            : ((_d = weekHorizonIds.get(monday)) !== null && _d !== void 0 ? _d : null);
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const docData = {
            pulse_question_id: pulseId,
            horizon_question_id: horizonId,
            pulse_locked: pulseLocked,
            horizon_locked: horizonLocked,
            updated_at: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (!e)
            docData.created_at = admin.firestore.FieldValue.serverTimestamp();
        if (!pulseId && !pulseLocked)
            docData.status = "needs_question";
        batch.set(db.collection("question_schedule").doc(date), docData, { merge: true });
        summary.dates_processed.push(date);
        summary.assignments[date] = { pulse: pulseId, horizon: horizonId };
    }
    await batch.commit();
    // ── 8. Write run summary to scheduling_log ────────────────────────────────
    // No email provider is configured. Review runs at:
    //   Firestore > scheduling_log > <log-id>
    // TODO: email summary to tee_em@warmingneon.com once a provider is wired.
    const logId = now.toISOString().replace(/[:.]/g, "-").slice(0, 19);
    await db.collection("scheduling_log").doc(logId).set({
        ...summary,
        completed_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`[SCHEDULER] Done — ${summary.dates_processed.length} dates processed, ` +
        `${summary.warnings.length} warning(s). Review: scheduling_log/${logId}`);
    return summary;
}
// Scheduled: every Sunday at 02:00 UTC.
exports.scheduleUpcomingQuestions = (0, scheduler_1.onSchedule)({ schedule: "0 2 * * 0", timeZone: "UTC" }, async () => { await runScheduler(admin.firestore()); });
// Callable: on-demand admin trigger. Requires Firebase Auth.
// Returns the full SchedulerSummary so you can inspect results immediately.
exports.scheduleUpcomingQuestionsManual = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    return await runScheduler(admin.firestore());
});
// ── submitModerationReview ────────────────────────────────────────────────────
// Callable: client submits a human-review request for a blocked response.
// Validates that the responseId belongs to a real blocked response, then
// writes a moderation_review doc for human triage.
exports.submitModerationReview = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const { responseId } = request.data;
    if (!responseId || typeof responseId !== "string" || responseId.trim().length === 0) {
        throw new https_1.HttpsError("invalid-argument", "responseId is required.");
    }
    const db = admin.firestore();
    const responseSnap = await db.collection("responses").doc(responseId).get();
    if (!responseSnap.exists) {
        throw new https_1.HttpsError("not-found", "Response not found.");
    }
    const data = responseSnap.data();
    if (data["blocked"] !== true) {
        throw new https_1.HttpsError("failed-precondition", "Response is not blocked.");
    }
    await db.collection("moderation_review").add({
        responseId,
        audioPath: (_a = data["audioPath"]) !== null && _a !== void 0 ? _a : null,
        geminiClassification: (_b = data["blockedReason"]) !== null && _b !== void 0 ? _b : null,
        submittedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewedAt: null,
        reviewerNotes: null,
        finalDecision: null,
        userMessage: "User requested review",
        requestorUid: request.auth.uid,
    });
    return { success: true };
});
// ── deleteUserData ────────────────────────────────────────────────────────────
// Callable. Permanently deletes all data held for the authenticated caller:
//   1. Firestore response docs where uid == caller uid (production mode only;
//      beta-mode responses use random UUIDs and carry no uid field).
//   2. The users/{uid} document.
//   3. The onboarding audio file (audio_uploads/onboarding_{uid}.m4a) if still
//      present — normally deleted immediately post-verification, so this is
//      defensive cleanup.
// Sentiment audio clips use random UUIDs in their path and cannot be enumerated
// by uid; the 120-day purge schedule handles eventual deletion.
exports.deleteUserData = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const uid = request.auth.uid;
    const db = admin.firestore();
    const bucket = admin.storage().bucket("stewyrt-11.firebasestorage.app");
    // 1. Delete response docs (where uid is stored — production mode).
    const responsesSnap = await db.collection("responses").where("uid", "==", uid).get();
    if (!responsesSnap.empty) {
        const batch = db.batch();
        for (const doc of responsesSnap.docs)
            batch.delete(doc.ref);
        await batch.commit();
    }
    // 2. Delete the user document.
    await db.collection("users").doc(uid).delete();
    // 3. Attempt to delete onboarding audio (already gone in most cases).
    try {
        await bucket.file(`audio_uploads/onboarding_${uid}.m4a`).delete();
    }
    catch (_) {
        // File not found — expected; ignore.
    }
    return { success: true };
});
// ── submitContentReport ───────────────────────────────────────────────────────
// Callable. Accepts { responseId, reason } from an authenticated user and
// writes a moderation record to content_reports.
// Rate limit: max 10 reports per user per rolling hour.
exports.submitContentReport = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const uid = request.auth.uid;
    const data = request.data;
    // Validate inputs.
    if (typeof data.responseId !== "string" || !UUID_V4_RE.test(data.responseId)) {
        throw new https_1.HttpsError("invalid-argument", "responseId must be a valid UUID v4.");
    }
    const responseId = data.responseId;
    const ALLOWED_REASONS = [
        "harassment",
        "hate_speech",
        "spam",
        "misinformation",
        "other",
    ];
    if (typeof data.reason !== "string" || !ALLOWED_REASONS.includes(data.reason)) {
        throw new https_1.HttpsError("invalid-argument", "reason must be one of the allowed values.");
    }
    const reason = data.reason;
    const db = admin.firestore();
    // Rate limit: max 10 reports per user per rolling hour.
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const recentSnap = await db
        .collection("content_reports")
        .where("reportedBy", "==", uid)
        .where("reportedAt", ">=", oneHourAgo)
        .get();
    if (recentSnap.size >= 10) {
        throw new https_1.HttpsError("resource-exhausted", "Report limit reached. Try again later.");
    }
    // Verify the response doc exists.
    const responseDoc = await db.collection("responses").doc(responseId).get();
    if (!responseDoc.exists) {
        throw new https_1.HttpsError("not-found", "Response not found.");
    }
    // Write the report.
    await db.collection("content_reports").add({
        responseId,
        reason,
        reportedBy: uid,
        reportedAt: admin.firestore.FieldValue.serverTimestamp(),
        reviewed: false,
    });
    return { success: true };
});
async function runDailyActivation(db) {
    const now = new Date();
    const today = now.toISOString().slice(0, 10); // YYYY-MM-DD UTC
    const isMonday = now.getUTCDay() === 1;
    const summary = {
        date: today,
        pulseQuestionText: null,
        newPulsePollId: null,
        horizonActivated: false,
        horizonReason: "",
        horizonQuestionText: null,
        newHorizonPollId: null,
        previousPollsDeactivated: [],
        warnings: [],
    };
    // 1. Read today's schedule entry.
    const schedSnap = await db.collection("question_schedule").doc(today).get();
    if (!schedSnap.exists) {
        const warn = `question_schedule/${today} missing — aborting activation`;
        console.warn(`[ACTIVATION] ${warn}`);
        summary.warnings.push(warn);
        return summary;
    }
    const sched = schedSnap.data();
    const pulseQuestionId = sched["pulse_question_id"];
    const horizonQuestionId = sched["horizon_question_id"];
    if (!pulseQuestionId) {
        const warn = `question_schedule/${today} has no pulse_question_id — aborting activation`;
        console.warn(`[ACTIVATION] ${warn}`);
        summary.warnings.push(warn);
        return summary;
    }
    // ── PULSE ACTIVATION ──────────────────────────────────────────────────────
    const pulseQSnap = await db.collection("questions").doc(pulseQuestionId).get();
    if (!pulseQSnap.exists) {
        const warn = `questions/${pulseQuestionId} not found — aborting pulse activation`;
        console.warn(`[ACTIVATION] ${warn}`);
        summary.warnings.push(warn);
        return summary;
    }
    const pulseQData = pulseQSnap.data();
    const pulseText = pulseQData["text"];
    const isFirstPulseUse = !pulseQData["first_used_date"];
    // Deactivate previous active pulse polls.
    const prevPulseSnap = await db.collection("polls")
        .where("tier", "==", "pulse")
        .where("isActive", "==", true)
        .get();
    const deactivateBatch = db.batch();
    for (const doc of prevPulseSnap.docs) {
        deactivateBatch.update(doc.ref, { isActive: false });
        summary.previousPollsDeactivated.push(doc.id);
    }
    await deactivateBatch.commit();
    // Create new pulse poll.
    const newPulseRef = await db.collection("polls").add({
        tier: "pulse",
        question: pulseText,
        questionId: pulseQuestionId,
        isActive: true,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await updateQuestionUsage(db, pulseQuestionId, isFirstPulseUse);
    summary.pulseQuestionText = pulseText;
    summary.newPulsePollId = newPulseRef.id;
    console.log(`[ACTIVATION] Pulse activated — pollId: ${newPulseRef.id}, question: "${pulseText.slice(0, 60)}"`);
    // ── HORIZON ACTIVATION (Mondays only) ────────────────────────────────────
    if (!isMonday) {
        summary.horizonReason = "not Monday";
    }
    else if (!horizonQuestionId) {
        const warn = `question_schedule/${today} has no horizon_question_id — skipping horizon`;
        console.warn(`[ACTIVATION] ${warn}`);
        summary.warnings.push(warn);
        summary.horizonReason = "no horizon_question_id in schedule";
    }
    else {
        const horizonQSnap = await db.collection("questions").doc(horizonQuestionId).get();
        if (!horizonQSnap.exists) {
            const warn = `questions/${horizonQuestionId} not found — skipping horizon`;
            console.warn(`[ACTIVATION] ${warn}`);
            summary.warnings.push(warn);
            summary.horizonReason = "horizon question doc missing";
        }
        else {
            const horizonQData = horizonQSnap.data();
            const horizonText = horizonQData["text"];
            const isFirstHorizonUse = !horizonQData["first_used_date"];
            // Deactivate previous active horizon polls.
            const prevHorizonSnap = await db.collection("polls")
                .where("tier", "==", "horizon")
                .where("isActive", "==", true)
                .get();
            const horizonBatch = db.batch();
            for (const doc of prevHorizonSnap.docs) {
                horizonBatch.update(doc.ref, { isActive: false });
                summary.previousPollsDeactivated.push(doc.id);
            }
            await horizonBatch.commit();
            // Create new horizon poll.
            const newHorizonRef = await db.collection("polls").add({
                tier: "horizon",
                question: horizonText,
                questionId: horizonQuestionId,
                isActive: true,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            await updateQuestionUsage(db, horizonQuestionId, isFirstHorizonUse);
            summary.horizonActivated = true;
            summary.horizonReason = "Monday — activated";
            summary.horizonQuestionText = horizonText;
            summary.newHorizonPollId = newHorizonRef.id;
            console.log(`[ACTIVATION] Horizon activated — pollId: ${newHorizonRef.id}, question: "${horizonText.slice(0, 60)}"`);
        }
    }
    return summary;
}
// Scheduled: daily at 00:01 UTC.
exports.activateDailyQuestion = (0, scheduler_1.onSchedule)({ schedule: "1 0 * * *", timeZone: "UTC" }, async () => { await runDailyActivation(admin.firestore()); });
// Callable: immediate manual trigger. Returns the full ActivationSummary.
exports.activateDailyQuestionManual = (0, https_1.onCall)(async (request) => {
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    return await runDailyActivation(admin.firestore());
});
//# sourceMappingURL=index.js.map