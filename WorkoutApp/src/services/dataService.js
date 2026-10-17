/**
 * DataService Adapter & Per-User Profile Manager
 * Decouples raw sheet data from pre-generated AI enrichments & diagrams (Option A),
 * while providing a drop-in sync adapter for Google Sheets / Apps Script (Options B/C).
 */

const STORAGE_KEY_PROFILES = 'joshal_workout_profiles_v1';
const STORAGE_KEY_ACTIVE_PROFILE_ID = 'joshal_workout_active_profile_v1';
const STORAGE_KEY_REMOTE_CACHE = 'joshal_workout_remote_sheet_cache_v1';

export const DEFAULT_INPUTS = {
  workoutCategory: 'HIIT',
  bodyCategory: 'All',
  equipment: 'Any',
  workoutType: 'Timed Trios (40/20)'
};

export function createDefaultProfiles() {
  return [
    {
      id: 'user-josh',
      name: 'Josh',
      excludedExerciseIds: [],
      optionsPerSlot: 1,
      inputs: { ...DEFAULT_INPUTS },
      activeWorkout: null
    },
    {
      id: 'user-guest',
      name: 'Guest',
      excludedExerciseIds: [],
      optionsPerSlot: 1,
      inputs: { ...DEFAULT_INPUTS },
      activeWorkout: null
    }
  ];
}

export class DataService {
  constructor() {
    this.sheetData = null;
    this.enrichments = null;
    this.profiles = createDefaultProfiles();
    this.activeProfileId = 'user-josh';
  }

  /**
   * Load static JSON files (Option A) and merge enrichments with sheet rows.
   */
  async init(sheetUrl = './data/sheet-data.json', enrichmentsUrl = './data/enrichments.json') {
    const [sheetRes, enrichRes] = await Promise.all([
      fetch(sheetUrl),
      fetch(enrichmentsUrl)
    ]);

    if (!sheetRes.ok) throw new Error(`Failed to load sheet data: ${sheetRes.status}`);
    if (!enrichRes.ok) throw new Error(`Failed to load enrichments: ${enrichRes.status}`);

    const rawSheet = await sheetRes.json();
    const rawEnrich = await enrichRes.json();

    this.setLoadedData(rawSheet, rawEnrich);
    this.loadProfilesFromStorage();
    return this;
  }

  /**
   * Initialize directly from in-memory objects (used in Node unit tests).
   */
  initFromObjects(rawSheet, rawEnrich) {
    this.setLoadedData(rawSheet, rawEnrich);
    return this;
  }

  setLoadedData(rawSheet, rawEnrich) {
    this.enrichments = rawEnrich;

    // Merge enrichments into exercises and workout types by ID
    const exercises = rawSheet.exercises.map(ex => ({
      ...ex,
      enrichment: rawEnrich.exercises?.[ex.id] || null
    }));

    const workouts = rawSheet.workouts.map(wk => ({
      ...wk,
      enrichment: rawEnrich.workoutTypes?.[wk.id] || null
    }));

    this.sheetData = {
      ...rawSheet,
      exercises,
      workouts
    };
  }

  /**
   * Optional Future Migration Hook (Option B / C):
   * Fetch live exercises/workouts from a Google Apps Script Web App JSON endpoint
   * and merge automatically with our pre-generated enrichments and SVG diagrams.
   */
  async syncFromAppsScriptEndpoint(endpointUrl) {
    const response = await fetch(endpointUrl);
    if (!response.ok) {
      throw new Error(`Apps Script sync failed: ${response.status}`);
    }
    const remoteSheetData = await response.json();
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(STORAGE_KEY_REMOTE_CACHE, JSON.stringify(remoteSheetData));
    }
    this.setLoadedData(remoteSheetData, this.enrichments);
    return this.sheetData;
  }

  // ==========================================================================
  // Per-User Profile Management (Exclusion List, 1/2/3 Options, Active Workout)
  // ==========================================================================
  loadProfilesFromStorage() {
    if (typeof localStorage === 'undefined') return;
    try {
      const savedProfiles = localStorage.getItem(STORAGE_KEY_PROFILES);
      const savedActiveId = localStorage.getItem(STORAGE_KEY_ACTIVE_PROFILE_ID);
      if (savedProfiles) {
        const parsed = JSON.parse(savedProfiles);
        if (Array.isArray(parsed) && parsed.length > 0) {
          this.profiles = parsed;
        }
      }
      if (savedActiveId && this.profiles.some(p => p.id === savedActiveId)) {
        this.activeProfileId = savedActiveId;
      } else {
        this.activeProfileId = this.profiles[0].id;
      }
    } catch (e) {
      console.warn('Could not load profiles from localStorage:', e);
    }
  }

  saveProfilesToStorage() {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(STORAGE_KEY_PROFILES, JSON.stringify(this.profiles));
      localStorage.setItem(STORAGE_KEY_ACTIVE_PROFILE_ID, this.activeProfileId);
    } catch (e) {
      console.warn('Could not save profiles to localStorage:', e);
    }
  }

  getActiveProfile() {
    return (
      this.profiles.find(p => p.id === this.activeProfileId) ||
      this.profiles[0]
    );
  }

  setActiveProfile(profileId) {
    if (this.profiles.some(p => p.id === profileId)) {
      this.activeProfileId = profileId;
      this.saveProfilesToStorage();
    }
    return this.getActiveProfile();
  }

  addProfile(name) {
    const cleanName = (name || '').trim();
    if (!cleanName) return null;
    const id = `user-${cleanName.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${Date.now().toString().slice(-4)}`;
    const newProfile = {
      id,
      name: cleanName,
      excludedExerciseIds: [],
      optionsPerSlot: 1,
      inputs: { ...DEFAULT_INPUTS },
      activeWorkout: null
    };
    this.profiles.push(newProfile);
    this.activeProfileId = id;
    this.saveProfilesToStorage();
    return newProfile;
  }

  deleteProfile(profileId) {
    if (this.profiles.length <= 1) return false;
    this.profiles = this.profiles.filter(p => p.id !== profileId);
    if (!this.profiles.some(p => p.id === this.activeProfileId)) {
      this.activeProfileId = this.profiles[0].id;
    }
    this.saveProfilesToStorage();
    return true;
  }

  updateActiveProfile(patch) {
    const profile = this.getActiveProfile();
    Object.assign(profile, patch);
    this.saveProfilesToStorage();
    return profile;
  }

  toggleExerciseExclusion(exerciseId) {
    const profile = this.getActiveProfile();
    const set = new Set(profile.excludedExerciseIds || []);
    if (set.has(exerciseId)) {
      set.delete(exerciseId);
    } else {
      set.add(exerciseId);
    }
    profile.excludedExerciseIds = Array.from(set);
    this.saveProfilesToStorage();
    return profile.excludedExerciseIds;
  }

  setOptionsPerSlot(count) {
    const num = Math.min(3, Math.max(1, Number(count) || 1));
    const profile = this.getActiveProfile();
    profile.optionsPerSlot = num;
    this.saveProfilesToStorage();
    return num;
  }
}
