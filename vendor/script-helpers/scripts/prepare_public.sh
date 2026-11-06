#!/usr/bin/env bash
# SCRIPT: prepare_public.sh
# DESCRIPTION: Audit a repository's whole history and build a cleaned copy of it.
# USAGE: scripts/prepare_public.sh <audit|clean|verify|plan-example> [options]
# PARAMETERS:
#   audit  --source <path|url> --work <dir>   Mirror-clone the source into a new work
#          directory, archive it, and audit every ref, commit, file, message,
#          tag and identity. Writes <work>/report.json and <work>/report.txt.
#   clean  --work <dir> --plan <file>         Build <work>/public.git from the mirror
#          with git filter-repo, as the plan says. Writes <work>/changes.txt.
#   verify --work <dir>                       Re-run the full audit on public.git.
#          Writes <work>/report-public.json and .txt. Exit 0 only with zero hits.
#   plan-example                              Print an example plan file.
#   --list <path> | --names <a,b>             Name list for the name check
#                                             (default: the check's own list).
#   --self <name>                             This repository's own name, which is
#                                             not a hit (default: the source's name).
#   -h, --help                                Show this help message.
# EXIT_CODES:
#   0  nothing found (audit, verify); done (clean)
#   1  something found
#   2  usage error, or a check could not run: the result is NOT clean
#   130, 143  interrupted (INT, TERM); scratch directories are removed
# EXAMPLE:
#   scripts/prepare_public.sh audit --source ../my-repo --work /tmp/pub-audit
# ----------------------------------------------------
#
# Every commit, message, tag and file a repository ever held is audited, on
# every ref. The source is never changed: this tool works on mirror clones in a
# work directory it creates, and the cleaned copy goes to a new repository. It
# never pushes, and never writes to the source.
#
# Checks, over all refs and all history (added lines, so a deleted file is seen
# in the commit that added it):
#   names      check_private_names.sh --strict-ambiguous (the --self name excepted),
#              branch and tag names and the printable text of binary files too
#   sensitive  check_sensitive.sh: credentials (gitleaks), personal terms and
#              this machine's identifiers, PII. Tag messages and identities too.
#   foxguard   static analysis: the default branch on audit, every copied
#              branch on verify; advisory, never a hit.
# ----------------------------------------------------
set -euo pipefail
# The mirror, the archive and the reports hold the whole history: owner only.
umask 077
# History is bytes, not text in the caller's locale: in a UTF-8 locale a Latin-1
# line makes gawk warn and miscount, and BSD tr, sed and grep fail outright.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An exported GIT_DIR or GIT_WORK_TREE (a hook, a wrapper) wins over git -C: the
# filter-repo run and the ref deletions in clean would land in that repository,
# which can be the source.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR 2>/dev/null || true
TAG="[prepare_public]"
MARKER=".prepare-public"

say()  { echo "$TAG $*" >&2; }
# Scratch directories hold history text and names; removed on every exit,
# Ctrl-C and kill included.
SCRATCH=()
# Not through $(...): a subshell would record the directory and forget it.
scratch() { SCRATCH_DIR="$(mktemp -d)"; SCRATCH+=("$SCRATCH_DIR"); }
cleanup() { [[ ${#SCRATCH[@]} -eq 0 ]] || rm -rf "${SCRATCH[@]}"; }
# Guarded: a subshell inherits the trap and must not delete the owner's scratch.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then cleanup; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
die()  { echo "$TAG ERROR: $*" >&2; exit 2; }

usage() { sed -n '2,/^# ------/p' "${BASH_SOURCE[0]}" | sed -e '/^# ---/d' -e 's/^# \{0,1\}//'; }

CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift
SOURCE=""; WORK=""; PLAN=""; LIST=""; NAMES=""; SELF=""
while [[ $# -gt 0 ]]; do
  opt="$1"; val=""; shift
  case "$opt" in
    -h|--help) usage; exit 0 ;;
    --*=*) val="${opt#*=}"; opt="${opt%%=*}" ;;
    --source|--work|--plan|--list|--names|--self)
      [[ $# -gt 0 && -n "$1" ]] || die "$opt needs a value"
      val="$1"; shift ;;
  esac
  case "$opt" in
    --source) SOURCE="$val" ;;
    --work)   WORK="$val" ;;
    --plan)   PLAN="$val" ;;
    --list)   LIST="$val" ;;
    --names)  NAMES="$val" ;;
    --self)   SELF="$val" ;;
    *) die "unknown argument: $opt" ;;
  esac
  [[ -n "$val" ]] || die "$opt needs a value"
done

case "$CMD" in
  -h|--help) usage; exit 0 ;;
  plan-example)
    cat <<'EOF'
# prepare_public plan. One directive per line; a line starting with # is a comment.
#
# ref <pattern>        A ref the copy keeps (shell pattern). Every other ref is dropped.
ref refs/heads/main
ref refs/tags/*
# drop <path>          A file or directory removed from all history (literal, no wildcards).
#drop internal-notes/
# rename <old>==><new> A path renamed in all history.
#rename docs/old-name.md==>docs/new-name.md
# replace <text>==><new>  Text replaced in every file and every commit/tag message.
#                      git filter-repo syntax: literal, or regex:..., or glob:...
#replace old-name==>R-000
# mailmap <line>       A .mailmap line, applied to authors and committers.
#mailmap Your Name <you@users.noreply.github.com> <old@example.org>
EOF
    exit 0 ;;
  audit|clean|verify) ;;
  *) die "unknown command: $CMD (audit, clean, verify, plan-example)" ;;
esac

command -v git >/dev/null 2>&1 || die "git is not installed"
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || die "python3 is not installed (it writes the JSON report)"

abspath() { (cd -- "$1" && pwd); }

# The work directory is ours: audit creates it, and clean and verify accept only
# one that audit made. Inside a git work tree it could end up committed.
check_work_parent() {
  local parent="$1"
  # --git-dir also answers inside a .git directory or a bare repository, which
  # --is-inside-work-tree reports as false: the source's own .git included.
  if git -C "$parent" rev-parse --git-dir >/dev/null 2>&1; then
    die "the work directory must not be inside a git repository: $parent"
  fi
}
require_work() {
  [[ -n "$WORK" ]] || die "--work is required"
  [[ -f "$WORK/$MARKER" ]] || die "$WORK was not made by prepare_public.sh audit"
  WORK="$(abspath "$WORK")"
  [[ -d "$WORK/source.git" ]] || die "$WORK/source.git is missing"
  if [[ -z "$SELF" ]]; then SELF="$(sed -n 's/^self=//p' "$WORK/$MARKER" | sed -n 1p)"; fi
}

# ---- the audit -------------------------------------------------------------
# audit_repo <git dir> <report prefix> <head|all>: writes <prefix>.json and <prefix>.txt.
# Returns 0 clean, 1 hits, 2 a check could not run.
audit_repo() {
  local g="$1" prefix="$2" fox_scope="$3" t rc unchecked=0
  scratch; t="$SCRATCH_DIR"
  : > "$t/hits.tsv"     # check, label, text
  : > "$t/allowed-words"

  git -C "$g" for-each-ref --format='%(refname)' > "$t/refs"
  [[ -s "$t/refs" ]] || { say "no refs in $g"; return 2; }
  # Branch and tag names travel with the history.
  awk '{ print "- ref\t" $0 }' "$t/refs" > "$t/units"

  # Every line the history ever added, labelled "<commit> <path>:<line>".
  git -C "$g" -c core.quotePath=false log --all -p --cc -M -U0 --no-color --no-ext-diff --format='%x01%H' > "$t/log" \
    || { say "git could not read the history of $g"; return 2; }
  : > "$t/binary"
  awk -v sep="$(printf '\001')" -v binf="$t/binary" '
    index($0, sep) == 1 { commit = substr($0, 2); next }
    /^diff --(git|cc|combined) / { hdr = 1; cc = ($2 != "--git"); np = 1; ccf = substr($0, length($1 " " $2 " ") + 1); next }
    # A merge prints "Binary files differ" with no path: name it from the header.
    hdr && /^Binary files / {
      bin = $0; if (cc && bin == "Binary files differ") bin = "Binary files a/" ccf " and b/" ccf " differ"
      print "binary " commit "\t" bin > binf; next }
    hdr && /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
    /^@@@* / {
      hdr = 0; np = 1
      if (cc) { np = 0; while (substr($1, np + 1, 1) == "@") np++; np-- }
      n = $(np + 2); sub(/^\+/, "", n); split(n, b, ","); ln = b[1] + 0; next }
    hdr { next }
    {
      m = substr($0, 1, np)
      if (m ~ /^\++$/) { print commit " " f ":" ln "\t" substr($0, np + 1); ln++ }
      else if (m !~ /-/) ln++
    }' "$t/log" >> "$t/units" 2> "$t/parse-errors" \
    || { say "could not parse the history of $g:"; head -3 "$t/parse-errors" | sed 's/^/    /' >&2; return 2; }
  # File names, which a line-based scan of contents never sees.
  git -C "$g" -c core.quotePath=false log --all --format='%x01%H' --name-only --no-renames \
    | awk -v sep="$(printf '\001')" 'index($0, sep) == 1 { c = substr($0, 2); next } NF { print c " path\t" $0 }' >> "$t/units" \
    || { say "git could not list the file names of $g"; return 2; }
  # Commit messages.
  git -C "$g" log --all --format='%x01%H%n%B' \
    | awk -v sep="$(printf '\001')" 'index($0, sep) == 1 { c = substr($0, 2); n = 0; next } { n++; print c " message:" n "\t" $0 }' >> "$t/units" \
    || { say "git could not read the commit messages of $g"; return 2; }
  # Annotated tag messages (the signature block is not text anybody wrote).
  git -C "$g" for-each-ref --format='%(objecttype) %(objectname) %(refname)' refs/tags | while read -r type obj ref; do
    [[ "$type" == tag ]] || continue
    git -C "$g" cat-file tag "$obj" > "$t/tagobj" || { echo "unreadable $ref" >&2; continue; }
    awk -v r="$ref" '/^-----BEGIN (PGP|SSH) SIGNATURE-----/ { exit } /^tagger / { print "- " r " tagger\t" substr($0, 8); next } p { n++; print "- " r " tag-message:" n "\t" $0 } /^$/ { p = 1 }' "$t/tagobj"
  done >> "$t/units" 2> "$t/tag-errors"
  [[ -s "$t/tag-errors" ]] && { say "could not read a tag of $g:"; sed 's/^/    /' "$t/tag-errors" >&2; return 2; }
  awk -F'\t' '$1 ~ / tag-message:/ || $1 ~ / tagger$/ { print substr($0, length($1) + 2) }' "$t/units" > "$t/tags.txt"
  # Every author and committer.
  git -C "$g" log --all --format='%an <%ae>%n%cn <%ce>' | sort -u > "$t/identities.txt" \
    || { say "git could not read the identities of $g"; return 2; }
  awk '{ print "- identity\t" $0 }' "$t/identities.txt" >> "$t/units"
  # An email at a machine-local domain (git's default on an unconfigured host)
  # carries the machine's name. The local part is masked, the host is the hit.
  grep -iE '@([^>.]+|[^>]*\.(local|lan|localdomain|home|internal|localhost))>$' "$t/identities.txt" \
    | sed -E 's/^.*<(.{1,3})[^@]*@([^>]*)>$/sensitive\t- identity\tan email at a machine-local domain (\1***@\2)/' >> "$t/hits.tsv" || true
  # A NUL byte, or an encoding error outside the C locale, makes grep call the
  # whole input binary and match nothing in it: the check would pass blind.
  { tr -d '\000' < "$t/units" > "$t/units.c" && mv "$t/units.c" "$t/units"; } || { say "could not prepare the text"; return 2; }
  # A binary file version (a PDF, an image, an archive) can carry a name in its
  # text: its printable strings go to the name check. One larger than the limit
  # is not read, and the result is then incomplete.
  : > "$t/binary-skipped"
  if [[ -s "$t/binary" ]]; then
    "$PY" -I - "$g" "$t/binary" "$t/units" "$t/binary-skipped" <<'PY' || { say "could not read the binary file versions of $g"; return 2; }
import re, subprocess, sys
g, listing, units, skipped = sys.argv[1:5]
LIMIT = 50 * 1024 * 1024
want = []
for line in open(listing, encoding="utf-8", errors="surrogateescape"):
    commit, _, rest = line.rstrip("\n").partition("\t")
    commit = commit.split(" ", 1)[1] if " " in commit else commit
    m = re.match(r"Binary files (?:a/.*|/dev/null) and b/(.*) differ$", rest)
    if m:
        want.append((commit, m.group(1)))
    elif not rest.endswith(" and /dev/null differ"):   # a deletion adds nothing
        open(skipped, "a", encoding="utf-8", errors="surrogateescape").write("%s (not parsed: %s)\n" % (commit, rest))
if want:
    spec = "".join("%s:%s\n" % w for w in want).encode("utf-8", "surrogateescape")
    sizes = subprocess.run(["git", "-C", g, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                           input=spec, capture_output=True, check=True).stdout.decode().splitlines()
    with open(units, "ab") as out, open(skipped, "a", encoding="utf-8", errors="surrogateescape") as sk:
        for (commit, path), line in zip(want, sizes):
            f = line.split()
            if len(f) < 3 or f[1] != "blob":
                sk.write("%s %s (unreadable)\n" % (commit, path)); continue
            if int(f[2]) > LIMIT:
                sk.write("%s %s (%s bytes, over the limit)\n" % (commit, path, f[2])); continue
            data = subprocess.run(["git", "-C", g, "cat-file", "blob", f[0]], capture_output=True, check=True).stdout
            label = ("%s %s:binary" % (commit, path)).encode("utf-8", "surrogateescape")
            for s in set(re.findall(rb"[\x20-\x7e]{4,}", data)):
                out.write(label + b"\t" + s + b"\n")
PY
    say "$(wc -l < "$t/binary" | tr -d ' ') binary file version(s): printable strings checked for names"
  fi
  if [[ -s "$t/binary-skipped" ]]; then
    unchecked=1; say "binary file version(s) NOT read:"; sed 's/^/    /' "$t/binary-skipped" >&2
  fi
  # Git LFS keeps the content outside the history: only the pointer is here.
  grep -E $':1\tversion https://git-lfs\.github\.com/spec/v1$' "$t/units" | cut -f1 | sed 's/:1$//' | sort -u > "$t/lfs" || true
  if [[ -s "$t/lfs" ]]; then
    unchecked=1; say "Git LFS file(s): the content is not in the history and is NOT checked; drop them or check them by hand:"
    sed 's/^/    /' "$t/lfs" >&2
  fi

  # 1. Listed names. The check prints each hit as "<n>:<label>\t<text>".
  local -a nargs=(--stdin --strict-ambiguous)
  [[ -n "$LIST" ]] && nargs+=(--list "$LIST")
  [[ -n "$NAMES" ]] && nargs+=(--names "$NAMES")
  rc=0
  # Run from the scratch directory, so the allowlist of whatever repository the
  # caller stands in does not apply. The machine's allowlist still does: each
  # name it frees as a word is checked only in the shape of a repository
  # reference, and is listed in the report as such, never silently passed.
  # The repository's own name is not a hit in any shape: its README clones it.
  (cd "$t" && LC_ALL=C PRIVATE_NAMES_SELF="$SELF" \
    bash "$SCRIPT_DIR/check_private_names.sh" "${nargs[@]}") < "$t/units" > "$t/names.out" 2>&1 || rc=$?
  sed -n 's/.*allowed by override as a word; checked as a repository reference: //p' "$t/names.out" | sort -u > "$t/allowed-words" || true
  [[ -s "$t/allowed-words" ]] && say "names an allowlist frees as words, checked only as a repository reference: $(paste -sd, - < "$t/allowed-words")"
  if [[ $rc -ge 2 ]]; then
    unchecked=1; say "the name check could not run:"; tail -5 "$t/names.out" | sed 's/^/    /' >&2
  fi
  sed -n 's/^      [0-9][0-9]*://p' "$t/names.out" | sort -u | awk -F'\t' '{ print "names\t" $0 }' >> "$t/hits.tsv"
  # The names found, "name" or "name -> code", for the report and the plan.
  sed -n 's/^        \([^ ].*\)$/\1/p' "$t/names.out" > "$t/names-found" || true
  if [[ $rc -eq 1 ]] && ! grep -q '^names' "$t/hits.tsv"; then
    unchecked=1; say "the name check failed but no hit could be read from it"
  fi

  # 2. Credentials, personal terms and PII: every added line, all refs.
  rc=0
  bash "$SCRIPT_DIR/check_sensitive.sh" --repo "$g" --range --all > "$t/sens.out" 2>&1 || rc=$?
  # The tag messages and identities, which a commit range does not include.
  local rc2=0
  if [[ -s "$t/tags.txt" || -s "$t/identities.txt" ]]; then
    local -a files=()
    [[ -s "$t/tags.txt" ]] && files+=(--file "$t/tags.txt")
    [[ -s "$t/identities.txt" ]] && files+=(--file "$t/identities.txt")
    (cd "$t" && bash "$SCRIPT_DIR/check_sensitive.sh" --repo "$g" "${files[@]}") >> "$t/sens.out" 2>&1 || rc2=$?
  fi
  [[ $rc -ge 2 || $rc2 -ge 2 ]] && { unchecked=1; say "the sensitive check could not check everything:"; grep -E 'NOT checked|COULD NOT|could not' "$t/sens.out" | sed 's/^/    /' >&2 || true; }
  sed -n 's/^\[sensitive\] BLOCK \(.*\): \(.*\)$/\1\t\2/p' "$t/sens.out" | grep -v '^gitleaks found' \
    | awk -F'\t' '{ print "sensitive\t" $0 }' >> "$t/hits.tsv" || true
  # gitleaks findings come as blocks of "Key: value" lines.
  awk '
    /^\[sensitive\] gitleaks: (RuleID|File|Line|Commit):/ {
      sub(/^\[sensitive\] gitleaks: /, ""); k = $1; sub(/:$/, "", k); v = $0; sub(/^[^:]*: */, "", v); r[k] = v
    }
    /^\[sensitive\] gitleaks: Fingerprint:/ {
      printf "credentials\t%s %s:%s\tgitleaks %s\n", (r["Commit"] == "" ? "-" : r["Commit"]), r["File"], r["Line"], r["RuleID"]
      delete r
    }' "$t/sens.out" >> "$t/hits.tsv"
  if [[ $rc -eq 1 || $rc2 -eq 1 ]] && ! grep -qE '^(sensitive|credentials)' "$t/hits.tsv"; then
    unchecked=1; say "the sensitive check failed but no hit could be read from it"
  fi

  # 3. foxguard: advisory, recorded, never a hit. audit scans the default
  # branch (an old repository has many stale branches, and each scan runs
  # per file); verify scans every branch of the copy.
  : > "$t/foxguard.tsv"
  git clone -q --no-hardlinks "$g" "$t/tip" 2>/dev/null || true
  if [[ -d "$t/tip/.git" ]]; then
    if [[ "$fox_scope" == all ]]; then
      grep '^refs/heads/' "$t/refs" > "$t/fox-refs" || true
    else
      git -C "$g" symbolic-ref -q HEAD > "$t/fox-refs" || true
    fi
    while read -r ref; do
      git -C "$t/tip" checkout -q --detach "origin/${ref#refs/heads/}" 2>/dev/null || continue
      local -a files=()
      while IFS= read -r -d '' f; do files+=("$f"); done < <(git -C "$t/tip" ls-files -z)
      local frc=0
      (cd "$t/tip" && bash "$SCRIPT_DIR/foxguard_report.sh" --output "$t/fox.json" -- "${files[@]+"${files[@]}"}" >/dev/null 2>&1) || frc=$?
      case "$frc" in
        0) printf '%s\tclean\n' "$ref" ;;
        1) printf '%s\t%s finding(s)\n' "$ref" "$("$PY" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["finding_counts"]["total"])' "$t/fox.json" 2>/dev/null || echo some)" ;;
        3) printf '%s\tnot run: foxguard not installed\n' "$ref" ;;
        *) printf '%s\tnot run (exit %s)\n' "$ref" "$frc" ;;
      esac
    done < "$t/fox-refs" >> "$t/foxguard.tsv"
  fi

  # Which ref each commit is on, for the report.
  local head_ref r
  head_ref="$(git -C "$g" symbolic-ref -q HEAD || true)"
  cut -f2 "$t/hits.tsv" | awk '{ print $1 }' | grep -E '^[0-9a-f]{7,40}$' | sort -u | while read -r c; do
    # The default branch when it has the commit, else the first ref that does.
    git -C "$g" for-each-ref --contains "$c" --format='%(refname)' 2>/dev/null > "$t/on" || true
    r="$(grep -xF "$head_ref" "$t/on" || sed -n 1p "$t/on")"
    printf '%s\t%s\n' "$c" "$r"
  done > "$t/commit-refs"

  "$PY" -I - "$t" "$g" "$prefix" "$unchecked" <<'PY' || { say "could not write the report"; return 2; }
import json, os, re, sys, datetime
t, g, prefix, unchecked = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
codes = {}
for line in open(os.path.join(t, "names-found"), encoding="utf-8", errors="replace"):
    name, _, code = line.strip().partition(" -> ")
    if name:
        codes[name] = code
def names_in(text):
    return sorted(n for n in codes if re.search(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", text, re.I))
refs_of = {}
for line in open(os.path.join(t, "commit-refs"), encoding="utf-8", errors="replace"):
    c, _, r = line.rstrip("\n").partition("\t")
    refs_of[c] = r
hits = []
for line in open(os.path.join(t, "hits.tsv"), encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t", 2)
    if len(parts) < 3:
        continue
    check, label, text = parts
    # Labels from check_sensitive --file name the scratch file: say what it held.
    # gitleaks names it after "- " (no commit), the other checks first.
    for name, k in (("tags.txt", "tag-text"), ("identities.txt", "identity")):
        for pre in ("", "- "):
            if label.startswith(pre + os.path.join(t, name) + ":"):
                label = "- %s:%s" % (k, label.rsplit(":", 1)[1])
    first, _, where = label.partition(" ")
    if first == "message":           # check_sensitive: "message <commit>:<n>"
        first, _, n = where.partition(":")
        where = "message:" + n
    commit = first if first != "-" else ""
    path, line_no, kind = "", None, "file"
    if where.startswith(("tag-text:", "identity:")):
        kind, line_no = where.split(":", 1)
    elif where.startswith("message:"):
        kind, line_no = "commit-message", where.split(":", 1)[1]
    elif where == "path":
        kind, path = "path", text
    elif where == "ref":
        kind, path = "ref", text
    elif where.endswith(":binary"):
        kind, path = "binary-file", where[:-len(":binary")]
    elif where.startswith("refs/"):
        ref, _, k = where.partition(" ")
        kind = "tag-message" if k.startswith("tag-message") else "tagger"
        path = ref
        line_no = k.split(":", 1)[1] if ":" in k else None
    elif where == "identity":
        kind = "identity"
    elif where:
        path, _, line_no = where.rpartition(":")
        if not path:
            path, line_no = where, None
    elif not commit:
        kind = "text"
        path = label
    ref = ""
    if commit:
        ref = next((r for c, r in refs_of.items() if c.startswith(commit) or commit.startswith(c)), "")
    hit = {"check": check, "kind": kind, "ref": ref, "commit": commit, "path": path,
           "line": int(line_no) if line_no and line_no.isdigit() else None, "text": text}
    if check == "names":
        hit["names"] = names_in(text + " " + path)
    hits.append(hit)
binary = [l.rstrip("\n") for l in open(os.path.join(t, "binary-skipped"), encoding="utf-8", errors="replace")]
lfs = [l.rstrip("\n") for l in open(os.path.join(t, "lfs"), encoding="utf-8", errors="replace")]
fox = [dict(zip(("ref", "result"), l.rstrip("\n").split("\t", 1))) for l in open(os.path.join(t, "foxguard.tsv"), encoding="utf-8")]
refs = [l.strip() for l in open(os.path.join(t, "refs"), encoding="utf-8") if l.strip()]
allowed_words = [l.strip() for l in open(os.path.join(t, "allowed-words"), encoding="utf-8") if l.strip()]
counts = {}
for h in hits:
    counts[h["check"]] = counts.get(h["check"], 0) + 1
terms = {}
for h in hits:
    for n in h.get("names", []):
        terms.setdefault(n, {"code": codes.get(n, ""), "hits": 0})["hits"] += 1
report = {
    "repository": os.path.abspath(g),
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "complete": not unchecked,
    "refs": refs,
    "hit_counts": {"total": len(hits), **counts},
    "terms": terms,
    "hits": hits,
    "names_allowed_as_words": allowed_words,
    "binary_not_read": binary,
    "lfs_not_checked": lfs,
    "foxguard_advisory": fox,
}
with open(prefix + ".json", "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
with open(prefix + ".txt", "w", encoding="utf-8") as f:
    f.write("Audit of %s, %s\n" % (report["repository"], report["generated"]))
    f.write("Refs: %d. Hits: %d (%s).\n" % (len(refs), len(hits), ", ".join("%s %d" % kv for kv in sorted(counts.items())) or "none"))
    if unchecked:
        f.write("INCOMPLETE: a check could not run; this is not a clean result.\n")
    if terms:
        f.write("Names found: %s\n" % ", ".join("%s%s %d" % (n, " (%s)" % v["code"] if v["code"] else "", v["hits"])
                                                for n, v in sorted(terms.items(), key=lambda kv: -kv[1]["hits"])))
    if allowed_words:
        f.write("Names an allowlist frees as words, checked only as a repository reference: %s\n" % ", ".join(allowed_words))
    for h in hits:
        loc = h["path"] + (":%d" % h["line"] if h["line"] else "")
        f.write("\n[%s] %s %s %s %s%s\n    %s\n" % (h["check"], h["kind"], h["ref"] or "-", (h["commit"] or "-")[:12], loc,
                                              " [%s]" % ", ".join(h["names"]) if h.get("names") else "", h["text"][:200]))
    if binary:
        f.write("\nBinary file versions NOT read: %d\n" % len(binary))
        for b in binary:
            f.write("    %s\n" % b)
    if lfs:
        f.write("\nGit LFS files, content NOT checked: %d\n" % len(lfs))
        for b in lfs:
            f.write("    %s\n" % b)
    if fox:
        f.write("\nfoxguard (advisory, not a hit):\n")
        for x in fox:
            f.write("    %s: %s\n" % (x.get("ref", ""), x.get("result", "")))
PY
  local n
  n="$(wc -l < "$t/hits.tsv" | tr -d ' ')"
  say "report: $prefix.txt ($n hit(s))"
  [[ $unchecked -eq 1 ]] && { say "INCOMPLETE: a check could not run, so this is NOT a clean result"; return 2; }
  [[ "$n" -gt 0 ]] && return 1
  return 0
}

case "$CMD" in
  audit)
    [[ -n "$SOURCE" ]] || die "--source is required"
    [[ -n "$WORK" ]] || die "--work is required"
    [[ ! -e "$WORK" ]] || die "$WORK already exists; audit makes a new work directory"
    parent="$(dirname -- "$WORK")"
    [[ -d "$parent" ]] || die "no such directory: $parent"
    check_work_parent "$parent"
    if [[ -d "$SOURCE" ]]; then SOURCE="$(abspath "$SOURCE")"; fi
    if [[ -z "$SELF" ]]; then SELF="$(basename -- "${SOURCE%/}")"; SELF="${SELF%.git}"; fi
    mkdir -- "$WORK"
    WORK="$(abspath "$WORK")"
    printf 'source=%s\nself=%s\n' "$SOURCE" "$SELF" > "$WORK/$MARKER"
    say "mirror clone of $SOURCE"
    git clone -q --mirror --no-hardlinks -- "$SOURCE" "$WORK/source.git" \
      || { rm -rf "$WORK"; die "could not clone $SOURCE"; }
    # The mirror must not be able to reach the source again: no remote.
    git -C "$WORK/source.git" remote remove origin 2>/dev/null || true
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    tar -czf "$WORK/source-$stamp.tar.gz" -C "$WORK" source.git || { rm -rf "$WORK"; die "could not archive the mirror"; }
    say "archived: $WORK/source-$stamp.tar.gz"
    rc=0; audit_repo "$WORK/source.git" "$WORK/report" head || rc=$?
    [[ $rc -eq 0 ]] || say "next: write a plan (plan-example), then clean --work $WORK --plan <file>"
    exit "$rc" ;;

  clean)
    require_work
    # verify accepts public.git only from a clean that finished.
    rm -f "$WORK/$MARKER.clean"
    [[ -n "$PLAN" && -f "$PLAN" ]] || die "--plan <file> is required"
    git filter-repo --version >/dev/null 2>&1 \
      || die "git filter-repo is not installed (https://github.com/newren/git-filter-repo)"
    scratch; t="$SCRATCH_DIR"
    : > "$t/refs"; : > "$t/drop"; : > "$t/rename"; : > "$t/replace"; : > "$t/mailmap"
    # A mistyped drop path removes nothing, and the file stays: refuse it.
    # Literal, as filter-repo reads --path: "*.pem" would match here and drop nothing there.
    in_history() { [[ -n "$(git -C "$WORK/source.git" log --all --format=%H -1 -- ":(literal)$1" 2>/dev/null)" ]]; }
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%% *}"; val="${line#* }"
      [[ "$key" != "$line" && -n "$val" ]] || die "plan line $n: '$line' has no value"
      case "$key" in
        ref)     printf '%s\n' "$val" >> "$t/refs" ;;
        drop)    in_history "${val%/}" || die "plan line $n: drop '$val' is not a path anywhere in the history"
                 printf '%s\n' "$val" >> "$t/drop" ;;
        rename)  [[ "$val" == *'==>'* ]] || die "plan line $n: rename needs old==>new"
                 in_history "${val%%==>*}" || die "plan line $n: rename '${val%%==>*}' is not a path anywhere in the history"
                 printf '%s:%s\n' "${val%%==>*}" "${val#*==>}" >> "$t/rename" ;;
        replace) printf '%s\n' "$val" >> "$t/replace" ;;
        mailmap) printf '%s\n' "$val" >> "$t/mailmap" ;;
        *) die "plan line $n: unknown directive '$key' (ref, drop, rename, replace, mailmap)" ;;
      esac
    done < "$PLAN"
    [[ -s "$t/refs" ]] || die "the plan names no ref to keep (ref <pattern>)"

    pub="$WORK/public.git"
    rm -rf "$pub"
    git clone -q --mirror --no-hardlinks "$WORK/source.git" "$pub" || die "could not copy the mirror"
    git -C "$pub" remote remove origin 2>/dev/null || true
    kept=0
    while read -r ref; do
      keep=false
      while IFS= read -r pat; do
        # shellcheck disable=SC2254  # a plan pattern is a shell pattern on purpose
        case "$ref" in $pat) keep=true; break ;; esac
      done < "$t/refs"
      if [[ "$keep" == true ]]; then kept=$((kept + 1)); else git -C "$pub" update-ref -d "$ref"; fi
    done < <(git -C "$pub" for-each-ref --format='%(refname)')
    [[ $kept -gt 0 ]] || die "no ref matches the plan's ref lines"
    say "keeping $kept ref(s)"

    if [[ -s "$t/drop" ]]; then
      args=(--force --quiet --replace-refs delete-no-add --invert-paths)
      while IFS= read -r p; do args+=(--path "$p"); done < "$t/drop"
      git -C "$pub" filter-repo "${args[@]}" || die "git filter-repo failed (drop)"
    fi
    args=(--force --quiet --replace-refs delete-no-add)
    while IFS= read -r r; do args+=(--path-rename "$r"); done < "$t/rename"
    [[ -s "$t/replace" ]] && args+=(--replace-text "$t/replace" --replace-message "$t/replace")
    [[ -s "$t/mailmap" ]] && args+=(--mailmap "$t/mailmap")
    cp "$pub/filter-repo/commit-map" "$t/map1" 2>/dev/null || true
    git -C "$pub" filter-repo "${args[@]}" || die "git filter-repo failed"
    git -C "$pub" remote remove origin 2>/dev/null || true
    # A plan that drops every file leaves no commit, so no ref: nothing to copy.
    [[ -n "$(git -C "$pub" for-each-ref --format='%(refname)')" ]] || die "after the plan no ref is left"

    # Per-commit summary: old -> new, and what changed. Two passes of
    # filter-repo leave two maps; they are chained.
    "$PY" -I - "$WORK/source.git" "$pub" "$t/map1" "$WORK/changes.txt" <<'PY' || die "could not write changes.txt"
import os, re, subprocess, sys
src, pub, map1, out = sys.argv[1:5]
def read_map(p):
    m = {}
    if not os.path.exists(p):
        return None
    for line in open(p):
        a, b = line.split()
        if a != "old":
            m[a] = b
    return m
first = read_map(map1)
second = read_map(os.path.join(pub, "filter-repo", "commit-map")) or {}
if first is not None:
    chained = {a: second.get(b, b) if b != "0" * len(b) else b for a, b in first.items()}
else:
    chained = second
def info(repo, shas):
    p = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], input="".join(s + "\n" for s in shas).encode(),
                       capture_output=True, check=True)
    data, res, i = p.stdout, {}, 0
    for s in shas:
        nl = data.index(b"\n", i)
        head = data[i:nl].split()
        if head[1] == b"missing":
            res[s] = None; i = nl + 1; continue
        size = int(head[2]); body = data[nl + 1:nl + 1 + size]; i = nl + 1 + size + 1
        hdr, _, msg = body.partition(b"\n\n")
        who = [l for l in hdr.split(b"\n") if l.startswith((b"author ", b"committer "))]
        res[s] = (msg, b"\n".join(who))
    return res
def own_changes(repo):
    # What each commit itself changed (path, blob, status), not its whole tree:
    # a tree differs in every descendant of a rewritten file.
    out = subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", "log", "--all", "--root", "-r", "--raw",
                          "--no-renames", "--no-abbrev", "--diff-merges=first-parent", "--format=%x01%H"], capture_output=True, check=True).stdout
    res, c = {}, None
    for line in out.split(b"\n"):
        if line.startswith(b"\x01"):
            c = line[1:].decode(); res[c] = set()
        elif line.startswith(b":") and c:
            meta, _, path = line.partition(b"\t")
            f = meta.split()
            res[c].add((path, f[3], f[4]))
    return res
def who(raw):
    # Name and email only: the timestamps are kept by filter-repo anyway.
    return [re.sub(rb" [0-9]+ [+-][0-9]{4}$", b"", l) for l in raw.split(b"\n")]
olds = sorted(chained)
news = [n for n in chained.values() if n.strip("0")]
oi, ni = info(src, olds), info(pub, news)
oc, nc = own_changes(src), own_changes(pub)
with open(out, "w", encoding="utf-8") as f:
    f.write("old          new          changes\n")
    for o in olds:
        n = chained[o]
        if not n.strip("0"):
            f.write("%s dropped      (empty after the plan)\n" % o[:12]); continue
        a, b = oi.get(o), ni.get(n)
        what = []
        if a and b:
            if oc.get(o) != nc.get(n): what.append("files")
            if a[0] != b[0]: what.append("message")
            if who(a[1]) != who(b[1]): what.append("identity")
        if not what and n != o:
            what.append("parents")
        f.write("%s %s %s\n" % (o[:12], n[:12], ", ".join(what) or "unchanged"))
PY
    : > "$WORK/$MARKER.clean"
    say "cleaned history: $pub"
    say "per-commit changes: $WORK/changes.txt"
    say "next: verify --work $WORK"
    exit 0 ;;

  verify)
    require_work
    [[ -d "$WORK/public.git" && -f "$WORK/$MARKER.clean" ]] || die "no finished clean in $WORK; run clean first"
    if [[ -n "$(git -C "$WORK/public.git" remote)" ]]; then
      die "public.git has a remote configured; it must have none"
    fi
    rc=0; audit_repo "$WORK/public.git" "$WORK/report-public" all || rc=$?
    if [[ $rc -eq 0 ]]; then
      say "verified: zero hits in $WORK/public.git"
      say "next, by hand: create the new repository, protect it, then push $WORK/public.git to it"
    fi
    exit "$rc" ;;
esac
