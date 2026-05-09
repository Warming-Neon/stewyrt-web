import * as admin from "firebase-admin";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import {
  GoogleGenAI,
  HarmCategory,
  HarmBlockThreshold,
} from "@google/genai";

admin.initializeApp();

// Store your Gemini API key in Google Cloud Secret Manager:
//   firebase functions:secrets:set GEMINI_API_KEY
const geminiApiKey = defineSecret("GEMINI_API_KEY");

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
const ALLOWED_ETHNICITIES: string[] = ["Asian", "Black or African", "Hispanic/Latino", "White", "Mixed", "Other", "Prefer not to say"];
const ALLOWED_REGIONS: string[]     = ["Northern Europe", "Western Europe", "Southern Europe", "Eastern Europe", "North America", "Latin America", "Middle East & North Africa", "Sub-Saharan Africa", "South Asia", "East Asia", "Southeast Asia", "Oceania", "Prefer not to say"];

// ── analyzeAudio ──────────────────────────────────────────────────────────────
// Storage trigger: processes every file uploaded to audio_uploads/.
// Routes on filename prefix:
//   onboarding_* → bot-detection verification flow
//   everything else → sentiment analysis flow
export const analyzeAudio = onObjectFinalized(
  { secrets: [geminiApiKey], bucket: "stewyrt-11.firebasestorage.app" },
  async (event) => {
    const filePath = event.data.name;

    // Only process uploads into audio_uploads/
    if (!filePath || !filePath.startsWith("audio_uploads/")) return;

    const fileName      = path.basename(filePath);
    const storageBucket = admin.storage().bucket(event.data.bucket);
    const tempFilePath  = path.join(os.tmpdir(), fileName);
    const metadata      = event.data.metadata ?? {};
    const db            = admin.firestore();

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
        const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

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
              `isHuman is true if this is a real human voice (not synthesised, not silence, not pure noise). ` +
              `isContinuousSpeech is true if the speech is continuous and natural, not a recording of a recording ` +
              `or a fragmented clip. note is a brief sentence explaining the assessment.`,
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
        await db.collection("users").doc(uuid).set({
          verifiedAsHuman:         detection.isHuman            ?? false,
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
      // Falls back to null in beta mode (UUID v4 responseId) — rate limiting is skipped.
      const rateUid = extractUidForRateLimit(rawResponseId);

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
        if (countSnap.data().count >= 30) {
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

        const ai = new GoogleGenAI({ apiKey: geminiApiKey.value() });

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

        // Store UID when derivable — used by the rate limiter on subsequent submissions.
        if (rateUid) doc["uid"] = rateUid;

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

  const { age, gender, ethnicity, region } = request.data as {
    age?: string;
    gender?: string;
    ethnicity?: string;
    region?: string;
  };

  if (!age       || !ALLOWED_AGES.includes(age))         throw new HttpsError("invalid-argument", `Invalid age value: ${age}`);
  if (!gender    || !ALLOWED_GENDERS.includes(gender))   throw new HttpsError("invalid-argument", `Invalid gender value: ${gender}`);
  if (!ethnicity || !ALLOWED_ETHNICITIES.includes(ethnicity)) throw new HttpsError("invalid-argument", `Invalid ethnicity value: ${ethnicity}`);
  if (!region    || !ALLOWED_REGIONS.includes(region))   throw new HttpsError("invalid-argument", `Invalid region value: ${region}`);

  const uid = request.auth.uid;
  const db  = admin.firestore();

  // merge: true preserves verifiedAsHuman and other verification fields.
  await db.collection("users").doc(uid).set(
    {
      selfReportedAge:       age,
      selfReportedGender:    gender,
      selfReportedEthnicity: ethnicity,
      selfReportedRegion:    region,
      selfReportedAt:        admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { success: true };
});
