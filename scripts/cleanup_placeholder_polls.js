#!/usr/bin/env node
// One-shot cleanup: removes placeholder pulse and horizon polls and all
// response documents that reference them. Idempotent — safe to run twice.

const admin = require("firebase-admin");
admin.initializeApp({ credential: admin.credential.cert(process.env.GOOGLE_APPLICATION_CREDENTIALS) });
const { getFirestore } = require("firebase-admin/firestore");

const PLACEHOLDER_POLL_IDS = [
  "SDIQeGRTg9DdXu8PUzD7", // placeholder pulse
  "vAFqqAiBhGfYAEN7OPtl", // placeholder horizon
];

async function deleteResponsesForPoll(db, pollId) {
  const snap = await db.collection("responses").where("pollId", "==", pollId).get();
  if (snap.empty) return 0;

  const BATCH_SIZE = 400;
  let deleted = 0;
  for (let i = 0; i < snap.docs.length; i += BATCH_SIZE) {
    const batch = db.batch();
    snap.docs.slice(i, i + BATCH_SIZE).forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += Math.min(BATCH_SIZE, snap.docs.length - i);
  }
  return deleted;
}

async function deletePoll(db, pollId) {
  const ref  = db.collection("polls").doc(pollId);
  const snap = await ref.get();
  if (!snap.exists) {
    console.log(`  polls/${pollId} — not found (already deleted or never existed)`);
    return false;
  }
  await ref.delete();
  return true;
}

async function main() {
  const db = getFirestore();

  let totalResponsesDeleted = 0;

  for (const pollId of PLACEHOLDER_POLL_IDS) {
    console.log(`\nProcessing poll: ${pollId}`);
    const count = await deleteResponsesForPoll(db, pollId);
    console.log(`  responses deleted: ${count}`);
    totalResponsesDeleted += count;

    const wasDeleted = await deletePoll(db, pollId);
    console.log(`  polls/${pollId} — ${wasDeleted ? "deleted" : "already absent"}`);
  }

  console.log(`\nDone. Total responses deleted: ${totalResponsesDeleted}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
