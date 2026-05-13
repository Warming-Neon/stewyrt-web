// Seed the verification_prompts collection with varied onboarding prompts.
// Run once from the repo root:
//   GOOGLE_APPLICATION_CREDENTIALS=./stewyrt-sa-key.json node scripts/seed_verification_prompts.js
//
// Prerequisites:
//   cd functions && npm install   (ensures firebase-admin is available)
//
// Idempotent — uses doc IDs based on index, so re-running overwrites cleanly.

const path  = require('path');
const admin = require(path.join(__dirname, '../functions/node_modules/firebase-admin'));

const projectId = process.env.FIREBASE_PROJECT_ID || 'stewyrt-11';

admin.initializeApp({ projectId });

const db = admin.firestore();

const PROMPTS = [
  "Tell us your favourite snack.",
  "Describe today's weather like a poet would.",
  "Name your favourite parent. We won't tell the other one.",
  "Say the colour of your socks today.",
  "Describe what's in your fridge right now.",
  "Say your full name like you're being introduced at the Oscars.",
  "Read out the nearest bit of writing you can see.",
  "Count to ten in any accent that isn't yours.",
  "Tell us what you had for breakfast — be honest.",
  "Pretend you're calling a radio show. Go.",
  "Describe your living room like an estate agent.",
  "What's a word you love saying? Say it three times.",
  "Quote your favourite film line, badly.",
  "Tell us what's on your mind. Anything at all.",
  "Pretend you're narrating a nature documentary about your hands.",
  "Describe the last thing that made you smile.",
  "What's the most boring sentence you can think of? Bore us.",
  "Read the next text message you've got. Out loud.",
];

async function seed() {
  const batch = db.batch();
  const col = db.collection('verification_prompts');
  const ts = admin.firestore.Timestamp.now();

  PROMPTS.forEach((text, i) => {
    const ref = col.doc(`prompt_${String(i + 1).padStart(2, '0')}`);
    batch.set(ref, { text, active: true, createdAt: ts });
  });

  await batch.commit();
  console.log(`✓ Seeded ${PROMPTS.length} verification prompts`);
}

seed().catch((e) => { console.error(e); process.exit(1); });
