#!/usr/bin/env bash
# SCRIPT: github_release_test.sh
# DESCRIPTION: scripts/github_release.sh against a stub gh: a new release is
#              created with every flag the inputs ask for and its files
#              uploaded with --clobber; an existing one is edited, not
#              recreated, and OVERWRITE_FILES=false keeps the assets it has;
#              refs/tags/ is stripped; an unmatched pattern fails only when
#              asked; a bad tag, a missing token or a gh error stops the run
#              before anything is created. Then the release workflows: no
#              softprops/action-gh-release step is left, each release step
#              runs the script with the checked snapshot, and the checkout
#              that step reads the script from carries scripts/.
# USAGE: bash tests/github_release_test.sh
# ----------------------------------------------------
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/github_release.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

[ -f "$script" ] || { echo "FAIL: $script does not exist"; exit 1; }

# Stub gh: records each call, one line per invocation, in $CALLS.
# RELEASES lists the published stable release tags `api --paginate` returns
# (the jq filter is the script's; LIST_ERR makes that call fail).
# EXISTS=1 makes `release view` find the release; ASSETS lists its asset
# names; VIEW_ERR makes `release view` fail with that text.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "release view")
    if [ -n "${VIEW_ERR:-}" ]; then echo "$VIEW_ERR" >&2; exit 1; fi
    if [ "${EXISTS:-0}" != 1 ] && [ ! -f "$CALLS.created" ]; then echo "release not found" >&2; exit 1; fi
    case "$*" in
      *"--json assets"*)
        for a in ${ASSETS:-}; do echo "$a"; done ;;
      *"--json databaseId"*) echo 4242 ;;
      *"--json isPrerelease,isDraft"*) echo "${EXIST_STATE:-false false}" ;;
      *"--json url,uploadUrl"*) printf 'url=https://example.invalid/r/%s\nupload_url=https://example.invalid/u\n' "$3" ;;
      *) echo '{"url":"https://example.invalid/r"}' ;;
    esac
    exit 0 ;;
  "release create") : > "$CALLS.created"; exit 0 ;;
  "release edit"|"release upload"|"api -X") exit 0 ;;
  "api --paginate")
    if [ -n "${LIST_ERR:-}" ]; then echo "$LIST_ERR" >&2; exit 1; fi
    for r in ${RELEASES:-}; do echo "$r"; done
    exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 9
STUB
chmod +x "$work/bin/gh"

mkdir -p "$work/dist" "$work/dir with space"
printf 'a\n' > "$work/dist/a.deb"
printf 'b\n' > "$work/dist/b.deb"
printf 's\n' > "$work/dir with space/s.tar.gz"
printf 'notes\n' > "$work/notes.md"

run() {  # env assignments... ; runs the script, output in $work/out, rc returned
  : > "$work/calls"; : > "$work/gho"; rm -f "$work/calls.created"
  local rc=0
  env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" CALLS="$work/calls" \
    GH_TOKEN=stub GITHUB_REPOSITORY=owner/repo GITHUB_OUTPUT="$work/gho" "$@" \
    bash "$script" > "$work/out" 2>&1 || rc=$?
  return "$rc"
}
calls() { grep -c . "$work/calls" || true; }
has_call() { grep -qF -- "$1" "$work/calls"; }

ok() {  # name, command...: the command's failure is a reported FAIL, never an exit
  local name="$1"; shift
  if ! "$@"; then echo "FAIL $name"; sed 's/^/  /' "$work/out" "$work/calls"; fail=1; fi
}
not() { ! "$@"; }

# A new release with files: view, then one create that carries the files, so
# gh publishes only after the assets are on it (an immutable release takes
# no asset once published).
rc=0; run TAG_NAME=1.2.3 RELEASE_NAME="Release 1.2.3" BODY_PATH="$work/notes.md" \
  FILES="$work/dist/*.deb" OVERWRITE_FILES=true || rc=$?
ok "new release exits 0" [ "$rc" = 0 ]
ok "new release looked up first" has_call "release view 1.2.3 -R owner/repo"
ok "create with title and notes" has_call "release create 1.2.3 -R owner/repo --title Release 1.2.3 --notes-file $work/notes.md"
ok "files passed to create" has_call "release create 1.2.3 -R owner/repo --title Release 1.2.3 --notes-file $work/notes.md --latest=true -- $work/dist/a.deb $work/dist/b.deb"
ok "no separate upload on a new release" not has_call "release upload"
ok "no edit on a new release" not has_call "release edit"
ok "not a draft unless asked" not has_call "--draft"
ok "not a prerelease unless asked" not has_call "--prerelease"
ok "first stable release is Latest" has_call "--latest=true"
ok "url output written" grep -q '^url=https://example.invalid/r/1.2.3$' "$work/gho"
ok "upload_url output written" grep -q '^upload_url=' "$work/gho"

# No name: the title is the tag. No notes: empty notes, not generated ones.
rc=0; run TAG_NAME=2.0.0 || rc=$?
ok "bare tag exits 0" [ "$rc" = 0 ]
ok "title defaults to the tag, notes empty" has_call "release create 2.0.0 -R owner/repo --title 2.0.0 --notes "
ok "no upload without FILES" not has_call "release upload"
ok "notes are never generated" not has_call "--generate-notes"

# refs/tags/ is stripped, as the action did with github.ref.
rc=0; run TAG_NAME=refs/tags/3.1.0 || rc=$?
ok "refs/tags exits 0" [ "$rc" = 0 ]
ok "refs/tags/ stripped" has_call "release create 3.1.0 -R"

# Draft, prerelease, make_latest=false and a target commit.
rc=0; run TAG_NAME=4.0.0-rc1 DRAFT=true PRERELEASE=true MAKE_LATEST=false TARGET_COMMITISH=abc123 || rc=$?
ok "flags exit 0" [ "$rc" = 0 ]
ok "draft, prerelease, target and latest passed" has_call "release create 4.0.0-rc1 -R owner/repo --title 4.0.0-rc1 --notes  --draft --prerelease --target abc123 --latest=false"

# make_latest=legacy has no gh flag; it goes through the REST field.
rc=0; run TAG_NAME=4.0.1 MAKE_LATEST=legacy || rc=$?
ok "legacy exits 0" [ "$rc" = 0 ]
ok "legacy set through the API" has_call "api -X PATCH repos/owner/repo/releases/4242 -f make_latest=legacy"

# Latest goes to the highest stable X.Y.Z among the published releases only.
# Backfilling 1.0.0 after 1.0.2 exists marked 1.0.0 Latest.
latest_case() {  # name, expected --latest value, env...
  local name="$1" want="$2"; shift 2
  local rc=0; run "$@" || rc=$?
  ok "$name exits 0" [ "$rc" = 0 ]
  ok "$name: --latest=$want" has_call "--latest=$want"
}
latest_case "older tag after a newer one" false TAG_NAME=1.0.0 RELEASES="0.9.0 1.0.2"
ok "older tag says why" grep -q "1.0.2 is a higher release than 1.0.0" "$work/out"
latest_case "newest tag" true TAG_NAME=1.0.3 RELEASES="1.0.0 1.0.2"
latest_case "same tag already released" true TAG_NAME=1.0.2 RELEASES="1.0.0 1.0.2"
latest_case "numeric, not text, compare" true TAG_NAME=1.10.0 RELEASES="1.9.0 1.2.0"
latest_case "1.9.0 below 1.10.0" false TAG_NAME=1.9.0 RELEASES="1.10.0"
latest_case "leading zero is not octal" false TAG_NAME=1.9.0 RELEASES="1.010.0"
latest_case "v prefix compares" false TAG_NAME=v1.0.0 RELEASES="v1.0.1"
latest_case "other tags ignored" true TAG_NAME=1.0.0 RELEASES="pkg@9.0.0 2.0.0-rc1 nightly"
latest_case "auto on a candidate" false TAG_NAME=2.0.0-rc1 MAKE_LATEST=auto RELEASES=""
latest_case "auto on an existing release" false TAG_NAME=1.0.0 MAKE_LATEST=auto EXISTS=1 RELEASES="1.1.0"
latest_case "explicit true is kept" true TAG_NAME=1.0.0 MAKE_LATEST=true RELEASES="1.1.0"
rc=0; run TAG_NAME=1.0.0 PRERELEASE=true RELEASES="1.1.0" || rc=$?
ok "prerelease with no MAKE_LATEST leaves Latest to GitHub" not has_call "--latest"
rc=0; run TAG_NAME=1.0.0 EXISTS=1 RELEASES="1.1.0" || rc=$?
ok "existing release keeps its Latest" not has_call "--latest"
rc=0; run TAG_NAME=pkg@1.0.0 || rc=$?
ok "non-semver tag leaves Latest to GitHub" not has_call "--latest"
rc=0; run TAG_NAME=1.0.0 LIST_ERR="HTTP 502" || rc=$?
ok "unreadable release list fails" [ "$rc" != 0 ]
ok "unreadable release list creates nothing" not has_call "release create"

# create-github-release.yml leaves the decision to the script: a stable tag
# asks for auto, never a fixed true.
wf="$root/.github/workflows/create-github-release.yml"
ok "create-github-release asks for auto" grep -q "make_latest=auto" "$wf"
ok "create-github-release never forces Latest" not grep -q "make_latest=true" "$wf"
# The tauri dist repo release has its own `gh release create`; without
# --latest GitHub marks it Latest whatever its version.
ok "tauri dist release follows this repository's Latest" \
  grep -q '"--latest=${latest}"' "$root/.github/workflows/tauri-release.yml"

# An existing release is edited, not created; notes and title replace.
rc=0; run EXISTS=1 TAG_NAME=1.2.3 RELEASE_NAME=Renamed BODY_PATH="$work/notes.md" PRERELEASE=false FILES="$work/dist/a.deb" || rc=$?
ok "existing release exits 0" [ "$rc" = 0 ]
ok "existing release not recreated" not has_call "release create"
ok "existing release edited" has_call "release edit 1.2.3 -R owner/repo --title Renamed --notes-file $work/notes.md --prerelease=false"
ok "existing release gets the file" has_call "release upload 1.2.3 -R owner/repo --clobber $work/dist/a.deb"

# Existing release, nothing to change: no edit call at all.
rc=0; run EXISTS=1 TAG_NAME=1.2.3 FILES="$work/dist/a.deb" || rc=$?
ok "upload-only exits 0" [ "$rc" = 0 ]
ok "no edit when no field is set" not has_call "release edit"
ok "upload-only says so" grep -q "nothing to change" "$work/out"

# OVERWRITE_FILES=false keeps a published asset and uploads the rest without --clobber.
rc=0; run EXISTS=1 ASSETS="a.deb" TAG_NAME=1.2.3 FILES="$work/dist/*.deb" OVERWRITE_FILES=false || rc=$?
ok "overwrite=false exits 0" [ "$rc" = 0 ]
ok "only the new file uploaded, no --clobber" has_call "release upload 1.2.3 -R owner/repo $work/dist/b.deb"
ok "published asset not uploaded" not has_call "a.deb"
ok "kept asset named" grep -q "a.deb is already on 1.2.3; kept" "$work/out"

# Several patterns, one per line, and a path with a space.
rc=0; run TAG_NAME=5.0.0 FILES="$(printf '%s\n%s' "$work/dist/a.deb" "$work/dir with space/*.tar.gz")" || rc=$?
ok "multi-line FILES exits 0" [ "$rc" = 0 ]
ok "both patterns uploaded, space kept" has_call "-- $work/dist/a.deb $work/dir with space/s.tar.gz"

# An unmatched pattern: a warning by default, an error when asked, and then
# nothing is created.
rc=0; run TAG_NAME=6.0.0 FILES="$work/dist/*.rpm" || rc=$?
ok "unmatched pattern warns" [ "$rc" = 0 ]
ok "unmatched pattern warned" grep -q "::warning::.*matches no file" "$work/out"
ok "nothing uploaded for an unmatched pattern" not has_call "release upload"
rc=0; run TAG_NAME=6.0.0 FILES="$work/dist/*.rpm" FAIL_ON_UNMATCHED_FILES=true || rc=$?
ok "unmatched pattern fails when asked (rc=$rc)" [ "$rc" != 0 ]
ok "unmatched failure happens before any gh call" [ "$(calls)" = 0 ]

# A tag git accepts is accepted: `pkg@1.2.3` (monorepo release tools) and
# `release_2026` reach gh as given.
rc=0; run TAG_NAME=pkg@1.2.3 || rc=$?
ok "a tag with @ accepted (rc=$rc)" [ "$rc" = 0 ]
ok "a tag with @ created" has_call "release create pkg@1.2.3 -R"

# No gh on the runner (a self-hosted release_runner): a named error, not
# "command not found" halfway through.
mkdir -p "$work/nogh"
for t in bash env grep head mktemp rm printf basename cat; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$work/nogh/$t"
done
rc=0; env -i PATH="$work/nogh" GH_TOKEN=stub GITHUB_REPOSITORY=owner/repo TAG_NAME=1.0.0 \
  "$work/nogh/bash" "$script" > "$work/out" 2>&1 || rc=$?
ok "missing gh refused (rc=$rc)" [ "$rc" != 0 ]
ok "missing gh named" grep -q "::error::github_release: the GitHub CLI" "$work/out"

# gh reads `file#label`; a '#' in a path would upload the wrong name.
printf 'h\n' > "$work/dist/x#y.deb"
rc=0; run TAG_NAME=7.0.0 FILES="$work/dist/x#y.deb" || rc=$?
ok "a '#' in a file path refused (rc=$rc)" [ "$rc" != 0 ]
ok "a '#' path made no gh call" [ "$(calls)" = 0 ]
rm -f "$work/dist/x#y.deb"

# Refusals, each before any gh call.
rc=0; run "TAG_NAME=a b" || rc=$?
ok "a tag with a space refused (rc=$rc)" [ "$rc" != 0 ]
for case in "TAG_NAME=" "TAG_NAME=-x" "TAG_NAME=a..b" "TAG_NAME=a~1" "TAG_NAME=a:b" "TAG_NAME=a@{1}" "TAG_NAME=x.lock" "TAG_NAME=a/" "TAG_NAME=a\\b" "TAG_NAME=1.0.0 DRAFT=yes" \
            "TAG_NAME=1.0.0 MAKE_LATEST=maybe" "TAG_NAME=1.0.0 OVERWRITE_FILES=1" "TAG_NAME=1.0.0 BODY_PATH=$work/missing.md"; do
  rc=0; run $case || rc=$?
  ok "'$case' refused (rc=$rc)" [ "$rc" != 0 ]
  ok "'$case' made no gh call" [ "$(calls)" = 0 ]
done
rc=0; env -i PATH="$work/bin:/usr/bin:/bin" CALLS="$work/calls" GITHUB_REPOSITORY=owner/repo TAG_NAME=1.0.0 bash "$script" > "$work/out" 2>&1 || rc=$?
ok "missing token refused (rc=$rc)" [ "$rc" != 0 ]
ok "missing token named" grep -q "GH_TOKEN" "$work/out"
rc=0; run GITHUB_REPOSITORY="owner/repo/x" TAG_NAME=1.0.0 || rc=$?
ok "bad GITHUB_REPOSITORY refused (rc=$rc)" [ "$rc" != 0 ]

# A gh error other than "not found" stops the run instead of creating a duplicate.
# auto on an existing release judges that release's own state when the
# caller leaves PRERELEASE or DRAFT empty.
run EXISTS=1 EXIST_STATE="true false" MAKE_LATEST=auto TAG_NAME=2.0.0 RELEASES="1.0.0"
ok "existing prerelease with auto: --latest=false" has_call "--latest=false"
ok "existing prerelease state not re-sent" not has_call "--prerelease="
run EXISTS=1 EXIST_STATE="false true" MAKE_LATEST=auto TAG_NAME=2.0.0 RELEASES="1.0.0"
ok "existing draft with auto: --latest=false" has_call "--latest=false"
run EXISTS=1 EXIST_STATE="false false" MAKE_LATEST=auto TAG_NAME=2.0.0 RELEASES="1.0.0"
ok "existing stable with auto: --latest=true" has_call "--latest=true"
run EXISTS=1 MAKE_LATEST=auto PRERELEASE=false DRAFT=false TAG_NAME=2.0.0 RELEASES="1.0.0"
ok "caller-set state skips the state lookup" not has_call "--json isPrerelease,isDraft"

rc=0; run VIEW_ERR="gh: Server Error (HTTP 502)" TAG_NAME=1.0.0 || rc=$?
ok "view error stops the run (rc=$rc)" [ "$rc" != 0 ]
ok "nothing created after a view error" not has_call "release create"

# The workflows: no release action left; each release step runs this script
# behind the publication check, with the checked snapshot and notes, and the
# checkout it reads the script from carries scripts/.
python3 - "$root" <<'PY' || fail=1
import glob, re, sys, yaml
root = sys.argv[1]
problems = []
steps_seen = 0
for path in sorted(glob.glob(f"{root}/.github/workflows/*.yml")):
    rel = path[len(root) + 1:]
    doc = yaml.safe_load(open(path))
    for job_name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps") or []
        for i, step in enumerate(steps):
            uses = str(step.get("uses", ""))
            if "softprops/action-gh-release" in uses:
                problems.append(f"{rel}: {job_name}: still uses softprops/action-gh-release")
            if "scripts/github_release.sh" not in str(step.get("run", "")):
                continue
            steps_seen += 1
            where = f"{rel}: {job_name}.steps[{i}]"
            env = step.get("env") or {}
            if "${{" in str(step.get("run")):
                problems.append(f"{where}: ${{{{ }}}} inside run; inputs go through env")
            for key in ("GH_TOKEN", "TAG_NAME"):
                if key not in env:
                    problems.append(f"{where}: env has no {key}")
            for key in ("BODY", "GENERATE_RELEASE_NOTES"):
                if key in env:
                    problems.append(f"{where}: env sets {key}; notes come from the checked snapshot only")
            checks = [s for s in steps[:i] if str(s.get("uses", "")).endswith("/publication-check")]
            if not checks:
                problems.append(f"{where}: no publication-check step before it")
                continue
            ids = {s.get("id") for s in checks}
            cond = str(step.get("if", ""))
            if not any(f"steps.{k}.outcome == 'success'" in cond for k in ids):
                problems.append(f"{where}: if does not require the publication check to pass")
            for key, out in (("FILES", "paths"), ("BODY_PATH", "body_path")):
                if key in env and not any(env[key] == f"${{{{ steps.{k}.outputs.{out} }}}}" for k in ids):
                    problems.append(f"{where}: {key} is not the publication check's {out} output")
            run = str(step.get("run"))
            # The script runs from a verified copy: LIB names the isolate
            # step, whose run names the checkout it copied.
            m = re.match(r"^\$\{\{ steps\.([\w-]+)\.outputs\.lib \}\}$", str(env.get("LIB", "")))
            iso = [s for s in steps[:i] if m and s.get("id") == m.group(1)]
            im = re.search(r"(\.ci-helpers-[a-z]+)/scripts/lib_isolate\.sh", str(iso[0].get("run", ""))) if iso else None
            if '"$run_lib/scripts/github_release.sh"' not in run or not im:
                problems.append(f"{where}: does not run the script from a verified copy (scripts/lib_isolate.sh)")
                continue
            checkout_dir = im.group(1)
            co = [s for s in steps[:i] if str(s.get("uses", "")).startswith("actions/checkout")
                  and (s.get("with") or {}).get("path") == checkout_dir]
            if not co:
                problems.append(f"{where}: no checkout at {checkout_dir} to read the script from")
            else:
                w = co[-1].get("with") or {}
                if "scripts" not in str(w.get("sparse-checkout", "")).split():
                    problems.append(f"{where}: checkout at {checkout_dir} does not carry scripts/")
                if w.get("ref") != "${{ job.workflow_sha }}":
                    problems.append(f"{where}: checkout at {checkout_dir} is not at job.workflow_sha")
                if str(w.get("persist-credentials")).lower() != "false":
                    problems.append(f"{where}: checkout at {checkout_dir} keeps its token")
if steps_seen < 10:
    problems.append(f"only {steps_seen} release steps run the script; the action had 10")
for p in problems:
    print("FAIL", p)
sys.exit(1 if problems else 0)
PY

# Each release step runs the script inside the keep form, which drops every
# name it does not list. Run the script through each step's own wrapper, with
# the variables the runner sets, against a stub gh: run 43970155173 failed
# here because GITHUB_REPOSITORY was not kept.
mkdir -p "$work/kbin"
sed "s|\"\$CALLS\"|\"$work/kcalls\"|g; s|\$CALLS.created|$work/kcalls.created|g" "$work/bin/gh" > "$work/kbin/gh"
grep -q "$work/kcalls.created" "$work/kbin/gh" || { echo "FAIL premise: stub gh not rewritten"; fail=1; }
chmod +x "$work/kbin/gh"
steps_list="$(python3 - "$root" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "scripts"))
import yaml
import check_lib_isolation as c
for f in sorted((Path(sys.argv[1]) / ".github" / "workflows").glob("*.yml")):
    doc = yaml.safe_load(f.read_text())
    for jid, job in (doc.get("jobs") or {}).items():
        for st in job.get("steps") or []:
            run = st.get("run") if isinstance(st, dict) else None
            if not isinstance(run, str) or '"$run_lib/scripts/github_release.sh"' not in run:
                continue
            if c.KEEP_PREFIX not in run:
                print(f"{f.name}|{st.get('name')}|ENV-I")
                continue
            names, _t, _b, _e = c.envelope(run)
            print(f"{f.name}|{st.get('name')}|{' '.join(names)}")
PY
)"
snippet="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import check_lib_isolation as c; print(c.KEEP_SNIPPET, end="")' "$root/scripts")"
kept_steps=0
while IFS='|' read -r wf_file step_name keep; do
  [ -n "$wf_file" ] || continue
  [ "$keep" != ENV-I ] || { echo "FAIL $wf_file ($step_name): not in the keep form this test drives"; fail=1; continue; }
  kept_steps=$((kept_steps + 1))
  rc=0; rm -f "$work/kcalls" "$work/kcalls.created"
  /usr/bin/env -i PATH="$work/kbin:/usr/bin:/bin" HOME="$HOME" GH_TOKEN=x TAG_NAME=1.2.3 \
    GITHUB_REPOSITORY=owner/name GITHUB_SERVER_URL=https://github.com GITHUB_API_URL=https://api.github.com \
    GITHUB_OUTPUT="$work/kout" RUNNER_TEMP="$work" \
    /bin/bash --noprofile --norc -c "$snippet" ci-helpers-env "$keep" \
    /bin/bash --noprofile --norc -c 'export PATH="$STEP_PATH"; exec /bin/bash "$0"' "$script" \
    > "$work/keep.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL $wf_file ($step_name): github_release.sh fails behind the step's keep list (exit $rc):"; cat "$work/keep.out"; fail=1; }
done <<< "$steps_list"
[ "$kept_steps" -ge 10 ] || { echo "FAIL premise: only $kept_steps release steps found in the keep form"; fail=1; }

[ "$fail" = 0 ] && echo "ok: github_release.sh creates, updates and uploads through gh as the action did, and every release workflow runs it behind the publication check"
exit "$fail"
