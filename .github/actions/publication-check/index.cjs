const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');

const MAX_FILES = 2000;
// The shared checker's own ceiling (check_scan_output.sh --max-mib 2048) and
// GitHub's release asset limit. Above 64 MiB the checker streams the file,
// so a Linux AppImage or a large installer is still checked.
const MAX_BYTES = 2048 * 1024 * 1024;
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

async function snapshot(input, stage, check) {
  if (input.metadata) check(null, input.metadata);
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
    check(source);
    check(null, relative);
    const parent = input.mode === 'release' ? path.join(payload, String(index).padStart(6, '0')) : payload;
    const destination = path.join(parent, relative);
    fs.mkdirSync(path.dirname(destination), {recursive: true, mode: 0o700});
    fs.copyFileSync(source, destination);
    fs.chmodSync(destination, 0o600);
    check(destination, null, path.relative(parent, destination), parent);
    if (input.mode === 'release') outputs.push(path.join(parent, '*').replaceAll('\\', '/'));
  }
  let bodyPath = '';
  if (input.bodyPath) {
    if (isGitMetadata(fs.realpathSync(input.bodyPath)) || !fs.statSync(input.bodyPath).isFile() || fs.statSync(input.bodyPath).size > MAX_BYTES) throw new Error('uninspectable release notes');
    check(path.resolve(input.bodyPath));
    bodyPath = path.join(stage, 'notes.md');
    fs.copyFileSync(input.bodyPath, bodyPath);
    fs.chmodSync(bodyPath, 0o600);
    check(bodyPath);
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
  let stage, log, bash, gl = '';
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
    const check = (file, text, relative, cwd) => {
      const args = [bashPath(path.join(helpers, 'scripts/check_publication.sh')), ...(file ? ['--file', bashPath(relative || file)] : ['--stdin'])];
      const result = cp.spawnSync(bash, args, {cwd: cwd || process.cwd(), input: text || undefined,
        env: {...privateEnv, GITLEAKS_BIN: gl}, stdio: [text === null || text === undefined ? 'ignore' : 'pipe', log, log]});
      if (result.status !== 0) throw new Error('publication refused');
    };
    const result = await snapshot({mode: process.env.INPUT_MODE, paths: process.env.INPUT_PATHS || '',
      metadata: process.env.INPUT_METADATA || '',
      includeHidden: process.env.INPUT_INCLUDE_HIDDEN_FILES === 'true', workingDirectory: process.env.INPUT_WORKING_DIRECTORY || '',
      bodyPath: process.env.INPUT_BODY_PATH || '', failUnmatched: process.env.INPUT_FAIL_ON_UNMATCHED_FILES === 'true'}, stage, check);
    writeOutput('paths', result.paths); writeOutput('body_path', result.bodyPath);
    restore(); fs.closeSync(log); log = undefined;
    fs.unlinkSync(path.join(stage, 'private.log'));
    fs.unlinkSync(binaryFile);
  } catch {
    restore();
    if (log !== undefined) { try { fs.closeSync(log); } catch {} }
    if (bash) cp.spawnSync(bash, ['-c', 'source "$1/security_notice.sh"; security_notice "$(security_notice_tool "$2")"', '_',
      bashPath(path.join(helpers, 'scripts')), stage ? bashPath(path.join(stage, 'private.log')) : ''], {env: {...privateEnv, GITLEAKS_BIN: gl}, stdio: 'inherit'});
    else process.stderr.write('Security checks failed. Run repository checks locally first. https://nikolareljin.github.io/leak-lock/\n');
    if (stage) { try { fs.rmSync(stage, {recursive: true, force: true}); } catch {} }
    process.exitCode = 1;
  }
}

module.exports = {snapshot, selectFiles, releasePatterns, artifactRoot, isGitMetadata};
if (require.main === module) main();
