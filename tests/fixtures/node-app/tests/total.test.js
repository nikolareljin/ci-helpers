const test = require('node:test');
const assert = require('node:assert');
const total = require('../src/total');
const fs = require('fs');
const path = require('path');

test('adds the amounts', () => {
  assert.equal(total([1, 2, 39]), 42);
});

test('an empty basket is zero', () => {
  assert.equal(total([]), 0);
});

// The marker the preset's extra_command looks for.
fs.mkdirSync(path.join(__dirname, '..', '.marks'), { recursive: true });
fs.writeFileSync(path.join(__dirname, '..', '.marks', 'test'), 'ran\n');
