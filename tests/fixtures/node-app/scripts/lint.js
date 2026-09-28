// A lint that really reads the source, so the leg proves the step ran rather
// than that a script called `lint` exists. It also leaves a marker, which the
// preset's extra_command checks: a step that silently stopped running looks
// exactly like one that passed.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src', 'total.js'), 'utf8');

if (source.includes('\t')) {
  console.error('lint: tabs in src/total.js');
  process.exit(1);
}

fs.mkdirSync(path.join(root, '.marks'), { recursive: true });
fs.writeFileSync(path.join(root, '.marks', 'lint'), 'ran\n');
console.log('lint: ok');
