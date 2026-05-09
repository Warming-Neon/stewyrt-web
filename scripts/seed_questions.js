#!/usr/bin/env node
/**
 * One-shot seed: populates the `questions` collection with the initial
 * curated question set. Idempotent — questions with matching text are
 * skipped, not duplicated.
 *
 * Usage (run from the repo root):
 *
 *   GOOGLE_APPLICATION_CREDENTIALS=./stewyrt-sa-key.json \
 *     node scripts/seed_questions.js
 *
 * firebase-admin is resolved from functions/node_modules so no separate
 * install is required.
 */

const admin = require('../functions/node_modules/firebase-admin');

const PROJECT_ID = 'stewyrt-11';

admin.initializeApp({ projectId: PROJECT_ID });
const db  = admin.firestore();
const now = admin.firestore.FieldValue.serverTimestamp();

const QUESTIONS = [
  {
    text:             'If you knew the world was listening, what urgent truth do you need to speak right now?',
    tier:             'horizon',
    category:         'confessional',
    emotional_weight: 'heavy',
    day_affinity:     null,
    cooldown_days:    180,
    notes:            'Original test question. Heavy weight — use sparingly.',
  },
  {
    text:             'If you had two buttons and one takes you 20 years back and one takes you 20 years forward, which one do you press and why?',
    tier:             'pulse',
    category:         'retrospective',
    emotional_weight: 'medium',
    day_affinity:     'saturday',
    cooldown_days:    90,
    notes:            'Generates strong age-segmented variance. Good for early data demos.',
  },
  {
    text:             'What was the biggest lie you were taught about how the world works, that you are only now unlearning?',
    tier:             'pulse',
    category:         'rebellion',
    emotional_weight: 'medium',
    day_affinity:     'monday',
    cooldown_days:    90,
    notes:            'Flagship Monday Rebellion question. Externalises blame, invites honesty.',
  },
  {
    text:             "What's the one thing keeping you from truly connecting with the people in your life?",
    tier:             'pulse',
    category:         'reflective',
    emotional_weight: 'heavy',
    day_affinity:     'tuesday',
    cooldown_days:    90,
    notes:            'Reframed from earlier draft. Avoid pairing with another heavy question on adjacent days.',
  },
  {
    text:             'Look at the trajectory of the next ten years. What are you quietly preparing for that no one else is talking about?',
    tier:             'horizon',
    category:         'anticipatory',
    emotional_weight: 'medium',
    day_affinity:     null,
    cooldown_days:    180,
    notes:            'Excellent press-hook question. Reserve for high-visibility Horizon weeks.',
  },
  {
    text:             "If there were no financial or social consequences, what is the first thing you'd stop doing tomorrow?",
    tier:             'pulse',
    category:         'rebellion',
    emotional_weight: 'medium',
    day_affinity:     'monday',
    cooldown_days:    90,
    notes:            "Strong Monday alternative. 'Stop' framing yields more honest data than 'start' equivalents.",
  },

  // ── Week 1 ──────────────────────────────────────────────────────────────────

  {
    text:             "What's something you do every day without a second thought... that you'd technically get told off for?",
    tier:             'pulse',
    category:         'rebellion',
    emotional_weight: 'medium',
    day_affinity:     'monday',
    cooldown_days:    90,
    notes:            'Week 1 Monday Rebellion. Trapdoor structure — user discovers the rule mid-recording.',
  },
  {
    text:             "Think of someone you used to be close to and aren't anymore. What did they teach you that you still carry?",
    tier:             'pulse',
    category:         'reflective',
    emotional_weight: 'medium',
    day_affinity:     'tuesday',
    cooldown_days:    90,
    notes:            'Week 1 Tuesday Reflective. Reframes loss as legacy.',
  },
  {
    text:             "What's something you do when nobody's watching that you'd be slightly embarrassed to explain?",
    tier:             'pulse',
    category:         'confessional',
    emotional_weight: 'light',
    day_affinity:     'wednesday',
    cooldown_days:    90,
    notes:            "Week 1 Wednesday Confessional. 'Slightly embarrassed' opens door to delightful private weirdness.",
  },
  {
    text:             "What's something most people seem to agree on that you secretly think is wrong?",
    tier:             'pulse',
    category:         'provocative',
    emotional_weight: 'medium',
    day_affinity:     'thursday',
    cooldown_days:    90,
    notes:            'Week 1 Thursday Provocative. Direct invitation to disagree with consensus.',
  },
  {
    text:             'If you had to give a TED talk, completely seriously, on the most ridiculous topic — what would it be?',
    tier:             'pulse',
    category:         'whimsical',
    emotional_weight: 'light',
    day_affinity:     'friday',
    cooldown_days:    90,
    notes:            "Week 1 Friday Whimsical. 'Completely seriously' is the comedy frame.",
  },
  {
    text:             'Tell me about a small kindness from a stranger that you still remember.',
    tier:             'pulse',
    category:         'retrospective',
    emotional_weight: 'medium',
    day_affinity:     'saturday',
    cooldown_days:    90,
    notes:            'Week 1 Saturday Retrospective. Universal answerability. Strong press-hook potential.',
  },
  {
    text:             'If your life were an audiobook, which chapter would be playing right now — and what\'s the title?',
    tier:             'pulse',
    category:         'existential',
    emotional_weight: 'medium',
    day_affinity:     'sunday',
    cooldown_days:    90,
    notes:            'Week 1 Sunday Existential. Audio metaphor matches the medium.',
  },

  // ── Week 2 ──────────────────────────────────────────────────────────────────

  {
    text:             "What's a thought you've had recently that you wouldn't dare say out loud to the people closest to you?",
    tier:             'pulse',
    category:         'confessional',
    emotional_weight: 'heavy',
    day_affinity:     'wednesday',
    cooldown_days:    90,
    notes:            'Week 2 Wednesday Confessional. Inner-circle stakes. Bounded to thoughts.',
  },
  {
    text:             "What's something we treat as 'just the way things are' that future generations will look back on and find genuinely barbaric?",
    tier:             'pulse',
    category:         'provocative',
    emotional_weight: 'medium',
    day_affinity:     'thursday',
    cooldown_days:    90,
    notes:            'Week 2 Thursday Provocative. Future-frame gives permission to critique present.',
  },
  {
    text:             "What's the weirdest hill you'd genuinely die on? Doesn't matter how trivial — defend it like you mean it.",
    tier:             'pulse',
    category:         'whimsical',
    emotional_weight: 'light',
    day_affinity:     'friday',
    cooldown_days:    90,
    notes:            'Week 2 Friday Whimsical. Permission to be passionate about something stupid.',
  },
  {
    text:             "What are you secretly hoping happens in the next year — but you'd never say out loud in case it doesn't?",
    tier:             'pulse',
    category:         'anticipatory',
    emotional_weight: 'heavy',
    day_affinity:     'saturday',
    cooldown_days:    90,
    notes:            'Week 2 Saturday Anticipatory. Superstitious-hope reveal mechanism.',
  },
  {
    text:             'If you had to describe your life right now using one piece of weather, what would it be — and what\'s the forecast for next week?',
    tier:             'pulse',
    category:         'existential',
    emotional_weight: 'medium',
    day_affinity:     'sunday',
    cooldown_days:    90,
    notes:            "Week 2 Sunday Existential. Weather metaphor — load-bearing for 'Emotional Weather Station' positioning.",
  },

  // ── Week 3 ──────────────────────────────────────────────────────────────────

  {
    text:             "What's a habit of yours that you got from someone you love?",
    tier:             'pulse',
    category:         'reflective',
    emotional_weight: 'medium',
    day_affinity:     'tuesday',
    cooldown_days:    90,
    notes:            'Week 3 Tuesday Reflective. Gentle, warm. Surfaces inheritance from relationships.',
  },
  {
    text:             'Confess a time you faked enjoying something to avoid the awkward conversation.',
    tier:             'pulse',
    category:         'confessional',
    emotional_weight: 'medium',
    day_affinity:     'wednesday',
    cooldown_days:    90,
    notes:            'Week 3 Wednesday Confessional. Single-anecdote shape. Story-led.',
  },
  {
    text:             'What secret reaction would you like to have to being patronised?',
    tier:             'pulse',
    category:         'provocative',
    emotional_weight: 'medium',
    day_affinity:     'thursday',
    cooldown_days:    90,
    notes:            'Week 3 Thursday Provocative. Fantasy-mode reveals class/gender/authority dynamics implicitly.',
  },
  {
    text:             'If you got to design one mandatory school subject that everyone had to take for a year — what would it be, and what would the final exam look like?',
    tier:             'pulse',
    category:         'whimsical',
    emotional_weight: 'light',
    day_affinity:     'friday',
    cooldown_days:    90,
    notes:            'Week 3 Friday Whimsical. Accidental sociology dressed as joke.',
  },
  {
    text:             'When was the last time you felt genuinely awake — not busy, not distracted, just fully here?',
    tier:             'pulse',
    category:         'existential',
    emotional_weight: 'medium',
    day_affinity:     'sunday',
    cooldown_days:    90,
    notes:            'Week 3 Sunday Existential. Asks about presence, not happiness.',
  },

  // ── Week 4 ──────────────────────────────────────────────────────────────────

  {
    text:             'Confess how often you thieve time from your employer and how you spend it.',
    tier:             'pulse',
    category:         'rebellion',
    emotional_weight: 'medium',
    day_affinity:     'monday',
    cooldown_days:    90,
    notes:            "Week 4 Monday Rebellion. 'Thieve time' is brilliant phrasing — primes specific anecdote.",
  },
  {
    text:             "What's something you tried and gave up on too quickly?",
    tier:             'pulse',
    category:         'reflective',
    emotional_weight: 'medium',
    day_affinity:     'tuesday',
    cooldown_days:    90,
    notes:            'Week 4 Tuesday Reflective. Direct, simple, no second-guessing tag.',
  },
  {
    text:             "What's your shameful comfort blanket right now?",
    tier:             'pulse',
    category:         'confessional',
    emotional_weight: 'light',
    day_affinity:     'wednesday',
    cooldown_days:    90,
    notes:            "Week 4 Wednesday Confessional. Specific, evocative, low barrier. Tel's curation.",
  },
  {
    text:             "What's something we praise as 'brave' or 'inspirational' that you secretly think is just... normal?",
    tier:             'pulse',
    category:         'provocative',
    emotional_weight: 'medium',
    day_affinity:     'thursday',
    cooldown_days:    90,
    notes:            'Week 4 Thursday Provocative. Targets performative elevation of ordinary acts.',
  },
  {
    text:             "You're at a dinner party and someone asks you to do your best impression... Go!",
    tier:             'pulse',
    category:         'whimsical',
    emotional_weight: 'light',
    day_affinity:     'friday',
    cooldown_days:    90,
    notes:            'Week 4 Friday Whimsical. Performative invitation — users may actually do the impression in audio.',
  },
  {
    text:             'In ten years time, what does your best life look like and how did you get there?',
    tier:             'pulse',
    category:         'anticipatory',
    emotional_weight: 'heavy',
    day_affinity:     'saturday',
    cooldown_days:    90,
    notes:            "Week 4 Saturday Anticipatory. Future-self + path-aware. Tel's simplification.",
  },
  {
    text:             "If your life had a soundtrack right now — not the one you'd choose, the one that actually fits — what would be playing?",
    tier:             'pulse',
    category:         'existential',
    emotional_weight: 'medium',
    day_affinity:     'sunday',
    cooldown_days:    90,
    notes:            'Week 4 Sunday Existential. Bypasses verbal defences. Users may play actual audio in their recording.',
  },

  // ── Horizon ─────────────────────────────────────────────────────────────────

  {
    text:             "What one thing do you want to be remembered for after you're gone?",
    tier:             'horizon',
    category:         'existential',
    emotional_weight: 'heavy',
    day_affinity:     null,
    cooldown_days:    180,
    notes:            'Horizon-grade gut-punch. Short questions sit longest in the head.',
  },
  {
    text:             'Twelve months can change a person. Has the last year changed you at all?',
    tier:             'horizon',
    category:         'reflective',
    emotional_weight: 'medium',
    day_affinity:     null,
    cooldown_days:    180,
    notes:            'Conversational, slightly cheeky. Dares user to actually answer instead of platitude.',
  },
];

async function run() {
  console.log(`[seed] project=${PROJECT_ID}`);

  const col = db.collection('questions');

  for (const q of QUESTIONS) {
    const existing = await col.where('text', '==', q.text).limit(1).get();

    if (!existing.empty) {
      console.log(`[seed] SKIP  "${q.text.slice(0, 60)}..."`);
      continue;
    }

    await col.add({
      ...q,
      status:          'approved',
      times_used:      0,
      last_used_date:  null,
      first_used_date: null,
      created_at:      now,
      updated_at:      now,
    });

    console.log(`[seed] CREATE "${q.text.slice(0, 60)}..."`);
  }

  console.log('[seed] Done.');
}

run().catch((err) => {
  console.error('[seed] Fatal:', err);
  process.exit(1);
});
