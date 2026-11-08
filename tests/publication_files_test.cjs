const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const {snapshot} = require('../.github/actions/publication-check/index.cjs');
const guard = path.resolve(__dirname, '../vendor/script-helpers/scripts/check_publication.sh');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'publication-test-'));
process.env.GITHUB_WORKSPACE = root;
const fake = path.join(root, 'scanner');
fs.writeFileSync(fake, '#!/bin/sh\nprintf "[]"\n', {mode: 0o700});
let serial = 0;
function fixture() {
  const dir = path.join(root, String(++serial));
  const stage = path.join(dir, 'stage');
  fs.mkdirSync(stage, {recursive: true});
  return {dir, stage};
}
function check(file, text, relative, cwd) {
  const result = cp.spawnSync('bash', [guard, ...(file ? ['--file', relative || file] : ['--stdin'])], {
    cwd: cwd || root, input: text || undefined, encoding: 'utf8',
    env: {...process.env, CI: 'true', GITHUB_ACTIONS: 'true', GITLEAKS_BIN: fake},
  });
  if (result.status !== 0) throw new Error('refused');
}
const input = (mode, paths, extra = {}) => ({mode, paths, includeHidden: false, ...extra});
test.after(() => fs.rmSync(root, {recursive: true, force: true}));

test('artifact snapshot preserves layout, excludes and hidden-file policy', async () => {
  const {dir, stage} = fixture();
  fs.mkdirSync(path.join(dir, 'build/sub'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'build/sub/package.txt'), 'ordinary package');
  fs.writeFileSync(path.join(dir, 'build/.config'), 'ordinary configuration');
  fs.writeFileSync(path.join(dir, 'build/omit.txt'), 'excluded');
  const result = await snapshot(input('artifact', `${dir}/build/\n!${dir}/build/omit.txt`), stage, check);
  assert.equal(fs.readFileSync(path.join(result.paths, 'sub/package.txt'), 'utf8'), 'ordinary package');
  assert.equal(fs.existsSync(path.join(result.paths, '.config')), false);
  assert.equal(fs.existsSync(path.join(result.paths, 'omit.txt')), false);
  fs.writeFileSync(path.join(dir, 'build/sub/package.txt'), 'changed after validation');
  assert.equal(fs.readFileSync(path.join(result.paths, 'sub/package.txt'), 'utf8'), 'ordinary package');
});

test('renamed scanner JSON never reaches the publisher', async () => {
  const {dir, stage} = fixture();
  const file = path.join(dir, 'data.json');
  fs.writeFileSync(file, JSON.stringify([{['Rule'+'ID']: 'fixture', ['Sec'+'ret']: 'synthetic', ['Fi'+'le']: 'fixture.txt', ['Start'+'Line']: 1}]));
  let published = false;
  await assert.rejects(async () => { await snapshot(input('artifact', file), stage, check); published = true; });
  assert.equal(published, false);
});

test('known empty report names and symlink aliases are refused', async () => {
  for (const alias of [false, true]) {
    const {dir, stage} = fixture();
    const file = path.join(dir, 'gitleaks'+'-report.json');
    fs.writeFileSync(file, '[]');
    const selected = alias ? path.join(dir, 'ordinary.json') : file;
    if (alias) fs.symlinkSync(file, selected);
    await assert.rejects(snapshot(input('artifact', selected), stage, check));
  }
});

test('PII filenames and nested archive members are refused', async () => {
  for (const archive of [false, true]) {
    const {dir, stage} = fixture();
    const file = path.join(dir, archive ? 'package.zip' : 'person'+'@customer.tld.txt');
    if (archive) {
      const result = cp.spawnSync('python3', ['-c', 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("person"+"@customer.tld.txt", "ordinary"); z.close()', file]);
      assert.equal(result.status, 0);
    } else fs.writeFileSync(file, '');
    await assert.rejects(snapshot(input('artifact', file), stage, check));
  }
});

test('ordinary empty JSON, hidden files and release notes remain publishable', async () => {
  const {dir, stage} = fixture();
  const file = path.join(dir, '.data.json');
  const notes = path.join(dir, 'notes.md');
  fs.writeFileSync(file, '[]'); fs.writeFileSync(notes, 'Release fixes.');
  const result = await snapshot(input('artifact', file, {includeHidden: true, bodyPath: notes}), stage, check);
  assert.equal(fs.readFileSync(path.join(result.paths, '.data.json'), 'utf8'), '[]');
  assert.equal(fs.readFileSync(result.bodyPath, 'utf8'), 'Release fixes.');
});

test('release brace and CSV patterns keep exact asset names and order', async () => {
  const {dir, stage} = fixture();
  for (const name of ['a.txt', 'b.txt', 'literal[1],item.txt']) fs.writeFileSync(path.join(dir, name), name);
  const result = await snapshot(input('release', '{a,b}.txt\nliteral*.txt', {workingDirectory: dir, failUnmatched: true}), stage, check);
  const folders = result.paths.split('\n').map(pattern => path.dirname(pattern));
  assert.equal(folders.length, 3);
  const names = folders.map(folder => fs.readdirSync(folder)[0]);
  assert.deepEqual(new Set(names), new Set(['a.txt', 'b.txt', 'literal[1],item.txt']));
});

test('unmatched release patterns fail closed when requested', async () => {
  const {dir, stage} = fixture();
  await assert.rejects(snapshot(input('release', 'missing/*', {workingDirectory: dir, failUnmatched: true}), stage, check));
});

test('release notes and artifact metadata are checked without asset files', async () => {
  for (const metadata of [false, true]) {
    const {dir, stage} = fixture();
    const body = path.join(dir, 'notes.md');
    fs.writeFileSync(body, JSON.stringify({['to'+'ol']: 'fox'+'guard', ['find'+'ings']: [], ['finding_'+'counts']: {total: 0}}));
    const extra = metadata ? {metadata: 'person'+'@customer.tld'} : {bodyPath: body};
    await assert.rejects(snapshot(input('release', '', extra), stage, check));
  }
});

test('Git metadata and inspection limits refuse publication', async () => {
  for (const large of [false, true]) {
    const {dir, stage} = fixture();
    const file = path.join(dir, large ? 'large.bin' : '.git/config');
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(file, '');
    if (large) fs.truncateSync(file, 64 * 1024 * 1024 + 1);
    await assert.rejects(snapshot(input('artifact', file, {includeHidden: true}), stage, check));
  }
});
