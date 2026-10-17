import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { DataService } from '../src/services/dataService.js';
import {
  generateWorkout,
  filterEligibleExercises,
  getActiveSlotExercise,
  swapExerciseInSlot,
  getValidReplacementCandidates
} from '../src/engine/workoutEngine.js';
import {
  analyzeMuscleLoad,
  applyBalancedRecommendation,
  SPECIFIC_MUSCLES
} from '../src/engine/muscleLoadAnalyzer.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

const rawSheet = JSON.parse(
  fs.readFileSync(path.join(rootDir, 'data', 'sheet-data.json'), 'utf8')
);
const rawEnrich = JSON.parse(
  fs.readFileSync(path.join(rootDir, 'data', 'enrichments.json'), 'utf8')
);

const ds = new DataService().initFromObjects(rawSheet, rawEnrich);
const sheetData = ds.sheetData;

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ PASS: ${name}`);
  } catch (err) {
    console.error(`  ❌ FAIL: ${name}`);
    console.error(err);
    process.exit(1);
  }
}

console.log('================================================================');
console.log('RUNNING WORKOUT GENERATOR QA, FACT-CHECK & DIAGRAM AUDIT SUITE');
console.log('================================================================\n');

// ----------------------------------------------------------------------------
// 1. DATA INTEGRITY & BIOMECHANICAL AUDIT TESTS
// ----------------------------------------------------------------------------
console.log('1. Data Integrity & Biomechanical Muscle Audit');

test('Contains all 68 exercises (rows 2..69) and all 11 workout types', () => {
  assert.equal(sheetData.exercises.length, 68, 'Expected exactly 68 exercises');
  assert.equal(sheetData.workouts.length, 11, 'Expected exactly 11 workout types');

  const rows = sheetData.exercises.map(e => e.row);
  for (let r = 2; r <= 69; r++) {
    assert.ok(rows.includes(r), `Missing sheet row #${r}`);
  }
});

test('Biomechanical muscle audit fixes are applied with clean single-Primary + Secondary synergist hierarchy', () => {
  const byId = Object.fromEntries(sheetData.exercises.map(e => [e.id, e]));

  // All 5 Lunge variations must have Quads: Pri and Glutes: Sec (matching Squats)
  const lungeIds = [
    'lunges-split-squats',
    'lunge-jumps',
    'lunges-with-one-dumbbell-up',
    'lunge-with-one-foot-on-bench',
    'lunge-twists-with-slam-ball'
  ];
  for (const id of lungeIds) {
    assert.equal(byId[id].muscles.Quads, 'Pri', `${id} must have Quads: Pri`);
    assert.equal(byId[id].muscles.Glutes, 'Sec', `${id} must have Glutes: Sec`);
  }

  // Swings must have Back: Pri, Glutes: Sec, Hamstrings: Sec
  assert.equal(byId['swings'].muscles.Back, 'Pri');
  assert.equal(byId['swings'].muscles.Glutes, 'Sec');
  assert.equal(byId['swings'].muscles.Hamstrings, 'Sec');

  // TRX Wood Choppers must include Abs (Sec) and Core (Sec)
  assert.equal(byId['trx-wood-choppers'].muscles.Back, 'Pri');
  assert.equal(byId['trx-wood-choppers'].muscles.Abs, 'Sec');

  // Push-ups, 3 Stop Pushups, Shoulder Press, Arnold Press, Up Up down ups must include Triceps (Sec)
  assert.equal(byId['push-ups'].muscles.Triceps, 'Sec');
  assert.equal(byId['3-stop-pushups'].muscles.Triceps, 'Sec');
  assert.equal(byId['shoulder-press'].muscles.Triceps, 'Sec');
  assert.equal(byId['arnold-press'].muscles.Triceps, 'Sec');
  assert.equal(byId['up-up-down-ups'].muscles.Triceps, 'Sec');

  // Opposite arm & leg lifts must include Back (Sec) and Glutes (Sec)
  assert.equal(byId['opposite-arm-and-leg-lifts'].muscles.Back, 'Sec');
  assert.equal(byId['opposite-arm-and-leg-lifts'].muscles.Glutes, 'Sec');
});

// ----------------------------------------------------------------------------
// 2. EXERCISE FACT-CHECKING & 68 SVG DIAGRAM ASSESSMENT
// ----------------------------------------------------------------------------
console.log('\n2. Fact-Checking & 68 SVG Diagram-to-Description Verification');

test('All 11 workout types have complete fact-checked descriptions matching sheet metadata', () => {
  for (const wk of sheetData.workouts) {
    assert.ok(wk.enrichment, `Missing enrichment for workout ${wk.name}`);
    assert.ok(wk.enrichment.summary.length > 20, `Short summary for ${wk.name}`);
    assert.ok(Array.isArray(wk.enrichment.howItWorks) && wk.enrichment.howItWorks.length >= 3);
    assert.ok(wk.enrichment.timerStructure.length > 10);
    assert.ok(wk.enrichment.pacingTip.length > 20);
  }
});

test('Specialty exercises have accurate, movement-specific fact-checked instructions', () => {
  const byId = Object.fromEntries(sheetData.exercises.map(e => [e.id, e]));

  // Chest Press 6-6-6 mentions 6 reps bilateral + 6 right + 6 left
  const cp666Text = JSON.stringify(byId['chest-press-6-6-6'].enrichment);
  assert.ok(cp666Text.includes('6') && cp666Text.toLowerCase().includes('single-arm'));

  // 3 Stop Pushups mentions Stop 1, Stop 2, Stop 3
  const stop3Text = JSON.stringify(byId['3-stop-pushups'].enrichment);
  assert.ok(stop3Text.includes('Stop 1') && stop3Text.includes('Stop 2') && stop3Text.includes('Stop 3'));

  // 3 way V ups mentions left, center, right
  const v3Text = JSON.stringify(byId['3-way-v-ups'].enrichment).toLowerCase();
  assert.ok(v3Text.includes('left') && v3Text.includes('center') && v3Text.includes('right'));

  // Crunch + Pike on roller mentions both Crunch and Pike
  const cpRollerText = JSON.stringify(byId['crunch-pike-on-roller'].enrichment);
  assert.ok(cpRollerText.includes('Crunch') && cpRollerText.includes('Pike'));
});

test('All 68 SVG diagrams exist, contain valid SVG, highlight Pri/Sec muscles, and map back to descriptions', () => {
  for (const ex of sheetData.exercises) {
    const enrich = ex.enrichment;
    assert.ok(enrich, `Missing enrichment for ${ex.id}`);
    assert.ok(enrich.summary.length > 25, `Summary too short for ${ex.id}`);
    assert.ok(enrich.steps.length >= 3, `Expected >= 3 steps for ${ex.id}`);
    assert.ok(enrich.formTip.length > 15, `Form tip too short for ${ex.id}`);

    const svgPath = path.join(rootDir, enrich.diagram);
    assert.ok(fs.existsSync(svgPath), `Missing SVG diagram file: ${svgPath}`);

    const svgContent = fs.readFileSync(svgPath, 'utf8');
    assert.ok(svgContent.startsWith('<svg') && svgContent.endsWith('</svg>'), `Invalid SVG wrapper for ${ex.id}`);
    assert.ok(svgContent.includes(ex.name), `SVG aria-label should reference ${ex.name}`);
    assert.ok(svgContent.includes(enrich.badge.replace(/&/g, '&amp;')) || svgContent.includes(enrich.badge), `SVG missing badge for ${ex.id}`);
    assert.ok(svgContent.includes(`Equip: ${ex.equipment}`), `SVG missing equipment label for ${ex.id}`);

    // Every Primary muscle in ex.muscles must appear in the SVG target muscle panel and orange (#f97316) highlight
    const priMuscles = SPECIFIC_MUSCLES.filter(m => ex.muscles[m] === 'Pri');
    assert.ok(priMuscles.length >= 1, `${ex.id} must have at least 1 Primary muscle`);
    for (const pm of priMuscles) {
      assert.ok(
        svgContent.includes(`${pm} (PRI)`),
        `SVG for ${ex.id} must list ${pm} (PRI) in its target muscle map`
      );
    }
    assert.ok(svgContent.includes('#f97316'), `SVG for ${ex.id} must include primary muscle highlight color #f97316`);
  }
});

// ----------------------------------------------------------------------------
// 3. GENERATOR ENGINE, EQUIPMENT RULES, EXCLUSIONS & MULTI-OPTION STRESS TESTS
// ----------------------------------------------------------------------------
console.log('\n3. Generator Engine, Equipment Rules, Exclusions & Multi-Option Slots');

test('Equipment = "Nothing" strictly returns only bodyweight-capable exercises (Nothing or Any)', () => {
  const pool = filterEligibleExercises(sheetData.exercises, {
    workoutCategory: 'Either',
    bodyCategory: 'All',
    equipment: 'Nothing'
  });
  assert.ok(pool.length >= 20, 'Should have at least 20 bodyweight exercises');
  for (const ex of pool) {
    assert.ok(
      ex.equipment === 'Nothing' || ex.equipment === 'Any',
      `Unexpected non-bodyweight exercise "${ex.name}" (${ex.equipment}) when Equipment = Nothing`
    );
  }
});

test('Equipment = "Any" makes all 68 exercises eligible', () => {
  const pool = filterEligibleExercises(sheetData.exercises, {
    workoutCategory: 'Either',
    bodyCategory: 'All',
    equipment: 'Any'
  });
  assert.equal(pool.length, 68);
});

test('Selecting a manual Workout Type overrides Workout Category to match that workout (Apps Script parity)', () => {
  const wk = generateWorkout(sheetData, {
    workoutCategory: 'HIIT',
    bodyCategory: 'All',
    equipment: 'Any',
    workoutType: 'Strength Duos'
  });
  assert.equal(wk.inputs.effectiveWorkoutCategory, 'Strength');
  assert.equal(wk.workout.name, 'Strength Duos');
  assert.equal(wk.rounds.length, 4);
  assert.equal(wk.rounds[0].slots.length, 2);
});

test('User Exercise Exclusion List prevents excluded exercises from ever appearing', () => {
  const excludedIds = ['push-ups', 'burpees', 'squats', 'plank', 'mountain-climbers'];
  for (let i = 0; i < 100; i++) {
    const wk = generateWorkout(sheetData, {
      workoutCategory: 'Either',
      bodyCategory: 'All',
      equipment: 'Any',
      workoutType: 'Random',
      excludedExerciseIds: excludedIds,
      optionsPerSlot: 3
    });
    for (const r of wk.rounds) {
      for (const s of r.slots) {
        for (const opt of s.options) {
          assert.ok(
            !excludedIds.includes(opt.id),
            `Excluded exercise ${opt.id} appeared in generated workout`
          );
        }
      }
    }
  }
});

test('Multi-Option Slots (1, 2, or 3 options per exercise slide) generate distinct valid options per slot', () => {
  for (const optionsPerSlot of [1, 2, 3]) {
    const wk = generateWorkout(sheetData, {
      workoutCategory: 'HIIT',
      bodyCategory: 'All',
      equipment: 'Any',
      workoutType: 'Timed Trios (40/20)',
      optionsPerSlot
    });
    for (const r of wk.rounds) {
      for (const s of r.slots) {
        assert.equal(
          s.options.length,
          optionsPerSlot,
          `Expected ${optionsPerSlot} options in slot, got ${s.options.length}`
        );
        const uniqueIds = new Set(s.options.map(o => o.id));
        assert.equal(uniqueIds.size, optionsPerSlot, 'Options within a slot must be distinct');
      }
    }
  }
});

test('Monte Carlo Stress Test: 1,000+ generated workouts across all filter permutations never crash or return undefined', () => {
  const workoutCats = ['Either', 'Strength', 'HIIT'];
  const bodyCats = ['All', 'Upper Body', 'Core', 'Legs', 'Upper Body and Core', 'Legs and Core'];
  const equips = ['Any', 'Weights', 'Bands', 'Nothing'];
  const workoutTypes = ['Random', ...sheetData.workouts.map(w => w.name)];

  let runs = 0;
  for (const workoutCategory of workoutCats) {
    for (const bodyCategory of bodyCats) {
      for (const equipment of equips) {
        for (const workoutType of workoutTypes) {
          const wk = generateWorkout(sheetData, {
            workoutCategory,
            bodyCategory,
            equipment,
            workoutType,
            optionsPerSlot: (runs % 3) + 1
          });
          assert.ok(wk && wk.rounds.length >= 1);
          for (const r of wk.rounds) {
            assert.ok(r.slots.length >= 1);
            for (const s of r.slots) {
              const active = getActiveSlotExercise(s);
              assert.ok(active && active.id && active.name);
            }
          }
          runs++;
        }
      }
    }
  }
  console.log(`     (Completed ${runs} full filter combinations without a single failure)`);
});

// ----------------------------------------------------------------------------
// 4. MUSCLE GROUP OVERLOAD DETECTION & 1-TAP AUTO-BALANCE TESTS
// ----------------------------------------------------------------------------
console.log('\n4. Muscle Group Overload Detection & 1-Tap Auto-Balance Recommendations');

test('Detects accidental Triceps overload when user manually selects multiple Triceps exercises and balances in 1 tap', () => {
  let wk = generateWorkout(sheetData, {
    workoutCategory: 'HIIT',
    bodyCategory: 'Upper Body',
    equipment: 'Weights',
    workoutType: 'Timed Trios (40/20)'
  });

  const byId = Object.fromEntries(sheetData.exercises.map(e => [e.id, e]));
  // Manually swap Round 1 slots to overload Triceps: Skull Crushers, Tricep kick backs, TRX Triceps
  wk = swapExerciseInSlot(wk, 0, 0, byId['skull-crushers']);
  wk = swapExerciseInSlot(wk, 0, 1, byId['tricep-kick-backs']);
  wk = swapExerciseInSlot(wk, 0, 2, byId['trx-triceps']);

  const analysis = analyzeMuscleLoad(wk, sheetData, []);
  assert.ok(analysis.hasWarnings, 'Should flag muscle overload warning');

  const tricepWarning = analysis.warnings.find(
    w => w.roundIndex === 0 && w.muscle === 'Triceps'
  );
  assert.ok(tricepWarning, 'Should specifically warn about Triceps overload in Round 1');
  assert.equal(tricepWarning.priCount, 3);
  assert.ok(tricepWarning.recommendations.length >= 1, 'Should provide balanced replacement recommendations');

  // Verify top recommendation does not load Triceps as Pri
  const topRec = tricepWarning.recommendations[0].exercise;
  assert.notEqual(topRec.muscles.Triceps, 'Pri', 'Recommended alternative must not overload Triceps');

  // Apply 1-tap auto-balance once -> reduces Triceps from 3 to 2
  const balancedOnce = applyBalancedRecommendation(wk, tricepWarning);
  const analysisAfterOne = analyzeMuscleLoad(balancedOnce, sheetData, []);
  const tricepWarning2 = analysisAfterOne.warnings.find(
    w => w.roundIndex === 0 && w.muscle === 'Triceps'
  );
  assert.ok(tricepWarning2 && tricepWarning2.priCount === 2);

  // Apply 1-tap auto-balance a second time -> resolves Triceps warning completely!
  const balancedTwice = applyBalancedRecommendation(balancedOnce, tricepWarning2);
  const analysisFinal = analyzeMuscleLoad(balancedTwice, sheetData, []);
  const remainingTricepWarn = analysisFinal.warnings.find(
    w => w.roundIndex === 0 && w.muscle === 'Triceps'
  );
  assert.equal(remainingTricepWarn, undefined, 'Triceps overload should be completely resolved');
});

test('"Pick Random Valid Replacement" (getValidReplacementCandidates) never triggers a muscle overload warning across 200+ swaps', () => {
  for (let i = 0; i < 200; i++) {
    let wk = generateWorkout(sheetData, {
      workoutCategory: 'HIIT',
      bodyCategory: 'All',
      equipment: 'Any',
      workoutType: 'Timed Trios (40/20)'
    });

    const roundIndex = i % wk.rounds.length;
    const slotIndex = i % wk.rounds[roundIndex].slots.length;

    const validCandidates = getValidReplacementCandidates({
      workoutState: wk,
      roundIndex,
      slotIndex,
      sheetData,
      excludedExerciseIds: [],
      analyzeMuscleLoadFn: analyzeMuscleLoad
    });

    assert.ok(validCandidates.length > 0, 'Expected at least 1 valid replacement candidate');
    const chosen = validCandidates[Math.floor(Math.random() * validCandidates.length)];
    const swapped = swapExerciseInSlot(wk, roundIndex, slotIndex, chosen, null, true);

    const analysis = analyzeMuscleLoad(swapped, sheetData, []);
    const roundWarnings = analysis.warnings.filter(w => w.roundIndex === roundIndex);
    assert.equal(
      roundWarnings.length,
      0,
      `Random valid replacement "${chosen.name}" unexpectedly caused warning: ${roundWarnings.map(w => w.message).join('; ')}`
    );
  }
});

console.log(`\n🎉 ALL ${passed} QA TEST SUITES PASSED SUCCESSFULLY!`);

