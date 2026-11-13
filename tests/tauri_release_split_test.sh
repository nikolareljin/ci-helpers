#!/usr/bin/env bash
# SCRIPT: tauri_release_split_test.sh
# DESCRIPTION: tauri-release.yml builds macOS and Windows with no secret and
#              signs in sign-macos and sign-windows, which run no caller
#              code. This checks the library side of that hand-off with stub
#              tools: safe_untar.py refuses traversal, absolute paths,
#              escaping or absolute symlinks, hard links, special files,
#              members under a symlink and bad top-level names;
#              artifact_parts.sh verify refuses a tampered, extra, symlinked
#              or badly named file with the two PATH_RE values the workflow
#              passes; tauri_macos_sign.sh signs, notarizes, packages and
#              refuses a bad version; tauri_updater_sign.sh runs the signer
#              in an empty directory and fails without a signature;
#              install_tauri_signer.sh installs the pinned version; and the
#              workflow keeps secrets out of the build jobs, checks the
#              artifact name before download, and turns the bundler's
#              signing off.
# USAGE: bash tests/tauri_release_split_test.sh
# ----------------------------------------------------
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
untar=(python3 -I "$root/scripts/safe_untar.py")
APP_RE='[A-Za-z0-9][A-Za-z0-9 ._+-]{0,99}\.app'

# ---------------------------------------------------------------- safe_untar
# make_tar NAME SPEC...: SPEC is f:path, d:path, l:path:target, h:path:target, p:path (fifo)
make_tar() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import io, sys, tarfile
out, specs = sys.argv[1], sys.argv[2:]
with tarfile.open(out, "w:gz") as tf:
    for spec in specs:
        kind, rest = spec.split(":", 1)
        ti = tarfile.TarInfo(rest.split(":")[0] if kind in "lh" else rest)
        if kind == "f":
            data = b"x"
            ti.size = len(data); ti.mode = 0o755
            tf.addfile(ti, io.BytesIO(data)); continue
        if kind == "d":
            ti.type = tarfile.DIRTYPE; ti.mode = 0o755
        elif kind == "l":
            ti.type = tarfile.SYMTYPE; ti.linkname = rest.split(":", 1)[1]
        elif kind == "h":
            ti.type = tarfile.LNKTYPE; ti.linkname = rest.split(":", 1)[1]
        elif kind == "p":
            ti.type = tarfile.FIFOTYPE
        tf.addfile(ti)
PY
}

good=(d:My\ App.app d:My\ App.app/Contents f:My\ App.app/Contents/Info.plist
      d:My\ App.app/Contents/Frameworks/X.framework/Versions/A f:My\ App.app/Contents/Frameworks/X.framework/Versions/A/X
      l:My\ App.app/Contents/Frameworks/X.framework/Versions/Current:A
      l:My\ App.app/Contents/Frameworks/X.framework/X:Versions/Current/X)
make_tar "$work/good.tgz" "${good[@]}"
mkdir "$work/d0"
if got="$("${untar[@]}" "$work/good.tgz" "$work/d0" "$APP_RE")" && [[ "$got" == "My App.app" ]] \
    && [[ -L "$work/d0/My App.app/Contents/Frameworks/X.framework/X" && -x "$work/d0/My App.app/Contents/Info.plist" ]]; then
  ok "safe_untar unpacks an app with internal symlinks"
else
  bad "safe_untar on a good app: '$got'"
fi
mkdir "$work/d0b"; : > "$work/d0b/x"
if "${untar[@]}" "$work/good.tgz" "$work/d0b" "$APP_RE" >/dev/null 2>&1; then bad "safe_untar wrote into a non-empty directory"; else ok "safe_untar refuses a non-empty destination"; fi

n=0
refuse() {  # refuse LABEL SPEC...
  local label="$1"; shift
  n=$((n + 1))
  make_tar "$work/bad$n.tgz" "$@"
  mkdir "$work/out$n"
  if "${untar[@]}" "$work/bad$n.tgz" "$work/out$n" "$APP_RE" > "$work/msg" 2>&1; then
    bad "safe_untar accepted: $label"
  elif [[ -n "$(find "$work/out$n" -mindepth 1 -maxdepth 1 ! -name '*.app' -print -quit)" || -e "$work/escaped" ]]; then
    bad "safe_untar wrote outside the destination: $label"
  else
    ok "safe_untar refuses: $label"
  fi
}
refuse "a .. component"          d:A.app f:A.app/../escaped
refuse "an absolute path"        d:A.app "f:$work/escaped"
refuse "a symlink out of the app" d:A.app l:A.app/l:../../escaped
refuse "an absolute symlink"     d:A.app l:A.app/l:/etc/passwd
refuse "a link chain out of the app" d:A.app d:A.app/x l:A.app/x/a:.. l:A.app/b:x/a/../escaped
refuse "a .. target that stays inside" d:A.app d:A.app/x l:A.app/x/l:../x
refuse "a hard link out of the app" d:A.app h:A.app/h:/etc/passwd
refuse "a hard link"             d:A.app f:A.app/f h:A.app/h:A.app/f
refuse "a fifo"                  d:A.app p:A.app/p
refuse "a member under a symlink (link first)" d:A.app d:A.app/real l:A.app/dir:real f:A.app/dir/x
refuse "a member under a symlink (link last)"  d:A.app f:A.app/dir/x l:A.app/dir:real
rm -rf "$work/many" "$work/manyout" && mkdir -p "$work/many/A.app" "$work/manyout"
for i in 1 2 3 4 5 6; do : > "$work/many/A.app/f$i"; done
(cd "$work/many" && tar -czf "$work/many.tgz" A.app)
if python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import safe_untar as s; s.MAX_ENTRIES = 5; sys.exit(s.main(["x"] + sys.argv[2:]))' \
    "$root/scripts" "$work/many.tgz" "$work/manyout" "$APP_RE" >/dev/null 2>&1; then
  bad "safe_untar accepted more members than MAX_ENTRIES"
else
  ok "safe_untar refuses more members than MAX_ENTRIES"
fi
refuse "two top-level entries"   d:A.app d:B.app
refuse "a duplicate member"      d:A.app f:A.app/x f:A.app/x
refuse "a top-level file"        f:A.app
refuse "a top-level symlink"     l:A.app:.
refuse "command substitution in the name" 'd:$(id).app'
refuse "a semicolon in the name" 'd:a;b.app'
refuse "a newline in the name"   $'d:a\nb.app'
refuse "a leading hyphen"        d:-x.app
refuse "a backslash"             'd:A.app' 'f:A.app/a\b'
refuse "no .app suffix"          d:App
refuse "an empty tarball"

# ---------------------------------------------------------------- artifact_parts verify
for broken in 'a\' '(' '[z-a]'; do
  mkdir -p "$work/re"; printf 'x' > "$work/re/a"
  echo "$(sha256sum < "$work/re/a" | cut -d' ' -f1)  ./a" > "$work/re.sha256"
  if bash "$root/scripts/artifact_parts.sh" verify "$work/re" "$work/re.sha256" "$broken" >/dev/null 2>&1; then
    bad "verify passed with the malformed pattern '$broken'"
  else
    ok "verify refuses the malformed pattern '$broken'"
  fi
done
# Every PATH_RE a workflow passes compiles (a grep error would refuse every run).
while IFS= read -r re; do
  rc=0; grep -E -- "^(${re})\$" </dev/null || rc=$?
  [[ "$rc" == 1 ]] && ok "workflow PATH_RE compiles: $re" || bad "workflow PATH_RE does not compile (grep exit $rc): $re"
done < <(grep -h 'artifact_parts.sh" verify' "$root"/.github/workflows/*.yml | sed -E "s/.* '([^']*)'\$/\1/")
WIN_RE='[A-Za-z0-9][A-Za-z0-9 ._+-]{0,150}\.(exe|msi)'
MAC_RE='app\.tar\.gz|entitlements\.plist'
setup_win() {
  rm -rf "$work/win" && mkdir -p "$work/win"
  printf 'msi' > "$work/win/My App_1.0.0_x64_en-US.msi"
  printf 'exe' > "$work/win/My App_1.0.0_x64-setup.exe"
  (cd "$work/win" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done) > "$work/win.sha256"
}
setup_win
if bash "$root/scripts/artifact_parts.sh" verify "$work/win" "$work/win.sha256" "$WIN_RE" >/dev/null 2>&1; then
  ok "verify accepts the Windows installers"
else
  bad "verify refused good Windows installers"
fi
vrefuse() {  # vrefuse LABEL win|mac (after the tree or manifest was changed)
  local pattern="$WIN_RE"
  [[ "$2" == win ]] || pattern="$MAC_RE"
  if bash "$root/scripts/artifact_parts.sh" verify "$work/win" "$work/win.sha256" "$pattern" >/dev/null 2>&1; then
    bad "verify accepted: $1"
  else
    ok "verify refuses: $1"
  fi
}
setup_win; printf 'evil' > "$work/win/My App_1.0.0_x64-setup.exe"; vrefuse "a tampered installer" win
setup_win; printf 'x' > "$work/win/extra.msi"; vrefuse "a file missing from the manifest" win
setup_win; rm "$work/win/My App_1.0.0_x64_en-US.msi"; ln -s /etc/passwd "$work/win/My App_1.0.0_x64_en-US.msi"; vrefuse "a symlink in place of an installer" win
setup_win; printf 'dll' > "$work/win/x.dll"; echo "$(sha256sum < "$work/win/x.dll" | cut -d' ' -f1)  ./x.dll" >> "$work/win.sha256"; vrefuse "a file that is not an installer" win
setup_win; mkdir "$work/win/sub"; printf 'x' > "$work/win/sub/a.msi"; echo "$(sha256sum < "$work/win/sub/a.msi" | cut -d' ' -f1)  ./sub/a.msi" >> "$work/win.sha256"; vrefuse "an installer in a subdirectory" win
setup_win; echo "$(printf '%064d' 0)  ./../a.msi" >> "$work/win.sha256"; vrefuse "a .. path in the manifest" win
setup_win; echo "$(printf '%064d' 0)  ./a;b.msi" >> "$work/win.sha256"; vrefuse "a ';' in an installer name" win
setup_win; printf 'x' > "$work/win/-x.msi"; echo "$(sha256sum < "$work/win/-x.msi" | cut -d' ' -f1)  ./-x.msi" >> "$work/win.sha256"; vrefuse "a leading hyphen" win
setup_win; printf 'app' > "$work/win/app.tar.gz"; echo "$(sha256sum < "$work/win/app.tar.gz" | cut -d' ' -f1)  ./app.tar.gz" >> "$work/win.sha256"; vrefuse "app.tar.gz against the Windows pattern" win
setup_win; vrefuse "Windows installers against the macOS pattern" mac

# ---------------------------------------------------------------- tauri_macos_sign.sh
stubs="$work/stubs"; mkdir -p "$stubs"
log="$work/calls.log"
for t in codesign xcrun spctl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$t" "$log" > "$stubs/$t"
done
cat > "$stubs/plutil" <<EOF
#!/bin/bash
echo "plutil \$*" >> "$log"
if [[ "\$1" == -extract ]]; then sed -n 's/^VERSION=//p' "\${@: -1}"; exit 0; fi
if [[ "\$1" == -lint ]]; then ! grep -q bad "\${@: -1}"; exit; fi
exit 2
EOF
cat > "$stubs/ditto" <<EOF
#!/bin/bash
echo "ditto \$*" >> "$log"
cp -R "\$1" "\$2"
EOF
cat > "$stubs/hdiutil" <<EOF
#!/bin/bash
echo "hdiutil \$*" >> "$log"
: > "\${@: -1}"
EOF
cat > "$stubs/signer" <<EOF
#!/bin/bash
echo "signer \$* cwd-entries=\$(ls -A | wc -l)" >> "$log"
[[ -n "\${SIGNER_NO_SIG:-}" ]] || printf 'sig' > "\${@: -1}.sig"
EOF
chmod +x "$stubs"/*

mac_in() {  # mac_in VERSION [entitlements content]
  rm -rf "$work/mac" "$work/macout" "$work/macapp" && mkdir -p "$work/mac" "$work/macout" "$work/macapp/My App.app/Contents"
  printf 'VERSION=%s\n' "$1" > "$work/macapp/My App.app/Contents/Info.plist"
  (cd "$work/macapp" && tar -czf "$work/mac/app.tar.gz" "My App.app")
  [[ $# -lt 2 ]] || printf '%s' "$2" > "$work/mac/entitlements.plist"
  : > "$log"
}
run_mac() {
  env -i PATH="$stubs:/usr/bin:/bin" HOME="$work" IN="$work/mac" OUT="$work/macout" LIB_SCRIPTS="$root/scripts" "$@" \
    bash "$root/scripts/tauri_macos_sign.sh" > "$work/mac.out" 2>&1
}

mac_in 1.2.3
if run_mac SIGN=false && [[ -f "$work/macout/My App_1.2.3_universal.dmg" && -f "$work/macout/My App.app.tar.gz" ]] \
    && ! grep -qE '^(codesign|xcrun|signer) ' "$log" && [[ "$(ls -A "$work/macout" | wc -l)" == 2 ]]; then
  ok "macOS unsigned: DMG and updater bundle, no codesign, no notarytool"
else
  bad "macOS unsigned"; cat "$work/mac.out" "$log"
fi
if tar -tzf "$work/macout/My App.app.tar.gz" | grep -qx 'My App.app/Contents/Info.plist'; then
  ok "the updater bundle holds the app"
else
  bad "the updater bundle does not hold My App.app"
fi

mac_in 1.2.3 '<plist/>'
if run_mac SIGN=true NOTARIZE=true IDENTITY='Developer ID Application: X (ABCDE12345)' KEYCHAIN=k.keychain-db \
      APPLE_ID=a@b.example APPLE_PASSWORD=pw TEAM_ID=ABCDE12345 SIGNER="$stubs/signer" TAURI_SIGNING_PRIVATE_KEY=key; then
  order="$(awk '/^codesign --force --deep/{printf "A"} /^codesign --verify/{printf "B"} /^hdiutil create/{printf "C"}
    /^codesign --force --timestamp/{printf "D"} /^xcrun notarytool/{printf "E"} /^xcrun stapler staple .*\.dmg$/{printf "F"}
    /^xcrun stapler staple .*\.app$/{printf "G"} /^spctl/{printf "H"} /^signer/{printf "I"}' "$log")"
  want=ABCDEFGHI
  if [[ "$order" == "$want" ]] && grep -q -- '--options runtime' "$log" && grep -q -- '--entitlements' "$log" \
      && grep -q 'signer tauri signer sign .*My App.app.tar.gz cwd-entries=0' "$log" && [[ -s "$work/macout/My App.app.tar.gz.sig" ]]; then
    ok "macOS signed: app, DMG, notarize, staple, then the updater signature from an empty directory"
  else
    bad "macOS signed order: $order"; cat "$log"
  fi
else
  bad "macOS signed run failed"; cat "$work/mac.out"
fi

mac_in '1.0;rm -rf x'
if run_mac SIGN=false; then bad "a version with ';' was accepted"; else ok "macOS refuses a CFBundleShortVersionString that is not a version"; fi
mac_in '$(id)'
if run_mac SIGN=false; then bad "a version with \$( was accepted"; else ok "macOS refuses command substitution in the version"; fi
mac_in 1.0.0 'bad'
if run_mac SIGN=true IDENTITY=x KEYCHAIN=k && ! grep -q '^codesign' "$log"; then bad "a bad entitlements plist was accepted"; else
  if grep -q '^codesign' "$log"; then bad "codesign ran with a bad entitlements plist"; else ok "macOS refuses entitlements that are not a property list"; fi
fi
mac_in 1.0.0
ln -s /etc/passwd "$work/mac/entitlements.plist"
if run_mac SIGN=true IDENTITY=x KEYCHAIN=k; then bad "a symlinked entitlements file was accepted"; else ok "macOS refuses a symlinked entitlements file"; fi
mac_in 1.0.0
if run_mac SIGN=true; then bad "signing without an identity ran"; else ok "macOS SIGN=true needs IDENTITY and KEYCHAIN"; fi
mac_in 1.0.0
if run_mac SIGN=false SIGNER="$stubs/signer" TAURI_SIGNING_PRIVATE_KEY=key SIGNER_NO_SIG=1; then bad "a missing updater signature passed"; else ok "macOS fails when the signer writes no .sig"; fi
mac_in 1.0.0
: > "$work/macout/stale"
if run_mac SIGN=false; then bad "a non-empty OUT was accepted"; else ok "macOS refuses a non-empty OUT"; fi

# ---------------------------------------------------------------- tauri_updater_sign.sh
mkdir -p "$work/upd"; printf 'm' > "$work/upd/a.msi"; printf 'e' > "$work/upd/a-setup.exe"
upd() { env -i PATH="/usr/bin:/bin" "$@" bash "$root/scripts/tauri_updater_sign.sh" "$work/upd/a.msi" "$work/upd/a-setup.exe" > "$work/upd.out" 2>&1; }
: > "$log"
if upd SIGNER="$stubs/signer" TAURI_SIGNING_PRIVATE_KEY=k && [[ -s "$work/upd/a.msi.sig" && -s "$work/upd/a-setup.exe.sig" ]] \
    && [[ "$(grep -c 'cwd-entries=0' "$log")" == 2 ]]; then
  ok "updater: one .sig per installer, signer run from an empty directory"
else
  bad "updater signing"; cat "$work/upd.out" "$log"
fi
rc=0; upd SIGNER="$stubs/signer" || rc=$?
[[ "$rc" == 2 ]] && ok "updater: no key, nothing signed" || bad "updater without a key exited $rc"
rc=0; upd SIGNER=signer TAURI_SIGNING_PRIVATE_KEY=k || rc=$?
[[ "$rc" == 2 ]] && ok "updater: a relative signer path is refused" || bad "updater with a relative signer exited $rc"
rc=0; upd SIGNER="$stubs/signer" TAURI_SIGNING_PRIVATE_KEY=k SIGNER_NO_SIG=1 || rc=$?
[[ "$rc" == 1 ]] && ok "updater: no signature written fails" || bad "updater with no signature exited $rc"
ln -s /etc/passwd "$work/upd/l.msi"
rc=0; env -i PATH=/usr/bin:/bin SIGNER="$stubs/signer" TAURI_SIGNING_PRIVATE_KEY=k bash "$root/scripts/tauri_updater_sign.sh" "$work/upd/l.msi" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] && ok "updater: a symlink is refused" || bad "updater on a symlink exited $rc"

# ---------------------------------------------------------------- install_tauri_signer.sh
mkdir -p "$work/cargo" "$work/home/.cargo"
printf '[build]\nrustc-wrapper = "/bin/false"\n' > "$work/home/.cargo/config.toml"
cat > "$work/cargo/cargo" <<EOF
#!/bin/bash
echo "cargo \$*" > "$work/cargo.log"
echo "home=\${CARGO_HOME:-unset} cwd-entries=\$(ls -A | wc -l)" >> "$work/cargo.log"
[[ -z "\${CARGO_HOME:-}" || ! -e "\$CARGO_HOME/config.toml" ]] || echo "config-seen" >> "$work/cargo.log"
root="\${@: -1}"; mkdir -p "\$root/bin"; : > "\$root/bin/cargo-tauri"
EOF
chmod +x "$work/cargo/cargo"
if out="$(cd "$work/home" && env -i PATH="$work/cargo:/usr/bin:/bin" HOME="$work/home" ROOT="$work/signer" bash "$root/scripts/install_tauri_signer.sh" 2>&1)" \
    && [[ "$out" == "signer=$work/signer/bin/cargo-tauri" ]] \
    && grep -qE "^cargo install tauri-cli --version =[0-9]+\.[0-9]+\.[0-9]+ --locked --root $work/signer$" "$work/cargo.log" \
    && grep -qE "^home=/.+ cwd-entries=0$" "$work/cargo.log" && ! grep -q "home=$work/home" "$work/cargo.log" \
    && ! grep -q config-seen "$work/cargo.log"; then
  ok "install_tauri_signer installs the pinned version with --locked, a fresh CARGO_HOME, from an empty directory"
else
  bad "install_tauri_signer: $out"
fi
printf 'TAURI_CLI_VERSION=^2\n' > "$work/pins.env"
rc=0; env -i PATH="$work/cargo:/usr/bin:/bin" ROOT="$work/signer2" TOOLCHAIN_PINS="$work/pins.env" bash "$root/scripts/install_tauri_signer.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] && ok "install_tauri_signer refuses a pin that is not X.Y.Z" || bad "a range pin exited $rc"

# ---------------------------------------------------------------- the workflow
if python3 - "$root/.github/workflows/tauri-release.yml" > "$work/wf.out" 2>&1 <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf["jobs"]
problems = []
for b in ("build-macos", "build-windows"):
    text = yaml.safe_dump(jobs[b], width=10**9)
    if re.search(r"secrets\.", text):
        problems.append(f"{b} names a secret")
    if jobs[b].get("permissions") != {"contents": "read"}:
        problems.append(f"{b} permissions are not contents: read")
    build = [s for s in jobs[b]["steps"] if "cargo tauri build" in str(s.get("run"))]
    if len(build) != 1 or '"createUpdaterArtifacts":false' not in build[0]["run"]:
        problems.append(f"{b} does not turn updater signing off in its one tauri build")
    for k in ("artifact", "manifest"):
        if k not in (jobs[b].get("outputs") or {}):
            problems.append(f"{b} has no {k} output")
def runs(j):
    return "\n".join(str(s.get("run") or "") for s in jobs[j]["steps"])
if '"signingIdentity":null' not in runs("build-macos"):
    problems.append("build-macos does not turn the bundler's codesign off")
if '"signCommand":null' not in runs("build-windows"):
    problems.append("build-windows does not turn the bundler's signCommand off")
for sj, bj in (("sign-macos", "build-macos"), ("sign-windows", "build-windows")):
    job = jobs[sj]
    if job.get("needs") != bj:
        problems.append(f"{sj} does not need {bj}")
    if "${{ inputs." not in str(job.get("runs-on")):
        problems.append(f"{sj} has no runner input")
    names = [s.get("name") or s.get("uses") for s in job["steps"]]
    for s in job["steps"]:
        uses = str(s.get("uses") or "")
        if uses.startswith("actions/checkout@") and (s.get("with") or {}).get("repository") != "${{ job.workflow_repository }}":
            problems.append(f"{sj} checks out the caller's repository")
        run = str(s.get("run") or "")
        if re.search(r"tauri build|npm |pnpm |yarn |bun |make |cargo build", run):
            problems.append(f"{sj} step '{s.get('name')}' builds")
    dl = next((i for i, s in enumerate(job["steps"]) if str(s.get("uses", "")).startswith("actions/download-artifact@")), None)
    chk = names.index("Check the build outputs") if "Check the build outputs" in names else None
    ver = names.index("Verify the build output against its manifest") if "Verify the build output against its manifest" in names else None
    if dl is None or chk is None or ver is None or not (chk < dl < ver):
        problems.append(f"{sj} does not check the name, download, then verify")
    first_secret = next((i for i, s in enumerate(job["steps"]) if re.search(r"secrets\.", yaml.safe_dump(s, width=10**9))), None)
    if first_secret is not None and ver is not None and first_secret < ver:
        problems.append(f"{sj} reads a secret before the artifact is verified")
for j, job in jobs.items():
    for s in job.get("steps") or []:
        if str(s.get("uses", "")).startswith("azure/artifact-signing-action@") and j != "sign-windows":
            problems.append(f"the Azure action runs in {j}")
if set(jobs["release"]["needs"]) != {"sign-macos", "sign-windows", "build-linux"}:
    problems.append(f"release needs {jobs['release']['needs']}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
then
  ok "workflow: no secret in the build jobs, sign jobs check, download, verify, and build nothing"
else
  bad "workflow:"; cat "$work/wf.out"
fi

# The name check in the sign jobs, run on the values a build job could send.
python3 - "$root/.github/workflows/tauri-release.yml" "$work" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
for j in ("sign-macos", "sign-windows"):
    s = next(s for s in jobs[j]["steps"] if s.get("name") == "Check the build outputs")
    open(f"{sys.argv[2]}/{j}.check.sh", "w").write(s["run"])
PY
for j in macos windows; do
  if ARTIFACT="tauri-$j-build-123-1-0123456789abcdef" MANIFEST=x bash "$work/sign-$j.check.sh" >/dev/null 2>&1; then
    ok "sign-$j accepts its build artifact name"
  else
    bad "sign-$j refused its own artifact name"
  fi
  for a in "tauri-$j-artifacts" "tauri-$j-build-1-1-0123456789abcdef/../x" "tauri-$j-build-1-1-0123456789abcdef
x" 'x$(id)' "tauri-other-build-1-1-0123456789abcdef"; do
    if ARTIFACT="$a" MANIFEST=x bash "$work/sign-$j.check.sh" >/dev/null 2>&1; then bad "sign-$j accepted artifact name '$a'"; else ok "sign-$j refuses artifact name '${a//$'\n'/\\n}'"; fi
  done
  if ARTIFACT="tauri-$j-build-1-1-0123456789abcdef" MANIFEST= bash "$work/sign-$j.check.sh" >/dev/null 2>&1; then bad "sign-$j accepted an empty manifest"; else ok "sign-$j refuses an empty manifest"; fi
done

exit "$fail"
