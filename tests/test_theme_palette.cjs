// Extracts the palette parser and hue helper from BarWidget.qml and evaluates
// them as plain JavaScript against synthetic input. This checks the parsing and
// the hue maths; it does not render QML.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const widget = fs.readFileSync('BarWidget.qml', 'utf8');
const ctx = {};
vm.createContext(ctx);

// Slice each function out by brace-matching from its signature, so the test
// does not depend on how the QML happens to be indented.
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
for (const name of ['parsePalette', 'hexHue']) vm.runInContext(extract(name), ctx);

test('parses quoted and bare hex, ignores everything else', () => {
  const p = ctx.parsePalette([
    'mode = "dark"',
    'accent = "#7d82d9"',
    'orange = #eb8b54',
    '  green   =  "#92a593"  # trailing comment',
    'not_a_colour = "sans-serif"',
    '',
  ].join('\n'));
  assert.equal(p.accent, '#7d82d9');
  assert.equal(p.orange, '#eb8b54');
  assert.equal(p.green, '#92a593');
  assert.equal(p.mode, undefined);
  assert.equal(p.not_a_colour, undefined);
});

test('an empty or missing file is an empty palette, not a crash', () => {
  // Object.keys, not deepEqual: the parser builds its object inside the vm
  // context, so it does not share this realm's Object.prototype.
  for (const input of ['', null, undefined, 'nothing = here']) {
    assert.equal(Object.keys(ctx.parsePalette(input)).length, 0);
  }
});

test('hue of the primaries', () => {
  assert.equal(ctx.hexHue('#ff0000'), 0);
  assert.ok(Math.abs(ctx.hexHue('#00ff00') - 1 / 3) < 1e-9);
  assert.ok(Math.abs(ctx.hexHue('#0000ff') - 2 / 3) < 1e-9);
});

test('hue is never negative for magenta, which wraps past red', () => {
  const h = ctx.hexHue('#ff00ff');
  assert.ok(h >= 0 && h <= 1, 'hue out of range: ' + h);
  assert.ok(Math.abs(h - 5 / 6) < 1e-9);
});

test('a grey has no hue to borrow', () => {
  assert.equal(ctx.hexHue('#808080'), -1);
  assert.equal(ctx.hexHue('#000000'), -1);
  assert.equal(ctx.hexHue('#ffffff'), -1);
});

test('every themed() lane names a fallback key, for themes missing one', () => {
  const calls = [...widget.matchAll(/themed\(\s*base\w+,\s*"(\w+)"(?:,\s*"(\w+)")?/g)];
  assert.ok(calls.length >= 13, 'expected the full ramp, saw ' + calls.length);
  for (const c of calls) {
    assert.ok(c[2], 'themed(..., "' + c[1] + '") has no fallback key');
  }
});
