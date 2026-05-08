import * as admin from "firebase-admin";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { onObjectFinalized } from "firebase-functions/v2/storage";
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

interface VerificationResult {
  confidenceScore: number;
  flagged:         boolean;
  reason:          string;
}

const safetySettings = [
  { category: HarmCategory.HARM_CATEGORY_HARASSMENT,        threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_HATE_SPEECH,       threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT, threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
  { category: HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT, threshold: HarmBlockThreshold.BLOCK_LOW_AND_ABOVE },
];

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

      // ── DEMOGRAPHIC ACOUSTIC VERIFICATION FLOW ──────────────────────────────
      // Filename format: onboarding_<uuid>.m4a
      const uuid             = fileName.replace(/^onboarding_/, "").replace(/\.m4a$/, "");
      const claimedAge       = metadata["claimedAge"]       ?? "";
      const claimedGender    = metadata["claimedGender"]    ?? "";
      const claimedEthnicity = metadata["claimedEthnicity"] ?? "";
      const claimedRegion    = metadata["claimedRegion"]    ?? "";

      let verification: VerificationResult | null = null;

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
                { text: "Verify this speaker." },
              ],
            },
          ],
          config: {
            systemInstruction:
              `You are an acoustic verification engine. The user claims their age is ${claimedAge} ` +
              `and their gender is ${claimedGender}. Listen to the speaker's voice. Does the acoustic ` +
              `profile broadly match this claim? Output ONLY a JSON object with this schema: ` +
              `{ "confidenceScore": [0-100 integer], "flagged": [boolean - true if obviously synthetic/bot ` +
              `or a massive mismatch, otherwise false], "reason": "Short 1-sentence explanation" }.`,
            responseMimeType: "application/json",
            safetySettings,
          },
        });

        const raw  = (result.text ?? "").trim();
        const json = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();
        verification = JSON.parse(json) as VerificationResult;
      } catch (err) {
        console.error("[STEWYRT] Verification Gemini call failed:", err);
        await db.collection("users").doc(uuid).set({
          isFlagged:        true,
          verificationNote: "Voice verification failed due to server error. Please try again.",
          error:            true,
          verifiedAt:       admin.firestore.FieldValue.serverTimestamp(),
        });
      } finally {
        // Per our consent promise: destroy audio NO MATTER WHAT — crash, error, or success.
        if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
        await storageBucket.file(filePath).delete();
      }

      // Write the full verified profile only on success.
      if (verification !== null) {
        await db.collection("users").doc(uuid).set({
          claimedAge,
          claimedGender,
          claimedEthnicity,
          claimedRegion,
          confidenceScore:  verification.confidenceScore ?? 0,
          isFlagged:        verification.flagged         ?? false,
          verificationNote: verification.reason          ?? "",
          verifiedAt:       admin.firestore.FieldValue.serverTimestamp(),
        });
      }

    } else {

      // ── SENTIMENT ANALYSIS FLOW ──────────────────────────────────────────────
      const uuid      = fileName.replace(/\.m4a$/, "");
      const question   = metadata["question"]   ?? "What is on your mind right now?";
      const pollId     = metadata["pollId"]     ?? "";
      const responseId = metadata["responseId"] ?? uuid;

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
          console.warn(`[STEWYRT] Content moderation blocked — responseId: ${responseId}`);
          if (fs.existsSync(tempFilePath)) fs.unlinkSync(tempFilePath);
          await db.collection("responses").doc(responseId).set({
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
      const responseRef = db.collection("responses").doc(responseId);
      const pollRef     = pollId ? db.collection("polls").doc(pollId) : null;

      await db.runTransaction(async (tx) => {
        tx.set(responseRef, {
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
          pollId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

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
