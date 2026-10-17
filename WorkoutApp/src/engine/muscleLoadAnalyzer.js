/**
 * Muscle Load Analyzer & Auto-Balance Recommender
 * Inspects active exercises across each round and the full workout to detect
 * accidental muscle group overloading (e.g., stacking Triceps or Shoulders)
 * and provides 1-tap balanced replacement recommendations.
 */

import {
  filterEligibleExercises,
  getActiveSlotExercise,
  swapExerciseInSlot
} from './workoutEngine.js';

export const SPECIFIC_MUSCLES = [
  'Chest',
  'Biceps',
  'Triceps',
  'Shoulders',
  'Back',
  'Abs',
  'Glutes',
  'Quads',
  'Hamstrings'
];

export const MUSCLE_TO_BODY_AREA = {
  Chest: 'Upper Body',
  Biceps: 'Upper Body',
  Triceps: 'Upper Body',
  Shoulders: 'Upper Body',
  Back: 'Upper Body',
  Abs: 'Core',
  Glutes: 'Legs',
  Quads: 'Legs',
  Hamstrings: 'Legs'
};

/**
 * Analyze a workout for muscle group overload and compute balanced replacement recommendations.
 */
export function analyzeMuscleLoad(workoutState, sheetData, excludedExerciseIds = []) {
  if (!workoutState || !workoutState.rounds || !sheetData) {
    return {
      hasWarnings: false,
      warnings: [],
      workoutMuscleTotals: {},
      roundSummaries: []
    };
  }

  const bodyCategory = workoutState.inputs?.bodyCategory || 'All';
  const equipment = workoutState.inputs?.equipment || 'Any';
  const effectiveWorkoutCategory =
    workoutState.inputs?.effectiveWorkoutCategory ||
    workoutState.workout?.workoutCategory ||
    'Either';

  // Collect all currently active exercise IDs across the workout
  const activeWorkoutExerciseIds = new Set();
  const workoutMuscleTotals = {};
  SPECIFIC_MUSCLES.forEach(m => {
    workoutMuscleTotals[m] = { pri: 0, sec: 0, score: 0, exercises: [] };
  });

  let totalSlots = 0;

  workoutState.rounds.forEach(round => {
    round.slots.forEach(slot => {
      const ex = getActiveSlotExercise(slot);
      if (!ex) return;
      totalSlots++;
      activeWorkoutExerciseIds.add(ex.id);
      SPECIFIC_MUSCLES.forEach(m => {
        const level = ex.muscles?.[m] || '';
        if (level === 'Pri') {
          workoutMuscleTotals[m].pri += 1;
          workoutMuscleTotals[m].score += 1.0;
          workoutMuscleTotals[m].exercises.push(ex.name);
        } else if (level === 'Sec') {
          workoutMuscleTotals[m].sec += 1;
          workoutMuscleTotals[m].score += 0.5;
          workoutMuscleTotals[m].exercises.push(`${ex.name} (sec)`);
        }
      });
    });
  });

  // Eligible replacement pool respecting user filters & exclusions
  const eligiblePool = filterEligibleExercises(sheetData.exercises, {
    workoutCategory: effectiveWorkoutCategory,
    bodyCategory,
    equipment,
    excludedExerciseIds
  });

  const warnings = [];
  const roundSummaries = [];

  // Check each round for specific muscle overload
  workoutState.rounds.forEach((round, roundIndex) => {
    const roundStats = {};
    SPECIFIC_MUSCLES.forEach(m => {
      roundStats[m] = { pri: 0, sec: 0, score: 0, contributingSlots: [] };
    });

    round.slots.forEach((slot, slotIndex) => {
      const ex = getActiveSlotExercise(slot);
      if (!ex) return;
      SPECIFIC_MUSCLES.forEach(m => {
        const level = ex.muscles?.[m] || '';
        if (level === 'Pri') {
          roundStats[m].pri += 1;
          roundStats[m].score += 1.0;
          roundStats[m].contributingSlots.push({ slotIndex, exercise: ex, level: 'Pri', manuallyModified: !!slot.manuallyModified });
        } else if (level === 'Sec') {
          roundStats[m].sec += 1;
          roundStats[m].score += 0.5;
          roundStats[m].contributingSlots.push({ slotIndex, exercise: ex, level: 'Sec', manuallyModified: !!slot.manuallyModified });
        }
      });
    });

    roundSummaries.push({ roundNumber: round.roundNumber, stats: roundStats });

    const nSlots = round.slots.length;
    if (nSlots < 2) return;

    // Determine which muscles are overloaded in this round
    SPECIFIC_MUSCLES.forEach(muscle => {
      const st = roundStats[muscle];
      if (st.pri === 0) return;

      // If the user explicitly asked for 'Core' only, Abs being hit on every exercise is expected
      if (muscle === 'Abs' && bodyCategory === 'Core') return;

      // For 'Legs' only, Glutes and Quads co-contract on almost all squats/lunges;
      // require higher threshold (e.g. >= 3 Pri or manual modification stacking) when Legs-only is selected
      const isLegsMuscleInLegsFilter =
        (muscle === 'Glutes' || muscle === 'Quads') &&
        (bodyCategory === 'Legs' || bodyCategory === 'Legs and Core');

      const hasManualContributor = st.contributingSlots.some(c => c.manuallyModified);

      let isOverloaded = false;
      if (!isLegsMuscleInLegsFilter) {
        // Trigger if >= 2 Pri in a short round (<= 4 exercises), or >= 3 Pri in an 8-exercise round,
        // or weighted score >= 2.0 when user manually selected/swapped an exercise
        if (nSlots <= 4 && st.pri >= 2 && (muscle !== 'Abs' || st.pri >= 3 || hasManualContributor)) {
          isOverloaded = true;
        } else if (nSlots > 4 && st.pri >= 3 && (muscle !== 'Abs' || st.pri >= 4)) {
          isOverloaded = true;
        } else if (hasManualContributor && st.pri >= 1 && st.score >= 2.0 && st.contributingSlots.length >= 2) {
          isOverloaded = true;
        }
      } else {
        // In Legs-only filter, warn if >= 3 Pri in a <=4 slot round or manual stacking >= 2.5 score
        if ((nSlots <= 4 && st.pri >= 3) || (hasManualContributor && st.pri >= 2 && st.score >= 2.5)) {
          isOverloaded = true;
        }
      }

      if (isOverloaded) {
        // Pick the best slot to recommend replacing (prefer manually modified slot, else the last Pri slot)
        const sortedContributors = [...st.contributingSlots].sort((a, b) => {
          if (a.manuallyModified !== b.manuallyModified) return a.manuallyModified ? -1 : 1;
          if (a.level !== b.level) return a.level === 'Pri' ? -1 : 1;
          return b.slotIndex - a.slotIndex;
        });

        const targetSlotInfo = sortedContributors[0];
        const recommendations = getBalancedAlternatives({
          overloadedMuscle: muscle,
          targetExercise: targetSlotInfo.exercise,
          eligiblePool,
          activeWorkoutExerciseIds,
          workoutMuscleTotals,
          roundStats,
          bodyCategory
        });

        if (recommendations.length > 0) {
          warnings.push({
            id: `warn-r${round.roundNumber}-${muscle.toLowerCase()}`,
            roundIndex,
            roundNumber: round.roundNumber,
            muscle,
            bodyArea: MUSCLE_TO_BODY_AREA[muscle],
            priCount: st.pri,
            secCount: st.sec,
            score: st.score,
            contributingExercises: st.contributingSlots.map(c => c.exercise.name),
            targetSlotIndex: targetSlotInfo.slotIndex,
            targetExercise: targetSlotInfo.exercise,
            recommendations,
            message: `${muscle} is heavily loaded in Round ${round.roundNumber} (${st.contributingSlots.map(c => c.exercise.name).join(', ')}).`
          });
        }
      }
    });
  });

  return {
    hasWarnings: warnings.length > 0,
    warnings,
    workoutMuscleTotals,
    roundSummaries
  };
}

/**
 * Compute ranked replacement exercises that relieve the overloaded muscle and target under-used muscles.
 */
function getBalancedAlternatives({
  overloadedMuscle,
  targetExercise,
  eligiblePool,
  activeWorkoutExerciseIds,
  workoutMuscleTotals,
  roundStats,
  bodyCategory
}) {
  // Filter candidates not already in workout and not hitting the overloaded muscle
  let candidates = eligiblePool.filter(
    ex =>
      !activeWorkoutExerciseIds.has(ex.id) &&
      ex.id !== targetExercise.id &&
      !ex.muscles?.[overloadedMuscle]
  );

  // Fallback if all unused exercises hit that muscle as Sec: allow Sec but not Pri
  if (candidates.length === 0) {
    candidates = eligiblePool.filter(
      ex =>
        !activeWorkoutExerciseIds.has(ex.id) &&
        ex.id !== targetExercise.id &&
        ex.muscles?.[overloadedMuscle] !== 'Pri'
    );
  }

  // Score candidates by how well they balance under-used muscles in the round & workout
  const scored = candidates.map(ex => {
    let balanceScore = 0;

    SPECIFIC_MUSCLES.forEach(m => {
      if (ex.muscles?.[m] === 'Pri') {
        const roundLoad = roundStats[m]?.score || 0;
        const workoutLoad = workoutMuscleTotals[m]?.score || 0;
        // High reward if this muscle currently has 0 load in the round / workout
        if (roundLoad === 0) balanceScore += 15;
        if (workoutLoad === 0) balanceScore += 10;
        balanceScore -= roundLoad * 4 + workoutLoad * 2;
      } else if (ex.muscles?.[m] === 'Sec') {
        const roundLoad = roundStats[m]?.score || 0;
        balanceScore -= roundLoad * 1.5;
      }
    });

    // Prefer keeping the same macro body area if Body Category is specific, or diversifying if 'All'
    const overloadedArea = MUSCLE_TO_BODY_AREA[overloadedMuscle];
    if (bodyCategory === 'Upper Body' && ex.bodyCategories['Upper Body'] === 'Pri') {
      balanceScore += 8;
    } else if (bodyCategory === 'All' && ex.bodyCategories[overloadedArea] !== 'Pri') {
      balanceScore += 6;
    }

    const primaryMuscles = SPECIFIC_MUSCLES.filter(m => ex.muscles?.[m] === 'Pri');

    return {
      exercise: ex,
      balanceScore,
      targetMuscles: primaryMuscles,
      reason: `Targets ${primaryMuscles.join(' & ')} with zero ${overloadedMuscle} strain`
    };
  });

  scored.sort((a, b) => b.balanceScore - a.balanceScore);
  return scored.slice(0, 5);
}

/**
 * Apply the top recommended balanced alternative for a specific warning in 1 tap.
 */
export function applyBalancedRecommendation(workoutState, warning, chosenExercise = null) {
  if (!workoutState || !warning) return workoutState;
  const replacement = chosenExercise || warning.recommendations?.[0]?.exercise;
  if (!replacement) return workoutState;

  return swapExerciseInSlot(
    workoutState,
    warning.roundIndex,
    warning.targetSlotIndex,
    replacement
  );
}
