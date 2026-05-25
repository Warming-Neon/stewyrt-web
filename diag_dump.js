const admin = require('./functions/node_modules/firebase-admin');
const path = require('path');
const serviceAccount = require('./stewyrt-sa-key.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function dump(collectionName) {
  console.log(`\n=== Collection: ${collectionName} ===`);
  try {
    const snap = await db.collection(collectionName).get();
    if (snap.empty) {
      console.log('(Empty)');
    } else {
      snap.forEach(doc => {
        console.log(`ID: ${doc.id}`);
        console.log(JSON.stringify(doc.data(), null, 2));
      });
    }
  } catch (e) {
    console.log(`Error reading ${collectionName}: ${e.message}`);
  }
}

async function main() {
  await dump('polls');
  await dump('questions');
  await dump('question_schedule');
}

main().catch(console.error);
