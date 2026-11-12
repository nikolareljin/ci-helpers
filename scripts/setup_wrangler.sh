#!/usr/bin/env bash
# SCRIPT: setup_wrangler.sh
# DESCRIPTION: Install the pinned wrangler into a private prefix. Downloads
#              the npm tarball of WRANGLER_VERSION, checks its sha256 against
#              WRANGLER_TARBALL_SHA256 and its sha512 against the lockfile's
#              integrity for wrangler, then runs `npm ci --ignore-scripts`
#              from scripts/wrangler/package-lock.json (every dependency
#              pinned by integrity, every one from registry.npmjs.org), with
#              no user or global npmrc. No package script runs.
# USAGE: TOOLCHAIN_PINS=<toolchain-pins.env> bash scripts/setup_wrangler.sh
# ENVIRONMENT:
#   TOOLCHAIN_PINS  The pins file (required).
#   RUNNER_TEMP     Parent of the prefix (default: mktemp -d).
#   GITHUB_OUTPUT   Receives node=<node path> and wrangler=<wrangler.js> when set.
# EXIT CODES:
#   0  Installed and checked.
#   1  A refusal: a digest, version or lockfile mismatch, or no Node 22+.
#   2  Usage error.
# ----------------------------------------------------
set -euo pipefail
export LC_ALL=C

fail() { echo "::error::$*" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry="https://registry.npmjs.org/"

[[ -n "${TOOLCHAIN_PINS:-}" && -f "$TOOLCHAIN_PINS" ]] || { echo "::error::TOOLCHAIN_PINS is not a file." >&2; exit 2; }
pin() { sed -n "s/^$1=//p" "$TOOLCHAIN_PINS" | tail -n 1; }
version="$(pin WRANGLER_VERSION)"
digest="$(pin WRANGLER_TARBALL_SHA256)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "WRANGLER_VERSION '$version' is not a release version."
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "WRANGLER_TARBALL_SHA256 is not a sha256."

node="$(command -v node || true)"
[[ -n "$node" && "$node" == /* ]] || fail "node is not on PATH; wrangler $version needs Node 22 or later."
major="$("$node" -p 'process.versions.node.split(".")[0]')"
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 22 ]] || fail "node $major is on PATH; wrangler $version needs Node 22 or later."
command -v npm >/dev/null 2>&1 || fail "npm is not on PATH."

# The lockfile is the library's. Its wrangler entry must be the pinned
# version, and every package must come from the registry with an integrity.
lock="$here/wrangler/package-lock.json"
want_url="${registry}wrangler/-/wrangler-${version}.tgz"
integrity="$("$node" -e '
const fs = require("fs");
const [lockPath, version, url, registry] = process.argv.slice(1);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const pkgs = lock.packages || {};
const w = pkgs["node_modules/wrangler"];
const die = (m) => { console.error("::error::" + m); process.exit(1); };
if (!w || w.version !== version || w.resolved !== url) die("the lockfile does not pin wrangler " + version + " from " + url + ".");
if ((pkgs[""] && pkgs[""].dependencies || {}).wrangler !== version) die("scripts/wrangler/package.json does not pin wrangler " + version + ".");
for (const [k, p] of Object.entries(pkgs)) {
  if (k === "") continue;
  if (p.link || !p.resolved || !p.resolved.startsWith(registry) || !/^sha512-/.test(p.integrity || ""))
    die("lockfile entry " + k + " is not a registry tarball with a sha512 integrity.");
}
process.stdout.write(w.integrity.slice("sha512-".length));
' "$lock" "$version" "$want_url" "$registry")"

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  prefix="$(mktemp -d "$RUNNER_TEMP/wrangler.XXXXXX")"
else
  prefix="$(mktemp -d)"
fi
chmod 700 "$prefix"
cp -P -- "$here/wrangler/package.json" "$here/wrangler/package-lock.json" "$prefix/"

curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$prefix/wrangler.tgz" "$want_url"
got="$(sha256sum "$prefix/wrangler.tgz" | cut -d' ' -f1)"
[[ "$got" == "$digest" ]] || fail "wrangler-$version.tgz has sha256 $got, expected $digest."
got512="$(openssl dgst -sha512 -binary "$prefix/wrangler.tgz" | base64 | tr -d '\n')"
[[ "$got512" == "$integrity" ]] || fail "wrangler-$version.tgz does not match the lockfile's sha512 integrity."
rm -f -- "$prefix/wrangler.tgz"

printf 'registry=%s\nignore-scripts=true\naudit=false\nfund=false\nupdate-notifier=false\n' "$registry" > "$prefix/.npmrc"
(
  cd "$prefix"
  NPM_CONFIG_USERCONFIG="$prefix/.npmrc" NPM_CONFIG_GLOBALCONFIG=/dev/null \
    NPM_CONFIG_CACHE="$prefix/.npm-cache" \
    npm ci --ignore-scripts --no-audit --no-fund --registry="$registry"
)

js="$prefix/node_modules/wrangler/bin/wrangler.js"
[[ -f "$js" && ! -L "$js" ]] || fail "the install has no wrangler/bin/wrangler.js."
installed="$("$node" -p 'require(process.argv[1]).version' "$prefix/node_modules/wrangler/package.json")"
[[ "$installed" == "$version" ]] || fail "installed wrangler is $installed, expected $version."
echo "wrangler $installed is installed in $prefix"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'node=%s\nwrangler=%s\n' "$node" "$js" >> "$GITHUB_OUTPUT"
fi
