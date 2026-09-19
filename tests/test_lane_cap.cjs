// The strip's ceiling is a physical allowance per visible lane, not a pixel
// count: one inch of desk per lane means the same strip on a 27" 4K and on a
// 49" ultrawide. Extracts the pure helper from BarWidget.qml and evaluates it
// as plain JavaScript; it does not render QML.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const widget = fs.readFileSync('BarWidget.qml', 'utf8');
const ctx = {};
vm.createContext(ctx);

function extract(name) {
  const start = widget.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'expected to find function ' + name);
  let depth = 0, i = widget.indexOf('{', start);
  assert.ok(i > 0, 'no body for ' + name);
  for (let j = i; j < widget.length; j++) {
    if (widget[j] === '{') depth++;
    else if (widget[j] === '}') { depth--; if (depth === 0) return widget.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces in ' + name);
}
vm.runInContext(extract('laneCapPx'), ctx);

test('one allowance per visible lane', () => {
  // 1.0 in per lane at 96 dpi: four lanes is four inches.
  assert.equal(ctx.laneCapPx(4, 10, 96), 384);
  assert.equal(ctx.laneCapPx(3, 10, 96), 288);
  assert.equal(ctx.laneCapPx(1, 10, 96), 96);
});

test('the allowance scales with the setting and the screen', () => {
  assert.equal(ctx.laneCapPx(2, 20, 96), 384);   // 2.0 in per lane
  assert.equal(ctx.laneCapPx(2, 5, 96), 96);     // 0.5 in per lane
  // A denser screen gets more pixels for the same physical width.
  assert.equal(ctx.laneCapPx(4, 10, 192), 768);
});

test('an unusable density means no cap, never a zero-width strip', () => {
  for (const dpi of [0, -5, NaN, Infinity, undefined, null, 'x']) {
    assert.equal(ctx.laneCapPx(4, 10, dpi), Infinity, 'dpi ' + String(dpi));
  }
});

test('a missing or absurd lane count still yields one lane, not none', () => {
  assert.equal(ctx.laneCapPx(0, 10, 96), 96);
  assert.equal(ctx.laneCapPx(-3, 10, 96), 96);
  assert.equal(ctx.laneCapPx(NaN, 10, 96), 96);
  assert.equal(ctx.laneCapPx(2.7, 10, 96), 192);  // floored, not rounded up
});

test('the cap is actually wired into sizing, not just defined', () => {
  // measureStretch must clamp by it, and the floor must win over the cap.
  const m = widget.slice(widget.indexOf('function measureStretch('));
  assert.match(m, /laneCapPx\(laneCount, maxPerLaneTenths, pixelsPerInch\(\)\)/);
  assert.match(m, /Math\.max\(Style\.spaceReal\(minWidthForCells\), Math\.min\(maximum, laneCap\)\)/);
  // And a stretching neighbour must be able to read the ceiling we refuse,
  // or the room the cap frees just sits blank.
  assert.match(widget, /readonly property int stretchMaxWidth:/);
  assert.match(widget, /readonly property int stretchMinWidth:/);
});
