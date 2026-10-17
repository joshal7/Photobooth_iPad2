import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const sheetDataPath = path.join(rootDir, 'data', 'sheet-data.json');
const enrichmentsPath = path.join(rootDir, 'data', 'enrichments.json');
const diagramsDir = path.join(rootDir, 'diagrams');

const sheetData = JSON.parse(fs.readFileSync(sheetDataPath, 'utf8'));

// ============================================================================
// 1. FACT-CHECKED WORKOUT TYPE ENRICHMENTS (All 11 Workout Types)
// ============================================================================
const workoutTypeEnrichments = {
  'strength-duos': {
    summary: '4 rounds of 2-exercise supersets performed for 3 sets per round with controlled strength tempo.',
    howItWorks: [
      'Your workout is divided into 4 rounds, with 2 paired exercises (a "Duo") in each round.',
      'In Round 1, perform Exercise A for 8–12 controlled reps, then transition to Exercise B for 8–12 reps.',
      'Rest 45–60 seconds as needed and repeat the pair for 3 total sets before advancing to Round 2.'
    ],
    timerStructure: 'Self-paced sets (8–12 reps) · 3 sets per round · 4 rounds total',
    pacingTip: 'Choose challenging weights that bring you within 1–2 reps of fatigue by the end of each set. Focus on full range of motion rather than speed.'
  },
  'strength-trios': {
    summary: '3 rounds of 3-exercise giant sets (trios) completed for 3 sets per round.',
    howItWorks: [
      'Your workout has 3 rounds, each containing 3 balanced exercises (mixing muscle groups so one recovers while another works).',
      'Perform Exercise 1, Exercise 2, and Exercise 3 sequentially for 8–12 controlled reps each.',
      'Rest 60 seconds after completing the trio, then repeat for 3 total sets before moving to the next round.'
    ],
    timerStructure: '3 exercises per round · 3 sets per round · 3 rounds total (27 working sets)',
    pacingTip: 'Keep transitions brisk between movements within a trio and save your main breather for the end of each set.'
  },
  'strength-quads': {
    summary: '2 heavy rounds of 4 exercises: 3 sets per round structured as 2 supersets plus a double burnout finisher.',
    howItWorks: [
      'Each of the 2 rounds contains 4 exercises performed across 3 sets.',
      'Pair the 4 exercises into 2 supersets (Exercises 1 & 2, and Exercises 3 & 4) for 3 sets each.',
      'Finish the round by taking 2 of the exercises and burning out twice at the end with lighter weight or bodyweight.'
    ],
    timerStructure: '2 rounds · 4 exercises per round · 3 sets + 2x end-of-round burnout',
    pacingTip: 'Go heavy on the main 3 sets, then drop weight by 25–30% for the two burnout sets at the end of each round.'
  },
  '30-20-10-10-20-30': {
    summary: 'Single-round 8-exercise HIIT pyramid where you complete all 6 timed sets (30s-20s-10s-10s-20s-30s) on one exercise before advancing.',
    howItWorks: [
      'You have 1 round of 8 exercises, with 6 timed interval sets performed on each exercise before moving on.',
      'For Exercise 1, follow the reverse-pyramid clock: 30s work / 30s rest → 20s work / 20s rest → 10s work / 10s rest → 10s work / 10s rest → 20s work / 20s rest → 30s work.',
      'Take a full 60-second recovery rest before starting the next exercise in the list of 8.'
    ],
    timerStructure: '8 exercises · 6 sets per exercise (30/30, 20/20, 10/10, 10/10, 20/20, 30) · 60s rest between exercises',
    pacingTip: 'The final 20s and 30s sets on the way back up the pyramid are tough because rest shrinks during the middle 10s intervals—pace your first 30s set at 85% effort.'
  },
  'timed-duos-40-20': {
    summary: '4 fast-paced HIIT rounds of 2 exercises alternating 40 seconds of work with 20 seconds of rest for 3 sets.',
    howItWorks: [
      'Your workout has 4 rounds, with 2 exercises per round.',
      'Start a 60-second repeating interval timer: work hard on Exercise 1 for 40 seconds, then rest and transition for 20 seconds.',
      'Perform Exercise 2 for 40 seconds, rest 20 seconds, and repeat the duo for 3 total sets (6 minutes per round) before moving to the next round.'
    ],
    timerStructure: '40s work / 20s rest · 2 exercises × 3 sets per round · 4 rounds (24 minutes total)',
    pacingTip: 'With only 2 exercises alternating in a round, local muscle fatigue builds quickly. Maintain crisp form during the final 10 seconds of each 40-second interval.'
  },
  'timed-trios-40-20': {
    summary: '3 HIIT rounds of 3 exercises rotating 40 seconds of work and 20 seconds of rest for 3 sets per round.',
    howItWorks: [
      'Your workout has 3 rounds, with 3 complementary exercises in each round.',
      'Work for 40 seconds on Exercise 1, rest 20 seconds, work 40 seconds on Exercise 2, rest 20 seconds, work 40 seconds on Exercise 3, rest 20 seconds.',
      'Complete 3 continuous laps of the trio (9 minutes per round) before advancing to the next round.'
    ],
    timerStructure: '40s work / 20s rest · 3 exercises × 3 sets per round · 3 rounds (27 minutes total)',
    pacingTip: 'Use the 20-second window to get set up for the next movement so you can start moving the instant the 40-second work bell rings.'
  },
  '8-excercises-40-20': {
    summary: 'Full-circuit HIIT: 1 big list of 8 exercises performed for 40s work / 20s rest, repeated for 3 full circuits.',
    howItWorks: [
      'All 8 generated exercises form a single continuous station circuit.',
      'Perform each exercise for 40 seconds of work followed by 20 seconds of rest/transition down the list from Exercise 1 to Exercise 8 (8 minutes per lap).',
      'Complete 3 full laps of the 8-exercise circuit for a 24-minute total conditioning session.'
    ],
    timerStructure: '40s work / 20s rest · 8 exercises per circuit · 3 circuits total (24 sets)',
    pacingTip: 'Because you only revisit each exercise once every 8 minutes, you can push higher intensity on every 40-second interval.'
  },
  '10-to-1-to-10': {
    summary: 'Rep-ladder conditioning: 5 exercises performed from 10 reps down to 1 rep and back up to 10 reps (20 sets total).',
    howItWorks: [
      'Cycle through all 5 generated exercises continuously on a rep ladder.',
      'Lap 1: Perform 10 reps of each of the 5 exercises (per side for unilateral movements). Lap 2: 9 reps of each, continuing down to 1 rep of each on Lap 10.',
      'Then climb back up the ladder from 1 rep back to 10 reps (20 total laps / 110 total reps per exercise).'
    ],
    timerStructure: '5 exercises · 20 rep-ladder sets (10 → 9 → ... → 1 → 1 → ... → 10)',
    pacingTip: 'Treat the middle sets (5 down to 1 and 1 up to 5) as active recovery with smooth transitions so you have energy for the sets of 8, 9, and 10 at the end.'
  },
  '6-excercise-pyramid': {
    summary: 'Add-on / drop-off timed pyramid across 6 exercises over 11 progressive rounds (30s per exercise + 30s rest).',
    howItWorks: [
      'Set 1: Do 30s of Exercise 1, then rest 30s. Set 2: Do 30s of Ex 1 + 30s of Ex 2 back-to-back, then rest 30s.',
      'Keep adding one exercise each set until Set 6, where you perform all 6 exercises for 30s each (3 minutes continuous work), then rest 30s.',
      'On Sets 7–11, drop Exercise 1, then Exercise 2, etc., until Set 11 finishes with just 30s of Exercise 6.'
    ],
    timerStructure: '6 exercises · 11 pyramid sets (1, 1-2, 1-2-3 ... up to 6, then dropping down to 1)',
    pacingTip: 'You will perform every exercise 6 times over the pyramid. Keep transitions seamless since there is no rest between exercises inside a pyramid rung.'
  },
  '8x8-duos': {
    summary: '4 AMRAP rounds of 2 exercises: alternate 8 reps of each exercise non-stop for 8 minutes per round.',
    howItWorks: [
      'Your workout has 4 rounds, each pairing 2 exercises together.',
      'Set an 8-minute countdown clock for Round 1. Perform 8 reps of Exercise A, immediately switch to 8 reps of Exercise B, and repeat back-and-forth with no scheduled rest.',
      'Log as many quality rounds as possible in 8 minutes, rest 60–90 seconds, and begin the next 8-minute Duo.'
    ],
    timerStructure: '4 rounds · 8-minute AMRAP per round · 8 reps Exercise A ↔ 8 reps Exercise B',
    pacingTip: '8 minutes of continuous work is an aerobic test—pick a sustainable rhythm from minute 1 rather than sprinting out of the gate.'
  },
  '5-constant-5-change-40-20': {
    summary: '3 rounds alternating a round-specific "Constant" exercise (first 3 generated exercises) with 5 shared "Changing" exercises at 40s/20s.',
    howItWorks: [
      'Of your 8 generated exercises, Exercises 1, 2, and 3 are your Round Constants (one per round), and Exercises 4–8 are your 5 shared Changing exercises.',
      'In Round 1 (10 sets at 40s work / 20s rest): alternate Constant #1 (Exercise 1) with each of the 5 Changing exercises (Ex 1 → Ex 4 → Ex 1 → Ex 5 → Ex 1 → Ex 6 → Ex 1 → Ex 7 → Ex 1 → Ex 8).',
      'Repeat the same 10-set alternating structure in Round 2 using Constant #2 (Exercise 2) and in Round 3 using Constant #3 (Exercise 3).'
    ],
    timerStructure: '3 rounds · 10 sets per round (40s/20s) · Constant exercise repeated 5x per round',
    pacingTip: 'You will perform each Constant exercise 5 times inside its round! Pace yourself on the Constant slots and use the Changing slots to shift load to other muscle groups.'
  }
};

// ============================================================================
// 2. EXERCISE ENRICHMENTS & MULTI-FRAME MOTION DEFINITIONS (All 68 Exercises)
// ============================================================================
const exerciseSpecs = {
  'push-ups': {
    summary: 'Classic bodyweight horizontal press targeting the chest, anterior shoulders, triceps, and core.',
    steps: [
      'Start in a rigid high plank with hands slightly wider than shoulder-width, wrists stacked under elbows, and glutes braced.',
      'Lower your chest toward the floor in a straight line while keeping elbows angled roughly 45° from your torso.',
      'Press forcefully through your palms back to full arm extension without letting your hips sag or hike.'
    ],
    formTip: 'Screw your palms outward into the floor to engage your lats and protect your shoulder joints.',
    pose: 'plank-pushup',
    equip: 'bodyweight',
    badge: '2-PHASE MOTION',
    frames: [
      { label: '1. High Plank Setup', phase: 'plank-high' },
      { label: '2. Bottom Press & Drive', phase: 'plank-low', arrow: 'up' }
    ]
  },
  '3-stop-pushups': {
    summary: 'Tempo push-up variation featuring 3 distinct isometric pause stops per repetition to maximize chest and tricep time-under-tension.',
    steps: [
      'From a high plank, lower halfway down (Stop 1) and hold for 1 full second.',
      'Lower to 1 inch above the floor (Stop 2) and hold for 1 full second with chest hovering.',
      'Press halfway back up (Stop 3) and hold for 1 second before locking out at the top.'
    ],
    formTip: 'Keep your core tight during all three pause points so your lower back never arches when fatigue sets in.',
    pose: 'plank-pushup',
    equip: 'bodyweight',
    badge: 'STOP 1 · 2 · 3',
    frames: [
      { label: '1. Stop 1 (Half Down)', phase: 'plank-mid', note: 'Hold 1s' },
      { label: '2. Stop 2 (1" Hover)', phase: 'plank-low', note: 'Hold 1s' },
      { label: '3. Stop 3 & Lockout', phase: 'plank-high', arrow: 'up', note: 'Hold 1s → Top' }
    ]
  },
  'pushups-with-shoulder-tap': {
    summary: 'Anti-rotation push-up combining a full chest press with alternating single-arm shoulder taps at the top of each rep.',
    steps: [
      'Set up in a high plank with feet slightly wider than hip-width for a stable base.',
      'Perform a full push-up and return to the top plank position.',
      'Brace your abs and glutes to keep your hips completely level as you lift one hand to tap the opposite shoulder, then alternate.'
    ],
    formTip: 'Pretend a cup of water is resting on your lower back—resist any side-to-side hip sway during the tap.',
    pose: 'plank-shoulder-tap',
    equip: 'bodyweight',
    badge: 'PRESS + TAP',
    frames: [
      { label: '1. Bottom Push-up', phase: 'plank-low' },
      { label: '2. Press Up & Tap Shoulder', phase: 'plank-tap', arrow: 'tap' }
    ]
  },
  'chest-flys': {
    summary: 'Wide-arc dumbbell chest isolation exercise stretching and contracting the pectoral fibers.',
    steps: [
      'Lie flat on a bench or floor holding dumbbells directly above your chest with palms facing each other and a slight bend in your elbows.',
      'Open your arms wide in a smooth arc until your elbows reach chest level and you feel a deep stretch across your pecs.',
      'Squeeze your chest to bring the dumbbells back together along the same arc, maintaining the fixed slight elbow bend.'
    ],
    formTip: 'Think about hugging a wide tree barrel—do not turn the movement into a bent-arm press.',
    pose: 'supine-press',
    equip: 'dumbbells-arc',
    badge: 'WIDE ARC FLY',
    frames: [
      { label: '1. Wide Pectoral Stretch', phase: 'bench-fly-open' },
      { label: '2. Arc Squeeze Together', phase: 'bench-press-top', arrow: 'arc-in' }
    ]
  },
  'chest-press-6-6-6': {
    summary: '18-rep dumbbell chest press complex: 6 bilateral reps, 6 right-arm reps with left held isometric, and 6 left-arm reps with right held isometric.',
    steps: [
      'Lie on a bench or floor pressing both dumbbells together for 6 full bilateral repetitions, finishing with both weights held at the top.',
      'Keep the left dumbbell locked out overhead while performing 6 single-arm presses with the right arm.',
      'Keep the right dumbbell locked out overhead while performing 6 single-arm presses with the left arm (18 total reps).'
    ],
    formTip: 'Actively press the stationary dumbbell toward the ceiling during the single-arm sets to maintain upper-chest tension.',
    pose: 'supine-press',
    equip: 'dumbbells-press',
    badge: '6 BOTH · 6R · 6L',
    frames: [
      { label: '1. 6x Both Arms', phase: 'bench-press-both', note: 'Reps 1–6' },
      { label: '2. 6x Right (Hold Left)', phase: 'bench-press-1arm-r', note: 'Reps 7–12' },
      { label: '3. 6x Left (Hold Right)', phase: 'bench-press-1arm-l', note: 'Reps 13–18' }
    ]
  },
  'trx-chest-press': {
    summary: 'Suspended incline push-up on TRX straps challenging chest pressing strength alongside deep shoulder and core stability.',
    steps: [
      'Stand facing away from the TRX anchor holding the handles at chest height with straps taut and body in a straight incline plank.',
      'Bend your elbows to lower your chest between your hands while keeping the straps lightly grazing above your forearms.',
      'Press your palms together and away to return to the starting incline plank without letting the straps saw against your arms.'
    ],
    formTip: 'Walk your feet closer to the anchor point to increase the incline and make the press heavier.',
    pose: 'trx-incline-press',
    equip: 'trx-push',
    badge: 'TRX PRESS',
    frames: [
      { label: '1. Suspended Incline Plank', phase: 'trx-press-start' },
      { label: '2. Deep Chest Lower & Press', phase: 'trx-press-low', arrow: 'trx-push' }
    ]
  },
  'up-up-down-ups': {
    summary: 'Dynamic plank-to-pushup (commando plank) transitioning between forearms and hands, with optional lateral hand/foot taps.',
    steps: [
      'Begin in a forearm plank with elbows directly beneath your shoulders and core braced.',
      'Place one palm flat under your shoulder and press up, followed by the other palm to reach a high plank ("Up-Up").',
      'Optionally perform a lateral hand/foot tap at the top, then lower back down one forearm at a time ("Down-Down"), alternating your lead arm every rep.'
    ],
    formTip: 'Place your hand exactly where your elbow just was so you press straight up with your triceps and chest.',
    pose: 'plank-up-down',
    equip: 'bodyweight',
    badge: 'FOREARM ↔ HIGH PLANK',
    frames: [
      { label: '1. Forearm Plank ("Down-Down")', phase: 'forearm-plank' },
      { label: '2. Single-Arm Transition', phase: 'plank-commando-mid' },
      { label: '3. High Plank ("Up-Up")', phase: 'plank-high', arrow: 'up' }
    ]
  },
  'curls': {
    summary: 'Elbow flexion exercise using dumbbells, resistance bands, or TRX straps to isolate and build the biceps.',
    steps: [
      'Stand tall (or lean back on TRX straps) with elbows pinned close to your ribcage and palms facing forward.',
      'Curl your hands toward your shoulders by contracting your biceps while keeping your upper arms completely stationary.',
      'Pause and squeeze at peak contraction before lowering slowly under control to full elbow extension.'
    ],
    formTip: 'Avoid swinging your torso or letting your elbows drift forward—make the biceps move 100% of the load.',
    pose: 'standing-curl',
    equip: 'dumbbells-band',
    badge: 'BICEP CURL',
    frames: [
      { label: '1. Full Extension Setup', phase: 'curl-down' },
      { label: '2. Peak Bicep Contraction', phase: 'curl-up', arrow: 'curl' }
    ]
  },
  'skull-crushers': {
    summary: 'Supine lying tricep extension isolating all three heads of the triceps.',
    steps: [
      'Lie on your back on a bench or mat holding dumbbells or a weight straight above your shoulders with palms facing each other.',
      'Keep your upper arms vertical and stationary as you hinge only at the elbows, lowering the weights toward your temples/forehead.',
      'Extend your forearms straight back up using your triceps to lock out at the top.'
    ],
    formTip: 'Angle your upper arms slightly back (about 10° toward your head) to keep constant tension on the triceps even at the top.',
    pose: 'supine-skullcrusher',
    equip: 'dumbbells-press',
    badge: 'ELBOW HINGE',
    frames: [
      { label: '1. Forearms Lowered to Temple', phase: 'skullcrusher-down' },
      { label: '2. Vertical Tricep Lockout', phase: 'bench-press-top', arrow: 'skull-up' }
    ]
  },
  'tricep-kick-backs': {
    summary: 'Bent-over dumbbell tricep extension targeting peak contraction of the triceps.',
    steps: [
      'Hinge forward at the hips to a 45°–60° torso angle with a flat back, tucking your upper arms parallel to your torso.',
      'Keeping your elbows glued to your sides, extend your forearms straight back until your arms are fully locked out behind you.',
      'Squeeze the triceps for a half-second at the top, then lower the dumbbells back to a 90° elbow bend.'
    ],
    formTip: 'Never let your elbows drop during the set—only your forearm should move like a pendulum.',
    pose: 'hinge-kickback',
    equip: 'dumbbells-hinge',
    badge: 'LOCK & SQUEEZE',
    frames: [
      { label: '1. 90° Elbow Tuck in Hinge', phase: 'kickback-bent' },
      { label: '2. Full Rear Tricep Extension', phase: 'kickback-extended', arrow: 'kickback' }
    ]
  },
  'trx-triceps': {
    summary: 'Suspended bodyweight overhead tricep extension on TRX straps.',
    steps: [
      'Stand facing away from the TRX anchor in a forward incline plank with arms extended forward at forehead height and palms facing down.',
      'Keep your elbows pointed straight ahead and shoulder-width apart as you bend at the elbows, lowering your forehead behind your hands.',
      'Press through your palms to extend your elbows back to the starting position while holding a rigid body line.'
    ],
    formTip: 'Keep your elbows tucked in rather than flaring wide so all the torque stays on your triceps.',
    pose: 'trx-incline-tricep',
    equip: 'trx-push',
    badge: 'TRX EXTENSION',
    frames: [
      { label: '1. Forehead to Hands (Bent)', phase: 'trx-tricep-bent' },
      { label: '2. Full Elbow Extension', phase: 'trx-tricep-ext', arrow: 'trx-push' }
    ]
  },
  'chair-dips': {
    summary: 'Bodyweight bench or chair dip targeting the triceps, anterior deltoids, and lower chest.',
    steps: [
      'Sit on the edge of a sturdy chair or bench, gripping the front edge next to your hips with fingers pointing forward.',
      'Slide your hips just off the front edge (knees bent for standard or legs straight for advanced) and lower until elbows reach 90°.',
      'Press through the heels of your palms to straighten your arms back to the top.'
    ],
    formTip: 'Keep your back grazing close to the front edge of the chair—drifting forward shifts stress onto the front of the shoulder.',
    pose: 'chair-dip',
    equip: 'chair',
    badge: 'BENCH / CHAIR DIP',
    frames: [
      { label: '1. Top Support off Bench', phase: 'dip-top' },
      { label: '2. 90° Dip & Press Up', phase: 'dip-low', arrow: 'up' }
    ]
  },
  'shoulder-press': {
    summary: 'Vertical overhead press using dumbbells or resistance bands to build deltoid and tricep strength.',
    steps: [
      'Stand or sit tall holding dumbbells or band handles at shoulder height with palms facing forward or neutral.',
      'Brace your core and glutes, then press the weights straight overhead until your arms are fully extended by your ears.',
      'Lower slowly back to shoulder level with control before beginning the next rep.'
    ],
    formTip: 'Keep your ribs tucked down so you press strictly with your shoulders rather than leaning back into an incline press.',
    pose: 'standing-press',
    equip: 'dumbbells-overhead',
    badge: 'OVERHEAD PRESS',
    frames: [
      { label: '1. Rack at Shoulder Level', phase: 'press-start' },
      { label: '2. Full Overhead Lockout', phase: 'press-top', arrow: 'up' }
    ]
  },
  'arnold-press': {
    summary: 'Rotational dumbbell shoulder press hitting the anterior, lateral, and posterior deltoids through a 180° pronation arc.',
    steps: [
      'Start with dumbbells held in front of your chin with palms facing toward you (like the top of a bicep curl).',
      'In one fluid motion, open your elbows out to the sides while rotating your palms forward and pressing the dumbbells overhead.',
      'Reverse the motion on the way down, rotating your palms back toward your face as the weights return to chin height.'
    ],
    formTip: 'Keep the rotation smooth and continuous throughout the press rather than breaking it into two robotic steps.',
    pose: 'standing-press',
    equip: 'dumbbells-overhead',
    badge: '180° ROTATION PRESS',
    frames: [
      { label: '1. Palms-In Chin Rack', phase: 'arnold-chin' },
      { label: '2. Open Elbows & Rotate', phase: 'press-start' },
      { label: '3. Overhead Lockout', phase: 'press-top', arrow: 'up' }
    ]
  },
  'lateral-shoulder-raises': {
    summary: 'Abduction raise with dumbbells or bands isolating the lateral (medial) head of the deltoids.',
    steps: [
      'Stand tall holding dumbbells or a resistance band at your sides with a soft 10° bend in your elbows.',
      'Raise your arms out to the sides in a wide arc until your elbows reach shoulder height (forming a "T").',
      'Pause briefly at shoulder level, then lower slowly for 2–3 seconds to resist gravity.'
    ],
    formTip: 'Lead with your elbows rather than your wrists, and keep your shoulders relaxed down away from your ears.',
    pose: 'standing-lat-raise',
    equip: 'dumbbells-side',
    badge: 'LATERAL RAISE',
    frames: [
      { label: '1. Dumbbells at Sides', phase: 'lat-raise-down' },
      { label: '2. Raise to Shoulder "T"', phase: 'lat-raise-up', arrow: 'wings-up' }
    ]
  },
  'cheerleaders': {
    summary: 'Multi-angle shoulder raise complex combining front, diagonal ("V"), and lateral raises with light dumbbells.',
    steps: [
      'Stand tall with light-to-moderate dumbbells at your thighs and a braced core.',
      'Raise both arms straight in front to shoulder height, lower, then raise diagonally into a high "V" (cheerleader stance).',
      'Lower with control and finish the sequence with a lateral raise out to a "T", repeating the multi-angle pattern rhythmically.'
    ],
    formTip: 'Use lighter weights than your standard shoulder press—the long lever arm creates intense deltoid burn quickly.',
    pose: 'standing-cheerleader',
    equip: 'dumbbells-v',
    badge: 'FRONT · V · SIDE',
    frames: [
      { label: '1. Front Raise', phase: 'front-raise' },
      { label: '2. High Diagonal "V"', phase: 'cheer-v', arrow: 'up' },
      { label: '3. Lateral "T" Raise', phase: 'lat-raise-up', arrow: 'wings-up' }
    ]
  },
  'swings': {
    summary: 'Explosive hip-hinge kettlebell or dumbbell swing driving power from the glutes, hamstrings, and back.',
    steps: [
      'Stand with feet slightly wider than shoulder-width, holding a kettlebell or dumbbell with both hands between your thighs.',
      'Hinge your hips back sharply with a flat back (shins nearly vertical) to load your hamstrings and glutes.',
      'Snap your hips forward explosively to float the weight up to chest/shoulder height, then let it swing back between your hips for the next rep.'
    ],
    formTip: 'A swing is a horizontal hip snap, not a squat—your arms act like ropes while your glutes generate 100% of the upward drive.',
    pose: 'hip-hinge-swing',
    equip: 'kettlebell-swing',
    badge: 'HIP SNAP POWER',
    frames: [
      { label: '1. Loaded Hip Hinge Hike', phase: 'swing-hike' },
      { label: '2. Explosive Hip Snap & Float', phase: 'swing-top', arrow: 'swing-up' }
    ]
  },
  'trx-i-y-ts': {
    summary: 'Three-angle TRX suspension rear-delt and upper-back fly sequence forming the letters "I", "Y", and "T".',
    steps: [
      'Lean back holding the TRX handles with arms extended in front of you and body in a straight plank.',
      'Pull your body up by raising straight arms overhead into an "I", lower with control, then pull up at a 45° angle into a "Y".',
      'Lower again, then pull your arms straight out to the sides into a "T" by squeezing your shoulder blades together.'
    ],
    formTip: 'Keep your elbows straight and hips locked in line with your torso—never break at the waist to pull yourself up.',
    pose: 'trx-lean-back',
    equip: 'trx-pull',
    badge: 'I · Y · T ANGLES',
    frames: [
      { label: '1. Lean Back Setup', phase: 'trx-pull-start' },
      { label: '2. Overhead "I" / "Y" Pull', phase: 'trx-pull-y', arrow: 'trx-pull' },
      { label: '3. Wide "T" Fly Squeeze', phase: 'trx-pull-t', arrow: 'trx-pull' }
    ]
  },
  'trx-wood-choppers': {
    summary: 'Rotational TRX core and upper-back torso sweep targeting the obliques, abs, lats, and shoulders.',
    steps: [
      'Stand sideways to the TRX anchor holding both handles together with interlocked hands and arms extended.',
      'Lean away with a rigid torso, then drive through your core and back to rotate your arms diagonally across and up like chopping wood.',
      'Return slowly under rotational control and complete all reps or half the interval on one side before switching.'
    ],
    formTip: 'Initiate the rotation from your ribcage and obliques while keeping your arms long and shoulders packed.',
    pose: 'trx-woodchop',
    equip: 'trx-pull',
    badge: 'ROTATIONAL CHOP',
    frames: [
      { label: '1. Loaded Side Lean', phase: 'trx-pull-start' },
      { label: '2. Rotational Torso Chop', phase: 'trx-chop-finish', arrow: 'trx-pull' }
    ]
  },
  'rows': {
    summary: 'Horizontal pulling movement using dumbbells, bands, or TRX to strengthen the lats, rhomboids, rear delts, and biceps.',
    steps: [
      'Hinge forward 45° with a flat back (for dumbbells/bands) or lean back on TRX straps with arms extended.',
      'Drive your elbows back past your ribcage while squeezing your shoulder blades together at the top of the pull.',
      'Lower the weights or extend your arms slowly back to a full stretch without rounding your upper back.'
    ],
    formTip: 'Think about pulling with your elbows toward your back pockets rather than curling with your wrists.',
    pose: 'hinge-row',
    equip: 'dumbbells-hinge',
    badge: 'ROW & RETRACT',
    frames: [
      { label: '1. Hinged Hang (Stretched Lats)', phase: 'row-hang' },
      { label: '2. Elbows Driven Past Ribs', phase: 'row-pulled', arrow: 'row-up' }
    ]
  },
  'pull-ups': {
    summary: 'Overhand-grip vertical pull targeting the latissimus dorsi, upper back, biceps, and core.',
    steps: [
      'Grip a pull-up bar slightly wider than shoulder-width with palms facing away from you (pronated grip).',
      'Depress your shoulder blades down and back, then pull your chest toward the bar by driving your elbows down to your sides.',
      'Once your chin clears the bar, lower yourself smoothly all the way to a controlled dead hang.'
    ],
    formTip: 'Cross your ankles or hollow your core slightly to prevent swinging and keep strict tension on your lats.',
    pose: 'pullup-hang',
    equip: 'pullup-bar',
    badge: 'OVERHAND GRIP',
    frames: [
      { label: '1. Active Dead Hang', phase: 'pullup-bottom' },
      { label: '2. Chest to Bar Pull', phase: 'pullup-top', arrow: 'up' }
    ]
  },
  'chin-ups': {
    summary: 'Underhand-grip vertical pull placing heavy emphasis on both the biceps and latissimus dorsi.',
    steps: [
      'Grip the bar at shoulder-width with palms facing toward you (supinated grip).',
      'Pull yourself upward by drawing your elbows down in front of your ribs until your chin clears the bar.',
      'Squeeze your biceps and lats at the top, then lower under full control to straight arms.'
    ],
    formTip: 'Lead with your chest toward the bar and keep your shoulders rolled back at the top.',
    pose: 'pullup-hang',
    equip: 'pullup-bar',
    badge: 'UNDERHAND GRIP',
    frames: [
      { label: '1. Supinated Hang', phase: 'pullup-bottom' },
      { label: '2. Chin Over Bar Squeeze', phase: 'pullup-top', arrow: 'up' }
    ]
  },
  'face-pulls': {
    summary: 'Banded high row with external shoulder rotation targeting the rear deltoids, rhomboids, and rotator cuff.',
    steps: [
      'Anchor a resistance band at upper-chest or eye level and hold the ends with both hands, stepping back to create tension.',
      'Pull the band toward your forehead while driving your elbows high and wide and rotating your thumbs back behind your ears.',
      'Pause for 1 second in a "double bicep" pose squeezing your upper back, then return slowly.'
    ],
    formTip: 'Your hands should finish by your ears, not your chest—external rotation at the end is what fires the rotator cuff.',
    pose: 'standing-facepull',
    equip: 'band-high',
    badge: 'HIGH REAR PULL',
    frames: [
      { label: '1. Arms Extended w/ Band Tension', phase: 'facepull-start' },
      { label: '2. High Pull & External Rotation', phase: 'facepull-end', arrow: 'pull-back' }
    ]
  },
  'reverse-flys': {
    summary: 'Bent-over rear deltoid and upper-back dumbbell fly strengthening postural scapular retractors.',
    steps: [
      'Hinge at the hips until your torso is nearly parallel to the floor, holding dumbbells beneath your chest with palms facing each other.',
      'Maintaining a slight bend in your elbows, sweep your arms out wide toward the ceiling until they are in line with your back.',
      'Squeeze your rear delts and mid-back at the top, then lower slowly without swinging your torso.'
    ],
    formTip: 'Keep your neck neutral by looking at the floor a few feet ahead rather than cranking your head up.',
    pose: 'hinge-row',
    equip: 'dumbbells-hinge',
    badge: 'REAR DELT FLY',
    frames: [
      { label: '1. Hinged Setup (Weights Down)', phase: 'row-hang' },
      { label: '2. Wide Rear-Delt Sweep', phase: 'reverse-fly-top', arrow: 'row-up' }
    ]
  },
  'serratus-pushups': {
    summary: 'Straight-arm scapular push-up isolating the serratus anterior and shoulder girdle stabilizers.',
    steps: [
      'Assume a rigid high plank with arms locked straight and hands stacked directly beneath your shoulders.',
      'Keeping your elbows 100% straight, let your chest sink slightly so your shoulder blades pinch together.',
      'Push the floor away forcefully to spread your shoulder blades wide apart and dome your upper back slightly at the top.'
    ],
    formTip: 'Zero elbow bend—all the movement happens in a 2–3 inch range at the shoulder blades.',
    pose: 'plank-pushup',
    equip: 'bodyweight',
    badge: 'SCAPULAR PROTRACT',
    frames: [
      { label: '1. Scapular Retraction (Sink)', phase: 'plank-scap-sink' },
      { label: '2. Scapular Protraction (Push Tall)', phase: 'plank-high', arrow: 'up' }
    ]
  },
  'slam-ball-slams': {
    summary: 'Explosive full-body overhead slam using a non-bounce slam ball to train the lats, abs, shoulders, and hip hinge.',
    steps: [
      'Stand with feet shoulder-width apart holding a slam ball at hip level.',
      'Reach the ball high overhead into full triple extension (hips, knees, and ankles extended) while inhaling.',
      'Brace your abs and lats to violently slam the ball straight down between your feet while hinging into an athletic squat to catch it.'
    ],
    formTip: 'Drop your hips down with the ball as you slam so you pick it up with a flat back and loaded legs, not a rounded spine.',
    pose: 'standing-slam',
    equip: 'slam-ball-overhead',
    badge: 'OVERHEAD SLAM',
    frames: [
      { label: '1. Overhead Triple Extension', phase: 'slam-top' },
      { label: '2. Explosive Downward Slam', phase: 'slam-bottom', arrow: 'down' }
    ]
  },
  'ab-wheel-roller': {
    summary: 'High-tension anti-extension core rollout using an ab wheel or foam roller to challenge the abs, lats, and shoulders.',
    steps: [
      'Kneel on a mat gripping the ab wheel handles directly beneath your shoulders, tucking your pelvis slightly into a posterior tilt.',
      'Roll the wheel forward slowly while keeping your abs braced tight and hips moving forward as one unit with your torso.',
      'Roll out as far as you can without letting your lower back arch, then contract your abs and lats to pull the wheel back under your shoulders.'
    ],
    formTip: 'Never let your lower back sag—keep a slight hollow-body rib tuck throughout the entire rollout.',
    pose: 'kneeling-rollout',
    equip: 'ab-roller',
    badge: 'ANTI-EXTENSION',
    frames: [
      { label: '1. Kneeling Tuck Setup', phase: 'rollout-start' },
      { label: '2. Full Anti-Extension Rollout', phase: 'rollout-ext', arrow: 'fwd-back' }
    ]
  },
  'trx-crunches': {
    summary: 'Suspended plank knee-tuck (or straight-leg pike) with feet hooked in TRX straps.',
    steps: [
      'Hook both feet into the low TRX foot cradles and press up into a solid high plank with wrists under shoulders.',
      'For a TRX Crunch, drive both knees in toward your chest while rounding your lower abs; for a Pike, keep legs straight and lift your hips high toward the ceiling.',
      'Extend your legs smoothly back to a neutral plank without letting your hips drop below shoulder level.'
    ],
    formTip: 'Pause for a half-second when your knees are tucked or hips are piked to eliminate pendulum momentum.',
    pose: 'trx-feet-plank',
    equip: 'trx-feet',
    badge: 'CRUNCH / PIKE',
    frames: [
      { label: '1. Suspended Plank', phase: 'roller-plank' },
      { label: '2. Knee-Tuck Crunch (or Pike)', phase: 'roller-tuck', arrow: 'tuck-in' }
    ]
  },
  'crunch-pike-on-roller': {
    summary: 'Combo core movement with shins/feet on a foam roller alternating a knee-tuck crunch with a straight-leg hip pike.',
    steps: [
      'Start in a high plank with your shins or insteps resting on a foam roller and hands stacked under shoulders.',
      'Rep 1 (Crunch): Pull the roller forward by bending your knees into your chest, then extend back to plank.',
      'Rep 2 (Pike): Keep your legs completely straight and contract your abs to lift your hips high into an inverted V as the roller rolls toward your hands.'
    ],
    formTip: 'Alternate 1 Crunch + 1 Pike cleanly, pushing the floor away through your shoulders the entire time.',
    pose: 'trx-feet-plank',
    equip: 'foam-roller-feet',
    badge: '1 CRUNCH + 1 PIKE',
    frames: [
      { label: '1. Plank on Roller', phase: 'roller-plank' },
      { label: '2. Knee-Tuck Crunch', phase: 'roller-tuck', arrow: 'tuck-in' },
      { label: '3. Straight-Leg Hip Pike', phase: 'roller-pike', arrow: 'up' }
    ]
  },
  'leg-lifts': {
    summary: 'Supine straight-leg raise targeting the lower rectus abdominis and hip flexors.',
    steps: [
      'Lie flat on your back with legs straight together and hands resting at your sides or tucked lightly beneath your outer hips.',
      'Press your lower back firmly into the mat and lift both straight legs up to a 90° vertical angle.',
      'Lower your legs slowly toward the floor (stopping 2 inches above the ground) while keeping your lower back glued down.'
    ],
    formTip: 'If your lower back starts lifting off the mat near the bottom, bend your knees slightly or limit the bottom range.',
    pose: 'supine-leg-lift',
    equip: 'bodyweight',
    badge: 'LOWER AB CONTROL',
    frames: [
      { label: '1. 2" Bottom Hover (Back Flat)', phase: 'leglift-low' },
      { label: '2. 90° Vertical Leg Raise', phase: 'leglift-high', arrow: 'legs-up' }
    ]
  },
  '3-way-v-ups': {
    summary: 'Tri-directional V-up series folding to the left, center, and right to hit the upper/lower abs and both obliques.',
    steps: [
      'Lie flat on your back with arms extended overhead and legs straight out.',
      'Fold your torso and legs up together into a "V", reaching both hands outside your left foot (1), then lower back down.',
      'Fold straight up the center reaching toward your toes (2), lower, then fold up reaching outside your right foot (3).'
    ],
    formTip: 'Exhale sharply as you fold up on each of the three angles to maximize abdominal contraction.',
    pose: 'supine-v-up',
    equip: 'bodyweight',
    badge: 'LEFT · CENTER · RIGHT',
    frames: [
      { label: '1. Full Hollow Extension', phase: 'vup-flat' },
      { label: '2. Left / Right Oblique V-Fold', phase: 'vup-side', arrow: 'v-fold' },
      { label: '3. Center Toe-Touch V-Up', phase: 'vup-peak', arrow: 'v-fold' }
    ]
  },
  'v-ups-with-the-ball': {
    summary: 'Weighted V-up passing or reaching a slam ball/medicine ball between hands and feet at the peak of the fold.',
    steps: [
      'Lie extended on your back holding a slam ball or weight with both hands overhead.',
      'Simultaneously lift your torso and straight legs into a "V" position, bringing the ball up to meet your shins/toes.',
      'Lower your arms and legs back toward the floor under tight abdominal control without resting completely between reps.'
    ],
    formTip: 'Keep your chin slightly tucked and lift your entire shoulder blades off the mat on every rep.',
    pose: 'supine-v-up',
    equip: 'slam-ball-hands',
    badge: 'WEIGHTED V-UP',
    frames: [
      { label: '1. Overhead Ball Extension', phase: 'vup-flat-ball' },
      { label: '2. Weighted V-Fold to Toes', phase: 'vup-peak-ball', arrow: 'v-fold' }
    ]
  },
  'crunches': {
    summary: 'Focused upper abdominal spinal flexion movement isolating the rectus abdominis.',
    steps: [
      'Lie on your back with knees bent at 90°, feet flat on the floor, and fingertips lightly behind your ears.',
      'Exhale and curl your upper spine to lift your head and shoulder blades off the mat while pressing your lower back down.',
      'Hold the top squeeze for 1 second, then lower slowly back to the mat.'
    ],
    formTip: 'Never pull on your neck with your hands—keep a fist-sized space between your chin and chest.',
    pose: 'supine-crunch',
    equip: 'bodyweight',
    badge: 'RIB-TO-HIP CURL',
    frames: [
      { label: '1. Supine Hook-Lying Setup', phase: 'crunch-down' },
      { label: '2. Upper Spine Curl & Squeeze', phase: 'crunch-up', arrow: 'crunch' }
    ]
  },
  'bicycle-crunches': {
    summary: 'Alternating rotational crunch pairing opposite elbow-to-knee touches with pedaling leg extensions.',
    steps: [
      'Lie on your back with knees lifted to tabletop, shoulders curled off the mat, and hands lightly behind your head.',
      'Extend your right leg straight out at a 45° angle while rotating your right armpit/elbow across to meet your left knee.',
      'Switch sides smoothly in a pedaling motion, bringing your left elbow to your right knee while fully extending the left leg.'
    ],
    formTip: 'Rotate your entire shoulder and ribcage toward the knee rather than just flapping your elbows inward.',
    pose: 'supine-bicycle',
    equip: 'bodyweight',
    badge: 'ROTATE & PEDAL',
    frames: [
      { label: '1. Right Elbow to Left Knee', phase: 'bicycle-left' },
      { label: '2. Pedal & Switch Sides', phase: 'bicycle-right', arrow: 'crunch' }
    ]
  },
  'mountain-climbers': {
    summary: 'High-tempo plank knee drives combining core stabilization with cardiovascular conditioning.',
    steps: [
      'Start in a strong high plank with hands stacked directly under shoulders and body in a straight line.',
      'Drive one knee rapidly toward your chest while keeping your hips low and back flat.',
      'Switch legs rhythmically in a running plank motion while pressing the floor away through your palms.'
    ],
    formTip: 'Keep your shoulders stacked directly over your wrists—do not let yourself drift backward into a downward dog.',
    pose: 'plank-mountain-climber',
    equip: 'bodyweight',
    badge: 'ALTERNATING DRIVE',
    frames: [
      { label: '1. Left Knee Drive to Chest', phase: 'climber-l', arrow: 'tuck-in' },
      { label: '2. Rapid Switch to Right Knee', phase: 'climber-r', arrow: 'tuck-in' }
    ]
  },
  'plank': {
    summary: 'Isometric full-body core hold building endurance in the transverse abdominis, rectus abdominis, shoulders, and glutes.',
    steps: [
      'Set your forearms on the floor with elbows directly under your shoulders and legs extended behind you.',
      'Tuck your tailbone slightly, squeeze your quads and glutes, and brace your abs as if preparing for a punch.',
      'Hold a completely straight line from head to heels while breathing steadily.'
    ],
    formTip: 'Pull your elbows isometrically toward your toes to double the activation in your abs.',
    pose: 'forearm-plank',
    equip: 'bodyweight',
    badge: 'ISOMETRIC BRACE',
    frames: [
      { label: '1. Elbow Stack & Pelvic Tuck', phase: 'forearm-plank' },
      { label: '2. Full-Body Isometric Brace', phase: 'forearm-plank-brace' }
    ]
  },
  'plank-jacks': {
    summary: 'Dynamic plank jumping both feet wide and together to challenge anti-extension core stability and hip abductors.',
    steps: [
      'Begin in a high plank or forearm plank with feet together and core tightly braced.',
      'Hop both feet out wide (wider than shoulder-width) like a horizontal jumping jack while keeping your hips level.',
      'Immediately hop your feet back together without letting your lower back bounce or dip.'
    ],
    formTip: 'Land softly on the balls of your feet and keep your hips at the exact same height throughout.',
    pose: 'plank-pushup',
    equip: 'bodyweight',
    badge: 'HOP WIDE & IN',
    frames: [
      { label: '1. Plank Feet Together', phase: 'plank-high' },
      { label: '2. Hop Feet Wide Apart', phase: 'plank-jack-wide', arrow: 'fwd-back' }
    ]
  },
  'round-the-worlds-plank-raises': {
    summary: 'Four-point anti-rotation plank sequentially raising your left arm, right arm, right leg, and left leg around the clock.',
    steps: [
      'Set up in a high or forearm plank with feet slightly wider than hip-width for rotational balance.',
      'Without shifting your hips, reach your left arm straight forward for 1 count, then set it down; reach your right arm forward, then set it down.',
      'Lift your right leg straight up squeezing the glute, set it down, then lift your left leg straight up to complete one full lap "around the world".'
    ],
    formTip: 'Move deliberately around the 4 limbs—rushing causes your torso to twist.',
    pose: 'plank-reach',
    equip: 'bodyweight',
    badge: '4-LIMB SEQUENCE',
    frames: [
      { label: '1. Single-Arm Forward Reach', phase: 'plank-arm-lift', arrow: 'up' },
      { label: '2. Single-Leg Glute Raise', phase: 'plank-leg-lift', arrow: 'up' }
    ]
  },
  'opposite-arm-and-leg-lifts': {
    summary: 'Contralateral quadruped (bird-dog) or prone extension strengthening the spinal erectors, abs, glutes, and shoulder stabilizers.',
    steps: [
      'Start on all fours with hands under shoulders and knees under hips (or lying prone on the mat).',
      'Brace your core and simultaneously extend your right arm straight forward and your left leg straight back until both are parallel to the floor.',
      'Pause for 1 second reaching long from fingertips to heel, return to start, and switch to left arm and right leg.'
    ],
    formTip: 'Think about reaching long horizontally rather than kicking high, which prevents overarching your lower back.',
    pose: 'quadruped-birddog',
    equip: 'bodyweight',
    badge: 'CONTRALATERAL REACH',
    frames: [
      { label: '1. All-Fours Tabletop Brace', phase: 'quadruped-start' },
      { label: '2. Opposite Arm & Leg Extension', phase: 'quadruped-ext', arrow: 'fwd-back' }
    ]
  },
  'side-plank-with-hip-dip': {
    summary: 'Lateral core and oblique exercise lowering and lifting the hips from a forearm side plank.',
    steps: [
      'Lie on your side propped on one forearm with your elbow stacked directly beneath your shoulder and feet stacked.',
      'Lift your hips into a straight side plank line, then slowly lower your bottom hip down until it lightly taps or hovers above the mat.',
      'Contract your bottom oblique and glute medius to drive your hips back up slightly past neutral.'
    ],
    formTip: 'Keep your chest and hips facing straight forward as if sliding between two panes of glass.',
    pose: 'side-plank',
    equip: 'bodyweight',
    badge: 'LATERAL HIP DIP',
    frames: [
      { label: '1. Controlled Hip Dip Down', phase: 'sideplank-dip' },
      { label: '2. Oblique Drive to High Line', phase: 'sideplank-high', arrow: 'up' }
    ]
  },
  'side-plank-with-hip-dip-and-leg-lift': {
    summary: 'Advanced side plank combining a lateral oblique hip dip with a top-leg abduction raise to fire the glute medius.',
    steps: [
      'Hold a strong forearm side plank with elbow under shoulder and body aligned.',
      'Perform one controlled hip dip down toward the floor and drive your hips back up to the top plank.',
      'At the top, hold your hips high and lift your top leg straight up toward the ceiling before lowering it and repeating.'
    ],
    formTip: 'Point the toes of your top foot slightly downward during the leg lift to maximize glute medius recruitment.',
    pose: 'side-plank-leg-lift',
    equip: 'bodyweight',
    badge: 'HIP DIP + LEG LIFT',
    frames: [
      { label: '1. Bottom Hip Dip', phase: 'sideplank-dip' },
      { label: '2. Drive Hips to Neutral', phase: 'sideplank-high', arrow: 'up' },
      { label: '3. Top-Leg Abduction Raise', phase: 'sideplank-leglift', arrow: 'up' }
    ]
  },
  'side-plank-with-reach-under': {
    summary: 'Rotational side plank threading the top arm underneath the ribcage and extending back up to target the obliques.',
    steps: [
      'Start in a forearm or high side plank with your top arm extended straight toward the ceiling.',
      'Keeping your hips elevated, rotate your torso to thread your top arm underneath your lower ribcage.',
      'Unwind smoothly and open your chest back out, reaching your top hand straight back up to the ceiling.'
    ],
    formTip: 'Follow your moving hand with your eyes to encourage full thoracic spine rotation.',
    pose: 'side-plank',
    equip: 'bodyweight',
    badge: 'THREAD THE NEEDLE',
    frames: [
      { label: '1. Open Side Plank Reach', phase: 'sideplank-high' },
      { label: '2. Thread Arm Under Ribcage', phase: 'sideplank-thread', arrow: 'crunch' }
    ]
  },
  'russian-twists-with-slam-ball': {
    summary: 'Seated V-sit rotational core exercise tapping a slam ball or weight side-to-side across the hips.',
    steps: [
      'Sit on the mat with knees bent, leaning your torso back 45° with a tall spine (heels lightly down or lifted off the floor) holding a slam ball.',
      'Rotate your shoulders and ribcage to bring the slam ball beside your right hip.',
      'Brace your obliques to sweep the ball across your torso to your left hip in a controlled rhythm.'
    ],
    formTip: 'Turn your shoulders with the ball—if only your arms move side-to-side while your chest faces forward, your obliques do less work.',
    pose: 'seated-twist',
    equip: 'slam-ball-hands',
    badge: 'OBLIQUE ROTATION',
    frames: [
      { label: '1. V-Sit Twist to Left Hip', phase: 'twist-left' },
      { label: '2. Sweep Ball to Right Hip', phase: 'twist-right', arrow: 'fwd-back' }
    ]
  },
  'single-leg-leg-lifts-on-bench-with-weight': {
    summary: 'Weighted unilateral hip extension / leg lift performed on a bench to isolate the glutes and hamstrings.',
    steps: [
      'Position yourself on a bench (either supine in a single-leg hip thrust setup with weight on your hip crease, or prone/side-supported with weight at the working leg/hip).',
      'Brace your core and drive through your working leg/glute to lift and extend the hip to full lockout.',
      'Pause for 1 full second squeezing the glute at the top before lowering under control; switch legs halfway.'
    ],
    formTip: 'Keep your chin tucked and ribs down at the top of the lift so all extension comes from the hip joint, not the lower spine.',
    pose: 'bench-glute-lift',
    equip: 'bench-weight',
    badge: 'WEIGHTED BENCH GLUTE',
    frames: [
      { label: '1. Weighted Bottom Hip Hinge', phase: 'bench-thrust-low' },
      { label: '2. Single-Leg Glute Lockout', phase: 'bench-thrust-high', arrow: 'up' }
    ]
  },
  'single-leg-band-glute-bridge': {
    summary: 'Unilateral supine glute bridge with a resistance band above the knees to fire the glute maximus, glute medius, and hamstrings.',
    steps: [
      'Lie on your back with a loop band just above your knees, one foot planted near your glutes and the other leg extended or held at 90°.',
      'Press through the heel of your planted foot while keeping tension outward against the band to lift your hips into a straight bridge.',
      'Squeeze your working glute at the top for 1 second, lower slowly, and switch legs halfway through the set.'
    ],
    formTip: 'Keep both hip bones level with the ceiling—do not let the unweighted hip drop.',
    pose: 'supine-single-bridge',
    equip: 'band-knees',
    badge: '1-LEG BAND BRIDGE',
    frames: [
      { label: '1. Supine 1-Leg Setup w/ Band', phase: 'bridge-1leg-low' },
      { label: '2. Full Unilateral Hip Bridge', phase: 'bridge-1leg-high', arrow: 'up' }
    ]
  },
  'alternating-glute-bridge-and-butterflies-with-band': {
    summary: 'Banded supine glute bridge holding at the top to perform a knees-out butterfly abduction on every rep.',
    steps: [
      'Lie on your back with a resistance band looped above your knees and feet planted hip-width apart.',
      'Drive through your heels to lift your hips into a high glute bridge.',
      'While holding your hips at the top, press both knees outward against the band ("butterfly"), bring knees back to neutral, then lower your hips down.'
    ],
    formTip: 'Keep your hips fully elevated during the butterfly abduction—do not let your glutes sink while pushing the knees out.',
    pose: 'supine-bridge',
    equip: 'band-knees',
    badge: 'BRIDGE + BUTTERFLY',
    frames: [
      { label: '1. Supine Setup w/ Band', phase: 'bridge-low' },
      { label: '2. Drive Hips to Bridge', phase: 'bridge-high', arrow: 'up' },
      { label: '3. Top Butterfly Abduction', phase: 'bridge-butterfly', arrow: 'knees-out' }
    ]
  },
  'butterflies-with-band': {
    summary: 'Seated, bridge-held, or supine banded hip abduction pulses targeting the glute medius and outer hip.',
    steps: [
      'Place a resistance band just above your knees while lying in a bridge position or seated with feet together.',
      'Drive both knees wide apart against the resistance of the band by contracting your outer glutes.',
      'Pause at peak width for a count, then return halfway in to keep constant tension on the band.'
    ],
    formTip: 'Keep the outer edges of your feet anchored and never let the band snap your knees inward.',
    pose: 'supine-bridge',
    equip: 'band-knees',
    badge: 'BAND ABDUCTION',
    frames: [
      { label: '1. Knees Neutral (Band Taut)', phase: 'bridge-high' },
      { label: '2. Drive Knees Wide Apart', phase: 'bridge-butterfly', arrow: 'knees-out' }
    ]
  },
  'lateral-band-walks': {
    summary: 'Athletic side-to-side steps with a resistance band around the ankles or knees to target the glute medius and quads.',
    steps: [
      'Place a loop band around your ankles or just above your knees and sink into an athletic quarter-squat with chest up.',
      'Take a wide lateral step to the right while keeping your toes pointed straight ahead, then step your left foot in to hip-width.',
      'Take several steps in one direction before reversing back to the left while maintaining low hip height.'
    ],
    formTip: 'Never let your feet come all the way together—keep at least hip-width tension on the band at all times.',
    pose: 'standing-band-walk',
    equip: 'band-ankles',
    badge: 'LATERAL STEP',
    frames: [
      { label: '1. Athletic Quarter-Squat Base', phase: 'band-walk-narrow' },
      { label: '2. Wide Lateral Step Out', phase: 'band-walk-wide', arrow: 'fwd-back' }
    ]
  },
  'forward-backward-band-walks': {
    summary: 'Monster walks stepping forward and backward in a low quarter-squat with a resistance band.',
    steps: [
      'Loop a resistance band around your ankles or knees and drop into an athletic quarter-squat with feet shoulder-width apart.',
      'Step forward and slightly outward keeping constant outward pressure against the band for 4–6 steps.',
      'Stay low and reverse the monster walk backward for 4–6 steps without bobbing your head up and down.'
    ],
    formTip: 'Imagine walking underneath a low ceiling so your quads and glutes stay under continuous tension.',
    pose: 'standing-band-walk',
    equip: 'band-ankles',
    badge: 'FWD / BACK WALK',
    frames: [
      { label: '1. Low Quarter-Squat Stance', phase: 'band-walk-narrow' },
      { label: '2. Diagonal Monster Step', phase: 'band-walk-wide', arrow: 'fwd-back' }
    ]
  },
  'band-leg-kick-backs-and-diagonals': {
    summary: 'Standing banded hip extension alternating straight-back kickbacks with 45° diagonal glute kickbacks.',
    steps: [
      'Loop a resistance band around your ankles and stand tall (optionally lightly touching a wall or chair for balance).',
      'Keeping your working leg straight and core braced, kick one heel straight back squeezing the glute maximus.',
      'Return with control, then kick the same leg back at a 45° diagonal angle to hit the upper/outer glute medius; switch legs halfway.'
    ],
    formTip: 'Keep your torso upright—leaning forward turns a glute kickback into a lower-back tilt.',
    pose: 'standing-kickback',
    equip: 'band-ankles',
    badge: 'BACK + 45° DIAGONAL',
    frames: [
      { label: '1. Tall Standing Band Setup', phase: 'kickback-stand' },
      { label: '2. Straight-Back & 45° Kick', phase: 'kickback-leg-ext', arrow: 'kickback' }
    ]
  },
  'frog-pumps': {
    summary: 'High-rep supine glute bridge with the soles of your feet pressed together and knees butterflied open.',
    steps: [
      'Lie on your back, press the soles of your shoes together (like a frog or butterfly stretch), and pull your heels close to your glutes.',
      'Tuck your chin slightly and drive through the outer edges of your feet to bridge your hips up.',
      'Squeeze your glutes hard at the top and pump rhythmically while keeping your knees flared wide.'
    ],
    formTip: 'Tucking your chin and looking toward your knees helps lock your ribcage down for a stronger glute contraction.',
    pose: 'supine-bridge',
    equip: 'bodyweight',
    badge: 'SOLES TOGETHER PUMP',
    frames: [
      { label: '1. Soles Together (Knees Wide)', phase: 'bridge-low' },
      { label: '2. High Frog Hip Bridge', phase: 'bridge-butterfly', arrow: 'up' }
    ]
  },
  'squats': {
    summary: 'Foundational lower-body squat building strength in the quadriceps, glutes, and core.',
    steps: [
      'Stand with feet shoulder-width apart and toes turned out 10°–15° (bodyweight or holding weights/bands).',
      'Sit your hips back and down while tracking your knees outward in line with your toes until thighs are at least parallel to the floor.',
      'Drive through your mid-foot and heels to stand tall and squeeze your glutes at the top.'
    ],
    formTip: 'Keep your chest proud and full foot anchored—never let your knees cave inward on the way up.',
    pose: 'squat-standard',
    equip: 'any-squat',
    badge: 'FULL DEPTH SQUAT',
    frames: [
      { label: '1. Tall Athletic Stance', phase: 'squat-top' },
      { label: '2. Parallel Depth & Drive', phase: 'squat-low', arrow: 'up' }
    ]
  },
  'sumo-squats': {
    summary: 'Wide-stance squat with toes turned out 45° emphasizing the glutes, inner thighs (adductors), and quads.',
    steps: [
      'Take a wide stance (well outside shoulder-width) and turn your toes out at a 45° angle.',
      'Keep your torso upright as you lower your hips straight down while actively pressing your knees outward toward your pinky toes.',
      'Drive through your heels to return to standing, squeezing your glutes and inner thighs at the top.'
    ],
    formTip: 'Because of the wide stance, keep your torso more vertical than a standard squat.',
    pose: 'squat-wide',
    equip: 'any-squat',
    badge: 'WIDE SUMO STANCE',
    frames: [
      { label: '1. Wide 45° Turnout Stance', phase: 'sumo-top' },
      { label: '2. Deep Sumo Drop (Knees Wide)', phase: 'sumo-low', arrow: 'up' }
    ]
  },
  '1-5-squats': {
    summary: 'One-and-a-half rep squat: descend to the bottom, rise halfway up, drop back to the bottom, and stand all the way up.',
    steps: [
      'Lower into a full-depth squat until your thighs are parallel to the floor.',
      'Press halfway up (about 45° knee angle), pause briefly, then lower all the way back down into the bottom of the squat.',
      'Drive forcefully from the bottom all the way to standing—that entire sequence counts as 1 rep!'
    ],
    formTip: 'Control the transition at the halfway point rather than bouncing out of the bottom.',
    pose: 'squat-standard',
    equip: 'any-squat',
    badge: 'BOTTOM → HALF → TOP',
    frames: [
      { label: '1. Full Bottom Squat', phase: 'squat-low' },
      { label: '2. Rise Halfway & Drop Back', phase: 'squat-half', note: '1/2 Rep Pulse' },
      { label: '3. Full Stand Lockout', phase: 'squat-top', arrow: 'up' }
    ]
  },
  'squat-and-hold': {
    summary: 'Isometric bottom-hold squat building intense quad and glute muscular endurance.',
    steps: [
      'Set your feet shoulder-width apart and lower into a parallel squat with chest proud and core braced.',
      'Hold the bottom parallel position (or pause for 3–5 seconds at the bottom of each rep) while keeping active tension in your quads and glutes.',
      'Drive up through your heels when prompted or at the end of each isometric hold.'
    ],
    formTip: 'Stay active at parallel—do not sink passively onto your calf/knee joints.',
    pose: 'squat-standard',
    equip: 'any-squat',
    badge: 'ISOMETRIC HOLD',
    frames: [
      { label: '1. Descend to Parallel', phase: 'squat-top' },
      { label: '2. Active Parallel Isometric Hold', phase: 'squat-low', note: 'Hold Tension' }
    ]
  },
  'wide-then-narrow-squats': {
    summary: 'Dynamic squat variation alternating between a wide sumo stance and a narrow shoulder-width stance.',
    steps: [
      'Perform a full squat in a wide stance with knees tracking outward.',
      'As you stand or hop lightly at the top, step or hop your feet inward to a narrow hip-width stance and immediately squat down.',
      'Continue alternating 1 Wide Squat and 1 Narrow Squat rhythmically.'
    ],
    formTip: 'Wide squats emphasize glutes and inner thighs; narrow squats shift emphasis directly onto the outer quads.',
    pose: 'squat-wide',
    equip: 'any-squat',
    badge: 'WIDE ↔ NARROW',
    frames: [
      { label: '1. Wide Stance Squat', phase: 'sumo-low' },
      { label: '2. Step / Hop Transition', phase: 'squat-top' },
      { label: '3. Narrow Quad Squat', phase: 'squat-low', arrow: 'up' }
    ]
  },
  'jump-out-squats': {
    summary: 'Explosive in-and-out squat jacks hopping feet from narrow to wide directly into a low squat.',
    steps: [
      'Start standing tall with feet together.',
      'Hop both feet out wide while dropping immediately into a deep squat (optionally touching the floor between your feet with one hand).',
      'Explode upward out of the squat to hop your feet back together at the top, then immediately drop into the next rep.'
    ],
    formTip: 'Absorb the landing by bending your hips and knees immediately as your feet touch down wide.',
    pose: 'squat-jump',
    equip: 'bodyweight',
    badge: 'IN & OUT SQUAT JACK',
    frames: [
      { label: '1. Feet Together Hop', phase: 'squat-top' },
      { label: '2. Jump Wide into Deep Squat', phase: 'sumo-low', arrow: 'up' }
    ]
  },
  'squat-jumps': {
    summary: 'Plyometric vertical jump squat developing lower-body explosive power and conditioning.',
    steps: [
      'Stand with feet shoulder-width apart and lower into a quarter-to-parallel squat while swinging your arms back.',
      'Drive explosively through the floor, extending hips, knees, and ankles to launch vertically into the air.',
      'Land softly toe-to-heel with bent knees, absorbing the impact smoothly into the next squat.'
    ],
    formTip: 'Aim for quiet, athletic landings—soft landings protect your knees and load your muscles properly.',
    pose: 'squat-jump',
    equip: 'bodyweight',
    badge: 'PLYO JUMP SQUAT',
    frames: [
      { label: '1. Loaded Squat Countermovement', phase: 'squat-low' },
      { label: '2. Explosive Vertical Launch', phase: 'squat-air', arrow: 'up' }
    ]
  },
  'step-ups': {
    summary: 'Unilateral bench or box step-up driving through the lead heel to build quad and glute strength.',
    steps: [
      'Place one entire foot flat on top of a sturdy bench, box, or step (bodyweight or holding dumbbells).',
      'Lean your torso slightly forward over your front knee and drive through your elevated heel to stand all the way up on the bench.',
      'Lower yourself back down slowly over 2 seconds using the elevated leg before switching or repeating.'
    ],
    formTip: 'Avoid pushing off the floor with your back toes—make the top leg lift 100% of your bodyweight.',
    pose: 'step-up-bench',
    equip: 'bench-any',
    badge: 'BENCH STEP-UP',
    frames: [
      { label: '1. Foot Planted on Bench', phase: 'stepup-start' },
      { label: '2. Drive Through Elevated Heel', phase: 'stepup-top', arrow: 'up' }
    ]
  },
  'lunges-split-squats': {
    summary: 'Unilateral split-squat or stepping lunge targeting the quads, glutes, and hamstrings.',
    steps: [
      'Step into a split stance with feet hip-width apart laterally (like standing on train tracks, not a tightrope).',
      'Lower your back knee toward the floor until both front and back knees form 90° angles.',
      'Drive through your front heel and mid-foot to return to standing; alternate legs or split the interval evenly.'
    ],
    formTip: 'Keep your front shin nearly vertical and torso tall to share the load evenly between quads and glutes.',
    pose: 'lunge-split',
    equip: 'dumbbells-band',
    badge: '90° / 90° SPLIT',
    frames: [
      { label: '1. Split Stance Setup', phase: 'lunge-high' },
      { label: '2. 90°/90° Lunge Depth', phase: 'lunge-low', arrow: 'up' }
    ]
  },
  'lunge-jumps': {
    summary: 'Plyometric split-squat jump switching lead legs mid-air for high-intensity leg power.',
    steps: [
      'Start at the bottom of a split lunge with both knees bent at 90° and torso upright.',
      'Drive explosively through both feet to jump straight up and scissor-switch your legs in mid-air.',
      'Land softly in a lunge on the opposite leg, absorbing the impact immediately into the next jump.'
    ],
    formTip: 'Use a rhythmic opposing arm swing (like sprinting) to help generate lift and balance.',
    pose: 'lunge-split',
    equip: 'bodyweight',
    badge: 'SCISSOR JUMP',
    frames: [
      { label: '1. 90° Split Lunge Load', phase: 'lunge-low' },
      { label: '2. Mid-Air Scissor Switch', phase: 'lunge-air', arrow: 'up' }
    ]
  },
  'lunges-with-one-dumbbell-up': {
    summary: 'Unilateral lunge holding a single dumbbell locked out overhead to challenge glutes, quads, shoulder stability, and core.',
    steps: [
      'Press one dumbbell straight overhead with your bicep locked by your ear and wrist neutral.',
      'Keeping the weight stacked directly over your shoulder, step into a controlled lunge until both knees hit 90°.',
      'Drive through your front heel back to standing; switch the overhead arm halfway through the set.'
    ],
    formTip: 'Keep your elbow locked straight overhead—looking at a fixed spot ahead helps maintain balance.',
    pose: 'lunge-overhead-db',
    equip: 'dumbbell-single-overhead',
    badge: '1-ARM OVERHEAD HOLD',
    frames: [
      { label: '1. Overhead Lockout Stand', phase: 'lunge-oh-high' },
      { label: '2. 90° Lunge w/ Overhead Hold', phase: 'lunge-oh-low', arrow: 'up' }
    ]
  },
  'lunge-with-one-foot-on-bench': {
    summary: 'Rear-foot-elevated split squat (Bulgarian split squat) placing deep stretch and load on the front glute and quad.',
    steps: [
      'Stand about two feet in front of a bench and rest the laces of your back foot on top of the bench.',
      'Lower your hips down and slightly back until your front thigh is parallel to the floor.',
      'Drive powerfully through your front heel to stand tall; complete half the set on each leg.'
    ],
    formTip: 'Hinging your torso forward 15° increases glute recruitment; staying vertical emphasizes the quad.',
    pose: 'lunge-bulgarian',
    equip: 'bench-weights',
    badge: 'BULGARIAN SPLIT SQUAT',
    frames: [
      { label: '1. Rear Foot Elevated on Bench', phase: 'bulgarian-high' },
      { label: '2. Deep Unilateral Split Squat', phase: 'bulgarian-low', arrow: 'up' }
    ]
  },
  'lunge-twists-with-slam-ball': {
    summary: 'Stepping lunge combined with a torso rotation over the front leg while holding a slam ball.',
    steps: [
      'Hold a slam ball at chest height with elbows wide and step forward or backward into a 90° lunge.',
      'At the bottom of the lunge, rotate your torso and the slam ball across toward your front knee/hip.',
      'Return to center and drive through your front heel back to standing, alternating legs.'
    ],
    formTip: 'Always twist toward the side of your front leg—this locks the pelvis in place and isolates the obliques.',
    pose: 'lunge-twist',
    equip: 'slam-ball-hands',
    badge: 'LUNGE + TWIST',
    frames: [
      { label: '1. Step into 90° Lunge w/ Ball', phase: 'lunge-ball-center' },
      { label: '2. Rotate Torso Over Lead Leg', phase: 'lunge-ball-twist', arrow: 'fwd-back' }
    ]
  },
  'bear-crawls': {
    summary: 'Quadruped knees-hovering crawl building shoulder stability, core anti-rotation, and quad endurance.',
    steps: [
      'Start on all fours with hands under shoulders, knees under hips, and lift your knees just 1–2 inches off the floor.',
      'Crawl forward by moving your opposite hand and foot simultaneously (right hand + left foot, then left hand + right foot) in short steps.',
      'Crawl forward several steps, then crawl backward for the same distance while keeping your back flat and knees low.'
    ],
    formTip: 'Take small 6-inch steps and keep your knees hovering right above the floor—do not let your hips rise up high.',
    pose: 'bear-crawl',
    equip: 'bodyweight',
    badge: 'HOVER KNEES 2"',
    frames: [
      { label: '1. Hover Knees 2" Off Floor', phase: 'bear-hover-1' },
      { label: '2. Contralateral Crawl Step', phase: 'bear-hover-2', arrow: 'fwd-back' }
    ]
  },
  'burpees': {
    summary: 'Full-body metabolic conditioning exercise combining a squat thrust, plank/push-up, and vertical jump.',
    steps: [
      'From standing, squat down and place both hands flat on the floor in front of your feet.',
      'Hop or step both feet back into a tight high plank (optionally dropping your chest to the floor for a push-up).',
      'Snap both feet back in wide outside your hands and explode straight up into a vertical jump with hands reaching overhead.'
    ],
    formTip: 'Snap your feet back in flat-footed rather than landing on your toes—this protects your knees and sets up an easy jump.',
    pose: 'burpee-flow',
    equip: 'bodyweight',
    badge: 'PLANK → SNAP → JUMP',
    frames: [
      { label: '1. Drop to Plank / Push-up', phase: 'plank-low' },
      { label: '2. Snap Feet In Flat', phase: 'squat-low' },
      { label: '3. Explosive Vertical Jump', phase: 'squat-air', arrow: 'up' }
    ]
  },
  'single-leg-deadlift': {
    summary: 'Unilateral hip-hinge balance exercise targeting the hamstrings, glutes, lower back, and ankle/core stabilizers.',
    steps: [
      'Stand on one leg with a soft 15° knee bend, holding dumbbells in front of your thighs.',
      'Hinge at the hip by extending your free leg straight back behind you like a seesaw while lowering the weights along your standing shin.',
      'When your torso and back leg reach parallel to the floor, drive your standing hip forward by squeezing your glute and hamstring to stand tall.'
    ],
    formTip: 'Point the toes of your lifted back foot straight down toward the floor to keep your hips square.',
    pose: 'single-leg-rdl',
    equip: 'dumbbells-hinge',
    badge: 'SEESAW HIP HINGE',
    frames: [
      { label: '1. Tall Single-Leg Balance', phase: 'rdl-stand' },
      { label: '2. Horizontal Seesaw Hinge', phase: 'rdl-hinge', arrow: 'up' }
    ]
  },
  'trx-hamstring-curls': {
    summary: 'Supine hamstring curl with heels suspended in TRX straps, intensely working the hamstrings, glutes, and core.',
    steps: [
      'Lie on your back facing the TRX anchor and place both heels into the low TRX foot cradles.',
      'Press your hips off the mat to form a straight supine plank from shoulders to heels.',
      'Dig your heels down and curl them in toward your glutes while lifting your hips higher, then extend slowly back out.'
    ],
    formTip: 'Keep your hips elevated during both the curl in and the extension out to prevent hamstring cramping and maximize glute synergy.',
    pose: 'trx-hamstring-curl',
    equip: 'trx-heels',
    badge: 'TRX HEEL CURL',
    frames: [
      { label: '1. Extended Supine Bridge', phase: 'trx-ham-ext' },
      { label: '2. Heel Curl & Hip Lift', phase: 'trx-ham-curl', arrow: 'tuck-in' }
    ]
  }
};

// ============================================================================
// 3. HIGH-FIDELITY SCULPTED ANATOMICAL MANNEQUIN & MULTI-FRAME RENDERER
// ============================================================================

/**
 * Draw a sculpted anatomical limb segment between (x1,y1) and (x2,y2) using
 * smooth cubic Bezier curves with natural muscle belly curvature.
 */
function sculptedSegment(x1, y1, x2, y2, r1, rMid, r2, fill = '#334155', stroke = '#94a3b8') {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const len = Math.hypot(dx, dy) || 1;
  const ux = dx / len;
  const uy = dy / len;
  const nx = -uy;
  const ny = ux;

  const mx = (x1 + x2) / 2;
  const my = (y1 + y2) / 2;

  const p1L = [x1 + nx * r1, y1 + ny * r1];
  const p1R = [x1 - nx * r1, y1 - ny * r1];
  const pML = [mx + nx * rMid, my + ny * rMid];
  const pMR = [mx - nx * rMid, my - ny * rMid];
  const p2L = [x2 + nx * r2, y2 + ny * r2];
  const p2R = [x2 - nx * r2, y2 - ny * r2];

  return `<path d="M ${p1L[0].toFixed(1)} ${p1L[1].toFixed(1)} Q ${pML[0].toFixed(1)} ${pML[1].toFixed(1)} ${p2L[0].toFixed(1)} ${p2L[1].toFixed(1)} A ${r2} ${r2} 0 0 1 ${p2R[0].toFixed(1)} ${p2R[1].toFixed(1)} Q ${pMR[0].toFixed(1)} ${pMR[1].toFixed(1)} ${p1R[0].toFixed(1)} ${p1R[1].toFixed(1)} A ${r1} ${r1} 0 0 1 ${p1L[0].toFixed(1)} ${p1L[1].toFixed(1)} Z" fill="${fill}" stroke="${stroke}" stroke-width="1.3" />`;
}

/**
 * Render an anatomical muscle highlight overlay on a segment or joint.
 */
function muscleGlow(x1, y1, x2, y2, r1, rMid, r2, level) {
  if (!level) return '';
  const color = level === 'Pri' ? '#f97316' : '#38bdf8';
  const stroke = level === 'Pri' ? '#fb923c' : '#7dd3fc';
  const op = level === 'Pri' ? '0.85' : '0.55';
  return `<g opacity="${op}">${sculptedSegment(x1, y1, x2, y2, r1, rMid, r2, color, stroke)}</g>`;
}

function jointCap(x, y, r, level) {
  const base = `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r}" fill="#334155" stroke="#94a3b8" stroke-width="1.3" />`;
  if (!level) return base;
  const color = level === 'Pri' ? '#f97316' : '#38bdf8';
  const op = level === 'Pri' ? '0.85' : '0.58';
  return `${base}<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r + 1.5}" fill="${color}" opacity="${op}" stroke="#fed7aa" stroke-width="0.8" />`;
}

function drawHead(x, y, angleDeg = 0) {
  return `<g transform="translate(${x.toFixed(1)}, ${y.toFixed(1)}) rotate(${angleDeg})">
    <ellipse cx="0" cy="0" rx="11" ry="12.5" fill="#475569" stroke="#cbd5e1" stroke-width="1.5" />
    <path d="M -10 -4 Q 0 -7 10 -4" stroke="#38bdf8" stroke-width="2.5" fill="none" opacity="0.75" />
  </g>`;
}

function drawDumbbell(x, y, angle = 0) {
  return `<g transform="translate(${x.toFixed(1)}, ${y.toFixed(1)}) rotate(${angle})">
    <rect x="-11" y="-3" width="22" height="6" rx="2" fill="#94a3b8" />
    <rect x="-13" y="-6.5" width="6" height="13" rx="2" fill="#facc15" stroke="#ca8a04" stroke-width="1" />
    <rect x="7" y="-6.5" width="6" height="13" rx="2" fill="#facc15" stroke="#ca8a04" stroke-width="1" />
  </g>`;
}

function drawSlamBall(x, y, r = 11) {
  return `<g transform="translate(${x.toFixed(1)}, ${y.toFixed(1)})">
    <circle cx="0" cy="0" r="${r}" fill="#eab308" stroke="#fef08a" stroke-width="1.4" />
    <path d="M -${r - 3} -3 Q 0 -7 ${r - 3} -3" stroke="#713f12" stroke-width="1.5" fill="none" />
  </g>`;
}

/**
 * Keyframe Pose Library — Maps every phase to sculpted anatomical coordinates
 * inside a 210x195 local panel coordinate system (floor at y=168).
 */
function getPhasePose(phase) {
  const P = {
    'plank-high': {
      head: [158, 86, -20],
      shoulder: [142, 98],
      hip: [90, 122],
      knee: [54, 144],
      ankle: [28, 165],
      elbow: [145, 132],
      wrist: [148, 165]
    },
    'plank-mid': {
      head: [160, 104, -12],
      shoulder: [142, 114],
      hip: [90, 132],
      knee: [54, 149],
      ankle: [28, 165],
      elbow: [128, 138],
      wrist: [148, 165]
    },
    'plank-low': {
      head: [162, 122, -5],
      shoulder: [142, 130],
      hip: [90, 140],
      knee: [54, 152],
      ankle: [28, 165],
      elbow: [122, 124],
      wrist: [148, 165]
    },
    'plank-scap-sink': {
      head: [158, 96, -15],
      shoulder: [142, 108],
      hip: [90, 126],
      knee: [54, 146],
      ankle: [28, 165],
      elbow: [145, 136],
      wrist: [148, 165]
    },
    'plank-tap': {
      head: [158, 84, -20],
      shoulder: [142, 96],
      hip: [90, 122],
      knee: [54, 144],
      ankle: [28, 165],
      elbow: [145, 132],
      wrist: [148, 165],
      elbow2: [122, 118],
      wrist2: [140, 96]
    },
    'plank-commando-mid': {
      head: [158, 98, -15],
      shoulder: [142, 110],
      hip: [90, 128],
      knee: [54, 146],
      ankle: [28, 165],
      elbow: [138, 165],
      wrist: [164, 165],
      elbow2: [146, 136],
      wrist2: [148, 165]
    },
    'forearm-plank': {
      head: [160, 110, -10],
      shoulder: [142, 120],
      hip: [88, 132],
      knee: [52, 148],
      ankle: [26, 165],
      elbow: [142, 165],
      wrist: [168, 165]
    },
    'forearm-plank-brace': {
      head: [160, 108, -10],
      shoulder: [142, 118],
      hip: [88, 128],
      knee: [52, 146],
      ankle: [26, 165],
      elbow: [142, 165],
      wrist: [168, 165],
      tension: true
    },
    'plank-jack-wide': {
      head: [158, 86, -20],
      shoulder: [142, 98],
      hip: [90, 122],
      knee: [58, 136],
      ankle: [32, 152],
      knee2: [52, 152],
      ankle2: [24, 168],
      elbow: [145, 132],
      wrist: [148, 165]
    },
    'plank-arm-lift': {
      head: [156, 86, -20],
      shoulder: [140, 98],
      hip: [88, 122],
      knee: [52, 144],
      ankle: [26, 165],
      elbow: [144, 132],
      wrist: [146, 165],
      elbow2: [168, 92],
      wrist2: [194, 86]
    },
    'plank-leg-lift': {
      head: [158, 86, -20],
      shoulder: [142, 98],
      hip: [90, 122],
      knee: [54, 144],
      ankle: [28, 165],
      knee2: [56, 112],
      ankle2: [24, 102],
      elbow: [145, 132],
      wrist: [148, 165]
    },
    'climber-l': {
      head: [160, 84, -20],
      shoulder: [144, 96],
      hip: [92, 118],
      knee: [54, 144],
      ankle: [28, 165],
      knee2: [126, 128],
      ankle2: [104, 150],
      elbow: [146, 132],
      wrist: [148, 165]
    },
    'climber-r': {
      head: [160, 84, -20],
      shoulder: [144, 96],
      hip: [92, 118],
      knee: [128, 124],
      ankle: [106, 148],
      knee2: [54, 144],
      ankle2: [28, 165],
      elbow: [146, 132],
      wrist: [148, 165]
    },
    'bench-fly-open': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [72, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [74, 146],
      wrist: [68, 116],
      dumbbell: [68, 112]
    },
    'bench-press-top': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [72, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [74, 96],
      wrist: [74, 68],
      dumbbell: [74, 64]
    },
    'bench-press-both': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [72, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [72, 136],
      wrist: [72, 102],
      dumbbell: [72, 96]
    },
    'bench-press-1arm-r': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [72, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [68, 96],
      wrist: [68, 66],
      elbow2: [80, 138],
      wrist2: [80, 104],
      dumbbell: [68, 62],
      dumbbell2: [80, 100]
    },
    'bench-press-1arm-l': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [72, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [80, 96],
      wrist: [80, 66],
      elbow2: [68, 138],
      wrist2: [68, 104],
      dumbbell: [80, 62],
      dumbbell2: [68, 100]
    },
    'skullcrusher-down': {
      bench: [38, 138, 110],
      head: [48, 124, -90],
      shoulder: [74, 126],
      hip: [126, 128],
      knee: [156, 122],
      ankle: [166, 165],
      elbow: [70, 92],
      wrist: [42, 106],
      dumbbell: [38, 106]
    },
    'trx-press-start': {
      trxAnchor: [28, 22],
      head: [150, 66, -25],
      shoulder: [136, 82],
      hip: [104, 122],
      knee: [82, 144],
      ankle: [64, 165],
      elbow: [158, 92],
      wrist: [176, 102]
    },
    'trx-press-low': {
      trxAnchor: [28, 22],
      head: [166, 82, -25],
      shoulder: [152, 98],
      hip: [112, 130],
      knee: [86, 148],
      ankle: [64, 165],
      elbow: [132, 106],
      wrist: [166, 106]
    },
    'trx-tricep-bent': {
      trxAnchor: [28, 22],
      head: [156, 76, -25],
      shoulder: [142, 92],
      hip: [106, 126],
      knee: [84, 146],
      ankle: [64, 165],
      elbow: [168, 78],
      wrist: [152, 58]
    },
    'trx-tricep-ext': {
      trxAnchor: [28, 22],
      head: [144, 68, -25],
      shoulder: [132, 84],
      hip: [102, 122],
      knee: [82, 144],
      ankle: [64, 165],
      elbow: [158, 72],
      wrist: [182, 64]
    },
    'trx-pull-start': {
      trxAnchor: [28, 22],
      head: [78, 74, 25],
      shoulder: [90, 90],
      hip: [118, 126],
      knee: [138, 146],
      ankle: [156, 165],
      elbow: [68, 78],
      wrist: [50, 68]
    },
    'trx-pull-y': {
      trxAnchor: [28, 22],
      head: [98, 56, 10],
      shoulder: [106, 74],
      hip: [128, 118],
      knee: [144, 142],
      ankle: [156, 165],
      elbow: [86, 52],
      wrist: [68, 36]
    },
    'trx-pull-t': {
      trxAnchor: [28, 22],
      head: [102, 58, 10],
      shoulder: [108, 76],
      hip: [128, 118],
      knee: [144, 142],
      ankle: [156, 165],
      elbow: [108, 76],
      wrist: [76, 72]
    },
    'trx-chop-finish': {
      trxAnchor: [28, 22],
      head: [104, 58, 8],
      shoulder: [110, 76],
      hip: [126, 118],
      knee: [142, 142],
      ankle: [156, 165],
      elbow: [128, 64],
      wrist: [144, 50]
    },
    'curl-down': {
      head: [105, 46, 0],
      shoulder: [105, 66],
      hip: [105, 112],
      knee: [105, 138],
      ankle: [105, 165],
      elbow: [108, 92],
      wrist: [114, 116],
      dumbbell: [114, 118]
    },
    'curl-up': {
      head: [105, 46, 0],
      shoulder: [105, 66],
      hip: [105, 112],
      knee: [105, 138],
      ankle: [105, 165],
      elbow: [110, 92],
      wrist: [128, 68],
      dumbbell: [130, 65]
    },
    'kickback-bent': {
      head: [146, 72, -35],
      shoulder: [128, 84],
      hip: [82, 112],
      knee: [94, 138],
      ankle: [86, 165],
      elbow: [102, 92],
      wrist: [108, 118],
      dumbbell: [108, 120]
    },
    'kickback-extended': {
      head: [146, 72, -35],
      shoulder: [128, 84],
      hip: [82, 112],
      knee: [94, 138],
      ankle: [86, 165],
      elbow: [102, 92],
      wrist: [72, 98],
      dumbbell: [68, 98]
    },
    'dip-top': {
      chair: [42, 122],
      head: [106, 60, 0],
      shoulder: [106, 78],
      hip: [104, 118],
      knee: [138, 124],
      ankle: [148, 165],
      elbow: [86, 100],
      wrist: [82, 122]
    },
    'dip-low': {
      chair: [42, 122],
      head: [108, 82, 0],
      shoulder: [108, 100],
      hip: [108, 140],
      knee: [142, 136],
      ankle: [152, 165],
      elbow: [78, 100],
      wrist: [82, 122]
    },
    'arnold-chin': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [105, 138],
      ankle: [105, 165],
      elbow: [122, 86],
      wrist: [124, 64],
      dumbbell: [124, 62]
    },
    'press-start': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [105, 138],
      ankle: [105, 165],
      elbow: [78, 76],
      wrist: [76, 54],
      elbow2: [132, 76],
      wrist2: [134, 54],
      dumbbell: [76, 52],
      dumbbell2: [134, 52]
    },
    'press-top': {
      head: [105, 52, 0],
      shoulder: [105, 72],
      hip: [105, 114],
      knee: [105, 140],
      ankle: [105, 165],
      elbow: [86, 48],
      wrist: [90, 26],
      elbow2: [124, 48],
      wrist2: [120, 26],
      dumbbell: [88, 22],
      dumbbell2: [122, 22]
    },
    'lat-raise-down': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [96, 138],
      ankle: [94, 165],
      elbow: [84, 92],
      wrist: [82, 114],
      elbow2: [126, 92],
      wrist2: [128, 114],
      dumbbell: [80, 116],
      dumbbell2: [130, 116]
    },
    'lat-raise-up': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [96, 138],
      ankle: [94, 165],
      elbow: [74, 68],
      wrist: [48, 66],
      elbow2: [136, 68],
      wrist2: [162, 66],
      dumbbell: [44, 66],
      dumbbell2: [166, 66]
    },
    'front-raise': {
      head: [100, 48, 0],
      shoulder: [100, 68],
      hip: [100, 112],
      knee: [100, 138],
      ankle: [100, 165],
      elbow: [126, 68],
      wrist: [154, 66],
      dumbbell: [158, 66]
    },
    'cheer-v': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [96, 138],
      ankle: [94, 165],
      elbow: [78, 50],
      wrist: [56, 32],
      elbow2: [132, 50],
      wrist2: [154, 32],
      dumbbell: [54, 28],
      dumbbell2: [156, 28]
    },
    'swing-hike': {
      head: [144, 72, -35],
      shoulder: [126, 84],
      hip: [78, 112],
      knee: [96, 138],
      ankle: [90, 165],
      elbow: [104, 106],
      wrist: [74, 122],
      slamBall: [66, 126]
    },
    'swing-top': {
      head: [102, 46, 0],
      shoulder: [102, 66],
      hip: [102, 110],
      knee: [102, 138],
      ankle: [102, 165],
      elbow: [128, 68],
      wrist: [154, 68],
      slamBall: [164, 68]
    },
    'row-hang': {
      head: [146, 72, -35],
      shoulder: [128, 84],
      hip: [82, 112],
      knee: [94, 138],
      ankle: [86, 165],
      elbow: [128, 112],
      wrist: [130, 138],
      dumbbell: [130, 142]
    },
    'row-pulled': {
      head: [146, 72, -35],
      shoulder: [128, 84],
      hip: [82, 112],
      knee: [94, 138],
      ankle: [86, 165],
      elbow: [98, 78],
      wrist: [112, 102],
      dumbbell: [112, 106]
    },
    'reverse-fly-top': {
      head: [146, 72, -35],
      shoulder: [128, 84],
      hip: [82, 112],
      knee: [94, 138],
      ankle: [86, 165],
      elbow: [120, 62],
      wrist: [114, 42],
      dumbbell: [114, 38]
    },
    'pullup-bottom': {
      pullupBar: true,
      head: [105, 64, 0],
      shoulder: [105, 82],
      hip: [105, 124],
      knee: [105, 148],
      ankle: [105, 166],
      elbow: [84, 54],
      wrist: [80, 28],
      elbow2: [126, 54],
      wrist2: [130, 28]
    },
    'pullup-top': {
      pullupBar: true,
      head: [105, 28, 0],
      shoulder: [105, 48],
      hip: [105, 94],
      knee: [105, 124],
      ankle: [112, 144],
      elbow: [78, 56],
      wrist: [80, 28],
      elbow2: [132, 56],
      wrist2: [130, 28]
    },
    'facepull-start': {
      bandAnchor: [24, 58],
      head: [128, 48, 0],
      shoulder: [128, 68],
      hip: [128, 112],
      knee: [128, 138],
      ankle: [128, 165],
      elbow: [102, 66],
      wrist: [76, 62]
    },
    'facepull-end': {
      bandAnchor: [24, 58],
      head: [128, 48, 0],
      shoulder: [128, 68],
      hip: [128, 112],
      knee: [128, 138],
      ankle: [128, 165],
      elbow: [142, 62],
      wrist: [118, 48]
    },
    'slam-top': {
      head: [105, 46, 0],
      shoulder: [105, 66],
      hip: [105, 110],
      knee: [105, 138],
      ankle: [105, 165],
      elbow: [112, 42],
      wrist: [114, 24],
      slamBall: [114, 18]
    },
    'slam-bottom': {
      head: [128, 86, -25],
      shoulder: [114, 98],
      hip: [78, 122],
      knee: [106, 138],
      ankle: [96, 165],
      elbow: [124, 124],
      wrist: [132, 148],
      slamBall: [136, 158]
    },
    'rollout-start': {
      head: [126, 86, -20],
      shoulder: [112, 98],
      hip: [68, 118],
      knee: [64, 165],
      ankle: [38, 165],
      elbow: [118, 130],
      wrist: [124, 158],
      roller: [124, 160]
    },
    'rollout-ext': {
      head: [164, 114, -10],
      shoulder: [146, 122],
      hip: [88, 136],
      knee: [54, 165],
      ankle: [30, 165],
      elbow: [168, 140],
      wrist: [188, 158],
      roller: [188, 160]
    },
    'roller-plank': {
      head: [162, 92, -15],
      shoulder: [146, 102],
      hip: [96, 118],
      knee: [64, 134],
      ankle: [38, 148],
      elbow: [148, 134],
      wrist: [150, 165],
      roller: [38, 156]
    },
    'roller-tuck': {
      head: [162, 92, -15],
      shoulder: [146, 102],
      hip: [102, 112],
      knee: [122, 138],
      ankle: [92, 148],
      elbow: [148, 134],
      wrist: [150, 165],
      roller: [92, 156]
    },
    'roller-pike': {
      head: [152, 108, 25],
      shoulder: [142, 94],
      hip: [108, 58],
      knee: [92, 106],
      ankle: [78, 148],
      elbow: [146, 130],
      wrist: [148, 165],
      roller: [78, 156]
    },
    'leglift-low': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [112, 158],
      knee: [146, 152],
      ankle: [182, 146],
      elbow: [86, 160],
      wrist: [108, 162]
    },
    'leglift-high': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [112, 158],
      knee: [114, 120],
      ankle: [116, 82],
      elbow: [86, 160],
      wrist: [108, 162]
    },
    'vup-flat': {
      head: [46, 148, -80],
      shoulder: [66, 154],
      hip: [114, 158],
      knee: [148, 152],
      ankle: [182, 144],
      elbow: [42, 146],
      wrist: [22, 140]
    },
    'vup-side': {
      head: [78, 106, -35],
      shoulder: [88, 124],
      hip: [114, 158],
      knee: [134, 122],
      ankle: [152, 86],
      elbow: [114, 114],
      wrist: [142, 96]
    },
    'vup-peak': {
      head: [74, 100, -40],
      shoulder: [84, 120],
      hip: [114, 158],
      knee: [130, 120],
      ankle: [146, 82],
      elbow: [110, 106],
      wrist: [138, 86]
    },
    'vup-flat-ball': {
      head: [46, 148, -80],
      shoulder: [66, 154],
      hip: [114, 158],
      knee: [148, 152],
      ankle: [182, 144],
      elbow: [42, 142],
      wrist: [24, 134],
      slamBall: [20, 130]
    },
    'vup-peak-ball': {
      head: [74, 100, -40],
      shoulder: [84, 120],
      hip: [114, 158],
      knee: [130, 120],
      ankle: [146, 82],
      elbow: [110, 104],
      wrist: [136, 84],
      slamBall: [140, 78]
    },
    'crunch-down': {
      head: [46, 152, -85],
      shoulder: [66, 156],
      hip: [114, 158],
      knee: [146, 126],
      ankle: [172, 165],
      elbow: [58, 138],
      wrist: [48, 150]
    },
    'crunch-up': {
      head: [66, 122, -45],
      shoulder: [78, 140],
      hip: [114, 158],
      knee: [146, 126],
      ankle: [172, 165],
      elbow: [82, 116],
      wrist: [68, 122]
    },
    'bicycle-left': {
      head: [64, 122, -45],
      shoulder: [78, 138],
      hip: [114, 158],
      knee: [116, 122],
      ankle: [142, 124],
      knee2: [148, 144],
      ankle2: [182, 136],
      elbow: [106, 122],
      wrist: [70, 124]
    },
    'bicycle-right': {
      head: [68, 120, -45],
      shoulder: [80, 138],
      hip: [114, 158],
      knee: [150, 142],
      ankle: [184, 134],
      knee2: [112, 122],
      ankle2: [138, 124],
      elbow: [104, 122],
      wrist: [72, 122]
    },
    'quadruped-start': {
      head: [152, 92, -10],
      shoulder: [134, 102],
      hip: [82, 104],
      knee: [82, 165],
      ankle: [54, 165],
      elbow: [134, 134],
      wrist: [134, 165]
    },
    'quadruped-ext': {
      head: [152, 92, -10],
      shoulder: [134, 102],
      hip: [82, 104],
      knee: [82, 165],
      ankle: [58, 165],
      knee2: [50, 102],
      ankle2: [20, 100],
      elbow: [134, 134],
      wrist: [134, 165],
      elbow2: [162, 100],
      wrist2: [192, 98]
    },
    'sideplank-dip': {
      head: [156, 108, -10],
      shoulder: [138, 118],
      hip: [90, 154],
      knee: [56, 160],
      ankle: [28, 165],
      elbow: [138, 165],
      wrist: [160, 165]
    },
    'sideplank-high': {
      head: [156, 92, -20],
      shoulder: [138, 104],
      hip: [90, 126],
      knee: [56, 146],
      ankle: [28, 165],
      elbow: [138, 165],
      wrist: [160, 165],
      elbow2: [138, 76],
      wrist2: [138, 52]
    },
    'sideplank-leglift': {
      head: [156, 92, -20],
      shoulder: [138, 104],
      hip: [90, 126],
      knee: [56, 146],
      ankle: [28, 165],
      knee2: [58, 106],
      ankle2: [30, 88],
      elbow: [138, 165],
      wrist: [160, 165],
      elbow2: [138, 76],
      wrist2: [138, 52]
    },
    'sideplank-thread': {
      head: [152, 98, -15],
      shoulder: [138, 106],
      hip: [90, 126],
      knee: [56, 146],
      ankle: [28, 165],
      elbow: [138, 165],
      wrist: [160, 165],
      elbow2: [122, 126],
      wrist2: [104, 136]
    },
    'twist-left': {
      head: [78, 86, -25],
      shoulder: [88, 106],
      hip: [110, 156],
      knee: [142, 128],
      ankle: [168, 154],
      elbow: [78, 126],
      wrist: [92, 138],
      slamBall: [90, 142]
    },
    'twist-right': {
      head: [82, 86, -25],
      shoulder: [92, 106],
      hip: [110, 156],
      knee: [142, 128],
      ankle: [168, 154],
      elbow: [116, 122],
      wrist: [132, 132],
      slamBall: [136, 134]
    },
    'bench-thrust-low': {
      bench: [26, 120, 44],
      head: [48, 96, -20],
      shoulder: [62, 112],
      hip: [106, 144],
      knee: [144, 118],
      ankle: [152, 165],
      knee2: [142, 102],
      ankle2: [176, 86],
      elbow: [84, 124],
      wrist: [104, 136],
      dumbbell: [106, 134]
    },
    'bench-thrust-high': {
      bench: [26, 120, 44],
      head: [48, 102, -80],
      shoulder: [64, 112],
      hip: [110, 114],
      knee: [148, 116],
      ankle: [152, 165],
      knee2: [148, 92],
      ankle2: [184, 68],
      elbow: [86, 112],
      wrist: [108, 108],
      dumbbell: [110, 104]
    },
    'bridge-1leg-low': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 156],
      knee: [144, 122],
      ankle: [156, 165],
      knee2: [142, 112],
      ankle2: [176, 86],
      elbow: [84, 160],
      wrist: [106, 162],
      bandKnees: true
    },
    'bridge-1leg-high': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 128],
      knee: [146, 116],
      ankle: [156, 165],
      knee2: [146, 92],
      ankle2: [182, 62],
      elbow: [84, 160],
      wrist: [106, 162],
      bandKnees: true
    },
    'bridge-low': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 156],
      knee: [144, 122],
      ankle: [158, 165],
      elbow: [84, 160],
      wrist: [106, 162],
      bandKnees: true
    },
    'bridge-high': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 126],
      knee: [146, 114],
      ankle: [158, 165],
      elbow: [84, 160],
      wrist: [106, 162],
      bandKnees: true
    },
    'bridge-butterfly': {
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 126],
      knee: [140, 104],
      ankle: [158, 165],
      knee2: [152, 124],
      ankle2: [158, 165],
      elbow: [84, 160],
      wrist: [106, 162],
      bandKnees: true
    },
    'band-walk-narrow': {
      head: [105, 54, 0],
      shoulder: [105, 74],
      hip: [98, 116],
      knee: [94, 140],
      ankle: [92, 165],
      knee2: [116, 140],
      ankle2: [118, 165],
      elbow: [96, 96],
      wrist: [114, 92],
      bandAnkles: true
    },
    'band-walk-wide': {
      head: [105, 58, 0],
      shoulder: [105, 78],
      hip: [98, 120],
      knee: [76, 142],
      ankle: [70, 165],
      knee2: [134, 142],
      ankle2: [142, 165],
      elbow: [96, 98],
      wrist: [114, 94],
      bandAnkles: true
    },
    'kickback-stand': {
      head: [116, 48, 0],
      shoulder: [114, 68],
      hip: [110, 112],
      knee: [110, 138],
      ankle: [110, 165],
      elbow: [122, 88],
      wrist: [134, 84],
      bandAnkles: true
    },
    'kickback-leg-ext': {
      head: [120, 50, -8],
      shoulder: [116, 70],
      hip: [108, 112],
      knee: [112, 138],
      ankle: [112, 165],
      knee2: [80, 132],
      ankle2: [52, 148],
      elbow: [124, 88],
      wrist: [138, 84],
      bandAnkles: true
    },
    'squat-top': {
      head: [105, 46, 0],
      shoulder: [105, 66],
      hip: [102, 110],
      knee: [104, 138],
      ankle: [102, 165],
      elbow: [108, 88],
      wrist: [122, 82]
    },
    'squat-half': {
      head: [114, 60, -10],
      shoulder: [108, 78],
      hip: [84, 118],
      knee: [116, 136],
      ankle: [104, 165],
      elbow: [118, 96],
      wrist: [138, 88]
    },
    'squat-low': {
      head: [118, 72, -15],
      shoulder: [110, 90],
      hip: [74, 130],
      knee: [118, 132],
      ankle: [106, 165],
      elbow: [124, 104],
      wrist: [148, 96]
    },
    'squat-air': {
      head: [105, 30, 0],
      shoulder: [105, 50],
      hip: [102, 92],
      knee: [104, 118],
      ankle: [102, 144],
      elbow: [96, 72],
      wrist: [86, 92]
    },
    'sumo-top': {
      head: [105, 48, 0],
      shoulder: [105, 68],
      hip: [105, 112],
      knee: [82, 138],
      ankle: [74, 165],
      knee2: [128, 138],
      ankle2: [136, 165],
      elbow: [105, 92],
      wrist: [105, 114]
    },
    'sumo-low': {
      head: [105, 68, 0],
      shoulder: [105, 88],
      hip: [105, 128],
      knee: [72, 132],
      ankle: [72, 165],
      knee2: [138, 132],
      ankle2: [138, 165],
      elbow: [105, 108],
      wrist: [105, 126]
    },
    'stepup-start': {
      bench: [122, 134, 48],
      head: [96, 56, -8],
      shoulder: [94, 76],
      hip: [86, 116],
      knee: [86, 142],
      ankle: [84, 165],
      knee2: [126, 108],
      ankle2: [136, 134],
      elbow: [96, 98],
      wrist: [110, 94]
    },
    'stepup-top': {
      bench: [122, 134, 48],
      head: [136, 28, 0],
      shoulder: [136, 48],
      hip: [134, 88],
      knee: [136, 112],
      ankle: [136, 134],
      knee2: [116, 114],
      ankle2: [110, 138],
      elbow: [138, 70],
      wrist: [150, 68]
    },
    'lunge-high': {
      head: [106, 46, 0],
      shoulder: [106, 66],
      hip: [104, 110],
      knee: [128, 136],
      ankle: [134, 165],
      knee2: [82, 138],
      ankle2: [64, 165],
      elbow: [106, 90],
      wrist: [108, 112]
    },
    'lunge-low': {
      head: [106, 66, 0],
      shoulder: [106, 86],
      hip: [104, 128],
      knee: [142, 130],
      ankle: [142, 165],
      knee2: [96, 156],
      ankle2: [62, 165],
      elbow: [106, 108],
      wrist: [110, 128]
    },
    'lunge-air': {
      head: [106, 32, 0],
      shoulder: [106, 52],
      hip: [104, 96],
      knee: [128, 118],
      ankle: [134, 144],
      knee2: [80, 120],
      ankle2: [66, 144],
      elbow: [122, 72],
      wrist: [134, 58]
    },
    'lunge-oh-high': {
      head: [106, 50, 0],
      shoulder: [106, 70],
      hip: [104, 112],
      knee: [126, 138],
      ankle: [132, 165],
      knee2: [82, 138],
      ankle2: [64, 165],
      elbow: [106, 44],
      wrist: [106, 22],
      dumbbell: [106, 18]
    },
    'lunge-oh-low': {
      head: [106, 68, 0],
      shoulder: [106, 88],
      hip: [104, 128],
      knee: [142, 130],
      ankle: [142, 165],
      knee2: [96, 156],
      ankle2: [62, 165],
      elbow: [106, 60],
      wrist: [106, 36],
      dumbbell: [106, 32]
    },
    'bulgarian-high': {
      bench: [24, 134, 38],
      head: [112, 48, 0],
      shoulder: [112, 68],
      hip: [108, 110],
      knee: [132, 136],
      ankle: [136, 165],
      knee2: [80, 132],
      ankle2: [44, 134],
      elbow: [112, 92],
      wrist: [114, 114],
      dumbbell: [114, 118]
    },
    'bulgarian-low': {
      bench: [24, 134, 38],
      head: [114, 68, -8],
      shoulder: [112, 86],
      hip: [104, 128],
      knee: [144, 130],
      ankle: [144, 165],
      knee2: [82, 152],
      ankle2: [44, 134],
      elbow: [112, 108],
      wrist: [114, 130],
      dumbbell: [114, 134]
    },
    'lunge-ball-center': {
      head: [106, 66, 0],
      shoulder: [106, 86],
      hip: [104, 128],
      knee: [142, 130],
      ankle: [142, 165],
      knee2: [96, 156],
      ankle2: [62, 165],
      elbow: [120, 104],
      wrist: [134, 100],
      slamBall: [140, 98]
    },
    'lunge-ball-twist': {
      head: [110, 66, 0],
      shoulder: [108, 86],
      hip: [104, 128],
      knee: [142, 130],
      ankle: [142, 165],
      knee2: [96, 156],
      ankle2: [62, 165],
      elbow: [130, 102],
      wrist: [152, 104],
      slamBall: [158, 104]
    },
    'bear-hover-1': {
      head: [154, 96, -12],
      shoulder: [136, 106],
      hip: [82, 108],
      knee: [92, 150],
      ankle: [62, 165],
      elbow: [136, 136],
      wrist: [138, 165]
    },
    'bear-hover-2': {
      head: [158, 96, -12],
      shoulder: [140, 106],
      hip: [86, 108],
      knee: [108, 148],
      ankle: [78, 165],
      knee2: [78, 150],
      ankle2: [52, 165],
      elbow: [152, 136],
      wrist: [158, 165]
    },
    'rdl-stand': {
      head: [110, 48, 0],
      shoulder: [110, 68],
      hip: [108, 112],
      knee: [108, 138],
      ankle: [108, 165],
      elbow: [112, 92],
      wrist: [116, 114],
      dumbbell: [116, 118]
    },
    'rdl-hinge': {
      head: [164, 92, -35],
      shoulder: [144, 96],
      hip: [98, 106],
      knee: [102, 136],
      ankle: [100, 165],
      knee2: [62, 104],
      ankle2: [28, 102],
      elbow: [142, 122],
      wrist: [140, 146],
      dumbbell: [140, 150]
    },
    'trx-ham-ext': {
      trxAnchor: [176, 22],
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [108, 146],
      knee: [142, 140],
      ankle: [174, 134],
      elbow: [84, 160],
      wrist: [106, 162]
    },
    'trx-ham-curl': {
      trxAnchor: [176, 22],
      head: [42, 152, -90],
      shoulder: [62, 156],
      hip: [106, 126],
      knee: [134, 104],
      ankle: [152, 138],
      elbow: [84, 160],
      wrist: [106, 162]
    }
  };
  return P[phase] || P['squat-top'];
}

function renderMotionArrow(arrowType) {
  if (!arrowType) return '';
  const c = '#34d399';
  switch (arrowType) {
    case 'up':
      return `<path d="M 184 142 L 184 74" stroke="${c}" stroke-width="2.5" stroke-linecap="round" marker-end="url(#arrow)" />`;
    case 'down':
      return `<path d="M 184 64 L 184 142" stroke="${c}" stroke-width="2.5" stroke-linecap="round" marker-end="url(#arrow)" />`;
    case 'arc-in':
      return `<path d="M 118 106 Q 108 68 82 64" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'curl':
      return `<path d="M 142 122 Q 158 92 138 66" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'skull-up':
      return `<path d="M 42 94 Q 52 64 74 62" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'kickback':
      return `<path d="M 102 126 Q 78 122 64 98" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'wings-up':
      return `<path d="M 52 108 Q 42 86 48 64" stroke="${c}" stroke-width="2.2" fill="none" marker-end="url(#arrow)" />
              <path d="M 158 108 Q 168 86 162 64" stroke="${c}" stroke-width="2.2" fill="none" marker-end="url(#arrow)" />`;
    case 'swing-up':
      return `<path d="M 88 144 Q 148 136 166 78" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'trx-push':
      return `<path d="M 164 126 L 188 104" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'trx-pull':
      return `<path d="M 62 96 L 88 64" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'row-up':
      return `<path d="M 146 136 L 122 86" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'pull-back':
      return `<path d="M 76 48 L 114 48" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'fwd-back':
      return `<path d="M 72 38 L 138 38" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'tuck-in':
      return `<path d="M 64 134 L 116 124" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'legs-up':
      return `<path d="M 178 134 Q 166 92 128 80" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'v-fold':
      return `<path d="M 54 114 Q 72 86 98 84" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'crunch':
      return `<path d="M 52 124 Q 72 98 96 112" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'knees-out':
      return `<path d="M 136 92 L 158 118" stroke="${c}" stroke-width="2.5" fill="none" marker-end="url(#arrow)" />`;
    case 'tap':
      return `<path d="M 152 154 Q 124 128 138 98" stroke="${c}" stroke-width="2.2" stroke-dasharray="3 2" fill="none" marker-end="url(#arrow)" />`;
    default:
      return '';
  }
}

function renderSingleFramePanel(frame, ex, panelX, panelWidth) {
  const p = getPhasePose(frame.phase);
  const m = ex.muscles;

  let g = `<g transform="translate(${panelX}, 10)">`;
  // Panel Card Frame
  g += `<rect width="${panelWidth}" height="186" rx="12" fill="#0d1322" stroke="#1e293b" stroke-width="1.2" />`;

  // Step Title Pill inside top of frame
  g += `<text x="12" y="21" fill="#e2e8f0" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="11" font-weight="700">${frame.label}</text>`;
  if (frame.note) {
    g += `<text x="${panelWidth - 12}" y="21" text-anchor="end" fill="#38bdf8" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="10" font-weight="700">${frame.note}</text>`;
  }

  // Floor line
  g += `<line x1="14" y1="168" x2="${panelWidth - 14}" y2="168" stroke="#334155" stroke-width="1.5" stroke-dasharray="4 4" />`;

  // Center the 210-wide coordinate space inside panelWidth
  const offsetX = Math.round((panelWidth - 205) / 2);
  g += `<g transform="translate(${offsetX}, 0)">`;

  // Optional Props Behind Body (Bench, Chair, Pull-up Bar, TRX Straps)
  if (p.bench) {
    const [bx, by, bw] = p.bench;
    g += `<rect x="${bx}" y="${by}" width="${bw}" height="9" rx="3" fill="#475569" stroke="#64748b" stroke-width="1" />
          <line x1="${bx + 12}" y1="${by + 9}" x2="${bx + 12}" y2="168" stroke="#475569" stroke-width="4.5" />
          <line x1="${bx + bw - 12}" y1="${by + 9}" x2="${bx + bw - 12}" y2="168" stroke="#475569" stroke-width="4.5" />`;
  }
  if (p.chair) {
    const [cx, cy] = p.chair;
    g += `<path d="M ${cx} 168 L ${cx} ${cy - 34} M ${cx} ${cy} L ${cx + 42} ${cy} L ${cx + 42} 168" stroke="#475569" stroke-width="5" stroke-linecap="round" fill="none" />`;
  }
  if (p.pullupBar) {
    g += `<line x1="48" y1="28" x2="162" y2="28" stroke="#facc15" stroke-width="4" stroke-linecap="round" />`;
  }
  if (p.trxAnchor) {
    const [ax, ay] = p.trxAnchor;
    const target = p.trxAnchor[0] > 100 ? p.ankle : p.wrist;
    g += `<circle cx="${ax}" cy="${ay}" r="4.5" fill="#facc15" />
          <line x1="${ax}" y1="${ay}" x2="${target[0]}" y2="${target[1]}" stroke="#facc15" stroke-width="2.2" stroke-dasharray="5 2" />`;
  }
  if (p.bandAnchor) {
    const [ax, ay] = p.bandAnchor;
    g += `<circle cx="${ax}" cy="${ay}" r="4" fill="#facc15" />
          <line x1="${ax}" y1="${ay}" x2="${p.wrist[0]}" y2="${p.wrist[1]}" stroke="#facc15" stroke-width="2.5" />`;
  }

  // Back Leg (if knee2/ankle2 defined)
  if (p.knee2 && p.ankle2) {
    g += `<g opacity="0.65">`;
    g += sculptedSegment(p.hip[0], p.hip[1], p.knee2[0], p.knee2[1], 7.5, 8.5, 5.5, '#1e293b', '#64748b');
    g += sculptedSegment(p.knee2[0], p.knee2[1], p.ankle2[0], p.ankle2[1], 5, 5.5, 3.5, '#1e293b', '#64748b');
    g += `</g>`;
  }

  // Sculpted Torso Volume (Hip to Shoulder)
  g += sculptedSegment(p.hip[0], p.hip[1], p.shoulder[0], p.shoulder[1], 9.5, 11.5, 10.5, '#334155', '#94a3b8');
  // Torso Muscle Overlays (Abs, Back, Chest)
  if (m.Back) {
    g += muscleGlow(p.hip[0], p.hip[1], p.shoulder[0], p.shoulder[1], 7, 9, 8.5, m.Back);
  }
  if (m.Abs) {
    const midX = (p.hip[0] * 0.6 + p.shoulder[0] * 0.4);
    const midY = (p.hip[1] * 0.6 + p.shoulder[1] * 0.4);
    g += muscleGlow(p.hip[0], p.hip[1], midX, midY, 6.5, 8, 6.5, m.Abs);
  }
  if (m.Chest) {
    const chestX = (p.shoulder[0] * 0.72 + p.hip[0] * 0.28);
    const chestY = (p.shoulder[1] * 0.72 + p.hip[1] * 0.28);
    g += jointCap(chestX, chestY, 7.5, m.Chest);
  }

  // Sculpted Thigh (Hip to Knee) + Quads / Hamstrings Glow
  g += sculptedSegment(p.hip[0], p.hip[1], p.knee[0], p.knee[1], 8.5, 9.5, 6, '#334155', '#94a3b8');
  if (m.Quads) {
    g += muscleGlow(p.hip[0], p.hip[1], p.knee[0], p.knee[1], 6, 7.5, 4.5, m.Quads);
  } else if (m.Hamstrings) {
    g += muscleGlow(p.hip[0], p.hip[1], p.knee[0], p.knee[1], 5.5, 7, 4.5, m.Hamstrings);
  }

  // Glutes Cap on Hip
  g += jointCap(p.hip[0], p.hip[1], 8, m.Glutes);

  // Sculpted Calf (Knee to Ankle) + Athletic Shoe
  g += sculptedSegment(p.knee[0], p.knee[1], p.ankle[0], p.ankle[1], 5.5, 6, 3.8, '#334155', '#94a3b8');
  g += `<ellipse cx="${(p.ankle[0] + 4).toFixed(1)}" cy="${p.ankle[1].toFixed(1)}" rx="6.5" ry="3.5" fill="#cbd5e1" />`;

  // Sculpted Upper Arm (Shoulder to Elbow) + Forearm (Elbow to Wrist)
  g += sculptedSegment(p.shoulder[0], p.shoulder[1], p.elbow[0], p.elbow[1], 6, 6.8, 4.8, '#334155', '#94a3b8');
  if (m.Biceps) {
    g += muscleGlow(p.shoulder[0], p.shoulder[1], p.elbow[0], p.elbow[1], 4.5, 6, 4, m.Biceps);
  } else if (m.Triceps) {
    g += muscleGlow(p.shoulder[0], p.shoulder[1], p.elbow[0], p.elbow[1], 4.5, 6, 4, m.Triceps);
  }
  g += sculptedSegment(p.elbow[0], p.elbow[1], p.wrist[0], p.wrist[1], 4.5, 4.8, 3.2, '#334155', '#94a3b8');

  // Second Arm if defined
  if (p.elbow2 && p.wrist2) {
    g += sculptedSegment(p.shoulder[0], p.shoulder[1], p.elbow2[0], p.elbow2[1], 5.5, 6.2, 4.5, '#334155', '#94a3b8');
    g += sculptedSegment(p.elbow2[0], p.elbow2[1], p.wrist2[0], p.wrist2[1], 4.2, 4.5, 3, '#334155', '#94a3b8');
  }

  // Deltoid Cap on Shoulder
  g += jointCap(p.shoulder[0], p.shoulder[1], 7, m.Shoulders);

  // Head
  g += drawHead(p.head[0], p.head[1], p.head[2] || 0);

  // Foreground Props (Dumbbells, Slam Ball, Ab Roller, Resistance Bands)
  if (p.dumbbell) g += drawDumbbell(p.dumbbell[0], p.dumbbell[1]);
  if (p.dumbbell2) g += drawDumbbell(p.dumbbell2[0], p.dumbbell2[1]);
  if (p.slamBall) g += drawSlamBall(p.slamBall[0], p.slamBall[1]);
  if (p.roller) {
    g += `<circle cx="${p.roller[0]}" cy="${p.roller[1]}" r="9" fill="#1e293b" stroke="#facc15" stroke-width="3" />`;
  }
  if (p.bandKnees) {
    const k2 = p.knee2 || [p.knee[0], p.knee[1] + 6];
    g += `<line x1="${p.knee[0]}" y1="${p.knee[1]}" x2="${k2[0]}" y2="${k2[1]}" stroke="#facc15" stroke-width="4" stroke-linecap="round" />`;
  }
  if (p.bandAnkles) {
    const a2 = p.ankle2 || [p.ankle[0] - 20, p.ankle[1]];
    g += `<line x1="${p.ankle[0]}" y1="${p.ankle[1] - 4}" x2="${a2[0]}" y2="${a2[1] - 4}" stroke="#facc15" stroke-width="3.5" stroke-linecap="round" />`;
  }

  // Motion Arrow inside frame
  g += renderMotionArrow(frame.arrow);

  g += `</g></g>`;
  return g;
}

function buildExerciseSVG(ex, spec) {
  const frames = spec.frames || [
    { label: '1. Setup', phase: 'squat-top' },
    { label: '2. Execution', phase: 'squat-low', arrow: 'up' }
  ];

  const numFrames = frames.length;
  const totalW = 680;
  const totalH = 248;
  const gap = 10;
  const sidePad = 12;
  const panelWidth = Math.floor((totalW - sidePad * 2 - gap * (numFrames - 1)) / numFrames);

  const panelsSvg = frames
    .map((frame, i) => {
      const x = sidePad + i * (panelWidth + gap);
      return renderSingleFramePanel(frame, ex, x, panelWidth);
    })
    .join('\n');

  const priMuscles = Object.entries(ex.muscles).filter(([, v]) => v === 'Pri').map(([k]) => k);
  const secMuscles = Object.entries(ex.muscles).filter(([, v]) => v === 'Sec').map(([k]) => k);

  const footerPills = [
    ...priMuscles.map(m => `<tspan fill="#f97316" font-weight="700">● ${m} (PRI)</tspan>`),
    ...secMuscles.map(m => `<tspan fill="#38bdf8" font-weight="600">  ○ ${m} (SEC)</tspan>`)
  ].join('  ');

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${totalW} ${totalH}" width="100%" height="100%" role="img" aria-label="${ex.name} multi-step exercise diagram">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
      <path d="M 0 1 L 10 5 L 0 9 z" fill="#34d399" />
    </marker>
  </defs>

  <!-- Minimalist Dark Canvas -->
  <rect width="${totalW}" height="${totalH}" rx="16" fill="#090d16" stroke="#1e293b" stroke-width="1.5" />

  <!-- Multi-Frame Motion Sequence Panels -->
  ${panelsSvg}

  <!-- Minimalist Footer Bar: Target Muscles & Equipment -->
  <text x="16" y="220" fill="#cbd5e1" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="11">
    ${footerPills}
  </text>
  <text x="${totalW - 16}" y="220" text-anchor="end" fill="#64748b" font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="10.5" font-weight="600">
    ${spec.badge} · Equip: ${ex.equipment} · Cat: ${ex.workoutCategory}
  </text>
</svg>`;
}

// ============================================================================
// 4. GENERATE FILES
// ============================================================================
fs.mkdirSync(diagramsDir, { recursive: true });

const exerciseEnrichments = {};
for (const ex of sheetData.exercises) {
  const spec = exerciseSpecs[ex.id];
  if (!spec) {
    throw new Error(`Missing enrichment spec for exercise: ${ex.id} (${ex.name})`);
  }

  const svgFilename = `${ex.id}.svg`;
  const svgContent = buildExerciseSVG(ex, spec);
  fs.writeFileSync(path.join(diagramsDir, svgFilename), svgContent, 'utf8');

  exerciseEnrichments[ex.id] = {
    summary: spec.summary,
    steps: spec.steps,
    formTip: spec.formTip,
    pose: spec.pose,
    equipVisual: spec.equip,
    badge: spec.badge,
    frameCount: spec.frames.length,
    diagram: `diagrams/${svgFilename}`
  };
}

const enrichmentsPayload = {
  version: '2.0.0',
  generatedAt: '2026-10-16',
  workoutTypes: workoutTypeEnrichments,
  exercises: exerciseEnrichments
};

fs.writeFileSync(enrichmentsPath, JSON.stringify(enrichmentsPayload, null, 2), 'utf8');
console.log(`Generated multi-frame sculpted diagrams for ${Object.keys(exerciseEnrichments).length} exercises.`);
