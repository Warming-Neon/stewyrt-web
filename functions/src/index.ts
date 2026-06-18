import * as admin from "firebase-admin";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as nodemailer from "nodemailer";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  GoogleGenAI,
  HarmCategory,
  HarmBlockThreshold,
} from "@google/genai";

admin.initializeApp();

// Used to validate whether a client-supplied responseId can be trusted.
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface AnalysisResult {
  tone:             string;
  flavor:           string;
  essence:          string;
  summary:          string;
  analysis_chain:   string;
  anatomicalRegion: string; // one of: Prefrontal | Amygdala | Nucleus | Insula
  language:         string; // 2-letter ISO 639-1 code of the speaker's language
  blocked?:         boolean; // set to true by the model if content violates policy
}

interface HumanDetectionResult {
  isHuman:            boolean;
  isContinuousSpeech: boolean;
  durationSeconds:    number;
  note:               string;
}

const safetySettings = [
  { category: HarmCategory.HARM_CATEGORY_HARASSMENT,        threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_HATE_SPEECH,       threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT, threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
];

// Constrained enums for submitSelfReportedDemographics.
const ALLOWED_AGES: string[]        = ["18-24", "25-34", "35-44", "45-54", "55-64", "65+", "Prefer not to say"];
const ALLOWED_GENDERS: string[]     = ["Male", "Female", "Non-Binary", "Prefer not to say"];
const ALLOWED_ETHNICITY_CODES: string[] = [
  "White_British", "White_Irish", "White_Gypsy_Irish_Traveller", "White_Roma", "White_Other",
  "Mixed_White_Black_Caribbean", "Mixed_White_Black_African", "Mixed_White_Asian", "Mixed_Other",
  "Asian_Indian", "Asian_Pakistani", "Asian_Bangladeshi", "Asian_Chinese", "Asian_Other",
  "Black_African", "Black_Caribbean", "Black_Other",
  "Other_Arab", "Other_Other",
  "prefer_not_to_say", "other_unlisted",
];
const ALLOWED_REGIONS: string[]     = ["Northern Europe", "Western Europe", "Southern Europe", "Eastern Europe", "North America", "Latin America", "Middle East & North Africa", "Sub-Saharan Africa", "South Asia", "East Asia", "Southeast Asia", "Oceania", "Prefer not to say"];

// ── analyzeAudio ──────────────────────────────────────────────────────────────
// Storage trigger: processes every file uploaded to audio_uploads/.
// Routes on filename prefix:
//   onboarding_* → bot-detection verification flow
//   everything else → sentiment analysis flow
export const analyzeAudio = onObjectFinalized(
  { bucket: "stewyrt-11.firebasestorage.app" },
  async (event) => {
    const filePath = event.data.name;

    // Only process uploads into audio_uploads/
    if (!filePath || !filePath.startsWith("audio_uploads/")) return;

    const fileName      = path.basename(filePath);
    const storageBucket = admin.storage().bucket(event.data.bucket);
    const tempFilePath  = path.join(os.tmpdir(), fileName);
    const metadata      = event.data.metadata ?? {};
    const db            = admin.firestore();

    // ── Check if the submitting UID is blocked ───────────────────────────────
    let submittingUid: string | null = null;
    if (fileName.startsWith("onboarding_")) {
      submittingUid = fileName.replace(/^onboarding_/, "").replace(/\.m4a$/, "");
    } else {
      const rawResponseId = (metadata["responseId"] as string | undefined) ?? "";
      submittingUid = extractUidForRateLimit(rawResponseId) || (event as any).auth?.uid || null;
    }

    if (submittingUid) {
      const blockedDoc = await db.collection("blocked_uids").doc(submittingUid).get();
      if (blockedDoc.exists) {
        console.warn(`[STEWYRT] Submitting UID ${submittingUid} is blocked. Silent exit.`);
        try {
          await storageBucket.file(filePath).delete();
        } catch (err) {
          console.error("[STEWYRT] Failed to delete blocked user audio:", err);
        }
        return;
      }
    }

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
      const userSnap   = await db.collection("users").doc(uuid).get();
      let attemptCount = 0;
      let windowStart: admin.firestore.Timestamp | null = null;

      if (userSnap.exists) {
        const d       = userSnap.data()!;
        const prevWin = d["verificationWindowStart"] as admin.firestore.Timestamp | undefined;
        if (prevWin && prevWin.toDate() > twentyFourHoursAgo) {
          attemptCount = (d["verificationAttempts"] as number) ?? 0;
          windowStart  = prevWin;
        }
      }

      if (attemptCount >= 3) {
        console.warn(`[STEWYRT] Verification rate limit hit for uid: ${uuid}`);
        if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
        await storageBucket.file(filePath).delete();
        await db.collection("users").doc(uuid).set({
          verifiedAsHuman:         false,
          verificationNote:        "Rate limit exceeded (3 attempts per 24h)",
          verifiedAt:              admin.firestore.FieldValue.serverTimestamp(),
          verificationAttempts:    attemptCount,
          verificationWindowStart: windowStart,
        }, { merge: true });
        await db.collection("system_logs").doc().set({
          type:      "verification_rate_limit",
          uid:       uuid,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return;
      }

      const newAttemptCount = attemptCount + 1;
      const newWindowStart  = windowStart ?? admin.firestore.Timestamp.now();

      let detection: HumanDetectionResult | null = null;

      try {
        const base64Audio = fs.readFileSync(tempFilePath).toString("base64");
        const ai = new GoogleGenAI({ vertexai: true, project: "stewyrt-11", location: "us-central1" });

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
            systemInstruction:
              `Listen to this audio. Respond with ONLY a JSON object: ` +
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

        const raw  = (result.text ?? "").trim();
        const json = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
        detection  = JSON.parse(json) as HumanDetectionResult;
      } catch (err) {
        console.error("[STEWYRT] Verification Gemini call failed:", err);
        await db.collection("users").doc(uuid).set({
          verifiedAsHuman:         false,
          verificationNote:        "Voice verification failed due to server error. Please try again.",
          error:                   true,
          verifiedAt:              admin.firestore.FieldValue.serverTimestamp(),
          verificationAttempts:    newAttemptCount,
          verificationWindowStart: newWindowStart,
        });
      } finally {
        // Per our consent promise: destroy audio NO MATTER WHAT — crash, error, or success.
        if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
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
          verifiedAsHuman:         verifiedAsHuman,
          isContinuousSpeech:      detection.isContinuousSpeech ?? false,
          durationSeconds:         detection.durationSeconds     ?? 0,
          verificationNote:        detection.note               ?? "",
          verifiedAt:              admin.firestore.FieldValue.serverTimestamp(),
          verificationAttempts:    newAttemptCount,
          verificationWindowStart: newWindowStart,
        });
      }

    } else {

      // ── SENTIMENT ANALYSIS FLOW ──────────────────────────────────────────────
      const uuid          = fileName.replace(/\.m4a$/, "");
      const question      = (metadata["question"]   as string | undefined) ?? "What is on your mind right now?";
      const rawResponseId = (metadata["responseId"] as string | undefined) ?? "";
      const rawPollId     = (metadata["pollId"]     as string | undefined) ?? "";

      // 1.2 — Derive a server-trusted responseId.
      // Trust only if it matches UUID v4; otherwise fall back to the storage filename UUID.
      const trustedResponseId = UUID_V4_RE.test(rawResponseId) ? rawResponseId : uuid;

      // 1.5 — Rate limiting: attempt to derive UID from available signals.
      // "owner" metadata is not currently set by the client. In production mode,
      // responseId = {uid}_{pollId}, from which the UID can be extracted.
      // In beta mode, we now derive the UID from the Firebase Auth context.
      const rateUid = extractUidForRateLimit(rawResponseId) || (event as any).auth?.uid;
      const metaUid = (metadata["uid"] as string | undefined) ?? "";
      const resolvedUid = rateUid || metaUid || null;

      if (!rateUid) {
        console.warn("[STEWYRT] No auth context available — skipping rate limiting and proceeding");
      }

      if (rateUid) {
        const oneHourAgo = admin.firestore.Timestamp.fromDate(
          new Date(Date.now() - 60 * 60 * 1000),
        );
        const countSnap = await db
          .collection("responses")
          .where("uid", "==", rateUid)
          .where("createdAt", ">", oneHourAgo)
          .count()
          .get();

        if (countSnap.data().count >= 5) {
          console.warn(`[STEWYRT] Rate limit hit for uid: ${rateUid}`);
          if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
          await db.collection("responses").doc(trustedResponseId).set({
            blocked:       true,
            blockedReason: "rate_limit",
            uid:           rateUid,
            createdAt:     admin.firestore.FieldValue.serverTimestamp(),
          });
          return;
        }
      }

      // 1.2 — Validate pollId: confirm the referenced poll document exists
      // before trusting it for counter increments.
      // Graceful fallback: if poll is missing, write the response with pollId=null
      // and skip counter update rather than failing the entire write.
      let trustedPollId: string | null = rawPollId || null;
      if (trustedPollId) {
        const pollSnap = await db.collection("polls").doc(trustedPollId).get();
        if (!pollSnap.exists) {
          console.warn(`[STEWYRT] pollId '${trustedPollId}' not found in polls — omitting poll counter update`);
          trustedPollId = null;
        }
      }

      // Definite assignment: TypeScript is told analysis will be set before use.
      let analysis!: AnalysisResult;

      try {
        const base64Audio = fs.readFileSync(tempFilePath).toString("base64");

        const ai = new GoogleGenAI({ vertexai: true, project: "stewyrt-11", location: "us-central1" });

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
            systemInstruction:
              `You are the analysis engine for Stewyrt, an anonymous audio sentiment platform. ` +
              `INTENTIONALITY CHECK (evaluate first, before anything else): ` +
              `Listen to the audio. If the recording contains ONLY ambient ` +
              `background noise, environmental sound, silence, or accidental ` +
              `recording with no intentional audio content — meaning no ` +
              `deliberate human speech, singing, humming, playback of music, ` +
              `comedy, or any other purposeful sound — you MUST return ONLY ` +
              `{ "blocked": true } and nothing else. ` +
              `Intentional content includes: ` +
              `- Human speech in any language ` +
              `- Singing or humming ` +
              `- Playback of music, comedy, film, or any recorded media ` +
              `- Any sound the person deliberately chose to submit ` +
              `Unintentional content includes: ` +
              `- Pure ambient noise (traffic, wind, room tone) ` +
              `- Pocket or accidental recordings ` +
              `- Silence with minor background noise ` +
              `If the audio contains ANY intentional content, proceed to ` +
              `the CONTENT MODERATION STEP as normal. ` +
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

        const raw  = (result.text ?? "").trim();
        const json = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
        analysis   = JSON.parse(json) as AnalysisResult;

        if (analysis.blocked === true) {
          console.warn(`[STEWYRT] Content moderation blocked — responseId: ${trustedResponseId}`);
          if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
          await db.collection("responses").doc(trustedResponseId).set({
            blocked:       true,
            blockedReason: "content_policy",
            createdAt:     admin.firestore.FieldValue.serverTimestamp(),
          });
          return;
        }

      } catch (err: unknown) {
        console.error("Content blocked or Gemini analysis failed:", err);
        if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
        await db.collection("responses").doc(trustedResponseId).set({
          blocked:       true,
          blockedReason: "analysis_error",
          error:         true,
          createdAt:     admin.firestore.FieldValue.serverTimestamp(),
        });
        return;
      }

      if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);

      // ── Atomic Firestore writes ─────────────────────────────────────────────
      const responseRef = db.collection("responses").doc(trustedResponseId);
      const pollRef     = trustedPollId ? db.collection("polls").doc(trustedPollId) : null;

      await db.runTransaction(async (tx) => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const doc: Record<string, any> = {
          uuid,
          audioPath:        filePath,
          tone:             analysis.tone             ?? "",
          flavor:           analysis.flavor           ?? "",
          essence:          analysis.essence          ?? "",
          summary:          analysis.summary          ?? "",
          analysis_chain:   analysis.analysis_chain   ?? "",
          anatomicalRegion: analysis.anatomicalRegion ?? "Prefrontal",
          // Per-field region mirrors for the Flutter → Three.js bridge.
          // All three tags share the same overall region for this response.
          toneRegion:       analysis.anatomicalRegion ?? "Prefrontal",
          flavorRegion:     analysis.anatomicalRegion ?? "Prefrontal",
          essenceRegion:    analysis.anatomicalRegion ?? "Prefrontal",
          language:         analysis.language         ?? "en",
          question,
          pollId:           trustedPollId ?? "",
          // 1.1: explicit false is required for collection queries scoped with
          // .where('blocked', isNotEqualTo: true) to match this document.
          // Omitting the field causes those queries to skip the document.
          blocked:          false,
          createdAt:        admin.firestore.FieldValue.serverTimestamp(),
        };

        // UID derivation: storage triggers have no auth context. UID is parsed
        // from responseId when it is in production format ({uid}_{pollId}).
        // In beta mode (UUID v4 responseId) UID is unavailable — no uid field
        // is written. Beta-mode responses are excluded from GDPR erasure via
        // deleteUserData; the 120-day audio purge is their only erasure path.
        if (resolvedUid) doc["uid"] = resolvedUid;

        tx.set(responseRef, doc);

        if (pollRef) {
          tx.update(pollRef, {
            total_submissions:                       admin.firestore.FieldValue.increment(1),
            [`counts.tone.${analysis.tone}`]:        admin.firestore.FieldValue.increment(1),
            [`counts.flavor.${analysis.flavor}`]:    admin.firestore.FieldValue.increment(1),
            [`counts.essence.${analysis.essence}`]:  admin.firestore.FieldValue.increment(1),
          });
        }
      });
    }
  }
);

// In production mode, UID is derived server-side from responseId ({uid}_{pollId}).
// In beta mode, rate limiting is disabled. Client-supplied metadata is never trusted.
function extractUidForRateLimit(responseId: string): string | null {
  if (!UUID_V4_RE.test(responseId)) {
    const idx = responseId.indexOf("_");
    if (idx > 10) return responseId.substring(0, idx);
  }
  return null;
}

// ── purgeOldSentimentAudio ────────────────────────────────────────────────────
// Deletes sentiment audio files older than 120 days from Storage.
// Runs daily at 03:00 UTC. Does NOT touch Firestore response documents.
// Idempotent: the system_logs doc is overwritten on repeat runs within the same day.
export const purgeOldSentimentAudio = onSchedule(
  { schedule: "0 3 * * *", timeZone: "UTC" },
  async () => {
    const bucket   = admin.storage().bucket("stewyrt-11.firebasestorage.app");
    const db       = admin.firestore();
    const cutoffMs = Date.now() - 120 * 24 * 60 * 60 * 1000;
    const todayKey = new Date().toISOString().slice(0, 10); // YYYY-MM-DD

    let filesDeleted = 0;
    let bytesFreed   = 0;
    const errors: string[] = [];

    const [files] = await bucket.getFiles({ prefix: "audio_uploads/" });

    const targets = files.filter((f) => {
      // Never purge verification audio — it should already be deleted immediately
      // after processing, but exclude it here as a safety net.
      if (path.basename(f.name).startsWith("onboarding_")) return false;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const created = (f.metadata as any)?.timeCreated as string | undefined;
      if (!created) return false;
      return new Date(created).getTime() < cutoffMs;
    });

    for (const file of targets) {
      try {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const sizeRaw = (file.metadata as any)?.size;
        const size    = typeof sizeRaw === "number" ? sizeRaw
                      : typeof sizeRaw === "string" ? parseInt(sizeRaw, 10)
                      : 0;
        await file.delete();
        filesDeleted++;
        bytesFreed += isNaN(size) ? 0 : size;
      } catch (err) {
        const msg = `${file.name}: ${String(err)}`;
        console.error(`[STEWYRT] Purge error — ${msg}`);
        errors.push(msg);
      }
    }

    console.log(
      `[STEWYRT] Audio purge complete — ${filesDeleted} files deleted, ` +
      `${bytesFreed} bytes freed, ${errors.length} errors`,
    );

    await db.collection("system_logs").doc(todayKey).set({
      type:         "audio_purge",
      filesDeleted,
      bytesFreed,
      errors,
      completedAt:  admin.firestore.FieldValue.serverTimestamp(),
    });
  },
);

// ── submitSelfReportedDemographics ────────────────────────────────────────────
// Callable: client submits self-reported demographics after onboarding.
// These are stored separately from the bot-detection verification result and
// are never used for acoustic inference.
export const submitSelfReportedDemographics = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const { age, gender, ethnicity, ethnicityCode, region } = request.data as {
    age?: string;
    gender?: string;
    ethnicity?: string;
    ethnicityCode?: string;
    region?: string;
  };

  if (!age          || !ALLOWED_AGES.includes(age))                          throw new HttpsError("invalid-argument", `Invalid age value: ${age}`);
  if (!gender       || !ALLOWED_GENDERS.includes(gender))                    throw new HttpsError("invalid-argument", `Invalid gender value: ${gender}`);
  if (!ethnicity    || typeof ethnicity !== "string" || !ethnicity.trim())   throw new HttpsError("invalid-argument", "ethnicity is required.");
  if (!ethnicityCode || !ALLOWED_ETHNICITY_CODES.includes(ethnicityCode))    throw new HttpsError("invalid-argument", `Invalid ethnicityCode value: ${ethnicityCode}`);
  if (!region       || !ALLOWED_REGIONS.includes(region))                    throw new HttpsError("invalid-argument", `Invalid region value: ${region}`);

  const uid = request.auth.uid;
  const db  = admin.firestore();

  // merge: true preserves verifiedAsHuman and other verification fields.
  await db.collection("users").doc(uid).set(
    {
      selfReportedAge:           age,
      selfReportedGender:        gender,
      selfReportedEthnicity:     ethnicity,
      selfReportedEthnicityCode: ethnicityCode,
      selfReportedRegion:        region,
      selfReportedAt:            admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { success: true };
});

// ── updateQuestionUsage ───────────────────────────────────────────────────────
// Increments times_used, sets last_used_date, and sets first_used_date only on
// first use. Called by runDailyActivation when a question goes live.
async function updateQuestionUsage(
  db:         admin.firestore.Firestore,
  questionId: string,
  isFirstUse: boolean,
): Promise<void> {
  const ref = db.collection("questions").doc(questionId);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const update: Record<string, any> = {
    times_used:     admin.firestore.FieldValue.increment(1),
    last_used_date: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (isFirstUse) {
    update["first_used_date"] = admin.firestore.FieldValue.serverTimestamp();
  }
  await ref.update(update);
}

// ── Question rotation ─────────────────────────────────────────────────────────
// Two exports sharing a single runScheduler() core:
//   scheduleUpcomingQuestions       — fires every Sunday at 02:00 UTC
//   scheduleUpcomingQuestionsManual — callable for on-demand admin triggers
//
// The scheduler fills the next 14 days of question_schedule, skipping any
// date that is already locked (pulse_locked / horizon_locked = true).
// Each run is logged to scheduling_log/{ISO-datetime}.
// No email service is currently configured — the log doc is the review mechanism.
// TODO: wire tee_em@warmingneon.com when an email provider is added.

interface QuestionDoc {
  id:               string;
  text:             string;
  tier:             "pulse" | "horizon";
  category:         string;
  emotional_weight: "light" | "medium" | "heavy";
  day_affinity:     string | null;
  times_used:       number;
  last_used_date:   admin.firestore.Timestamp | null;
  cooldown_days:    number;
}

interface SchedulerSummary {
  run_at:              string;
  dates_processed:     string[];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assignments:         Record<string, any>;
  warnings:            string[];
  horizon_updated:     boolean;
  horizon_question_id: string | null;
}

const WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

// Required pulse category per day-of-week. Saturday handled separately (alternates by week parity).
const DAY_CATEGORY: Record<string, string> = {
  monday:    "rebellion",
  tuesday:   "reflective",
  wednesday: "confessional",
  thursday:  "provocative",
  friday:    "whimsical",
  saturday:  "retrospective",
  sunday:    "existential",
};

function utcDateStr(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function addUTCDays(d: Date, n: number): Date {
  const r = new Date(d);
  r.setUTCDate(r.getUTCDate() + n);
  return r;
}

// ISO week number (1–53). Week starts Monday.
function isoWeekNumber(d: Date): number {
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
  const jan1 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  return Math.ceil(((t.getTime() - jan1.getTime()) / 86_400_000 + 1) / 7);
}

// Returns the Monday (UTC midnight) of the week containing d.
function mondayOf(d: Date): Date {
  const day = d.getUTCDay(); // 0 = Sunday
  return addUTCDays(d, day === 0 ? -6 : 1 - day);
}

function cooldownOk(q: QuestionDoc, nowMs: number): boolean {
  if (!q.last_used_date) return true;
  return nowMs - q.last_used_date.toDate().getTime() > q.cooldown_days * 86_400_000;
}

// Returns the required category/categories for a given day.
// odd ISO week = retrospective, even = anticipatory (Saturday alternation).
function requiredCategories(dayName: string, week: number): string[] {
  if (dayName === "saturday") {
    return [week % 2 === 1 ? "retrospective" : "anticipatory"];
  }
  const cat = DAY_CATEGORY[dayName];
  return cat ? [cat] : [];
}

// Sorts candidates in preference order and returns the best pick.
// Priority: (1) day_affinity match, (2) emotional balance, (3) fewest uses.
function pickBest(
  candidates:    QuestionDoc[],
  dayName:       string,
  recentWeights: ("light" | "medium" | "heavy")[],
): QuestionDoc {
  // Deprioritise heavy questions only when the preceding 2 days were both heavy.
  const precedingBothHeavy =
    recentWeights.length >= 2 &&
    recentWeights[recentWeights.length - 1] === "heavy" &&
    recentWeights[recentWeights.length - 2] === "heavy";

  return [...candidates].sort((a, b) => {
    const afA = a.day_affinity === dayName ? 0 : 1;
    const afB = b.day_affinity === dayName ? 0 : 1;
    if (afA !== afB) return afA - afB;

    if (precedingBothHeavy) {
      const hvA = a.emotional_weight === "heavy" ? 1 : 0;
      const hvB = b.emotional_weight === "heavy" ? 1 : 0;
      if (hvA !== hvB) return hvA - hvB;
    }

    return a.times_used - b.times_used;
  })[0];
}

async function runScheduler(db: admin.firestore.Firestore): Promise<SchedulerSummary> {
  const now   = new Date();
  const nowMs = now.getTime();

  const summary: SchedulerSummary = {
    run_at:              now.toISOString(),
    dates_processed:     [],
    assignments:         {},
    warnings:            [],
    horizon_updated:     false,
    horizon_question_id: null,
  };

  // ── 1. 14-day scheduling window (tomorrow → day 14) ───────────────────────
  const dates: string[] = [];
  for (let i = 1; i <= 14; i++) dates.push(utcDateStr(addUTCDays(now, i)));

  // ── 2. Fetch all approved questions (both tiers) ──────────────────────────
  const [pulseSnap, horizonSnap] = await Promise.all([
    db.collection("questions").where("tier", "==", "pulse").where("status", "==", "approved").get(),
    db.collection("questions").where("tier", "==", "horizon").where("status", "==", "approved").get(),
  ]);

  const pulseQ: QuestionDoc[]   = pulseSnap.docs.map((d) => ({
    id: d.id, ...(d.data() as Omit<QuestionDoc, "id">),
  }));
  const horizonQ: QuestionDoc[] = horizonSnap.docs.map((d) => ({
    id: d.id, ...(d.data() as Omit<QuestionDoc, "id">),
  }));

  // ── 3. Fetch schedule context: 7 days prior + full 14-day window ──────────
  // Used for: prior emotional context, previous horizon ID, and locked entries.
  const contextStart = utcDateStr(addUTCDays(now, -7));
  const windowEnd    = dates[dates.length - 1];

  const schedSnap = await db.collection("question_schedule")
    .where(admin.firestore.FieldPath.documentId(), ">=", contextStart)
    .where(admin.firestore.FieldPath.documentId(), "<=", windowEnd)
    .get();

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const existing: Record<string, Record<string, any>> = {};
  for (const doc of schedSnap.docs) existing[doc.id] = doc.data();

  // ── 4. Seed the assigned-IDs set with already-locked pulse IDs ───────────
  // Prevents double-booking: a question locked on date A can't be picked for B.
  const assignedIds = new Set<string>();
  for (const date of dates) {
    const e = existing[date];
    if (e?.pulse_locked && e?.pulse_question_id) assignedIds.add(e.pulse_question_id as string);
  }

  // ── 5. Prime emotional-weight context from the 2 days before the window ───
  const recentWeights: ("light" | "medium" | "heavy")[] = [];
  for (let offset = -2; offset <= -1; offset++) {
    const pid = existing[utcDateStr(addUTCDays(now, offset))]?.pulse_question_id as string | undefined;
    if (pid) {
      const q = pulseQ.find((q) => q.id === pid);
      if (q) recentWeights.push(q.emotional_weight);
    }
  }

  // ── 6. Horizon selection — one per Monday-to-Sunday calendar week ─────────
  // Group the 14 dates by their Monday.
  const weekGroups = new Map<string, string[]>();
  for (const date of dates) {
    const monday = utcDateStr(mondayOf(new Date(date + "T00:00:00Z")));
    if (!weekGroups.has(monday)) weekGroups.set(monday, []);
    weekGroups.get(monday)!.push(date);
  }

  // Find the most recent horizon set before this scheduling window.
  let prevHorizonId: string | null = null;
  for (const d of Object.keys(existing).filter((d) => d < dates[0]).sort().reverse()) {
    const hid = existing[d]?.horizon_question_id as string | undefined;
    if (hid) { prevHorizonId = hid; break; }
  }

  const weekHorizonIds = new Map<string, string | null>();

  for (const [monday, weekDates] of weekGroups) {
    // If any window-day in this week is horizon-locked, use that ID for all days.
    let lockedId: string | null = null;
    for (const date of weekDates) {
      const e = existing[date];
      if (e?.horizon_locked && e?.horizon_question_id) {
        lockedId = e.horizon_question_id as string;
        break;
      }
    }
    if (lockedId) { weekHorizonIds.set(monday, lockedId); continue; }

    // A prior scheduler run may have already assigned a horizon for this week
    // (on days that fall within our 7-day context window).
    let priorId: string | null = null;
    const weekStart = new Date(monday + "T00:00:00Z");
    for (let i = 0; i < 7 && !priorId; i++) {
      const hid = existing[utcDateStr(addUTCDays(weekStart, i))]?.horizon_question_id as string | undefined;
      if (hid) priorId = hid;
    }
    if (priorId) { weekHorizonIds.set(monday, priorId); continue; }

    // Select a new horizon: eligible = cooldown OK and not the immediately prior one.
    const eligible = [...horizonQ]
      .filter((q) => cooldownOk(q, nowMs) && q.id !== prevHorizonId)
      .sort((a, b) =>
        a.times_used !== b.times_used ? a.times_used - b.times_used : Math.random() - 0.5,
      );

    if (eligible.length === 0) {
      const warn = `No eligible horizon question for week of ${monday}`;
      console.warn(`[SCHEDULER] ${warn}`);
      summary.warnings.push(warn);
      weekHorizonIds.set(monday, null);
      continue;
    }

    const chosen = eligible[0];
    weekHorizonIds.set(monday, chosen.id);
    prevHorizonId              = chosen.id; // used as exclusion for the next week in this same run
    summary.horizon_updated    = true;
    summary.horizon_question_id = chosen.id;
    console.log(`[SCHEDULER] Horizon for week of ${monday}: "${chosen.text.slice(0, 60)}"`);
  }

  // ── 7. Assign pulse for each date and commit via batch ────────────────────
  const batch = db.batch();

  for (const date of dates) {
    const e             = existing[date];
    const pulseLocked   = e?.pulse_locked   === true;
    const horizonLocked = e?.horizon_locked === true;

    const d       = new Date(date + "T00:00:00Z");
    const dayName = WEEKDAY_NAMES[d.getUTCDay()];
    const week    = isoWeekNumber(d);
    const monday  = utcDateStr(mondayOf(d));

    let pulseId: string | null = null;

    if (pulseLocked) {
      pulseId = e.pulse_question_id as string;
      // Keep emotional-weight context current even for locked days.
      const q = pulseQ.find((q) => q.id === pulseId);
      if (q) {
        recentWeights.push(q.emotional_weight);
        if (recentWeights.length > 2) recentWeights.shift();
      }
    } else {
      const cats       = requiredCategories(dayName, week);
      const candidates = pulseQ.filter(
        (q) => cats.includes(q.category) && cooldownOk(q, nowMs) && !assignedIds.has(q.id),
      );

      if (candidates.length === 0) {
        // No valid candidate — leave a gap rather than pick the wrong category.
        const warn = `No pulse candidate for ${date} (${dayName}, ${cats.join("/")}) — needs_question`;
        console.warn(`[SCHEDULER] ${warn}`);
        summary.warnings.push(warn);
        // pulseId remains null; docData.status will be set to "needs_question" below.
      } else {
        const best = pickBest(candidates, dayName, recentWeights);
        pulseId    = best.id;
        assignedIds.add(best.id);
        recentWeights.push(best.emotional_weight);
        if (recentWeights.length > 2) recentWeights.shift();
        console.log(`[SCHEDULER] Pulse for ${date} (${dayName}): "${best.text.slice(0, 50)}"`);
      }
    }

    const horizonId: string | null = horizonLocked
      ? (e.horizon_question_id as string)
      : (weekHorizonIds.get(monday) ?? null);

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const docData: Record<string, any> = {
      pulse_question_id:   pulseId,
      horizon_question_id: horizonId,
      pulse_locked:        pulseLocked,
      horizon_locked:      horizonLocked,
      updated_at:          admin.firestore.FieldValue.serverTimestamp(),
    };

    if (!e)                       docData.created_at = admin.firestore.FieldValue.serverTimestamp();
    if (!pulseId && !pulseLocked) docData.status     = "needs_question";

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

  console.log(
    `[SCHEDULER] Done — ${summary.dates_processed.length} dates processed, ` +
    `${summary.warnings.length} warning(s). Review: scheduling_log/${logId}`,
  );

  return summary;
}

// Scheduled: every Sunday at 02:00 UTC.
export const scheduleUpcomingQuestions = onSchedule(
  { schedule: "0 2 * * 0", timeZone: "UTC" },
  async () => { await runScheduler(admin.firestore()); },
);

// Callable: on-demand admin trigger. Requires Firebase Auth.
// Returns the full SchedulerSummary so you can inspect results immediately.
export const scheduleUpcomingQuestionsManual = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  return await runScheduler(admin.firestore());
});

// ── submitModerationReview ────────────────────────────────────────────────────
// Callable: client submits a human-review request for a blocked response.
// Validates that the responseId belongs to a real blocked response, then
// writes a moderation_review doc for human triage.
export const submitModerationReview = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const { responseId } = request.data as { responseId?: string };

  if (!responseId || typeof responseId !== "string" || responseId.trim().length === 0) {
    throw new HttpsError("invalid-argument", "responseId is required.");
  }

  const db = admin.firestore();
  const responseSnap = await db.collection("responses").doc(responseId).get();

  if (!responseSnap.exists) {
    throw new HttpsError("not-found", "Response not found.");
  }

  const data = responseSnap.data()!;
  if (data["blocked"] !== true) {
    throw new HttpsError("failed-precondition", "Response is not blocked.");
  }

  await db.collection("moderation_review").add({
    responseId,
    audioPath:            data["audioPath"]     ?? null,
    geminiClassification: data["blockedReason"] ?? null,
    submittedAt:          admin.firestore.FieldValue.serverTimestamp(),
    reviewedAt:           null,
    reviewerNotes:        null,
    finalDecision:        null,
    userMessage:          "User requested review",
    requestorUid:         request.auth.uid,
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
export const deleteUserData = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const uid    = request.auth.uid;
  const db     = admin.firestore();
  const bucket = admin.storage().bucket("stewyrt-11.firebasestorage.app");

  // 1. Delete response docs (where uid is stored — production mode).
  const responsesSnap = await db.collection("responses").where("uid", "==", uid).get();
  if (!responsesSnap.empty) {
    const batch = db.batch();
    for (const doc of responsesSnap.docs) batch.delete(doc.ref);
    await batch.commit();
  }

  // 2. Delete the user document.
  await db.collection("users").doc(uid).delete();

  // 3. Attempt to delete onboarding audio (already gone in most cases).
  try {
    await bucket.file(`audio_uploads/onboarding_${uid}.m4a`).delete();
  } catch (_) {
    // File not found — expected; ignore.
  }

  return { success: true };
});

// ── submitContentReport ───────────────────────────────────────────────────────
// Callable. Accepts { responseId, reason } from an authenticated user and
// writes a moderation record to moderation_queue.
// Rate limit: max 10 reports per user per rolling hour.
export const submitContentReport = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const uid = request.auth.uid;
  const data = request.data as { responseId?: unknown; reason?: unknown };

  // Validate inputs.
  if (typeof data.responseId !== "string" || !UUID_V4_RE.test(data.responseId)) {
    throw new HttpsError("invalid-argument", "responseId must be a valid UUID v4.");
  }
  const responseId = data.responseId;

  const ALLOWED_REASONS = [
    "harassment",
    "hate_speech",
    "spam",
    "misinformation",
    "other",
    "child_safety",
  ];
  if (typeof data.reason !== "string" || !ALLOWED_REASONS.includes(data.reason)) {
    throw new HttpsError("invalid-argument", "reason must be one of the allowed values.");
  }
  const reason = data.reason;

  const db = admin.firestore();

  // Rate limit: max 10 reports per user per rolling hour.
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
  const recentSnap = await db
    .collection("user_blocks")
    .doc(uid)
    .collection("reports")
    .where("reportedAt", ">=", oneHourAgo)
    .get();
  if (recentSnap.size >= 10) {
    throw new HttpsError("resource-exhausted", "Report limit reached. Try again later.");
  }

  // Verify the response doc exists.
  const responseRef = db.collection("responses").doc(responseId);
  const responseDoc = await responseRef.get();
  if (!responseDoc.exists) {
    throw new HttpsError("not-found", "Response not found.");
  }

  const responseData = responseDoc.data()!;
  const targetUid = responseData.uid || "";

  const reportDocRef = db.collection("user_blocks").doc(uid).collection("reports").doc();

  if (reason === "child_safety") {
    // Query responses to bulk-block if strikes reach 3
    let userResponsesRefs: admin.firestore.DocumentReference[] = [];
    if (targetUid) {
      const userResponsesSnap = await db.collection("responses")
        .where("uid", "==", targetUid)
        .get();
      userResponsesRefs = userResponsesSnap.docs.map(doc => doc.ref);
    }

    await db.runTransaction(async (transaction) => {
      let newStrikes = 1;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let strikeHistoryCopy: any[] = [];
      const nowTimestamp = admin.firestore.Timestamp.now();
      const newHistoryItem = { responseId, reason, timestamp: nowTimestamp };

      if (targetUid) {
        const strikeRef = db.collection("user_strikes").doc(targetUid);
        const strikeDoc = await transaction.get(strikeRef);
        if (!strikeDoc.exists) {
          strikeHistoryCopy = [newHistoryItem];
          transaction.set(strikeRef, {
            strikes: 1,
            firstStrike: nowTimestamp,
            lastStrike: nowTimestamp,
            strikeHistory: strikeHistoryCopy,
          });
        } else {
          const strikeData = strikeDoc.data()!;
          newStrikes = (strikeData.strikes || 0) + 1;
          strikeHistoryCopy = [...(strikeData.strikeHistory || []), newHistoryItem];
          transaction.update(strikeRef, {
            strikes: newStrikes,
            lastStrike: nowTimestamp,
            strikeHistory: strikeHistoryCopy,
          });
        }
      }

      // Set blocked: true on the response document immediately
      transaction.update(responseRef, { blocked: true });

      // Always log the report to moderation_queue
      const queueRef = db.collection("moderation_queue").doc();
      transaction.set(queueRef, {
        responseId,
        reason,
        reportedAt: admin.firestore.FieldValue.serverTimestamp(),
        reporterUid: uid,
        status: "auto_approved",
        targetUid,
      });

      // Write rate limit report document in transaction
      transaction.set(reportDocRef, {
        responseId,
        reason,
        reportedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // If strike count reaches 3
      if (targetUid && newStrikes >= 3) {
        const blockedUidRef = db.collection("blocked_uids").doc(targetUid);
        transaction.set(blockedUidRef, {
          uid: targetUid,
          bannedAt: admin.firestore.FieldValue.serverTimestamp(),
          reason: "three_strikes",
          strikeHistory: strikeHistoryCopy,
        });

        // Set blocked: true on ALL response documents where uid == targetUid
        for (const ref of userResponsesRefs) {
          transaction.update(ref, { blocked: true });
        }
      }
    });

    return { success: true };
  } else {
    // For ALL OTHER reasons:
    // Write to user_blocks/{reporterUid}/blocked_responses/{responseId}
    // with fields: responseId, reason, blockedAt: serverTimestamp()
    // Do NOT touch the response document
    // Do NOT write to moderation_queue
    // Do NOT add any strikes
    // Return { success: true, personalBlock: true }
    const batch = db.batch();

    const blockRef = db.collection("user_blocks").doc(uid).collection("blocked_responses").doc(responseId);
    batch.set(blockRef, {
      responseId,
      reason,
      blockedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    batch.set(reportDocRef, {
      responseId,
      reason,
      reportedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    return { success: true, personalBlock: true };
  }
});

const ADMIN_UID = "PLACEHOLDER_SET_AFTER_AUTH_SETUP";

// ── approveModerationReport ──────────────────────────────────────────────────
// Callable. Accepts { reportId, ejectUser } from an authenticated admin and
// approves the moderation report, blocking the response and updating strikes.
export const approveModerationReport = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  if (request.auth.uid !== ADMIN_UID) {
    throw new HttpsError("permission-denied", "Unauthorized. Administrator access required.");
  }

  const data = request.data as { reportId?: unknown; ejectUser?: unknown };
  if (typeof data.reportId !== "string" || !data.reportId) {
    throw new HttpsError("invalid-argument", "reportId must be a non-empty string.");
  }
  const reportId = data.reportId;
  const ejectUser = !!data.ejectUser;

  const db = admin.firestore();
  const queueRef = db.collection("moderation_queue").doc(reportId);
  const queueDoc = await queueRef.get();
  if (!queueDoc.exists) {
    throw new HttpsError("not-found", "Moderation report not found.");
  }

  const queueData = queueDoc.data()!;
  const responseId = queueData.responseId;
  const targetUid = queueData.targetUid || "";
  const reason = queueData.reason || "unknown";

  if (typeof responseId !== "string" || !responseId) {
    throw new HttpsError("failed-precondition", "Report has no valid responseId.");
  }

  // Get all responses to bulk-block if needed
  let userResponsesRefs: admin.firestore.DocumentReference[] = [];
  if (targetUid) {
    const userResponsesSnap = await db.collection("responses")
      .where("uid", "==", targetUid)
      .get();
    userResponsesRefs = userResponsesSnap.docs.map(doc => doc.ref);
  }

  await db.runTransaction(async (transaction) => {
    // Re-verify queue doc in transaction
    const qDoc = await transaction.get(queueRef);
    if (!qDoc.exists) {
      throw new HttpsError("not-found", "Moderation report not found in transaction.");
    }

    const responseRef = db.collection("responses").doc(responseId);
    // 1. Set blocked: true on the response document
    transaction.update(responseRef, { blocked: true });

    // 2. Update moderation_queue document status to 'approved'
    transaction.update(queueRef, { status: "approved" });

    // 3. Increment strike on user_strikes
    let strikes = 1;
    let strikeHistoryCopy: any[] = [];
    const nowTimestamp = admin.firestore.Timestamp.now();
    const newHistoryItem = { responseId, reason, timestamp: nowTimestamp };

    if (targetUid) {
      const strikeRef = db.collection("user_strikes").doc(targetUid);
      const strikeDoc = await transaction.get(strikeRef);
      if (!strikeDoc.exists) {
        strikeHistoryCopy = [newHistoryItem];
        transaction.set(strikeRef, {
          strikes: 1,
          firstStrike: nowTimestamp,
          lastStrike: nowTimestamp,
          strikeHistory: strikeHistoryCopy,
        });
      } else {
        const strikeData = strikeDoc.data()!;
        strikes = (strikeData.strikes || 0) + 1;
        strikeHistoryCopy = [...(strikeData.strikeHistory || []), newHistoryItem];
        transaction.update(strikeRef, {
          strikes: strikes,
          lastStrike: nowTimestamp,
          strikeHistory: strikeHistoryCopy,
        });
      }
    }

    // 4. If ejectUser is true OR strikes >= 3: adds to blocked_uids and bulk-blocks all responses for that UID
    if (targetUid && (ejectUser || strikes >= 3)) {
      const blockedUidRef = db.collection("blocked_uids").doc(targetUid);
      transaction.set(blockedUidRef, {
        uid: targetUid,
        bannedAt: admin.firestore.FieldValue.serverTimestamp(),
        reason: strikes >= 3 ? "three_strikes" : "ejected",
        strikeHistory: strikeHistoryCopy,
      });

      for (const ref of userResponsesRefs) {
        transaction.update(ref, { blocked: true });
      }
    }
  });

  return { success: true };
});

// ── dismissModerationReport ──────────────────────────────────────────────────
// Callable. Accepts { reportId } from an authenticated admin and
// dismisses the moderation report without blocking or adding strikes.
export const dismissModerationReport = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  if (request.auth.uid !== ADMIN_UID) {
    throw new HttpsError("permission-denied", "Unauthorized. Administrator access required.");
  }

  const data = request.data as { reportId?: unknown };
  if (typeof data.reportId !== "string" || !data.reportId) {
    throw new HttpsError("invalid-argument", "reportId must be a non-empty string.");
  }
  const reportId = data.reportId;

  const db = admin.firestore();
  await db.collection("moderation_queue").doc(reportId).update({
    status: "dismissed",
  });

  return { success: true };
});

// ── deleteOwnResponse ────────────────────────────────────────────────────────
// Callable. Accepts { responseId } from an authenticated user and allows them
// to delete (hide) their own response doc.
export const deleteOwnResponse = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const uid = request.auth.uid;
  const data = request.data as { responseId?: unknown };

  if (typeof data.responseId !== "string" || !UUID_V4_RE.test(data.responseId)) {
    throw new HttpsError("invalid-argument", "responseId must be a valid UUID v4.");
  }
  const responseId = data.responseId;

  const db = admin.firestore();
  const responseRef = db.collection("responses").doc(responseId);
  const responseDoc = await responseRef.get();

  if (!responseDoc.exists) {
    throw new HttpsError("not-found", "Response not found.");
  }

  const responseData = responseDoc.data()!;
  if (responseData.uid !== uid) {
    throw new HttpsError("permission-denied", "You do not have permission to delete this response.");
  }

  await responseRef.update({
    blocked: true,
    deletedByUser: true,
  });

  return { success: true };
});

// ── restoreResponse ──────────────────────────────────────────────────────────
// Callable. Accepts { responseId: string }
// Verifies caller UID matches ADMIN_UID.
// Sets blocked: false, deletedByUser: false on response document.
// Finds user_strikes entry for this responseId, removes it from
// strikeHistory, decrements strikes. If strikes hits 0, delete
// the document.
// Updates moderation_queue document for this responseId to
// status: "restored".
// Returns { success: true }
export const restoreResponse = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  if (request.auth.uid !== ADMIN_UID) {
    throw new HttpsError("permission-denied", "Unauthorized. Administrator access required.");
  }

  const data = request.data as { responseId?: unknown };
  if (typeof data.responseId !== "string" || !data.responseId) {
    throw new HttpsError("invalid-argument", "responseId must be a non-empty string.");
  }
  const responseId = data.responseId;

  const db = admin.firestore();

  // Query moderation queue docs first
  const queueSnap = await db.collection("moderation_queue")
    .where("responseId", "==", responseId)
    .get();

  const responseRef = db.collection("responses").doc(responseId);

  await db.runTransaction(async (transaction) => {
    const responseSnap = await transaction.get(responseRef);
    if (!responseSnap.exists) {
      throw new HttpsError("not-found", "Response not found.");
    }
    const responseData = responseSnap.data()!;
    const targetUid = responseData.uid || "";

    // Update response document
    transaction.update(responseRef, {
      blocked: false,
      deletedByUser: false,
    });

    // Update user strikes if applicable
    if (targetUid) {
      const strikeRef = db.collection("user_strikes").doc(targetUid);
      const strikeSnap = await transaction.get(strikeRef);
      if (strikeSnap.exists) {
        const strikeData = strikeSnap.data()!;
        const strikeHistory = strikeData.strikeHistory || [];
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const updatedHistory = strikeHistory.filter((item: any) => item.responseId !== responseId);
        
        if (updatedHistory.length !== strikeHistory.length) {
          const newStrikes = Math.max(0, (strikeData.strikes || 0) - 1);
          if (newStrikes <= 0) {
            transaction.delete(strikeRef);
          } else {
            transaction.update(strikeRef, {
              strikes: newStrikes,
              strikeHistory: updatedHistory,
            });
          }
        }
      }
    }

    // Update moderation queue documents to "restored"
    for (const doc of queueSnap.docs) {
      transaction.update(doc.ref, { status: "restored" });
    }
  });

  return { success: true };
});

// ── Daily question activation ─────────────────────────────────────────────────
// Reads today's question_schedule entry, creates new active poll documents for
// pulse (daily) and horizon (Mondays only), deactivates the previous active polls,
// and calls updateQuestionUsage for each activated question.
// NEVER touches ice_breaker_v1 or any ice_breaker tier poll.

interface ActivationSummary {
  date:                    string;
  pulseQuestionText:       string | null;
  newPulsePollId:          string | null;
  horizonActivated:        boolean;
  horizonReason:           string;
  horizonQuestionText:     string | null;
  newHorizonPollId:        string | null;
  previousPollsDeactivated: string[];
  warnings:                string[];
}

async function runDailyActivation(db: admin.firestore.Firestore): Promise<ActivationSummary> {
  const now     = new Date();
  const today   = now.toISOString().slice(0, 10); // YYYY-MM-DD UTC
  const isMonday = now.getUTCDay() === 1;

  const summary: ActivationSummary = {
    date:                    today,
    pulseQuestionText:       null,
    newPulsePollId:          null,
    horizonActivated:        false,
    horizonReason:           "",
    horizonQuestionText:     null,
    newHorizonPollId:        null,
    previousPollsDeactivated: [],
    warnings:                [],
  };

  // 1. Read today's schedule entry.
  const schedSnap = await db.collection("question_schedule").doc(today).get();
  if (!schedSnap.exists) {
    const warn = `question_schedule/${today} missing — aborting activation`;
    console.warn(`[ACTIVATION] ${warn}`);
    summary.warnings.push(warn);
    return summary;
  }

  const sched = schedSnap.data()!;
  const pulseQuestionId   = sched["pulse_question_id"]   as string | undefined;
  const horizonQuestionId = sched["horizon_question_id"] as string | undefined;

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

  const pulseQData = pulseQSnap.data()!;
  const pulseText  = pulseQData["text"] as string;
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
    tier:       "pulse",
    question:   pulseText,
    questionId: pulseQuestionId,
    isActive:   true,
    createdAt:  admin.firestore.FieldValue.serverTimestamp(),
  });

  await updateQuestionUsage(db, pulseQuestionId, isFirstPulseUse);

  summary.pulseQuestionText = pulseText;
  summary.newPulsePollId    = newPulseRef.id;
  console.log(`[ACTIVATION] Pulse activated — pollId: ${newPulseRef.id}, question: "${pulseText.slice(0, 60)}"`);

  // ── HORIZON ACTIVATION (Mondays only) ────────────────────────────────────
  if (!isMonday) {
    summary.horizonReason = "not Monday";
  } else if (!horizonQuestionId) {
    const warn = `question_schedule/${today} has no horizon_question_id — skipping horizon`;
    console.warn(`[ACTIVATION] ${warn}`);
    summary.warnings.push(warn);
    summary.horizonReason = "no horizon_question_id in schedule";
  } else {
    const horizonQSnap = await db.collection("questions").doc(horizonQuestionId).get();
    if (!horizonQSnap.exists) {
      const warn = `questions/${horizonQuestionId} not found — skipping horizon`;
      console.warn(`[ACTIVATION] ${warn}`);
      summary.warnings.push(warn);
      summary.horizonReason = "horizon question doc missing";
    } else {
      const horizonQData = horizonQSnap.data()!;
      const horizonText  = horizonQData["text"] as string;
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
        tier:       "horizon",
        question:   horizonText,
        questionId: horizonQuestionId,
        isActive:   true,
        createdAt:  admin.firestore.FieldValue.serverTimestamp(),
      });

      await updateQuestionUsage(db, horizonQuestionId, isFirstHorizonUse);

      summary.horizonActivated    = true;
      summary.horizonReason       = "Monday — activated";
      summary.horizonQuestionText = horizonText;
      summary.newHorizonPollId    = newHorizonRef.id;
      console.log(`[ACTIVATION] Horizon activated — pollId: ${newHorizonRef.id}, question: "${horizonText.slice(0, 60)}"`);
    }
  }

  return summary;
}

// Scheduled: daily at 00:01 UTC.
export const activateDailyQuestion = onSchedule(
  { schedule: "1 0 * * *", timeZone: "UTC" },
  async () => { await runDailyActivation(admin.firestore()); },
);

// Callable: immediate manual trigger. Returns the full ActivationSummary.
export const activateDailyQuestionManual = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  return await runDailyActivation(admin.firestore());
});

// Shared helper to post to Buffer channels
async function postToBuffer(questionText: string, isMorning: boolean, totalUsers: number) {
  const bufferApiKey = process.env.BUFFER_API_KEY || "";
  if (!bufferApiKey) {
    console.error("[BUFFER] BUFFER_API_KEY not set.");
    return;
  }

  let postText = "";
  if (isMorning) {
    postText = `💬 Today on Stewyrt:\n\n"${questionText}"\n\nJoin ${totalUsers} anonymous voices. Record yours at stewyrt.com\n\n#Stewyrt #SoTellEveryoneWhatYouReallyThink #BeAnonymous #JustBeYou`;
  } else {
    postText = `🎙️ Have you answered today's question yet?\n\n"${questionText}"\n\n${totalUsers} anonymous voices and counting. stewyrt.com\n\n#Stewyrt #SoTellEveryoneWhatYouReallyThink #BeAnonymous #JustBeYou`;
  }

  const channelIds = [
    "6a33ee5338b5579345abd627", // Instagram
    "6a33ef7c38b5579345abdd85", // Bluesky
    "6a33efe138b5579345abdfa9"  // Threads
  ];

  for (const channelId of channelIds) {
    try {
      const bufferRes = await fetch("https://api.buffer.com/graphql", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${bufferApiKey}`
        },
        body: JSON.stringify({
          query: `
            mutation CreatePost($input: CreatePostInput!) {
              createPost(input: $input) {
                ... on PostActionSuccess {
                  post {
                    id
                  }
                }
                ... on PostActionError {
                  message
                }
              }
            }
          `,
          variables: {
            input: {
              channelId,
              content: {
                text: postText
              }
            }
          }
        })
      });
      const bufferData = await bufferRes.json();
      console.log(`[BUFFER] Posted to ${channelId} (isMorning: ${isMorning}):`, 
        JSON.stringify(bufferData));
    } catch (err) {
      console.error(`[BUFFER] Failed to post to ${channelId} (isMorning: ${isMorning}):`, err);
    }
  }
}

// Scheduled: daily at 09:00 UTC.
export const sendDailyDigest = onSchedule(
  { 
    schedule: "0 9 * * *", 
    timeZone: "UTC", 
    region: "us-central1",
    secrets: ["GMAIL_USER", "GMAIL_PASS", "BUFFER_API_KEY"]
  },
  async () => {
    // v2
    const db = admin.firestore();
    const now = new Date();
    const todayStr = now.toISOString().slice(0, 10); // YYYY-MM-DD

    // Calculate time windows
    const yesterday = admin.firestore.Timestamp.fromDate(new Date(now.getTime() - 24 * 60 * 60 * 1000));
    const last7days = admin.firestore.Timestamp.fromDate(new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000));
    const last30days = admin.firestore.Timestamp.fromDate(new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000));

    // Run count queries in parallel
    const [
      newUsersTodaySnap,
      newUsers7dSnap,
      newUsers30dSnap,
      totalUsersSnap,
      responsesTodaySnap,
      totalResponsesSnap,
      pendingModerationSnap,
      bannedUsersSnap,
    ] = await Promise.all([
      db.collection("users").where("verifiedAt", ">=", yesterday).count().get(),
      db.collection("users").where("verifiedAt", ">=", last7days).count().get(),
      db.collection("users").where("verifiedAt", ">=", last30days).count().get(),
      db.collection("users").count().get(),
      db.collection("responses").where("createdAt", ">=", yesterday).where("blocked", "==", false).count().get(),
      db.collection("responses").where("blocked", "==", false).count().get(),
      db.collection("moderation_queue").where("status", "==", "pending").count().get(),
      db.collection("blocked_uids").count().get(),
    ]);

    const newUsersToday = newUsersTodaySnap.data().count;
    const newUsers7d = newUsers7dSnap.data().count;
    const newUsers30d = newUsers30dSnap.data().count;
    const totalUsers = totalUsersSnap.data().count;
    const responsesToday = responsesTodaySnap.data().count;
    const totalResponses = totalResponsesSnap.data().count;
    const pendingModeration = pendingModerationSnap.data().count;
    const bannedUsers = bannedUsersSnap.data().count;

    // Fetch today's question
    let questionText = "No active pulse question found for today";
    const scheduleDoc = await db.collection("question_schedule").doc(todayStr).get();
    if (scheduleDoc.exists) {
      const pulseQuestionId = scheduleDoc.data()?.pulse_question_id;
      if (pulseQuestionId) {
        const pollSnap = await db.collection("polls")
          .where("questionId", "==", pulseQuestionId)
          .limit(1)
          .get();
        if (!pollSnap.empty) {
          questionText = pollSnap.docs[0].data()?.question || "No question text";
        } else {
          // Fallback check questions
          const questionSnap = await db.collection("questions").doc(pulseQuestionId).get();
          if (questionSnap.exists) {
            questionText = questionSnap.data()?.text || "No question text";
          }
        }
      }
    }

    // Build plain text email body
    const emailBody = `STEWYRT DAILY DIGEST — ${todayStr}

GROWTH
New users today: ${newUsersToday}
New users (7d): ${newUsers7d}
New users (30d): ${newUsers30d}
Total users: ${totalUsers}

ENGAGEMENT
Responses today: ${responsesToday}
Total responses: ${totalResponses}

TODAY'S PULSE QUESTION
"${questionText}"

MODERATION
Pending reports: ${pendingModeration}
Banned users: ${bannedUsers}

---
Open Admin: https://stewyrt.com/admin`;

    // Transporter configuration using Gmail SMTP with placeholder fallbacks
    const gmailUser = process.env.GMAIL_USER || "placeholder-user@gmail.com";
    const gmailPass = process.env.GMAIL_PASS || "placeholder-pass";

    const transporter = nodemailer.createTransport({
      service: "gmail",
      auth: {
        user: gmailUser,
        pass: gmailPass,
      },
    });

    const mailOptions = {
      from: `"Stewyrt System" <${gmailUser}>`,
      to: "wnltduk@gmail.com",
      subject: `Stewyrt Daily Digest — ${todayStr}`,
      text: emailBody,
    };

    try {
      const info = await transporter.sendMail(mailOptions);
      console.log(`[DAILY DIGEST] Email sent successfully: ${info.messageId}`);
    } catch (error) {
      console.error("[DAILY DIGEST] Failed to send email:", error);
    }

    // Call postToBuffer
    await postToBuffer(questionText, true, totalUsers);
  }
);

// Scheduled: daily at 14:00 UTC.
export const sendEveningPost = onSchedule(
  { 
    schedule: "0 14 * * *", 
    timeZone: "UTC", 
    region: "us-central1",
    secrets: ["BUFFER_API_KEY"]
  },
  async () => {
    const db = admin.firestore();
    const now = new Date();
    const todayStr = now.toISOString().slice(0, 10); // YYYY-MM-DD

    // Fetch today's question
    let questionText = "No active pulse question found for today";
    const scheduleDoc = await db.collection("question_schedule").doc(todayStr).get();
    if (scheduleDoc.exists) {
      const pulseQuestionId = scheduleDoc.data()?.pulse_question_id;
      if (pulseQuestionId) {
        const pollSnap = await db.collection("polls")
          .where("questionId", "==", pulseQuestionId)
          .limit(1)
          .get();
        if (!pollSnap.empty) {
          questionText = pollSnap.docs[0].data()?.question || "No question text";
        } else {
          // Fallback check questions
          const questionSnap = await db.collection("questions").doc(pulseQuestionId).get();
          if (questionSnap.exists) {
            questionText = questionSnap.data()?.text || "No question text";
          }
        }
      }
    }

    // Fetch totalUsers count
    const totalUsersSnap = await db.collection("users").count().get();
    const totalUsers = totalUsersSnap.data().count;

    // Call postToBuffer
    await postToBuffer(questionText, false, totalUsers);
  }
);
