/**
 * Workout Generator Engine
 * 1:1 Port of Google Apps Script `generateWorkout()` +
 * Per-User Exercise Exclusions, Clarified Equipment Filtering, and Multi-Option Slots (1, 2, or 3).
 */

export const BODY_AREAS = ['Upper Body', 'Core', 'Legs'];

export const MAX_BODY_CATEGORY_PERCENTAGES = {
  'All': 0.33,
  'Upper Body': 1.0,
  'Core': 1.0,
  'Legs': 1.0,
  'Upper Body and Core': 0.5,
  'Legs and Core': 0.5
};

/**
 * Pick a random element from an array using an optional RNG function (defaults to Math.random).
 */
export function getRandomEntry(arr, rng = Math.random) {
  if (!arr || arr.length === 0) return null;
  return arr[Math.floor(rng() * arr.length)];
}

/**
 * Filter exercises based on Workout Category, Equipment, Body Category, and User Exclusion List.
 */
export function filterEligibleExercises(allExercises, {
  workoutCategory,
  bodyCategory = 'All',
  equipment = 'Any',
  excludedExerciseIds = []
}) {
  const excludedSet = new Set(excludedExerciseIds);

  // 1. Exclude user's excluded exercises
  let pool = allExercises.filter(ex => !excludedSet.has(ex.id) && !excludedSet.has(ex.name));

  // 2. Filter by workoutCategory ('Strength' or 'HIIT' matches exact or 'Either')
  if (workoutCategory && workoutCategory !== 'Either') {
    pool = pool.filter(
      ex => ex.workoutCategory === workoutCategory || ex.workoutCategory === 'Either'
    );
  }

  // 3. Filter by equipment
  // - 'Any' or 'All': all equipment is available (no filter)
  // - 'Weights': exclude 'Bands'-only exercises
  // - 'Bands': exclude 'Weights'-only exercises
  // - 'Nothing': only bodyweight exercises ('Nothing' or bodyweight-capable 'Any' / 'All')
  if (equipment === 'Weights') {
    pool = pool.filter(ex => ex.equipment !== 'Bands');
  } else if (equipment === 'Bands') {
    pool = pool.filter(ex => ex.equipment !== 'Weights');
  } else if (equipment === 'Nothing') {
    pool = pool.filter(
      ex => ex.equipment === 'Nothing' || ex.equipment === 'Any' || ex.equipment === 'All'
    );
  }

  // 4. Filter by bodyCategory
  if (bodyCategory === 'Upper Body') {
    pool = pool.filter(ex => ex.bodyCategories['Upper Body'] === 'Pri');
  } else if (bodyCategory === 'Core') {
    pool = pool.filter(ex => ex.bodyCategories['Core'] === 'Pri');
  } else if (bodyCategory === 'Legs') {
    pool = pool.filter(ex => ex.bodyCategories['Legs'] === 'Pri');
  } else if (bodyCategory === 'Upper Body and Core') {
    pool = pool.filter(
      ex => ex.bodyCategories['Upper Body'] === 'Pri' || ex.bodyCategories['Core'] === 'Pri'
    );
  } else if (bodyCategory === 'Legs and Core') {
    pool = pool.filter(
      ex => ex.bodyCategories['Legs'] === 'Pri' || ex.bodyCategories['Core'] === 'Pri'
    );
  }

  return pool;
}

/**
 * Determine the primary body area ('Upper Body', 'Core', or 'Legs') for an exercise.
 */
export function getPrimaryBodyArea(exercise) {
  for (const area of BODY_AREAS) {
    if (exercise.bodyCategories[area] === 'Pri') return area;
  }
  return 'All';
}

/**
 * Generate a complete workout matching the Apps Script algorithm + multi-option slots.
 */
export function generateWorkout(sheetData, inputs = {}, rng = Math.random) {
  const {
    workoutCategory: rawWorkoutCategory = 'HIIT',
    bodyCategory = 'All',
    equipment = 'Any',
    workoutType = 'Random',
    excludedExerciseIds = [],
    optionsPerSlot = 1
  } = inputs;

  const numOptions = Math.min(3, Math.max(1, Number(optionsPerSlot) || 1));

  // Step 1: Resolve Workout Category if 'Either'
  let resolvedWorkoutCategory = rawWorkoutCategory;
  if (resolvedWorkoutCategory === 'Either') {
    resolvedWorkoutCategory = getRandomEntry(['Strength', 'HIIT'], rng);
  }

  // Step 2: Resolve Workout Type (Random vs Manually Selected)
  let selectedWorkout = null;
  if (!workoutType || workoutType === 'Random') {
    const categoryWorkouts = sheetData.workouts.filter(
      w => w.workoutCategory === resolvedWorkoutCategory
    );
    selectedWorkout = getRandomEntry(categoryWorkouts, rng) || sheetData.workouts[0];
  } else {
    selectedWorkout =
      sheetData.workouts.find(w => w.name === workoutType || w.id === workoutType) ||
      sheetData.workouts[0];
    // Parity with Apps Script line 74: manually selected workout updates workout_category
    resolvedWorkoutCategory = selectedWorkout.workoutCategory;
  }

  // Step 3: Filter eligible exercises
  const allFiltered = filterEligibleExercises(sheetData.exercises, {
    workoutCategory: resolvedWorkoutCategory,
    bodyCategory,
    equipment,
    excludedExerciseIds
  });

  // Fallback if user excluded almost everything
  const basePool = allFiltered.length > 0
    ? [...allFiltered]
    : sheetData.exercises.filter(ex => !excludedExerciseIds.includes(ex.id));

  let masterExercises = [...basePool];

  const nRounds = parseInt(selectedWorkout.rounds, 10) || 1;
  const nExercisesPerRound = parseInt(selectedWorkout.exercisesPerRound, 10) || 1;
  const maxBodyCategoryPercent =
    MAX_BODY_CATEGORY_PERCENTAGES[bodyCategory] !== undefined
      ? MAX_BODY_CATEGORY_PERCENTAGES[bodyCategory]
      : 1.0;

  const usedExerciseIds = new Set();
  const rounds = [];

  // Step 4: Loop over rounds and select balanced exercises
  for (let rnd = 0; rnd < nRounds; rnd++) {
    let exercisesRound = masterExercises.filter(ex => !usedExerciseIds.has(ex.id));
    const roundSlots = [];

    const bodyCategoryPercent = {
      'Upper Body': 0,
      'Core': 0,
      'Legs': 0
    };

    for (let exIdx = 0; exIdx < nExercisesPerRound; exIdx++) {
      // Safeguard if strict round balancing or small filtered pool emptied exercisesRound
      if (exercisesRound.length === 0) {
        exercisesRound = masterExercises.filter(ex => !usedExerciseIds.has(ex.id));
      }
      if (exercisesRound.length === 0) {
        // Pool exhausted across workout; recycle from basePool avoiding duplicates within the same round
        const roundIds = new Set(
          roundSlots.flatMap(s => s.options.map(o => o.id))
        );
        exercisesRound = basePool.filter(ex => !roundIds.has(ex.id));
      }
      if (exercisesRound.length === 0) {
        exercisesRound = [...basePool];
      }

      // Prefer candidates in exercisesRound that don't duplicate a specific Primary muscle already in this round
      const roundUsedPriMuscles = new Set();
      roundSlots.forEach(s => {
        const active = s.options[0];
        if (!active?.muscles) return;
        Object.entries(active.muscles).forEach(([m, lvl]) => {
          if (lvl === 'Pri') roundUsedPriMuscles.add(m);
        });
      });

      const nonCollidingRoundPool = exercisesRound.filter(ex => {
        const exPri = Object.entries(ex.muscles || {})
          .filter(([, lvl]) => lvl === 'Pri')
          .map(([m]) => m);
        return !exPri.some(m => roundUsedPriMuscles.has(m));
      });

      const primaryExercise = getRandomEntry(
        nonCollidingRoundPool.length > 0 ? nonCollidingRoundPool : exercisesRound,
        rng
      );
      usedExerciseIds.add(primaryExercise.id);

      // Remove from masterExercises and exercisesRound
      masterExercises = masterExercises.filter(ex => ex.id !== primaryExercise.id);
      exercisesRound = exercisesRound.filter(ex => ex.id !== primaryExercise.id);

      // Update body category percentages for this round (Apps Script lines 134-146)
      BODY_AREAS.forEach(area => {
        const isPri = primaryExercise.bodyCategories[area] === 'Pri' ? 1 : 0;
        bodyCategoryPercent[area] += isPri / nExercisesPerRound;
      });

      BODY_AREAS.forEach(area => {
        if (bodyCategoryPercent[area] > maxBodyCategoryPercent) {
          const pruned = exercisesRound.filter(ex => ex.bodyCategories[area] !== 'Pri');
          // Only apply pruning if at least 1 exercise remains or master pool still has other areas
          if (pruned.length > 0) {
            exercisesRound = pruned;
          }
        }
      });

      const slotOptions = [primaryExercise];

      // Step 5: Populate additional options (Option 2 / Option 3) if optionsPerSlot > 1
      if (numOptions > 1) {
        const targetArea = getPrimaryBodyArea(primaryExercise);
        for (let optIdx = 1; optIdx < numOptions; optIdx++) {
          // Prefer unused filtered exercises with the same primary body area that don't collide with other slots' primary muscles
          let altCandidates = basePool.filter(
            ex =>
              !usedExerciseIds.has(ex.id) &&
              !slotOptions.some(o => o.id === ex.id) &&
              (targetArea === 'All' || ex.bodyCategories[targetArea] === 'Pri') &&
              !Object.entries(ex.muscles || {}).some(
                ([m, lvl]) => lvl === 'Pri' && roundUsedPriMuscles.has(m)
              )
          );

          if (altCandidates.length === 0) {
            altCandidates = basePool.filter(
              ex =>
                !usedExerciseIds.has(ex.id) &&
                !slotOptions.some(o => o.id === ex.id) &&
                (targetArea === 'All' || ex.bodyCategories[targetArea] === 'Pri')
            );
          }
          if (altCandidates.length === 0) {
            altCandidates = basePool.filter(
              ex => !usedExerciseIds.has(ex.id) && !slotOptions.some(o => o.id === ex.id)
            );
          }
          if (altCandidates.length === 0) {
            altCandidates = basePool.filter(ex => !slotOptions.some(o => o.id === ex.id));
          }

          const altEx = getRandomEntry(altCandidates, rng);
          if (altEx) {
            slotOptions.push(altEx);
            usedExerciseIds.add(altEx.id);
          }
        }
      }

      roundSlots.push({
        roundIndex: rnd,
        slotIndex: exIdx,
        options: slotOptions,
        selectedOptionIndex: 0,
        completed: false,
        manuallyModified: false
      });
    }

    rounds.push({
      roundNumber: rnd + 1,
      slots: roundSlots
    });
  }

  const generated = {
    id: `wk-${Date.now()}-${Math.floor(rng() * 10000)}`,
    createdAt: new Date().toISOString(),
    inputs: {
      workoutCategory: rawWorkoutCategory,
      effectiveWorkoutCategory: resolvedWorkoutCategory,
      bodyCategory,
      equipment,
      workoutType,
      optionsPerSlot: numOptions
    },
    workout: selectedWorkout,
    workoutName: `WORKOUT: ${selectedWorkout.name}`,
    workoutInfo: {
      rounds: selectedWorkout.rounds,
      exercisesPerRound: selectedWorkout.exercisesPerRound,
      setsPerRound: selectedWorkout.setsPerRound ?? ''
    },
    workoutComments: selectedWorkout.comments || '',
    rounds
  };

  generated.summaryText = formatWorkoutSummary(generated);
  generated.exercisesText = formatExercisesText(generated);
  return generated;
}

/**
 * Get the currently active exercise for a given slot.
 */
export function getActiveSlotExercise(slot) {
  if (!slot || !slot.options || slot.options.length === 0) return null;
  const idx = Math.min(slot.options.length - 1, Math.max(0, slot.selectedOptionIndex || 0));
  return slot.options[idx];
}

/**
 * Format the plain-text exercises block (matching cell B13 in Google Sheet).
 */
export function formatExercisesText(workoutState, showAllOptionsInText = false) {
  if (!workoutState || !workoutState.rounds) return '';
  let txt = '';
  for (const round of workoutState.rounds) {
    txt += `\nROUND ${round.roundNumber}\n`;
    for (const slot of round.slots) {
      if (showAllOptionsInText && slot.options.length > 1) {
        const names = slot.options.map((o, idx) =>
          idx === slot.selectedOptionIndex ? o.name : `${o.name}`
        );
        txt += `  - ${names.join(' OR ')}\n`;
      } else {
        const active = getActiveSlotExercise(slot);
        if (active) {
          txt += `  - ${active.name}\n`;
        }
      }
    }
  }
  return txt.trim();
}

/**
 * Format the complete Workout Summary text block (matching cell B9 in Google Sheet).
 */
export function formatWorkoutSummary(workoutState, showAllOptionsInText = false) {
  if (!workoutState) return '';
  const exTxt = formatExercisesText(workoutState, showAllOptionsInText);
  return `${workoutState.workoutName}\n\n${exTxt}`;
}

/**
 * Format the Workout Info text block (matching cell B14 in Google Sheet).
 */
export function formatWorkoutInfoText(workoutState) {
  if (!workoutState || !workoutState.workoutInfo) return '';
  const { rounds, exercisesPerRound, setsPerRound } = workoutState.workoutInfo;
  return (
    `# Rounds            : ${rounds}\n` +
    `# Exercise Per Round: ${exercisesPerRound}\n` +
    `# Sets Per Round    : ${setsPerRound ?? ''}`
  );
}

/**
 * Swap an exercise in a specific round & slot (either replacing the active option or setting a new exercise).
 */
export function swapExerciseInSlot(workoutState, roundIndex, slotIndex, newExercise, optionIndex = null, isManual = true) {
  const nextState = structuredClone(workoutState);
  const round = nextState.rounds[roundIndex];
  if (!round) return nextState;
  const slot = round.slots[slotIndex];
  if (!slot) return nextState;

  const targetOptIdx = optionIndex !== null ? optionIndex : (slot.selectedOptionIndex || 0);
  slot.options[targetOptIdx] = newExercise;
  slot.selectedOptionIndex = targetOptIdx;
  slot.manuallyModified = isManual;

  nextState.exercisesText = formatExercisesText(nextState);
  nextState.summaryText = formatWorkoutSummary(nextState);
  return nextState;
}

/**
 * Compute valid replacement exercises for a specific round & slot that:
 * 1) Match active filters and user exclusions
 * 2) Are not already used in the workout
 * 3) Respect the round's body-category balance
 * 4) Do NOT trigger any muscle overload warning in that round!
 */
export function getValidReplacementCandidates({
  workoutState,
  roundIndex,
  slotIndex,
  sheetData,
  excludedExerciseIds = [],
  analyzeMuscleLoadFn
}) {
  const round = workoutState.rounds[roundIndex];
  const currentSlot = round?.slots[slotIndex];
  const currentEx = getActiveSlotExercise(currentSlot);
  const targetBodyArea = currentEx ? getPrimaryBodyArea(currentEx) : 'All';

  const usedIds = new Set(
    workoutState.rounds.flatMap(r => r.slots.flatMap(s => s.options.map(o => o.id)))
  );

  const eligible = filterEligibleExercises(sheetData.exercises, {
    workoutCategory: workoutState.inputs.effectiveWorkoutCategory,
    bodyCategory: workoutState.inputs.bodyCategory,
    equipment: workoutState.inputs.equipment,
    excludedExerciseIds
  }).filter(ex => !usedIds.has(ex.id) && ex.id !== currentEx?.id);

  // Check which candidates produce 0 muscle overload warnings in this round
  const warningFree = eligible.filter(candidate => {
    if (!analyzeMuscleLoadFn) return true;
    const simulated = swapExerciseInSlot(
      workoutState,
      roundIndex,
      slotIndex,
      candidate,
      null,
      true
    );
    const analysis = analyzeMuscleLoadFn(simulated, sheetData, excludedExerciseIds);
    const roundWarnings = analysis.warnings.filter(w => w.roundIndex === roundIndex);
    return roundWarnings.length === 0;
  });

  // Tier 1: Warning-free AND preserves the slot's primary body area (Upper Body / Core / Legs)
  const sameAreaWarningFree = warningFree.filter(
    ex => targetBodyArea === 'All' || ex.bodyCategories[targetAreaAlias(targetBodyArea)] === 'Pri'
  );

  if (sameAreaWarningFree.length > 0) return sameAreaWarningFree;
  if (warningFree.length > 0) return warningFree;
  return eligible;
}

function targetAreaAlias(area) {
  return area;
}

