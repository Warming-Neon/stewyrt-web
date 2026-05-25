#!/usr/bin/env node
// One-shot seed: creates the first live pulse and horizon poll documents
// with hardcoded IDs. Idempotent — will not overwrite existing documents.

const admin = require("firebase-admin");
admin.initializeApp({ credential: admin.credential.cert(process.env.GOOGLE_APPLICATION_CREDENTIALS) });
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const POLLS = [
  {
    id:         "pulse_live_v1",
    tier:       "pulse",
    question:   "What's something you do every day without a second thought... that you'd technically get told off for?",
    questionId: "w2vryI6uhcpJ4Hnfb28g",
    isActive:   true,
  },
  {
    id:         "horizon_live_v1",
    tier:       "horizon",
    question:   "Twelve months can change a person. Has the last year changed you at all?",
    questionId: "rF8GNbnKTY8o3um8ElDi",
    isActive:   true,
  },
];

async function main() {
  const db = getFirestore();

  for (const poll of POLLS) {
    const ref  = db.collection("polls").doc(poll.id);
    const snap = await ref.get();

    if (snap.exists) {
      console.log(`polls/${poll.id} — already exists, skipping`);
      continue;
    }

    await ref.set({
      tier:       poll.tier,
      question:   poll.question,
      questionId: poll.questionId,
      isActive:   poll.isActive,
      createdAt:  FieldValue.serverTimestamp(),
    });

    console.log(`polls/${poll.id} — created (${poll.tier})`);
  }

  console.log("\nDone.");
}

main().catch((err) => { console.error(err); process.exit(1); });
