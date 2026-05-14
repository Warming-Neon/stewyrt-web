// Backfill script: fix Ice Breaker responses that were recorded before
// day_one_screen.dart passed a pollId to Storage upload metadata.
//
// What it does:
//   1. Finds all responses where pollId == "" AND question matches the
//      Ice Breaker question exactly, then sets pollId = 'ice_breaker_v1'.
//   2. Checks polls/ice_breaker_v1 and corrects total_submissions to
//      integer 0 if it was written as a String (e.g. via Firebase Console).
//
// Run once from the repo root:
//   GOOGLE_APPLICATION_CREDENTIALS=./stewyrt-sa-key.json node scripts/fix_ice_breaker_poll_ids.js
//
// Idempotent — a second run finds zero matching response docs and skips the
// poll fix if total_submissions is already numeric.

const path  = require('path');
const admin = require(path.join(__dirname, '../functions/node_modules/firebase-admin'));

const PROJECT_ID      = process.env.FIREBASE_PROJECT_ID || 'stewyrt-11';
const ICE_BREAKER_ID  = 'ice_breaker_v1';
const ICE_BREAKER_Q   = 'Tell us about the last time you laughed so hard you cried.';

admin.initializeApp({ projectId: PROJECT_ID });

const db = admin.firestore();

async function fixResponsePollIds() {
  const snap = await db
    .collection('responses')
    .where('pollId',   '==', '')
    .where('question', '==', ICE_BREAKER_Q)
    .get();

  if (snap.empty) {
    console.log('✓ No responses with empty pollId — nothing to update.');
    return;
  }

  const BATCH_SIZE = 400;
  let batch        = db.batch();
  let count        = 0;
  let total        = 0;

  for (const doc of snap.docs) {
    batch.update(doc.ref, { pollId: ICE_BREAKER_ID });
    console.log(`  → ${doc.id}`);
    count++;
    total++;

    if (count === BATCH_SIZE) {
      await batch.commit();
      batch = db.batch();
      count = 0;
    }
  }

  if (count > 0) await batch.commit();
  console.log(`✓ Updated ${total} response(s) → pollId: '${ICE_BREAKER_ID}'`);
}

async function fixPollTotalSubmissions() {
  const ref  = db.collection('polls').doc(ICE_BREAKER_ID);
  const snap = await ref.get();

  if (!snap.exists) {
    console.warn(`⚠ polls/${ICE_BREAKER_ID} not found — skipping total_submissions fix.`);
    return;
  }

  const val = snap.data()['total_submissions'];

  if (typeof val === 'number') {
    console.log(`✓ total_submissions is already numeric (${val}) — no change needed.`);
    return;
  }

  const corrected = parseInt(val, 10);
  await ref.update({ total_submissions: isNaN(corrected) ? 0 : corrected });
  console.log(`✓ Corrected total_submissions: '${val}' (String) → ${isNaN(corrected) ? 0 : corrected} (number)`);
}

async function main() {
  console.log('── Fix A: response pollIds ─────────────────────────────');
  await fixResponsePollIds();
  console.log('── Fix C: poll total_submissions ───────────────────────');
  await fixPollTotalSubmissions();
  console.log('Done.');
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
