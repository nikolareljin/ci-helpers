const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const {snapshot, checkerEnv} = require('../.github/actions/publication-check/index.cjs');
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
    // The action's own environment for the checker, built from a CI one.
    env: checkerEnv({...process.env, CI: 'true', GITHUB_ACTIONS: 'true'}, fake),
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

test('ordinary artifact uploads cannot publish SARIF', async () => {
  const {dir, stage} = fixture();
  const file = path.join(dir, 'data.json');
  fs.writeFileSync(file, JSON.stringify({version: '2.1.0', runs: []}));
  await assert.rejects(snapshot(input('artifact', file), stage, check));
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
    if (large) fs.truncateSync(file, 2048 * 1024 * 1024 + 1);
    await assert.rejects(snapshot(input('artifact', file, {includeHidden: true}), stage, check));
  }
});

test('a Tauri Linux bundle with an AppImage above 64 MiB is publishable', async () => {
  const {dir, stage} = fixture();
  const out = path.join(dir, 'out');
  fs.mkdirSync(out);
  // An ELF header, then 77 MiB of zeros: the size of a real Tauri AppImage.
  const appimage = path.join(out, 'App_1.0.0_amd64.AppImage');
  const fd = fs.openSync(appimage, 'w');
  fs.writeSync(fd, Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]));
  fs.ftruncateSync(fd, 77 * 1024 * 1024);
  fs.closeSync(fd);
  fs.writeFileSync(path.join(out, 'App_1.0.0_amd64.deb'), '!<arch>\ndebian-binary   0           0     0     100644  4         `\n2.0\n');
  fs.writeFileSync(path.join(out, 'App-1.0.0-1.x86_64.rpm'), Buffer.from([0xed, 0xab, 0xee, 0xdb, 3, 0, 0, 0]));
  const result = await snapshot(input('artifact', `${out}/`), stage, check);
  assert.equal(fs.statSync(path.join(result.paths, 'App_1.0.0_amd64.AppImage')).size, 77 * 1024 * 1024);
  assert.ok(fs.existsSync(path.join(result.paths, 'App_1.0.0_amd64.deb')));
  assert.ok(fs.existsSync(path.join(result.paths, 'App-1.0.0-1.x86_64.rpm')));
});

test('a file the checker cannot fully inspect is refused, in CI too', async () => {
  const env = checkerEnv({CI: 'true', GITHUB_ACTIONS: 'true', PATH: '/bin'}, fake);
  assert.equal(env.CI, undefined);
  assert.equal(env.GITHUB_ACTIONS, undefined);
  assert.equal(env.GITLEAKS_BIN, fake);
  // 70 MiB that is not an executable: streamed, not decoded, so incomplete.
  const {dir, stage} = fixture();
  const file = path.join(dir, 'data.bin');
  const fd = fs.openSync(file, 'w');
  fs.writeSync(fd, Buffer.from('PK\x03\x04 not an archive'));
  fs.ftruncateSync(fd, 70 * 1024 * 1024);
  fs.closeSync(fd);
  await assert.rejects(snapshot(input('artifact', file), stage, check));
});

test('temporary storage stays private when caller TMPDIR is unusable', () => {
  const {dir} = fixture();
  const workspace = path.join(dir, 'workspace'), runner = path.join(dir, 'runner');
  fs.mkdirSync(workspace); fs.mkdirSync(runner);
  const file = path.join(workspace, 'ordinary.txt');
  fs.writeFileSync(file, 'ordinary package');
  const state = path.join(dir, 'state'), output = path.join(dir, 'output');
  fs.writeFileSync(state, ''); fs.writeFileSync(output, '');
  const action = path.resolve(__dirname, '../.github/actions/publication-check');
  const env = {...process.env, CI: 'true', GITHUB_ACTIONS: 'true', GITHUB_WORKSPACE: workspace,
    RUNNER_TEMP: runner, GITHUB_STATE: state, GITHUB_OUTPUT: output, GITLEAKS_BIN: fake,
    INPUT_MODE: 'artifact', INPUT_PATHS: file, INPUT_METADATA: '', INPUT_BODY_PATH: '',
    TMPDIR: path.join(dir, 'missing/tmp')};
  try {
    const result = cp.spawnSync(process.execPath, [path.join(action, 'index.cjs')], {cwd: workspace, env, encoding: 'utf8'});
    assert.equal(result.status, 0);
    assert.equal(result.stdout + result.stderr, '');
    assert.deepEqual(fs.readdirSync(workspace), ['ordinary.txt']);
  } finally {
    const stage = fs.readFileSync(state, 'utf8').trim().split('=')[1];
    if (stage) cp.spawnSync(process.execPath, [path.join(action, 'cleanup.cjs')], {env: {...env, STATE_publication_stage: stage}});
  }
});


test('renamed private diagnostic logs cannot reach the uploader', async () => {
  const {dir, stage} = fixture();
  const file = path.join(dir, 'ordinary.log');
  fs.writeFileSync(file, 'SCRIPT_HELPERS_PRIVATE_'+'SECURITY_REPORT_V1\nordinary diagnostics');
  let published = false;
  await assert.rejects(async () => { await snapshot(input('artifact', file), stage, check); published = true; });
  assert.equal(published, false);
});

test('ambiguous runner storage cannot change uploader selection', () => {
  const {dir} = fixture();
  const workspace = path.join(dir, 'workspace'), runner = path.join(dir, 'runner,storage');
  fs.mkdirSync(workspace); fs.mkdirSync(runner);
  const file = path.join(workspace, 'ordinary.txt'); fs.writeFileSync(file, 'ordinary package');
  const state = path.join(dir, 'state'), output = path.join(dir, 'output');
  fs.writeFileSync(state, ''); fs.writeFileSync(output, '');
  const action = path.resolve(__dirname, '../.github/actions/publication-check');
  const env = {...process.env, CI: 'true', GITHUB_ACTIONS: 'true', GITHUB_WORKSPACE: workspace,
    RUNNER_TEMP: runner, GITHUB_STATE: state, GITHUB_OUTPUT: output, GITLEAKS_BIN: fake,
    INPUT_MODE: 'release', INPUT_PATHS: file, INPUT_METADATA: '', INPUT_BODY_PATH: ''};
  try {
    const result = cp.spawnSync(process.execPath, [path.join(action, 'index.cjs')], {cwd: workspace, env, encoding: 'utf8'});
    assert.equal(result.status, 1);
    assert.equal(fs.readFileSync(output, 'utf8'), '');
  } finally {
    const stage = fs.readFileSync(state, 'utf8').trim().split('=')[1];
    if (stage) cp.spawnSync(process.execPath, [path.join(action, 'cleanup.cjs')], {env: {...env, STATE_publication_stage: stage}});
  }
});

test('a refusal is named by file and fixed category, never by matched value', () => {
  const {refusalCategory, commandText} = require('../.github/actions/publication-check/index.cjs');
  const block = what => `[sensitive] BLOCK app.bin:12: ${what} (ab***cd)\n`;
  assert.equal(refusalCategory(block('an email address'), 1), 'email-like string');
  assert.equal(refusalCategory(block('a phone number'), 1), 'phone-number-like string');
  assert.equal(refusalCategory(block('a payment card number'), 1), 'personal identifier');
  assert.equal(refusalCategory(block("this machine's home directory"), 1), "this runner's home directory path");
  assert.equal(refusalCategory(block("this machine's hostname"), 1), "this runner's host or network identifier");
  assert.equal(refusalCategory('[sensitive] BLOCK gitleaks found 1 credential(s) in a.txt\n', 1), 'credential (Gitleaks)');
  assert.equal(refusalCategory('Traceback (most recent call last):\nTypeError: x\n', 1), 'the checker failed with an internal error');
  assert.equal(refusalCategory('WARNING: security check incomplete: a: could not fully check: no zstd decoder\n', 3), 'file not fully inspected');
  assert.equal(refusalCategory('Security check failed.\nPublication refused: scanner results must stay local. Remove them\n', 1),
    'scanner output, or a credential or personal data inside an archive member');
  assert.equal(refusalCategory('Security check failed.\n', 2), 'file could not be inspected');
  assert.equal(refusalCategory('', 1), 'unclassified refusal');
  for (const category of ['email-like string', 'file not fully inspected']) {
    assert.doesNotMatch(category, /ab\*\*\*cd|\d/);
  }
  assert.equal(commandText('a%b\r\n::error::x'), 'a%25b%0D%0A::error::x');
});

test('the name is checked before the content, and each check carries its label', async () => {
  const {dir, stage} = fixture();
  fs.mkdirSync(path.join(dir, 'out/sub'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'out/sub/app.deb'), 'package');
  const calls = [];
  await snapshot(input('artifact', `${dir}/out/`), stage, (file, text, relative, cwd, label) => calls.push([file ? 'file' : 'text', label]));
  assert.deepEqual(calls, [['text', 'a file name'], ['file', path.join('sub', 'app.deb')], ['file', path.join('sub', 'app.deb')]]);
  const refused = [];
  await assert.rejects(snapshot(input('artifact', `${dir}/out/`), fixture().stage, (file, text, relative, cwd, label) => {
    refused.push(label);
    if (file) throw new Error('refused');
  }));
  assert.deepEqual(refused, ['a file name', path.join('sub', 'app.deb')]);
});

test('every refusal reason the action throws may be shown, and nothing else', () => {
  const {FIXED_REASONS} = require('../.github/actions/publication-check/index.cjs');
  const source = fs.readFileSync(path.resolve(__dirname, '../.github/actions/publication-check/index.cjs'), 'utf8');
  const thrown = new Set([...source.matchAll(/new Error\('([^']*)'\)/g)].map(match => match[1]));
  thrown.delete('publication refused');
  assert.deepEqual([...FIXED_REASONS].sort(), [...thrown].sort());
  for (const reason of FIXED_REASONS) assert.match(reason, /^[A-Za-z ]+$/);
});
