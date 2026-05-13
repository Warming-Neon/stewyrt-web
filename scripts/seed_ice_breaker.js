// Seed the Ice Breaker poll document into the `polls` collection.
// Run once from the repo root:
//   GOOGLE_APPLICATION_CREDENTIALS=./stewyrt-sa-key.json node scripts/seed_ice_breaker.js
//
// Prerequisites:
//   cd functions && npm install   (ensures firebase-admin is available)
//
// The script is idempotent — running it again overwrites the same doc.

const path  = require('path');
const admin = require(path.join(__dirname, '../functions/node_modules/firebase-admin'));

const projectId = process.env.FIREBASE_PROJECT_ID || 'stewyrt-11';

admin.initializeApp({ projectId });

const db = admin.firestore();

async function seed() {
  const ref = db.collection('polls').doc('ice_breaker_v1');
  await ref.set({
    tier:      'ice_breaker',
    question:  'Tell us about the last time you laughed so hard you cried.',
    topic:     'Ice Breaker',
    category:  'Always On',
    isActive:  true,
    createdAt: admin.firestore.Timestamp.now(),
  });
  console.log('✓ Seeded polls/ice_breaker_v1');
}

seed().catch((e) => { console.error(e); process.exit(1); });