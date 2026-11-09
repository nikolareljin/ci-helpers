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
      *"--json url,uploadUrl"*) printf 'url=https://example.invalid/r/%s\nupload_url=https://example.invalid/u\n' "$3" ;;
      *) echo '{"url":"https://example.invalid/r"}' ;;
    esac
    exit 0 ;;
  "release create") : > "$CALLS.created"; exit 0 ;;
  "release edit"|"release upload"|"api -X") exit 0 ;;
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

# A new release with files: view, create with the title and notes, upload --clobber.
rc=0; run TAG_NAME=1.2.3 RELEASE_NAME="Release 1.2.3" BODY_PATH="$work/notes.md" \
  FILES="$work/dist/*.deb" OVERWRITE_FILES=true || rc=$?
ok "new release exits 0" [ "$rc" = 0 ]
ok "new release looked up first" has_call "release view 1.2.3 -R owner/repo"
ok "create with title and notes" has_call "release create 1.2.3 -R owner/repo --title Release 1.2.3 --notes-file $work/notes.md"
ok "files uploaded with --clobber" has_call "release upload 1.2.3 -R owner/repo --clobber $work/dist/a.deb $work/dist/b.deb"
ok "no edit on a new release" not has_call "release edit"
ok "not a draft unless asked" not has_call "--draft"
ok "not a prerelease unless asked" not has_call "--prerelease"
ok "make_latest left to GitHub unless asked" not has_call "--latest"
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
ok "both patterns uploaded, space kept" has_call "--clobber $work/dist/a.deb $work/dir with space/s.tar.gz"

# An unmatched pattern: a warning by default, an error when asked, and then
# nothing is created.
rc=0; run TAG_NAME=6.0.0 FILES="$work/dist/*.rpm" || rc=$?
ok "unmatched pattern warns" [ "$rc" = 0 ]
ok "unmatched pattern warned" grep -q "::warning::.*matches no file" "$work/out"
ok "nothing uploaded for an unmatched pattern" not has_call "release upload"
rc=0; run TAG_NAME=6.0.0 FILES="$work/dist/*.rpm" FAIL_ON_UNMATCHED_FILES=true || rc=$?
ok "unmatched pattern fails when asked (rc=$rc)" [ "$rc" != 0 ]
ok "unmatched failure happens before any gh call" [ "$(calls)" = 0 ]

# Refusals, each before any gh call.
rc=0; run "TAG_NAME=a b" || rc=$?
ok "a tag with a space refused (rc=$rc)" [ "$rc" != 0 ]
for case in "TAG_NAME=" "TAG_NAME=-x" "TAG_NAME=a..b" "TAG_NAME=1.0.0 DRAFT=yes" \
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
rc=0; run VIEW_ERR="gh: Server Error (HTTP 502)" TAG_NAME=1.0.0 || rc=$?
ok "view error stops the run (rc=$rc)" [ "$rc" != 0 ]
ok "nothing created after a view error" not has_call "release create"

# The workflows: no release action left; each release step runs this script
# behind the publication check, with the checked snapshot and notes, and the
# checkout it reads the script from carries scripts/.
python3 - "$root" <<'PY' || fail=1
import glob, sys, yaml
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
            checkout_dir = run.split("scripts/github_release.sh")[0].split()[-1].rstrip("/")
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

[ "$fail" = 0 ] && echo "ok: github_release.sh creates, updates and uploads through gh as the action did, and every release workflow runs it behind the publication check"
exit "$fail"
