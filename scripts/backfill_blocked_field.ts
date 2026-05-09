#!/usr/bin/env ts-node
/**
 * One-shot backfill: stamps `blocked: false` on all approved response documents
 * created before the Phase 1 Cloud Function deploy (which started writing the
 * field explicitly). Without this, `isNotEqualTo: true` Firestore queries omit
 * those documents because Firestore excludes documents where the field is absent.
 *
 * Criteria for update:
 *   - document has at least one of tone / flavor / essence  (i.e. was processed)
 *   - document does NOT already have a `blocked` field
 *
 * Documents with blocked=true are left untouched.
 *
 * Usage (run from the functions/ directory so firebase-admin resolves):
 *
 *   cd functions
 *   GOOGLE_APPLICATION_CREDENTIALS=../path/to/service-account.json \
 *     npx ts-node ../scripts/backfill_blocked_field.ts
 *
 * Preview without writing:
 *
 *   ... npx ts-node ../scripts/backfill_blocked_field.ts --dry-run
 */

import * as admin from 'firebase-admin';

const PROJECT_ID = 'stewyrt-11';
const DRY_RUN   = process.argv.includes('--dry-run');
const PAGE_SIZE  = 200; // docs per page; well under 500-op batch limit

admin.initializeApp({ projectId: PROJECT_ID });
const db = admin.firestore();

async function run(): Promise<void> {
  console.log(`[backfill] project=${PROJECT_ID}  dry-run=${DRY_RUN}`);

  let totalScanned = 0;
  let totalUpdated = 0;
  let lastDoc: admin.firestore.QueryDocumentSnapshot | undefined;

  while (true) {
    let q = db.collection('responses')
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(PAGE_SIZE);

    if (lastDoc) q = q.startAfter(lastDoc);

    const page = await q.get();
    if (page.empty) break;

    totalScanned += page.size;
    lastDoc = page.docs[page.docs.length - 1];

    const candidates: admin.firestore.QueryDocumentSnapshot[] = [];
    for (const doc of page.docs) {
      const d = doc.data();
      const alreadySet = d['blocked'] !== undefined && d['blocked'] !== null;
      const isProcessed = d['tone'] != null || d['flavor'] != null || d['essence'] != null;
      if (!alreadySet && isProcessed) candidates.push(doc);
    }

    if (candidates.length > 0) {
      if (!DRY_RUN) {
        const batch = db.batch();
        for (const doc of candidates) {
          batch.update(doc.ref, { blocked: false });
        }
        await batch.commit();
      }
      totalUpdated += candidates.length;
    }

    console.log(
      `[backfill] page size=${page.size}  candidates=${candidates.length}` +
      `  running totals: scanned=${totalScanned}  ${DRY_RUN ? 'would-update' : 'updated'}=${totalUpdated}`,
    );

    if (page.size < PAGE_SIZE) break;
  }

  console.log(
    `[backfill] Complete. scanned=${totalScanned}  ` +
    `${DRY_RUN ? 'would-update (dry-run)' : 'updated'}=${totalUpdated}`,
  );
}

run().catch((err) => {
  console.error('[backfill] Fatal:', err);
  process.exit(1);
});
