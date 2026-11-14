const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');

const MAX_FILES = 2000;
// The shared checker's own ceiling (check_scan_output.sh --max-mib 2048) and
// GitHub's release asset limit. Above 64 MiB the checker streams the file and
// decodes executables; a file it cannot fully check is refused (checkerEnv).
const MAX_BYTES = 2048 * 1024 * 1024;

// The checker runs blocking: with CI or GITHUB_ACTIONS set it turns "could
// not fully check" into a warning and exit 0. Without them it exits 3, and
// any nonzero exit refuses the publication. Its output goes to the private
// log only, so nothing local-only reaches the job log.
function checkerEnv(base, gitleaks) {
  const env = {...base, GITLEAKS_BIN: gitleaks};
  delete env.CI;
  delete env.GITHUB_ACTIONS;
  return env;
}
const helpers = path.resolve(__dirname, '../../../vendor/script-helpers');
const bashPath = value => process.platform === 'win32' ? value.replaceAll('\\', '/') : value;

function findBash() {
  const candidates = process.platform === 'win32'
    ? [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], path.join(process.env.LOCALAPPDATA || '', 'Programs')]
      .filter(Boolean).map(root => path.join(root, 'Git/bin/bash.exe'))
    : ['/bin/bash', '/usr/bin/bash'];
  for (const folder of (process.env.PATH || '').split(path.delimiter)) {
    candidates.push(path.resolve(folder, '../bin/bash.exe'));
    candidates.push(path.join(folder, process.platform === 'win32' ? 'bash.exe' : 'bash'));
  }
  return candidates.find(file => fs.existsSync(file) && !/[\\/]Windows[\\/]System32[\\/]bash\.exe$/i.test(file));
}

function npmCli() {
  const candidates = new Set();
  for (const folder of (process.env.PATH || '').split(path.delimiter)) {
    candidates.add(path.join(folder, 'node_modules/npm/bin/npm-cli.js'));
    candidates.add(path.resolve(folder, '../lib/node_modules/npm/bin/npm-cli.js'));
    try { candidates.add(fs.realpathSync(path.join(folder, 'npm'))); } catch {}
  }
  const usable = [];
  for (const file of candidates) {
    try {
      if (path.basename(file) !== 'npm-cli.js') continue;
      const version = Number(JSON.parse(fs.readFileSync(path.resolve(path.dirname(file), '../package.json'))).version.split('.')[0]);
      if (version >= 9) usable.push({file, version});
    } catch {}
  }
  return usable.sort((left, right) => right.version - left.version)[0]?.file;
}

function isGitMetadata(file) {
  if (file.split(/[\\/]/).some(part => part.toLowerCase() === '.git')) return true;
  for (let folder = path.dirname(file); ; folder = path.dirname(folder)) {
    if (['HEAD', 'objects', 'config'].every(name => fs.existsSync(path.join(folder, name)))) return true;
    if (path.dirname(folder) === folder) return false;
  }
}

function allocateStage() {
  if (!process.env.RUNNER_TEMP) throw new Error('runner storage unavailable');
  const root = fs.realpathSync(process.env.RUNNER_TEMP);
  if (/[\r\n*?,\[\]{}]/.test(root) || /[+@!]\(/.test(root) || (process.platform !== 'win32' && root.includes('\\'))) throw new Error('ambiguous runner storage');
  const workspace = fs.realpathSync(process.env.GITHUB_WORKSPACE || process.cwd());
  const relative = path.relative(workspace, root);
  if (relative === '' || (!relative.startsWith('..' + path.sep) && !path.isAbsolute(relative))) throw new Error('unsafe runner storage');
  for (let folder = root; ; folder = path.dirname(folder)) {
    if (fs.existsSync(path.join(folder, '.git')) || isGitMetadata(path.join(folder, 'candidate'))) throw new Error('Git storage refused');
    if (path.dirname(folder) === folder) break;
  }
  const stage = fs.mkdtempSync(path.join(root, 'publication-'));
  fs.chmodSync(stage, 0o700);
  return stage;
}

function releasePatterns(text) {
  const result = [];
  for (const line of text.split(/\r?\n/)) {
    let braces = 0, start = 0;
    for (let index = 0; index <= line.length; index++) {
      if (line[index] === '{') braces++;
      if (line[index] === '}') braces--;
      if (index === line.length || (line[index] === ',' && braces === 0)) {
        const part = line.slice(start, index).trim();
        if (part) result.push(part);
        start = index + 1;
      }
    }
  }
  return result;
}

function normalizeReleasePattern(pattern) {
  if (pattern === '~') pattern = os.homedir();
  else if (pattern.startsWith('~/') || pattern.startsWith('~\\')) pattern = path.join(os.homedir(), pattern.slice(2));
  return process.platform === 'win32' ? pattern.replaceAll('\\', '/') : pattern;
}

function artifactRoot(searchPaths, files) {
  if (files.length === 1 && searchPaths.length === 1 && searchPaths[0] === files[0]) return path.dirname(files[0]);
  let common = searchPaths[0];
  if (!common) throw new Error('search root unavailable');
  for (const candidate of searchPaths.slice(1)) {
    while (candidate !== common && !candidate.startsWith(common.endsWith(path.sep) ? common : common + path.sep)) {
      const parent = path.dirname(common);
      if (parent === common) break;
      common = parent;
    }
  }
  return common;
}

async function selectFiles(input) {
  const files = [], seen = new Set();
  const add = file => {
    if (!fs.statSync(file).isFile()) return;
    const absolute = path.resolve(file);
    if (!seen.has(absolute)) { seen.add(absolute); files.push(absolute); }
    if (files.length > MAX_FILES) throw new Error('inspection budget exceeded');
  };
  if (input.mode === 'artifact') {
    const glob = await import('@actions/glob');
    const excluded = path.join(process.env.GITHUB_WORKSPACE || process.cwd(), '.ci-helpers-publication', '**').replaceAll('\\', '/');
    const globber = await glob.create(input.paths + '\n!' + excluded, {
      followSymbolicLinks: true, implicitDescendants: true, omitBrokenSymbolicLinks: true,
      excludeHiddenFiles: !input.includeHidden,
    });
    for await (const file of globber.globGenerator()) add(file);
    return {files, root: files.length ? artifactRoot(globber.getSearchPaths(), files) : process.cwd()};
  }
  if (input.mode !== 'release') throw new Error('unknown publication mode');
  const glob = await import('glob');
  for (const pattern of releasePatterns(input.paths)) {
    let matched = false;
    for (const file of glob.globIterateSync(normalizeReleasePattern(pattern), {cwd: input.workingDirectory || undefined, dot: true, absolute: false})) {
      const full = input.workingDirectory && !path.isAbsolute(file) ? path.join(input.workingDirectory, file) : file;
      if (fs.statSync(full).isFile()) { matched = true; add(full); }
    }
    if (!matched && input.failUnmatched) throw new Error('unmatched publication pattern');
  }
  return {files, root: ''};
}

// Refusal categories for the job log. Each is a fixed string chosen from the
// checker's private output; no matched value, count or snippet is shown.
const CATEGORIES = [
  [/Traceback \(most recent call last\)/, 'the checker failed with an internal error'],
  [/^\[sensitive\] BLOCK gitleaks found/m, 'credential (Gitleaks)'],
  [/^\[sensitive\] BLOCK .*: an email address/m, 'email-like string'],
  [/^\[sensitive\] BLOCK .*: a phone number/m, 'phone-number-like string'],
  [/^\[sensitive\] BLOCK .*: a (?:US social security|payment card) number/m, 'personal identifier'],
  [/^\[sensitive\] BLOCK .*: this machine's home directory/m, "this runner's home directory path"],
  [/^\[sensitive\] BLOCK .*: this machine's /m, "this runner's host or network identifier"],
  [/^\[sensitive\] BLOCK /m, 'personal term or identifier'],
  [/could not fully check: /, 'file not fully inspected'],
  [/^Publication refused: scanner results must stay local/m, 'scanner output, or a credential or personal data inside an archive member'],
];

function refusalCategory(text, status) {
  for (const [pattern, category] of CATEGORIES) if (pattern.test(text)) return category;
  return status === 2 ? 'file could not be inspected' : 'unclassified refusal';
}

// check_publication.sh keeps its checkers' output to itself, so a refusal is
// classified by running the two checkers again. Their output stays in memory.
function diagnose(runChecker) {
  const run = (script, extra = []) => runChecker(script, extra, {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
  const scan = run('check_scan_output.sh');
  if (scan.status !== 0) return refusalCategory(`${scan.stdout || ''}${scan.stderr || ''}`, scan.status);
  const sensitive = run('check_sensitive.sh', ['--no-inline-allow']);
  return refusalCategory(`${sensitive.stdout || ''}${sensitive.stderr || ''}`, sensitive.status);
}

// This file's own refusal reasons. Each is a fixed string, so the job log may
// show it when no file check is to blame (a system error is never shown).
const FIXED_REASONS = new Set(['ambiguous runner storage', 'credential scanner unavailable',
  'dependency installation failed', 'Git Bash unavailable', 'Git storage refused', 'inspection budget exceeded',
  'npm unavailable', 'output storage unavailable', 'publication name collision', 'runner storage unavailable',
  'search root unavailable', 'state storage unavailable', 'uninspectable publication file', 'uninspectable release notes',
  'unknown publication mode', 'unmatched publication pattern', 'unsafe publication name', 'unsafe runner storage']);

// A label safe for a workflow command: no newline, no command escape.
function commandText(value) {
  return String(value).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
}

async function snapshot(input, stage, check) {
  if (input.metadata) check(null, input.metadata, undefined, undefined, 'artifact or release metadata');
  const selected = await selectFiles(input);
  const payload = path.join(stage, 'payload');
  fs.mkdirSync(payload, {mode: 0o700});
  const outputs = [], names = new Set();
  for (const [index, source] of selected.files.entries()) {
    if (isGitMetadata(fs.realpathSync(source)) || fs.statSync(source).size > MAX_BYTES) throw new Error('uninspectable publication file');
    const relative = input.mode === 'artifact' ? path.relative(selected.root, source) : path.basename(source);
    if (!relative || path.isAbsolute(relative) || relative === '..' || relative.startsWith('..' + path.sep)) throw new Error('unsafe publication name');
    const nameKey = relative.toLowerCase();
    if (names.has(nameKey)) throw new Error('publication name collision');
    names.add(nameKey);
    // The name first: once it is clear, a content refusal can name the file.
    check(null, relative, undefined, undefined, 'a file name');
    check(source, null, undefined, undefined, relative);
    const parent = input.mode === 'release' ? path.join(payload, String(index).padStart(6, '0')) : payload;
    const destination = path.join(parent, relative);
    fs.mkdirSync(path.dirname(destination), {recursive: true, mode: 0o700});
    fs.copyFileSync(source, destination);
    fs.chmodSync(destination, 0o600);
    check(destination, null, path.relative(parent, destination), parent, relative);
    if (input.mode === 'release') outputs.push(path.join(parent, '*').replaceAll('\\', '/'));
  }
  let bodyPath = '';
  if (input.bodyPath) {
    if (isGitMetadata(fs.realpathSync(input.bodyPath)) || !fs.statSync(input.bodyPath).isFile() || fs.statSync(input.bodyPath).size > MAX_BYTES) throw new Error('uninspectable release notes');
    check(path.resolve(input.bodyPath), null, undefined, undefined, 'release notes');
    bodyPath = path.join(stage, 'notes.md');
    fs.copyFileSync(input.bodyPath, bodyPath);
    fs.chmodSync(bodyPath, 0o600);
    check(bodyPath, null, undefined, undefined, 'release notes');
  }
  return {paths: input.mode === 'artifact' ? payload : outputs.join('\n'), bodyPath};
}

function writeOutput(name, value) {
  if (!process.env.GITHUB_OUTPUT) throw new Error('output storage unavailable');
  const delimiter = 'PUBLICATION_' + crypto.randomUUID();
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}<<${delimiter}\n${value}\n${delimiter}\n`);
}

async function main() {
  process.umask(0o077);
  let stage, log, bash, gl = '', refusal;
  let privateEnv = process.env;
  const originalOut = process.stdout.write, originalErr = process.stderr.write;
  const restore = () => { process.stdout.write = originalOut; process.stderr.write = originalErr; };
  try {
    bash = findBash();
    if (!bash) throw new Error('Git Bash unavailable');
    stage = allocateStage();
    privateEnv = {...process.env, TMPDIR: bashPath(stage), TMP: stage, TEMP: stage};
    if (!process.env.GITHUB_STATE) throw new Error('state storage unavailable');
    fs.appendFileSync(process.env.GITHUB_STATE, `publication_stage=${stage}\n`);
    log = fs.openSync(path.join(stage, 'private.log'), 'wx', 0o600);
    fs.writeSync(log, 'SCRIPT_HELPERS_PRIVATE_SECURITY_REPORT_V1\n');
    const muted = (chunk, encoding, callback) => {
      fs.writeSync(log, Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, typeof encoding === 'string' ? encoding : 'utf8'));
      if (typeof encoding === 'function') encoding(); else if (callback) callback();
      return true;
    };
    process.stdout.write = muted; process.stderr.write = muted;
    const npm = npmCli();
    if (!npm) throw new Error('npm unavailable');
    const install = cp.spawnSync(process.execPath, [npm, 'ci', '--prefix', __dirname, '--ignore-scripts', '--workspaces=false', '--no-audit', '--no-fund'], {
      cwd: __dirname, env: {...privateEnv, NPM_CONFIG_USERCONFIG: os.devNull}, stdio: ['ignore', log, log],
    });
    if (install.status !== 0) throw new Error('dependency installation failed');
    const binaryFile = path.join(stage, 'scanner-path');
    const bootstrap = cp.spawnSync(bash, ['-c', `set -euo pipefail
export SCRIPT_HELPERS_DIR="$1"
source "$1/helpers.sh"
shlib_import logging foxguard gitleaks
if [[ -n "\${GITLEAKS_BIN:-}" ]]; then
  [[ -x "$GITLEAKS_BIN" ]] || exit 1
  printf '%s\\n' "$GITLEAKS_BIN" > "$2"
else
  gitleaks_bin >/dev/null 2>&1 || gitleaks_install
  gitleaks_bin > "$2"
fi`, '_', bashPath(helpers), bashPath(binaryFile)], {env: privateEnv, stdio: ['ignore', log, log]});
    if (bootstrap.status !== 0) throw new Error('credential scanner unavailable');
    gl = fs.readFileSync(binaryFile, 'utf8').trim();
    // One spawn for every checker run: the publication check and, on a
    // refusal, the two checkers again for the category.
    const runChecker = (script, target, cwd, text, output) => {
      const args = [bashPath(path.join(helpers, 'scripts', script)), ...target];
      const result = cp.spawnSync(bash, args, {cwd: cwd || process.cwd(), input: text || undefined,
        env: checkerEnv(privateEnv, gl), ...output});
      return result;
    };
    const check = (file, text, relative, cwd, label) => {
      const target = file ? ['--file', bashPath(relative || file)] : ['--stdin'];
      const result = runChecker('check_publication.sh', target, cwd, text,
        {stdio: [text === null || text === undefined ? 'ignore' : 'pipe', log, log]});
      if (result.status !== 0) {
        refusal = {label: label || 'a publication file',
          category: diagnose((script, extra, output) => runChecker(script, [...extra, ...target], cwd, text, output))};
        throw new Error('publication refused');
      }
    };
    const result = await snapshot({mode: process.env.INPUT_MODE, paths: process.env.INPUT_PATHS || '',
      metadata: process.env.INPUT_METADATA || '',
      includeHidden: process.env.INPUT_INCLUDE_HIDDEN_FILES === 'true', workingDirectory: process.env.INPUT_WORKING_DIRECTORY || '',
      bodyPath: process.env.INPUT_BODY_PATH || '', failUnmatched: process.env.INPUT_FAIL_ON_UNMATCHED_FILES === 'true'}, stage, check);
    writeOutput('paths', result.paths); writeOutput('body_path', result.bodyPath);
    restore(); fs.closeSync(log); log = undefined;
    fs.unlinkSync(path.join(stage, 'private.log'));
    fs.unlinkSync(binaryFile);
  } catch (error) {
    restore();
    if (log !== undefined) { try { fs.closeSync(log); } catch {} }
    if (bash) cp.spawnSync(bash, ['-c', 'source "$1/security_notice.sh"; security_notice "$(security_notice_tool "$2")"', '_',
      bashPath(path.join(helpers, 'scripts')), stage ? bashPath(path.join(stage, 'private.log')) : ''], {env: {...privateEnv, GITLEAKS_BIN: gl}, stdio: 'inherit'});
    else process.stderr.write('Security checks failed. Run repository checks locally first. https://nikolareljin.github.io/leak-lock/\n');
    if (refusal) process.stdout.write(`::error title=Publication check refused::${commandText(refusal.label)}: ${commandText(refusal.category)}\n`);
    else if (FIXED_REASONS.has(error?.message)) process.stdout.write(`::error title=Publication check refused::${error.message}\n`);
    if (stage) { try { fs.rmSync(stage, {recursive: true, force: true}); } catch {} }
    process.exitCode = 1;
  }
}

module.exports = {snapshot, selectFiles, releasePatterns, artifactRoot, isGitMetadata, checkerEnv, refusalCategory, commandText, FIXED_REASONS};
if (require.main === module) main();
