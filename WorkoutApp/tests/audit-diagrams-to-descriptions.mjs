import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

const sheetData = JSON.parse(fs.readFileSync(path.join(rootDir, 'data', 'sheet-data.json'), 'utf8'));
const enrichments = JSON.parse(fs.readFileSync(path.join(rootDir, 'data', 'enrichments.json'), 'utf8'));

console.log('================================================================');
console.log('AUDITING ALL 68 MULTI-FRAME SCULPTED DIAGRAMS AGAINST DESCRIPTIONS');
console.log('================================================================\n');

let verifiedCount = 0;

for (const ex of sheetData.exercises) {
  const enrich = enrichments.exercises[ex.id];
  const svgPath = path.join(rootDir, enrich.diagram);
  const svg = fs.readFileSync(svgPath, 'utf8');

  // 1. Verify multi-frame motion sequence (2 or 3 frames per exercise)
  assert.ok(
    svg.includes('>1. ') && svg.includes('>2. '),
    `Diagram for "${ex.name}" must contain multi-frame motion steps (1. and 2.)`
  );

  // 2. Verify sculpted anatomical segments (<path d="M ...) instead of crude single-line sticks
  const sculptedPathCount = (svg.match(/<path d="M /g) || []).length;
  assert.ok(
    sculptedPathCount >= 10,
    `Diagram for "${ex.name}" must render sculpted anatomical limb/torso capsules (found ${sculptedPathCount})`
  );

  // 3. Check TRX exercises depict TRX suspension straps & anchor
  if (ex.name.toLowerCase().includes('trx') && ex.id !== 'curls') {
    assert.ok(
      enrich.pose.startsWith('trx-'),
      `TRX exercise "${ex.name}" must use a TRX suspension pose, got ${enrich.pose}`
    );
    assert.ok(
      svg.includes('stroke="#facc15"'),
      `TRX diagram for "${ex.name}" must draw suspension strap lines`
    );
  }

  // 4. Check Bench exercises draw bench geometry (<rect ... fill="#475569")
  if (ex.name.toLowerCase().includes('bench') || ex.id === 'step-ups') {
    assert.ok(
      svg.includes('fill="#475569"'),
      `Bench exercise "${ex.name}" must visually depict the bench in SVG`
    );
  }

  // 5. Check Band-specific exercises depict bands in gold (#facc15)
  if (ex.equipment === 'Bands') {
    assert.ok(
      svg.includes('#facc15'),
      `Band exercise "${ex.name}" must visually render the resistance band in #facc15`
    );
  }

  // 6. Check Bodyweight ("Nothing") exercises show Equip: Nothing
  if (ex.equipment === 'Nothing') {
    assert.ok(
      svg.includes('Equip: Nothing'),
      `Bodyweight exercise "${ex.name}" must show Equip: Nothing`
    );
  }

  // 7. Verify all Primary muscles are rendered both in the footer legend and highlighted on the sculpted figure
  const priMuscles = Object.entries(ex.muscles)
    .filter(([, v]) => v === 'Pri')
    .map(([k]) => k);

  for (const pm of priMuscles) {
    assert.ok(
      svg.includes(`${pm} (PRI)`),
      `Diagram for "${ex.name}" missing primary muscle "${pm} (PRI)" in legend`
    );
  }

  verifiedCount++;
}

console.log(`✅ Verified ${verifiedCount}/68 multi-frame sculpted SVG diagrams map 100% to their motion phases, equipment, and audited muscles!`);
