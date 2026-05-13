// Seed the waiting_phrases collection with four-act analysis waiting room phrases.
// Run once from the repo root:
//   GOOGLE_APPLICATION_CREDENTIALS=./stewyrt-sa-key.json node scripts/seed_waiting_phrases.js
//
// Prerequisites:
//   cd functions && npm install   (ensures firebase-admin is available)
//
// Idempotent — uses deterministic doc IDs, so re-running overwrites cleanly.

const path  = require('path');
const admin = require(path.join(__dirname, '../functions/node_modules/firebase-admin'));

const projectId = process.env.FIREBASE_PROJECT_ID || 'stewyrt-11';

admin.initializeApp({ projectId });

const db = admin.firestore();

const PHRASES = [
  // Act 1 — setup
  { act: 'setup', text: 'Putting the kettle on...' },
  { act: 'setup', text: 'Having a quick chinwag...' },
  { act: 'setup', text: 'Pulling up a chair...' },
  { act: 'setup', text: 'Settling in for a proper listen...' },
  { act: 'setup', text: 'Cracking open a notebook...' },
  { act: 'setup', text: 'Adjusting the spectacles...' },
  { act: 'setup', text: 'Clearing the throat...' },
  { act: 'setup', text: 'Setting the scene...' },
  { act: 'setup', text: 'Lighting a metaphorical candle...' },
  { act: 'setup', text: 'Rolling up the sleeves...' },
  { act: 'setup', text: 'Loosening the tie...' },
  { act: 'setup', text: 'Taking a deep breath...' },

  // Act 2 — observation
  { act: 'observation', text: 'Having a proper gander...' },
  { act: 'observation', text: 'Squinting at the syllables...' },
  { act: 'observation', text: 'Tilting the head, owl-like...' },
  { act: 'observation', text: 'Sniffing the emotional air...' },
  { act: 'observation', text: 'Reading the tea leaves...' },
  { act: 'observation', text: 'Catching the cadence...' },
  { act: 'observation', text: 'Watching the words walk past...' },
  { act: 'observation', text: 'Holding it up to the light...' },
  { act: 'observation', text: 'Turning it over thoughtfully...' },
  { act: 'observation', text: 'Listening between the syllables...' },

  // Act 3 — empathy
  { act: 'empathy', text: 'Reading between the lines...' },
  { act: 'empathy', text: 'Distilling the sheer essence...' },
  { act: 'empathy', text: 'Letting it land properly...' },
  { act: 'empathy', text: 'Sitting with that for a moment...' },
  { act: 'empathy', text: 'Feeling the weight of it...' },
  { act: 'empathy', text: 'Catching the undertow...' },
  { act: 'empathy', text: 'Holding it gently...' },
  { act: 'empathy', text: 'Letting it settle in the chest...' },
  { act: 'empathy', text: 'Honouring the small ache...' },
  { act: 'empathy', text: 'Nodding slowly...' },

  // Act 4 — technical
  { act: 'technical', text: 'Consulting the emotional thesaurus...' },
  { act: 'technical', text: 'Booting up the empathy engine...' },
  { act: 'technical', text: 'Cross-referencing the feeling-files...' },
  { act: 'technical', text: 'Running it through the sentiment sieve...' },
  { act: 'technical', text: 'Checking with the committee of small voices...' },
  { act: 'technical', text: 'Putting it through the vibe-spectrometer...' },
  { act: 'technical', text: "Filing it under 'genuinely felt'..." },
  { act: 'technical', text: 'Comparing to the catalogue of human...' },
  { act: 'technical', text: 'Marking it on the great big chart...' },
  { act: 'technical', text: 'Tapping it into the system...' },
];

async function seed() {
  const ts = admin.firestore.Timestamp.now();
  const col = db.collection('waiting_phrases');

  // Split into batches of 500 (Firestore limit).
  const batchSize = 500;
  for (let i = 0; i < PHRASES.length; i += batchSize) {
    const batch = db.batch();
    PHRASES.slice(i, i + batchSize).forEach((p, j) => {
      const id  = `${p.act}_${String(i + j + 1).padStart(2, '0')}`;
      const ref = col.doc(id);
      batch.set(ref, { act: p.act, text: p.text, active: true, createdAt: ts });
    });
    await batch.commit();
  }
  console.log(`✓ Seeded ${PHRASES.length} waiting phrases`);
}

seed().catch((e) => { console.error(e); process.exit(1); });
