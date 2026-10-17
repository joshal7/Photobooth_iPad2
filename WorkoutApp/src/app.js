import { DataService } from './services/dataService.js';
import {
  generateWorkout,
  filterEligibleExercises,
  getActiveSlotExercise,
  swapExerciseInSlot,
  getValidReplacementCandidates,
  formatExercisesText,
  formatWorkoutSummary,
  formatWorkoutInfoText,
  getRandomEntry
} from './engine/workoutEngine.js';
import {
  analyzeMuscleLoad,
  applyBalancedRecommendation,
  SPECIFIC_MUSCLES
} from './engine/muscleLoadAnalyzer.js';

const dataService = new DataService();

// UI State for active modals
let currentSwapContext = null; // { roundIndex, slotIndex }
let currentSwapShowAll = false;
let currentAnalysis = null;

// DOM Elements
const els = {
  profileBtn: document.getElementById('profileBtn'),
  activeProfileAvatar: document.getElementById('activeProfileAvatar'),
  activeProfileName: document.getElementById('activeProfileName'),
  activeProfileOptionBadge: document.getElementById('activeProfileOptionBadge'),
  settingsBtn: document.getElementById('settingsBtn'),
  excludedCountBadge: document.getElementById('excludedCountBadge'),

  workoutCategorySelect: document.getElementById('workoutCategorySelect'),
  bodyCategorySelect: document.getElementById('bodyCategorySelect'),
  equipmentSelect: document.getElementById('equipmentSelect'),
  workoutTypeSelect: document.getElementById('workoutTypeSelect'),
  generateWorkoutBtn: document.getElementById('generateWorkoutBtn'),

  workoutNameText: document.getElementById('workoutNameText'),
  workoutTitleBtn: document.getElementById('workoutTitleBtn'),
  copySummaryBtn: document.getElementById('copySummaryBtn'),
  workoutMetaPills: document.getElementById('workoutMetaPills'),
  workoutCommentsBox: document.getElementById('workoutCommentsBox'),
  muscleLoadSummaryBar: document.getElementById('muscleLoadSummaryBar'),
  roundsContainer: document.getElementById('roundsContainer'),

  sheetWorkoutNameCell: document.getElementById('sheetWorkoutNameCell'),
  sheetExercisesCell: document.getElementById('sheetExercisesCell'),
  sheetWorkoutInfoCell: document.getElementById('sheetWorkoutInfoCell'),
  sheetWorkoutCommentsCell: document.getElementById('sheetWorkoutCommentsCell'),

  modalBackdrop: document.getElementById('modalBackdrop'),
  exerciseModal: document.getElementById('exerciseModal'),
  workoutTypeModal: document.getElementById('workoutTypeModal'),
  swapModal: document.getElementById('swapModal'),
  balanceModal: document.getElementById('balanceModal'),
  settingsModal: document.getElementById('settingsModal'),
  toast: document.getElementById('toast')
};

async function bootstrap() {
  await dataService.init('./data/sheet-data.json', './data/enrichments.json');
  populateWorkoutTypeSelect();
  syncUIFromActiveProfile();
  bindEvents();

  // Register offline Service Worker if supported
  if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  }
}

function populateWorkoutTypeSelect() {
  const select = els.workoutTypeSelect;
  select.innerHTML = `<option value="Random">Random</option>`;
  for (const wk of dataService.sheetData.workouts) {
    const opt = document.createElement('option');
    opt.value = wk.name;
    opt.textContent = `${wk.name} (${wk.workoutCategory})`;
    select.appendChild(opt);
  }
}

function syncUIFromActiveProfile() {
  const profile = dataService.getActiveProfile();

  // Top nav profile badge
  els.activeProfileAvatar.textContent = (profile.name || 'U')[0].toUpperCase();
  els.activeProfileName.textContent = profile.name;
  els.activeProfileOptionBadge.textContent = `${profile.optionsPerSlot || 1}x`;

  const excludedCount = (profile.excludedExerciseIds || []).length;
  if (excludedCount > 0) {
    els.excludedCountBadge.textContent = `${excludedCount} Excluded`;
    els.excludedCountBadge.hidden = false;
  } else {
    els.excludedCountBadge.hidden = true;
  }

  // Inputs
  const inputs = profile.inputs || {};
  els.workoutCategorySelect.value = inputs.workoutCategory || 'HIIT';
  els.bodyCategorySelect.value = inputs.bodyCategory || 'All';
  els.equipmentSelect.value = inputs.equipment === 'All' ? 'Any' : (inputs.equipment || 'Any');
  els.workoutTypeSelect.value = inputs.workoutType || 'Timed Trios (40/20)';

  // Ensure an active workout exists
  if (!profile.activeWorkout) {
    handleGenerateWorkout(false);
  } else {
    // Re-hydrate exercise objects from sheetData so enrichments are always attached
    rehydrateActiveWorkout(profile.activeWorkout);
    renderActiveWorkout();
  }
}

function rehydrateActiveWorkout(workoutState) {
  if (!workoutState || !workoutState.rounds) return;
  const exMap = new Map(dataService.sheetData.exercises.map(e => [e.id, e]));
  const wkMap = new Map(dataService.sheetData.workouts.map(w => [w.id, w]));
  if (workoutState.workout?.id && wkMap.has(workoutState.workout.id)) {
    workoutState.workout = wkMap.get(workoutState.workout.id);
  }
  workoutState.rounds.forEach(r => {
    r.slots.forEach(s => {
      s.options = s.options.map(o => exMap.get(o.id) || o);
    });
  });
}

function getSelectedInputs() {
  const profile = dataService.getActiveProfile();
  return {
    workoutCategory: els.workoutCategorySelect.value,
    bodyCategory: els.bodyCategorySelect.value,
    equipment: els.equipmentSelect.value,
    workoutType: els.workoutTypeSelect.value,
    excludedExerciseIds: profile.excludedExerciseIds || [],
    optionsPerSlot: profile.optionsPerSlot || 1
  };
}

function handleGenerateWorkout(showFeedback = true) {
  const inputs = getSelectedInputs();
  const workoutState = generateWorkout(dataService.sheetData, inputs);

  // Sync Workout Category select if manual Workout Type updated effective category
  if (inputs.workoutType !== 'Random' && workoutState.inputs.effectiveWorkoutCategory) {
    els.workoutCategorySelect.value = workoutState.inputs.effectiveWorkoutCategory;
    inputs.workoutCategory = workoutState.inputs.effectiveWorkoutCategory;
  }

  dataService.updateActiveProfile({
    inputs: {
      workoutCategory: inputs.workoutCategory,
      bodyCategory: inputs.bodyCategory,
      equipment: inputs.equipment,
      workoutType: inputs.workoutType
    },
    activeWorkout: workoutState
  });

  renderActiveWorkout();
  if (showFeedback) {
    showToast('Workout generated');
  }
}

function renderActiveWorkout() {
  const profile = dataService.getActiveProfile();
  const wkState = profile.activeWorkout;
  if (!wkState) return;

  // Run Muscle Load Analyzer
  currentAnalysis = analyzeMuscleLoad(
    wkState,
    dataService.sheetData,
    profile.excludedExerciseIds || []
  );

  // 1. Header & Clean Meta Summary
  const cleanWorkoutTypeName =
    wkState.workout?.name || wkState.workoutName.replace(/^WORKOUT:\s*/i, '');
  els.workoutNameText.textContent = cleanWorkoutTypeName;

  const setsDisplay =
    wkState.workoutInfo.setsPerRound !== null && wkState.workoutInfo.setsPerRound !== ''
      ? `${wkState.workoutInfo.setsPerRound} Sets`
      : 'AMRAP';

  els.workoutMetaPills.innerHTML = `
    <span class="meta-pill">${wkState.workoutInfo.rounds} Round${wkState.workoutInfo.rounds > 1 ? 's' : ''}</span>
    <span class="meta-sep">·</span>
    <span class="meta-pill">${wkState.workoutInfo.exercisesPerRound} Exercises</span>
    <span class="meta-sep">·</span>
    <span class="meta-pill">${setsDisplay}</span>
    <span class="meta-sep">·</span>
    <span class="meta-pill">${wkState.inputs.effectiveWorkoutCategory}</span>
  `;

  if (wkState.workoutComments) {
    els.workoutCommentsBox.textContent = wkState.workoutComments;
    els.workoutCommentsBox.hidden = false;
  } else {
    els.workoutCommentsBox.hidden = true;
  }

  // 2. Render Rounds & Minimalist Exercise Slots
  els.roundsContainer.innerHTML = '';

  wkState.rounds.forEach((round, roundIndex) => {
    const roundCard = document.createElement('div');
    roundCard.className = 'round-card';

    const roundWarnings = currentAnalysis.warnings.filter(w => w.roundIndex === roundIndex);

    let warningsHtml = '';
    if (roundWarnings.length > 0) {
      warningsHtml = roundWarnings
        .map(
          w => `
        <div class="overload-banner" data-warning-id="${w.id}">
          <div class="overload-banner-text">
            <strong>${w.muscle} Overload:</strong> ${w.message}
          </div>
          <div class="overload-banner-actions">
            <button class="balance-now-btn" data-action="auto-balance" data-warning-id="${w.id}" type="button">
              Swap to ${w.recommendations[0].exercise.name}
            </button>
            <button class="balance-options-btn" data-action="open-balance-modal" data-warning-id="${w.id}" type="button">
              More (${w.recommendations.length})
            </button>
          </div>
        </div>`
        )
        .join('');
    }

    const slotsHtml = round.slots
      .map((slot, slotIndex) => {
        const activeEx = getActiveSlotExercise(slot);
        if (!activeEx) return '';

        // Multi-option tabs if slot has 2 or 3 options
        let multiTabsHtml = '';
        if (slot.options.length > 1) {
          multiTabsHtml = `
            <div class="multi-option-tabs" role="tablist" aria-label="Exercise slot options">
              ${slot.options
                .map(
                  (optEx, optIdx) => `
                <button
                  type="button"
                  class="multi-opt-pill ${optIdx === (slot.selectedOptionIndex || 0) ? 'active' : ''}"
                  data-action="select-slot-option"
                  data-round-index="${roundIndex}"
                  data-slot-index="${slotIndex}"
                  data-option-index="${optIdx}"
                >
                  ${optIdx + 1}. ${optEx.name}
                </button>`
                )
                .join('')}
            </div>
          `;
        }

        return `
          <div class="exercise-slot ${slot.completed ? 'completed' : ''}" data-round-index="${roundIndex}" data-slot-index="${slotIndex}">
            ${multiTabsHtml}
            <div class="slot-main-row">
              <div class="slot-left">
                <button
                  type="button"
                  class="check-circle-btn"
                  data-action="toggle-complete"
                  data-round-index="${roundIndex}"
                  data-slot-index="${slotIndex}"
                  aria-label="Mark ${activeEx.name} completed"
                >✓</button>

                <button
                  type="button"
                  class="exercise-name-btn"
                  data-action="open-exercise-modal"
                  data-exercise-id="${activeEx.id}"
                  data-round-index="${roundIndex}"
                  data-slot-index="${slotIndex}"
                >
                  ${activeEx.name}
                </button>
              </div>

              <div class="slot-actions">
                <button
                  type="button"
                  class="swap-trigger-btn"
                  data-action="open-swap-modal"
                  data-round-index="${roundIndex}"
                  data-slot-index="${slotIndex}"
                  title="Swap exercise"
                  aria-label="Swap ${activeEx.name}"
                >
                  ⇄
                </button>
              </div>
            </div>
          </div>
        `;
      })
      .join('');

    roundCard.innerHTML = `
      <div class="round-header">
        <span class="round-title">Round ${round.roundNumber}</span>
        <span class="round-sets-badge">${setsDisplay}</span>
      </div>
      ${warningsHtml}
      <div class="slots-list">
        ${slotsHtml}
      </div>
    `;

    els.roundsContainer.appendChild(roundCard);
  });

  // 3. Update Spreadsheet Parity View
  wkState.exercisesText = formatExercisesText(wkState);
  wkState.summaryText = formatWorkoutSummary(wkState);

  els.sheetWorkoutNameCell.textContent = wkState.workoutName;
  els.sheetExercisesCell.textContent = wkState.exercisesText;
  els.sheetWorkoutInfoCell.textContent = formatWorkoutInfoText(wkState);
  els.sheetWorkoutCommentsCell.textContent = wkState.workoutComments || '—';
}

// ============================================================================
// Modal Controllers
// ============================================================================
function openModal(modalEl) {
  els.modalBackdrop.hidden = false;
  modalEl.hidden = false;
}

function closeAllModals() {
  els.modalBackdrop.hidden = true;
  els.exerciseModal.hidden = true;
  els.workoutTypeModal.hidden = true;
  els.swapModal.hidden = true;
  els.balanceModal.hidden = true;
  els.settingsModal.hidden = true;
}

function openExerciseModal(exerciseId, roundIndex = null, slotIndex = null) {
  const ex = dataService.sheetData.exercises.find(e => e.id === exerciseId);
  if (!ex) return;

  currentSwapContext =
    roundIndex !== null && slotIndex !== null ? { roundIndex, slotIndex } : null;

  const enrich = ex.enrichment || {};
  document.getElementById('exerciseModalCategory').textContent =
    `${Object.entries(ex.bodyCategories).filter(([, v]) => v === 'Pri').map(([k]) => k).join(' · ')} · ${ex.workoutCategory}`;
  document.getElementById('exerciseModalTitle').textContent = ex.name;

  const diagramImg = document.getElementById('exerciseModalDiagram');
  diagramImg.src = enrich.diagram || `./diagrams/${ex.id}.svg`;
  diagramImg.alt = `${ex.name} multi-frame movement diagram`;

  const priMuscles = SPECIFIC_MUSCLES.filter(m => ex.muscles?.[m] === 'Pri');
  const secMuscles = SPECIFIC_MUSCLES.filter(m => ex.muscles?.[m] === 'Sec');

  document.getElementById('exerciseModalBadges').innerHTML = [
    ...priMuscles.map(m => `<span class="mini-tag pri-muscle">Primary: ${m}</span>`),
    ...secMuscles.map(m => `<span class="mini-tag sec-muscle">Secondary: ${m}</span>`),
    `<span class="mini-tag">Equipment: ${ex.equipment}</span>`
  ].join('');

  document.getElementById('exerciseModalSummary').textContent = enrich.summary || '';

  const stepsEl = document.getElementById('exerciseModalSteps');
  stepsEl.innerHTML = (enrich.steps || []).map(s => `<li>${s}</li>`).join('');

  document.getElementById('exerciseModalTip').textContent = enrich.formTip || '';

  const auditBox = document.getElementById('exerciseModalAuditBox');
  if (ex.auditUpdated && ex.auditNote) {
    document.getElementById('exerciseModalAuditNote').textContent = ex.auditNote;
    auditBox.hidden = false;
  } else {
    auditBox.hidden = true;
  }

  document.getElementById('exerciseModalFooterActions').hidden = !currentSwapContext;
  openModal(els.exerciseModal);
}

function openWorkoutTypeModal(workoutNameOrId) {
  const wkState = dataService.getActiveProfile().activeWorkout;
  let wk = dataService.sheetData.workouts.find(
    w => w.name === workoutNameOrId || w.id === workoutNameOrId
  );
  if (!wk && wkState?.workout) {
    wk = wkState.workout;
  }
  if (!wk) {
    wk = dataService.sheetData.workouts[0];
  }

  const enrich = wk.enrichment || {};
  document.getElementById('workoutTypeModalCategory').textContent =
    `${wk.workoutCategory.toUpperCase()} FORMAT`;
  document.getElementById('workoutTypeModalTitle').textContent = wk.name;

  const setsLabel = wk.setsPerRound !== null && wk.setsPerRound !== '' ? `${wk.setsPerRound} Sets` : 'AMRAP (8 min)';
  document.getElementById('workoutTypeModalPills').innerHTML = `
    <span class="meta-pill">${wk.rounds} Round${wk.rounds > 1 ? 's' : ''}</span>
    <span class="meta-sep">·</span>
    <span class="meta-pill">${wk.exercisesPerRound} Exercises / Round</span>
    <span class="meta-sep">·</span>
    <span class="meta-pill">${setsLabel}</span>
  `;

  document.getElementById('workoutTypeModalSummary').textContent = enrich.summary || '';

  const commentsBox = document.getElementById('workoutTypeSheetCommentsBox');
  if (wk.comments) {
    commentsBox.textContent = wk.comments;
    commentsBox.hidden = false;
  } else {
    commentsBox.hidden = true;
  }

  document.getElementById('workoutTypeModalSteps').innerHTML = (enrich.howItWorks || [])
    .map(step => `<li>${step}</li>`)
    .join('');

  document.getElementById('workoutTypeModalTimer').textContent = enrich.timerStructure || '';
  document.getElementById('workoutTypeModalPacing').textContent = enrich.pacingTip || '';

  openModal(els.workoutTypeModal);
}

function openSwapModal(roundIndex, slotIndex) {
  currentSwapContext = { roundIndex, slotIndex };
  currentSwapShowAll = false;
  const wkState = dataService.getActiveProfile().activeWorkout;
  const slot = wkState?.rounds?.[roundIndex]?.slots?.[slotIndex];
  const currentEx = getActiveSlotExercise(slot);

  document.getElementById('swapModalSlotLabel').textContent =
    `ROUND ${roundIndex + 1} · EXERCISE ${slotIndex + 1}`;
  document.getElementById('swapModalTitle').textContent =
    currentEx ? currentEx.name : 'Swap Exercise';

  document.getElementById('swapSearchInput').value = '';
  document.getElementById('swapFilterMatchingBtn').classList.add('active');
  document.getElementById('swapFilterAllBtn').classList.remove('active');

  renderSwapExerciseList();
  openModal(els.swapModal);
}

function renderSwapExerciseList() {
  if (!currentSwapContext) return;
  const profile = dataService.getActiveProfile();
  const wkState = profile.activeWorkout;
  const query = (document.getElementById('swapSearchInput').value || '').trim().toLowerCase();

  const validBalancedCandidates = getValidReplacementCandidates({
    workoutState: wkState,
    roundIndex: currentSwapContext.roundIndex,
    slotIndex: currentSwapContext.slotIndex,
    sheetData: dataService.sheetData,
    excludedExerciseIds: profile.excludedExerciseIds || [],
    analyzeMuscleLoadFn: analyzeMuscleLoad
  });
  const balancedIds = new Set(validBalancedCandidates.map(e => e.id));

  let pool = [];
  if (currentSwapShowAll) {
    pool = [...dataService.sheetData.exercises];
  } else {
    pool = filterEligibleExercises(dataService.sheetData.exercises, {
      workoutCategory: wkState.inputs.effectiveWorkoutCategory,
      bodyCategory: wkState.inputs.bodyCategory,
      equipment: wkState.inputs.equipment,
      excludedExerciseIds: profile.excludedExerciseIds || []
    });
  }

  // Sort balanced conflict-free exercises to the top
  pool.sort((a, b) => {
    const aBal = balancedIds.has(a.id) ? 1 : 0;
    const bBal = balancedIds.has(b.id) ? 1 : 0;
    return bBal - aBal;
  });

  if (query) {
    pool = pool.filter(ex => {
      const musclesStr = Object.entries(ex.muscles)
        .filter(([, v]) => v)
        .map(([k]) => k.toLowerCase())
        .join(' ');
      return (
        ex.name.toLowerCase().includes(query) ||
        ex.equipment.toLowerCase().includes(query) ||
        musclesStr.includes(query)
      );
    });
  }

  const listEl = document.getElementById('swapExerciseList');
  if (pool.length === 0) {
    listEl.innerHTML = `<p class="settings-help">No matching exercises found. Tap "All Exercises" to browse all 68 movements.</p>`;
    return;
  }

  listEl.innerHTML = pool
    .map(ex => {
      const pri = SPECIFIC_MUSCLES.filter(m => ex.muscles?.[m] === 'Pri').join(', ');
      const isBalanced = balancedIds.has(ex.id);
      return `
      <button type="button" class="swap-option-item" data-action="confirm-swap" data-exercise-id="${ex.id}">
        <div>
          <div class="swap-option-title">${ex.name}</div>
          <div class="swap-option-meta">${pri} · ${ex.equipment}</div>
        </div>
        <span class="swap-badge ${isBalanced ? 'balanced' : ''}">${isBalanced ? 'Balanced' : 'Select'}</span>
      </button>`;
    })
    .join('');
}

function openBalanceModal(warningId) {
  if (!currentAnalysis) return;
  const warning = currentAnalysis.warnings.find(w => w.id === warningId);
  if (!warning) return;

  document.getElementById('balanceModalTitle').textContent =
    `Balance Round ${warning.roundNumber} (${warning.muscle})`;
  document.getElementById('balanceModalDescription').textContent =
    `${warning.message} Select an alternative to replace "${warning.targetExercise.name}":`;

  const listEl = document.getElementById('balanceRecommendationsList');
  listEl.innerHTML = warning.recommendations
    .map(
      rec => `
      <button
        type="button"
        class="swap-option-item"
        data-action="apply-balance-choice"
        data-warning-id="${warning.id}"
        data-exercise-id="${rec.exercise.id}"
      >
        <div>
          <div class="swap-option-title">${rec.exercise.name}</div>
          <div class="swap-option-meta">${rec.reason} · ${rec.exercise.equipment}</div>
        </div>
        <span class="swap-badge balanced">Swap</span>
      </button>`
    )
    .join('');

  openModal(els.balanceModal);
}

function openSettingsModal() {
  renderSettingsModalContent();
  openModal(els.settingsModal);
}

function renderSettingsModalContent() {
  const profile = dataService.getActiveProfile();

  // 1. User profiles chips
  const profilesContainer = document.getElementById('profileListContainer');
  profilesContainer.innerHTML = dataService.profiles
    .map(
      p => `
      <button
        type="button"
        class="profile-chip ${p.id === profile.id ? 'active' : ''}"
        data-action="switch-profile"
        data-profile-id="${p.id}"
      >
        ${p.name} (${p.optionsPerSlot || 1}x)
      </button>`
    )
    .join('');

  // 2. Options per slot segmented buttons
  document.querySelectorAll('[data-options-count]').forEach(btn => {
    const count = Number(btn.getAttribute('data-options-count'));
    btn.classList.toggle('active', count === (profile.optionsPerSlot || 1));
  });

  // 3. Exclusion list
  document.getElementById('exclusionUserNameLabel').textContent = profile.name;
  renderExclusionChecklist();
}

function renderExclusionChecklist() {
  const profile = dataService.getActiveProfile();
  const excludedSet = new Set(profile.excludedExerciseIds || []);
  const query = (document.getElementById('exclusionSearchInput').value || '').trim().toLowerCase();

  const exercises = dataService.sheetData.exercises.filter(ex =>
    !query || ex.name.toLowerCase().includes(query)
  );

  const container = document.getElementById('exclusionChecklist');
  container.innerHTML = exercises
    .map(ex => {
      const isExcluded = excludedSet.has(ex.id);
      return `
        <label class="exclusion-row ${isExcluded ? 'is-excluded' : ''}">
          <span>${ex.name} <small style="color:var(--text-muted)">(${ex.equipment})</small></span>
          <input
            type="checkbox"
            data-action="toggle-exclusion"
            data-exercise-id="${ex.id}"
            ${!isExcluded ? 'checked' : ''}
          />
        </label>
      `;
    })
    .join('');
}

// ============================================================================
// Event Listeners
// ============================================================================
function bindEvents() {
  els.generateWorkoutBtn.addEventListener('click', () => handleGenerateWorkout(true));

  // Sync Workout Category if user picks a specific Workout Type in dropdown
  els.workoutTypeSelect.addEventListener('change', () => {
    const val = els.workoutTypeSelect.value;
    if (val !== 'Random') {
      const wk = dataService.sheetData.workouts.find(w => w.name === val);
      if (wk) {
        els.workoutCategorySelect.value = wk.workoutCategory;
      }
    }
  });

  // Click the Workout Type directly to view its description
  els.workoutTitleBtn.addEventListener('click', () => {
    const wk = dataService.getActiveProfile().activeWorkout?.workout;
    if (wk) openWorkoutTypeModal(wk.id);
  });

  els.copySummaryBtn.addEventListener('click', async () => {
    const wkState = dataService.getActiveProfile().activeWorkout;
    if (!wkState) return;
    try {
      await navigator.clipboard.writeText(wkState.summaryText);
      showToast('Copied workout summary');
    } catch {
      showToast('Summary ready in Spreadsheet View');
    }
  });

  els.profileBtn.addEventListener('click', openSettingsModal);
  els.settingsBtn.addEventListener('click', openSettingsModal);

  els.modalBackdrop.addEventListener('click', closeAllModals);
  document.querySelectorAll('[data-close-modal]').forEach(btn => {
    btn.addEventListener('click', closeAllModals);
  });

  // Transition from Exercise Guide Modal -> Swap Modal
  document.getElementById('openSwapFromExerciseModalBtn').addEventListener('click', () => {
    if (!currentSwapContext) return;
    const { roundIndex, slotIndex } = currentSwapContext;
    closeAllModals();
    openSwapModal(roundIndex, slotIndex);
  });

  // Swap Modal Controls
  document.getElementById('swapSearchInput').addEventListener('input', renderSwapExerciseList);
  document.getElementById('swapFilterMatchingBtn').addEventListener('click', () => {
    currentSwapShowAll = false;
    document.getElementById('swapFilterMatchingBtn').classList.add('active');
    document.getElementById('swapFilterAllBtn').classList.remove('active');
    renderSwapExerciseList();
  });
  document.getElementById('swapFilterAllBtn').addEventListener('click', () => {
    currentSwapShowAll = true;
    document.getElementById('swapFilterAllBtn').classList.add('active');
    document.getElementById('swapFilterMatchingBtn').classList.remove('active');
    renderSwapExerciseList();
  });

  document.getElementById('randomSwapBtn').addEventListener('click', () => {
    if (!currentSwapContext) return;
    const profile = dataService.getActiveProfile();
    const wkState = profile.activeWorkout;

    const validCandidates = getValidReplacementCandidates({
      workoutState: wkState,
      roundIndex: currentSwapContext.roundIndex,
      slotIndex: currentSwapContext.slotIndex,
      sheetData: dataService.sheetData,
      excludedExerciseIds: profile.excludedExerciseIds || [],
      analyzeMuscleLoadFn: analyzeMuscleLoad
    });

    const chosen = getRandomEntry(
      validCandidates.length > 0 ? validCandidates : dataService.sheetData.exercises
    );
    if (chosen) {
      performSlotSwap(currentSwapContext.roundIndex, currentSwapContext.slotIndex, chosen, false);
      closeAllModals();
    }
  });

  // Delegated clicks inside roundsContainer
  els.roundsContainer.addEventListener('click', e => {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const action = btn.getAttribute('data-action');
    const roundIndex = Number(btn.getAttribute('data-round-index'));
    const slotIndex = Number(btn.getAttribute('data-slot-index'));

    const profile = dataService.getActiveProfile();
    const wkState = profile.activeWorkout;

    if (action === 'toggle-complete') {
      const slot = wkState.rounds[roundIndex]?.slots[slotIndex];
      if (slot) {
        slot.completed = !slot.completed;
        dataService.saveProfilesToStorage();
        renderActiveWorkout();
      }
    } else if (action === 'select-slot-option') {
      const optionIndex = Number(btn.getAttribute('data-option-index'));
      const slot = wkState.rounds[roundIndex]?.slots[slotIndex];
      if (slot) {
        slot.selectedOptionIndex = optionIndex;
        slot.manuallyModified = true;
        dataService.saveProfilesToStorage();
        renderActiveWorkout();
      }
    } else if (action === 'open-exercise-modal') {
      const exId = btn.getAttribute('data-exercise-id');
      openExerciseModal(exId, roundIndex, slotIndex);
    } else if (action === 'open-swap-modal') {
      openSwapModal(roundIndex, slotIndex);
    } else if (action === 'auto-balance') {
      const warningId = btn.getAttribute('data-warning-id');
      const warning = currentAnalysis?.warnings.find(w => w.id === warningId);
      if (warning) {
        profile.activeWorkout = applyBalancedRecommendation(wkState, warning);
        dataService.saveProfilesToStorage();
        renderActiveWorkout();
        showToast(`Balanced Round ${warning.roundNumber}`);
      }
    } else if (action === 'open-balance-modal') {
      const warningId = btn.getAttribute('data-warning-id');
      openBalanceModal(warningId);
    }
  });

  // Delegated clicks in Swap Modal list
  document.getElementById('swapExerciseList').addEventListener('click', e => {
    const btn = e.target.closest('[data-action="confirm-swap"]');
    if (!btn || !currentSwapContext) return;
    const exId = btn.getAttribute('data-exercise-id');
    const ex = dataService.sheetData.exercises.find(item => item.id === exId);
    if (ex) {
      performSlotSwap(currentSwapContext.roundIndex, currentSwapContext.slotIndex, ex);
      closeAllModals();
    }
  });

  // Delegated clicks in Balance Recommendations Modal
  document.getElementById('balanceRecommendationsList').addEventListener('click', e => {
    const btn = e.target.closest('[data-action="apply-balance-choice"]');
    if (!btn) return;
    const warningId = btn.getAttribute('data-warning-id');
    const exId = btn.getAttribute('data-exercise-id');
    const warning = currentAnalysis?.warnings.find(w => w.id === warningId);
    const chosenEx = dataService.sheetData.exercises.find(item => item.id === exId);
    if (warning && chosenEx) {
      const profile = dataService.getActiveProfile();
      profile.activeWorkout = applyBalancedRecommendation(profile.activeWorkout, warning, chosenEx);
      dataService.saveProfilesToStorage();
      closeAllModals();
      renderActiveWorkout();
      showToast(`Swapped to ${chosenEx.name}`);
    }
  });

  // Settings Modal interactions
  document.getElementById('profileListContainer').addEventListener('click', e => {
    const btn = e.target.closest('[data-action="switch-profile"]');
    if (!btn) return;
    const profileId = btn.getAttribute('data-profile-id');
    dataService.setActiveProfile(profileId);
    syncUIFromActiveProfile();
    renderSettingsModalContent();
    showToast(`Profile: ${dataService.getActiveProfile().name}`);
  });

  document.getElementById('addProfileBtn').addEventListener('click', () => {
    const input = document.getElementById('newProfileNameInput');
    const created = dataService.addProfile(input.value);
    if (created) {
      input.value = '';
      syncUIFromActiveProfile();
      renderSettingsModalContent();
      showToast(`Created profile "${created.name}"`);
    }
  });

  document.querySelectorAll('[data-options-count]').forEach(btn => {
    btn.addEventListener('click', () => {
      const count = Number(btn.getAttribute('data-options-count'));
      dataService.setOptionsPerSlot(count);
      els.activeProfileOptionBadge.textContent = `${count}x`;
      renderSettingsModalContent();
      handleGenerateWorkout(false);
      showToast(`${count} option${count > 1 ? 's' : ''} per slot`);
    });
  });

  document.getElementById('exclusionSearchInput').addEventListener('input', renderExclusionChecklist);

  document.getElementById('exclusionChecklist').addEventListener('change', e => {
    const input = e.target.closest('[data-action="toggle-exclusion"]');
    if (!input) return;
    const exId = input.getAttribute('data-exercise-id');
    dataService.toggleExerciseExclusion(exId);
    syncUIFromActiveProfile();
    renderExclusionChecklist();
  });

  document.getElementById('clearExclusionsBtn').addEventListener('click', () => {
    dataService.updateActiveProfile({ excludedExerciseIds: [] });
    syncUIFromActiveProfile();
    renderExclusionChecklist();
    showToast('All 68 exercises included');
  });
}

function performSlotSwap(roundIndex, slotIndex, newExercise, isManual = true) {
  const profile = dataService.getActiveProfile();
  profile.activeWorkout = swapExerciseInSlot(
    profile.activeWorkout,
    roundIndex,
    slotIndex,
    newExercise,
    null,
    isManual
  );
  dataService.saveProfilesToStorage();
  renderActiveWorkout();
  showToast(`Swapped to ${newExercise.name}`);
}

let toastTimer = null;
function showToast(msg) {
  els.toast.textContent = msg;
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    els.toast.hidden = true;
  }, 2200);
}

bootstrap();
