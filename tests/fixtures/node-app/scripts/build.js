// Writes a build output and a marker. `npm run build` is the one default that
// is not guarded by --if-present, so this is also what proves the build step
// is reached at all.
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const total = require(path.join(root, 'src', 'total.js'));

fs.mkdirSync(path.join(root, 'dist'), { recursive: true });
fs.writeFileSync(path.join(root, 'dist', 'bundle.js'), `module.exports = ${total([1, 2])};\n`);

fs.mkdirSync(path.join(root, '.marks'), { recursive: true });
fs.writeFileSync(path.join(root, '.marks', 'build'), 'ran\n');
console.log('build: wrote dist/bundle.js');
