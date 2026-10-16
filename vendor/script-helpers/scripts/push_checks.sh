#!/usr/bin/env bash
# SCRIPT: push_checks.sh
# DESCRIPTION: Sourced by the pre-push hook and the hook dispatcher: hygiene and lint of what a push changes; blocks on any finding.
# USAGE: source scripts/push_checks.sh; push_checks <refs-file> <remote-name> [<url>]
# PARAMETERS:
#   <refs-file>    The ref lines git gave pre-push, saved to a file.
#   <remote-name>  git's first pre-push argument.
#   <url>          git's second pre-push argument.
# EXAMPLE: push_checks "$refs" origin git@github.com:owner/repo.git
# ----------------------------------------------------
# Checks the content being pushed (each ref's tip), not the work tree, and only
# the files the push adds or changes. Every check runs to the end; a large push
# takes longer. Tests are not run here: `make test` or `./dev test`, or
# push_tests below for a repository that opts in.
#
# Writes nothing: lists live in variables, and each file goes from git (or the
# work tree, when that holds the pushed content) to its tool through a pipe.
# No here-string or heredoc either: bash before 5.1 backs those with temp files.
#
# Hygiene (always):
#   - conflict markers (<<<<<<< or >>>>>>> at the start of a line)
#   - files over script-helpers.max-file-mb (default 5) MB
#   - secret-looking file names (.env, *.pem, *.key, id_rsa, *.p12, ...)
#   - on release/X.Y.Z: the CHANGELOG release heading and VERSION match X.Y.Z
#   - in a repository of the configured owners (script-helpers.owners): commit
#     trailers or "Generated with" lines naming an AI tool
#     (git config script-helpers.ai-trailers allow turns that off for a repo)
#   - with git config script-helpers.ascii-commits true: commit messages in
#     plain ASCII (no em-dashes, curly quotes, ...)
# .script-helpers-push-allow (one glob per line, # comments) exempts paths from
# the name and size checks. Symbolic links are not linted: a push sends the link.
#
# Lint (each tool only when installed; a missing one is named, not fatal):
#   shell: bash -n, shellcheck -S warning      python: ruff (repo config, else
#   fatal rules only), or a syntax parse       js/ts: the repo's eslint, when
#   installed under node_modules               go: gofmt -l -e
#   rust: rustfmt --check, when the repo has a rustfmt config
#   workflows: actionlint   json, yaml: parse   powershell: pwsh parse
# A Makefile target `lint-changed` replaces all of it; it gets the changed
# files, one per line, in CHANGED_FILES.

PC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC_NL=$'\n'
PC_EMDASH=$'\xe2\x80\x94'

pc_say()  { printf '[pre-push] %s\n' "$*"; }
pc_find() { printf '[pre-push] REFUSED (%s): %s\n' "$1" "$2" >&2; PC_FINDINGS=$((PC_FINDINGS + 1)); }

# pc_python: a working Python 3, or return 1 (Windows has a python3 stub that
# only opens the store). Probed from /, never from the repository.
pc_python() {
  local p
  for p in python3 python; do
    command -v "$p" >/dev/null 2>&1 && ( cd / && "$p" -c 'import sys; sys.exit(sys.version_info[0] != 3)' ) 2>/dev/null \
      && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# pc_py <python> <code> [args]: run Python code from /, so a json.py or yaml.py
# committed to the repository is never imported; -B writes no bytecode.
pc_py() { local py="$1" code="$2"; shift 2; ( cd / && "$py" -B -c "$code" "$@" ); }

# pc_repo_code_ok: 0 when this file lives inside the repository being pushed,
# so the hook is the repository's own code already. An install outside it (the
# chained setup, the global dispatcher) never runs code the repository supplies:
# a `lint-changed` target, node_modules/.bin/eslint and its JS config.
# Inside is not enough: a repository whose work tree is $HOME contains the
# installed copy too. This file must be tracked, by the repository or by a
# submodule of it (script-helpers vendored).
pc_repo_code_ok() {
  local top own super
  top="$(pwd -P)"
  case "$(cd "$PC_DIR" && pwd -P)/" in "$top"/*) ;; *) return 1 ;; esac
  git -C "$PC_DIR" ls-files --error-unmatch -- push_checks.sh >/dev/null 2>&1 || return 1
  own="$(cd "$(git -C "$PC_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [[ "$own" == "$top" ]] && return 0
  super="$(git -C "$own" rev-parse --show-superproject-working-tree 2>/dev/null)"
  [[ -n "$super" && "$(cd "$super" && pwd -P)" == "$top" ]]
}

# pc_allowed <path>: 0 when .script-helpers-push-allow (at the pushed tip) lists it.
pc_allowed() {
  local pat
  [[ -n "$PC_ALLOW" ]] || return 1
  while IFS= read -r pat; do
    pat="${pat%%#*}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -n "$pat" ]] || continue
    # shellcheck disable=SC2053  # the pattern is a glob on purpose
    [[ "$1" == $pat || "${1##*/}" == $pat ]] && return 0
  done < <(printf '%s\n' "$PC_ALLOW")
  return 1
}

# pc_cat <tip> <path>: the pushed content of a file, on stdout, from git: the
# bytes the push sends. Not the work tree, even when git calls it clean: with
# core.autocrlf a script checked out with CRLF reads as broken to bash -n.
pc_cat() { git cat-file blob "$1:$2"; }

# pc_prepare <refs> <remote>: sets PC_FILES, one "<tip><TAB><path><TAB><size><TAB><src>"
# line per changed regular file. Links and submodules are left out. <src> is
# "wt" when the checked-out work tree holds that file unchanged: only eslint,
# which reads files and its config from the work tree, uses it.
pc_prepare() {
  local head dirty changed types links t f tip path size type src
  PC_FILES=""
  head="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
  dirty="$PC_NL$(git diff --no-ext-diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n')$PC_NL"
  # Could not list them is not "nothing changed": refuse rather than pass.
  changed="$(sec_changed_files "$1" "${2:-}")" || { pc_find hygiene "could not list the files this push changes"; return 0; }
  [[ -n "$changed" ]] || return 0
  types="$(printf '%s\n' "$changed" | awk -F'\t' '{ print $1 ":" $2 }' \
    | git cat-file --batch-check='%(objectsize) %(objecttype)' 2>/dev/null)"
  # Links (mode 120000) at each tip, one ls-tree per pushed ref.
  links="$PC_NL"
  for t in $(printf '%s\n' "$changed" | cut -f1 | LC_ALL=C sort -u); do
    links="$links$(git ls-tree -r -z --full-tree "$t" 2>/dev/null \
      | while IFS= read -r -d '' f; do
          [[ "$f" == 120000\ * ]] && printf '%s\t%s\n' "$t" "${f#*$'\t'}"
        done)$PC_NL"
  done
  while IFS=$'\t' read -r tip path && IFS=' ' read -r size type <&3; do
    [[ "$type" == blob ]] || continue      # a submodule commit has no content here
    case "$links" in *"$PC_NL$tip	$path$PC_NL"*) continue ;; esac   # the push sends a link
    src=git
    if [[ "$tip" == "$head" && -f "$path" && ! -L "$path" ]]; then
      case "$dirty" in *"$PC_NL$path$PC_NL"*) ;; *) src=wt ;; esac
    fi
    PC_FILES="$PC_FILES$tip	$path	$size	$src$PC_NL"
  done < <(printf '%s\n' "$changed") 3< <(printf '%s\n' "$types")
  return 0
}

# pc_named <path> <text>: tool output for one file read from stdin, with the
# placeholder names tools give stdin replaced by the path (plain bash string
# replacement: a path is data, never a sed or awk program).
pc_named() {
  local out="$2"
  out="${out//<standard input>/$1}"
  out="${out//bash: line /$1: line }"
  out="${out//In - line /In $1 line }"
  printf '%s' "$out"
}

# --------------------------------------------------------------- hygiene
pc_hygiene() {
  local refs="$1" remote="${2:-}" url="${3:-}" max_mb max tip path size src hits lref lsha rref rsha v top revs out
  max_mb="$(git config --get script-helpers.max-file-mb 2>/dev/null || true)"
  [[ "$max_mb" =~ ^[0-9]+$ ]] || max_mb=5
  max=$((max_mb * 1024 * 1024))
  while IFS=$'\t' read -r tip path size src; do
    [[ -n "$path" ]] || continue
    if ! pc_allowed "$path"; then
      [[ "$size" -gt "$max" ]] && pc_find hygiene "$path is $((size / 1024 / 1024)) MB, over $max_mb MB (git config script-helpers.max-file-mb, or list it in .script-helpers-push-allow)"
      case "${path##*/}" in
        # The templates pre-commit allows too, including variants (.env.local.example).
        .env.example|.env.sample|.env.template|.env.dist|.env.*.example|.env.*.sample|.env.*.template|.env.*.dist|*.pub) ;;
        .env|.env.*|*.pem|*.key|id_rsa|id_rsa.*|id_dsa|id_ecdsa|id_ecdsa.*|id_ed25519|id_ed25519.*|*.p12|*.pfx|*.jks|*.keystore|.netrc|_netrc|.pypirc|*.tfstate|*.tfstate.backup|*.kdbx)
          pc_find hygiene "$path looks like a secret file (list it in .script-helpers-push-allow if it is not)" ;;
      esac
    fi
    hits="$(pc_cat "$tip" "$path" 2>/dev/null | LC_ALL=C grep -I -n -E '^(<{7}|>{7})( |$)' | head -3 | cut -d: -f1 | tr '\n' ' ' || true)"
    [[ -n "$hits" ]] && pc_find hygiene "$path has merge conflict markers (line ${hits% })"
  done < <(printf '%s' "$PC_FILES")

  # Commit messages. Each starts with a marker line (\x01 and the hash): a
  # message line cannot fake it, so the right commit is named.
  local ai=false ascii=false msgs what
  pc_ai_scope "$url" && ai=true
  [[ "$(git config --get --type=bool script-helpers.ascii-commits 2>/dev/null || true)" == true ]] && ascii=true
  if [[ "$ai" == true || "$ascii" == true ]]; then
    msgs="$(while IFS= read -r revs; do
        # shellcheck disable=SC2086
        git log --format='%x01%h%n%B' $revs 2>/dev/null
      done < <(sec_revs "$refs" "$remote") | LC_ALL=C awk -v ai="$ai" -v ascii="$ascii" '
        /^\001/ { c = substr($0, 2); next }
        { l = tolower($0) }
        ai == "true" && (l ~ /(co-authored-by|signed-off-by):.*(claude|anthropic|copilot|chatgpt|openai|gemini|cursor|codex|aider|devin|windsurf|codeium)/ ||
                         l ~ /generated (with|by).*(claude|copilot|chatgpt|gemini|cursor|codex|aider|devin|windsurf|codeium)/) { print "ai " c }
        ascii == "true" && /[^\001-\177]/ { print "ascii " c }' | LC_ALL=C sort -u)"
    while read -r what v; do
      case "$what" in
        ai)    pc_find hygiene "commit $v names an AI tool in a trailer or a \"Generated with\" line (git commit --amend, or git rebase to reword it)" ;;
        ascii) pc_find hygiene "commit $v has non-ASCII characters in its message (script-helpers.ascii-commits; em-dashes, curly quotes, ...)" ;;
      esac
    done < <(printf '%s\n' "$msgs")
  fi

  # release/X.Y.Z: the release heading and VERSION at the pushed tip.
  # shellcheck disable=SC2034
  while read -r lref lsha rref rsha; do
    [[ -n "${lsha:-}" && ! "$lsha" =~ ^0+$ ]] || continue
    v="${rref#refs/heads/release/}"
    [[ "$v" != "$rref" && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    # Only when the newest release heading is dated ("## YYYY-MM-DD ..."); another
    # changelog style is not this check's to judge, even above older dated ones.
    top="$(git cat-file blob "$lsha:CHANGELOG.md" 2>/dev/null | grep -m1 -E '^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]|\[?v?[0-9]+\.[0-9]+\.[0-9]+)' || true)"
    [[ "$top" =~ ^##[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]] ]] || continue
    # The format ci-helpers reads release notes from: "## YYYY-MM-DD <em-dash> vX.Y.Z".
    [[ "$top" =~ ^##[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+${PC_EMDASH}[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+ ]] \
      || pc_find hygiene "release/$v CHANGELOG heading needs an em-dash: '## YYYY-MM-DD <em-dash> v$v', found '$top'"
    out="$(printf '%s' "$top" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ "$out" == "$v" ]] || pc_find hygiene "release/$v: the newest CHANGELOG release is '${out:-none}', not $v"
    if git cat-file -e "$lsha:VERSION" 2>/dev/null; then
      out="$(git cat-file blob "$lsha:VERSION" | tr -d '[:space:]')"; out="${out#v}"
      [[ "$out" == "$v" ]] || pc_find hygiene "release/$v: VERSION says '$out'"
    fi
  done < "$refs"
}

# pc_ai_scope <url>: 0 when the AI-trailer check applies: a repository of the
# configured owners, not turned off with script-helpers.ai-trailers allow.
pc_ai_scope() {
  local owners urls=() u
  [[ "$(git config --get script-helpers.ai-trailers 2>/dev/null || true)" == allow ]] && return 1
  declare -F scope_in_scope >/dev/null || { [[ -f "$PC_DIR/owner_scope.sh" ]] && source "$PC_DIR/owner_scope.sh"; } || return 1
  owners="$(scope_owners 2>/dev/null)" && [[ -n "$owners" ]] || return 1
  [[ -n "${1:-}" ]] && urls+=("$1")
  while IFS= read -r u; do [[ -n "$u" ]] && urls+=("$u"); done < <(scope_repo_urls 2>/dev/null || true)
  scope_in_scope "$owners" "${urls[@]+"${urls[@]}"}"
}

# ------------------------------------------------------------------ lint
pc_missing() { pc_say "lint: $1 not installed; $2 not checked."; }

# Python, run from / with the file on stdin. Exit 3 = a module is missing.
PC_PY_SYNTAX='import ast, sys
try:
    ast.parse(sys.stdin.buffer.read(), sys.argv[1])
except SyntaxError as e:
    print("%s:%s: %s" % (sys.argv[1], e.lineno, e.msg)); sys.exit(1)'
PC_PY_JSON='import json, sys
try:
    json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
except Exception as e:
    print("%s: %s" % (sys.argv[1], e)); sys.exit(1)'
PC_PY_YAML='import re, sys
try:
    import yaml
except ImportError:
    sys.exit(3)
class L(yaml.SafeLoader):
    pass
# Custom tags (!Ref, !reference) are valid YAML; only the structure is checked.
L.add_multi_constructor("", lambda loader, suffix, node: None)
text = sys.stdin.buffer.read().decode("utf-8-sig")
# A template (Helm, Jinja) is not YAML until rendered; ${{ }} is not one.
if re.search(r"(?<!\$)\{\{|\{%", text):
    sys.exit(0)
try:
    list(yaml.load_all(text, Loader=L))
except yaml.YAMLError as e:
    print("%s: %s" % (sys.argv[1], str(e).replace("\n", " "))); sys.exit(1)'

pc_lint() {
  local tip path size src out f mk="" py="" kind rc any_js_git=0 sel=()
  local n_sh=0 n_py=0 n_go=0 n_rs=0 n_wf=0 n_data=0 js=()
  for f in Makefile makefile GNUmakefile; do [[ -f "$f" ]] && { mk="$f"; break; }; done
  if [[ -n "$mk" ]] && grep -qE '^lint-changed[[:space:]]*:' "$mk"; then
    if ! pc_repo_code_ok; then
      pc_say "lint: make lint-changed not run: this hook is installed outside the repository, and runs none of its code."
    else
      pc_say "lint: make lint-changed"
      CHANGED_FILES="$(printf '%s' "$PC_FILES" | cut -f2)" make lint-changed >&2 \
        || pc_find lint "make lint-changed failed"
      return 0
    fi
  fi
  py="$(pc_python || true)"
  local have_sc=false have_ruff=false have_gofmt=false have_rustfmt=false have_al=false have_pwsh=false rust_cfg=false
  command -v shellcheck >/dev/null 2>&1 && have_sc=true
  command -v ruff >/dev/null 2>&1 && have_ruff=true
  command -v gofmt >/dev/null 2>&1 && have_gofmt=true
  command -v rustfmt >/dev/null 2>&1 && have_rustfmt=true
  command -v actionlint >/dev/null 2>&1 && have_al=true
  command -v pwsh >/dev/null 2>&1 && have_pwsh=true
  [[ -f rustfmt.toml || -f .rustfmt.toml ]] && rust_cfg=true
  [[ -f pyproject.toml ]] && grep -q '^\[tool\.ruff' pyproject.toml || [[ -f ruff.toml || -f .ruff.toml ]] \
    || sel=(--select 'E9,F63,F7,F82')

  while IFS=$'\t' read -r tip path size src; do
    [[ -n "$path" ]] || continue
    case "$path" in
      .github/workflows/*.yml|.github/workflows/*.yaml) kind="workflow" ;;
      *.sh|*.bash) kind="sh" ;;
      *.py) kind="py" ;;
      *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) kind="js" ;;
      *.go) kind="go" ;;
      *.rs) kind="rs" ;;
      *.jsonc|tsconfig*.json|jsconfig*.json|*/tsconfig*.json|*/jsconfig*.json|.vscode/*|*/.vscode/*|*devcontainer.json|.eslintrc.json|*/.eslintrc.json|tslint.json) kind="none" ;;
      *.json) kind="json" ;;
      *.yml|*.yaml) kind="yaml" ;;
      *.ps1|*.psm1) kind="ps" ;;
      *) kind="none"
         if [[ "${path##*/}" != *.* ]] && pc_cat "$tip" "$path" 2>/dev/null | head -n1 \
              | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)'; then kind="sh"; fi ;;
    esac
    case "$kind" in
      sh)
        n_sh=$((n_sh + 1))
        out="$(pc_cat "$tip" "$path" | bash -n 2>&1)" || pc_find lint "$(pc_named "$path" "$out")"
        if [[ "$have_sc" == true ]]; then
          # No shebang (a sourced library): bash, as bash -n above reads it;
          # otherwise shellcheck refuses with SC2148 for any such file.
          local scsh=()
          pc_cat "$tip" "$path" | head -n1 | grep -q '^#!' || scsh=(--shell=bash)
          out="$(pc_cat "$tip" "$path" | shellcheck -S warning "${scsh[@]+"${scsh[@]}"}" - 2>&1)" || pc_find lint "shellcheck:$PC_NL$(pc_named "$path" "$out")"
        fi ;;
      py)
        n_py=$((n_py + 1))
        if [[ "$have_ruff" == true ]]; then
          out="$(pc_cat "$tip" "$path" | ruff check --quiet --no-cache --force-exclude "${sel[@]+"${sel[@]}"}" --stdin-filename "$path" - 2>&1)" \
            || pc_find lint "ruff:$PC_NL$out"
        elif [[ -n "$py" ]]; then
          out="$(pc_cat "$tip" "$path" | pc_py "$py" "$PC_PY_SYNTAX" "$path" 2>&1)" || pc_find lint "python syntax: $out"
        fi ;;
      js)
        if [[ "$src" == wt ]]; then js+=("./$path"); else any_js_git=1; fi ;;
      go)
        n_go=$((n_go + 1))
        if [[ "$have_gofmt" == true ]]; then
          out="$(pc_cat "$tip" "$path" | gofmt -l -e 2>&1)"
          [[ -z "$out" ]] || pc_find lint "gofmt (run gofmt -w): $(pc_named "$path" "$out")"
        fi ;;
      rs)
        if [[ "$rust_cfg" == true ]]; then
          n_rs=$((n_rs + 1))
          if [[ "$have_rustfmt" == true ]]; then
            out="$(pc_cat "$tip" "$path" | rustfmt --check 2>&1)" || pc_find lint "rustfmt --check: $path:$PC_NL$(pc_named "$path" "$out")"
          fi
        fi ;;
      workflow)
        n_wf=$((n_wf + 1))
        if [[ "$have_al" == true ]]; then
          out="$(pc_cat "$tip" "$path" | actionlint -no-color -stdin-filename "$path" - 2>&1)" || pc_find lint "actionlint:$PC_NL$out"
        fi
        kind="yaml" ;;
      json)
        n_data=$((n_data + 1))
        if [[ -n "$py" ]]; then
          out="$(pc_cat "$tip" "$path" | pc_py "$py" "$PC_PY_JSON" "$path" 2>&1)" || pc_find lint "json: $out"
        fi ;;
      ps)
        if [[ "$have_pwsh" == true ]]; then
          out="$(pc_cat "$tip" "$path" | pwsh -NoProfile -NonInteractive -Command '$t=$null; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$t,[ref]$e); $e | ForEach-Object { "{0}:{1}: {2}" -f $args[0],$_.Extent.StartLineNumber,$_.Message }; exit [int]($e.Count -gt 0)' "$path" 2>&1)" \
            || pc_find lint "powershell: $out"
        fi ;;
    esac
    if [[ "$kind" == yaml ]]; then
      n_data=$((n_data + 1))
      if [[ -n "$py" ]]; then
        out="$(pc_cat "$tip" "$path" | pc_py "$py" "$PC_PY_YAML" "$path" 2>&1)"; rc=$?
        case "$rc" in
          0) ;;
          3) PC_NO_YAML=$((PC_NO_YAML + 1)) ;;
          *) pc_find lint "yaml: $out" ;;
        esac
      fi
    fi
  done < <(printf '%s' "$PC_FILES")

  [[ "$n_sh" -gt 0 && "$have_sc" != true ]] && pc_missing shellcheck "$n_sh shell file(s)"
  [[ "$n_py" -gt 0 && "$have_ruff" != true && -z "$py" ]] && pc_missing "ruff or python" "$n_py python file(s)"
  [[ "$n_go" -gt 0 && "$have_gofmt" != true ]] && pc_missing gofmt "$n_go go file(s)"
  [[ "$n_rs" -gt 0 && "$have_rustfmt" != true ]] && pc_missing rustfmt "$n_rs rust file(s)"
  [[ "$n_wf" -gt 0 && "$have_al" != true ]] && pc_missing actionlint "$n_wf workflow file(s)"
  [[ "$n_data" -gt 0 && -z "$py" ]] && pc_missing python "$n_data JSON/YAML file(s)"
  [[ "${PC_NO_YAML:-0}" -gt 0 ]] && pc_missing PyYAML "$PC_NO_YAML YAML file(s)"

  # eslint reads files and its JS config from the work tree: the checked-out
  # branch's files only, and only from the repository's own copy of this hook.
  if [[ ${#js[@]} -gt 0 ]]; then
    local has_cfg=false
    for f in eslint.config.* .eslintrc*; do [[ -e "$f" ]] && { has_cfg=true; break; }; done
    if [[ -x node_modules/.bin/eslint && "$has_cfg" == true ]]; then
      if ! pc_repo_code_ok; then
        pc_say "lint: eslint not run: it and its config are the repository's code, and this hook is installed outside it."
      else
        out="$(node_modules/.bin/eslint -- "${js[@]}" 2>&1)" || pc_find lint "eslint:$PC_NL$out"
      fi
    fi
  fi
  [[ "$any_js_git" == 1 ]] && pc_say "lint: eslint runs only on the checked-out branch's files."
  return 0
}

# push_tests: with git config script-helpers.push-tests quick, run the
# repository's quick tests (run_repo_tests.sh beside this file) and block on a
# failure. Off by default; for repositories with no CI test gate.
# 0 = passed or off, 1 = failed or misconfigured.
push_tests() {
  local mode t0 rc=0
  mode="$(git config --get script-helpers.push-tests 2>/dev/null || true)"
  case "$mode" in
    ""|off|false) return 0 ;;
    quick) ;;
    *)
      # A typo must not turn the gate off without a word.
      echo "[pre-push] REFUSED: script-helpers.push-tests is '$mode'; use quick or off." >&2
      return 1 ;;
  esac
  if [[ ! -f "$PC_DIR/run_repo_tests.sh" ]]; then
    echo "[pre-push] REFUSED: script-helpers.push-tests is quick, but run_repo_tests.sh is not next to the hooks; reinstall them." >&2
    return 1
  fi
  pc_say "tests: quick (git config script-helpers.push-tests)"
  t0=$SECONDS
  bash "$PC_DIR/run_repo_tests.sh" --require < /dev/null || rc=$?
  case "$rc" in
    0) ;;
    4) echo "[pre-push] push refused: no tests found to run." >&2; return 1 ;;
    *) echo "[pre-push] push refused: tests failed." >&2; return 1 ;;
  esac
  pc_say "tests: passed ($((SECONDS - t0)) s)"
  return 0
}

# push_checks <refs-file> <remote-name> [<url>]: 0 = clean, 1 = refused.
push_checks() {
  local refs="$1" remote="${2:-}" url="${3:-}" t0 tip n
  PC_FINDINGS=0; PC_NO_YAML=0; PC_ALLOW=""
  declare -F sec_changed_files >/dev/null || source "$PC_DIR/security_hooks.sh" || return 1
  t0=$SECONDS
  pc_prepare "$refs" "$remote"
  for tip in $(printf '%s' "$PC_FILES" | cut -f1 | LC_ALL=C sort -u); do
    PC_ALLOW="$PC_ALLOW$(git cat-file blob "$tip:.script-helpers-push-allow" 2>/dev/null || true)$PC_NL"
  done
  pc_hygiene "$refs" "$remote" "$url"
  n="$(printf '%s' "$PC_FILES" | grep -c . || true)"
  pc_say "hygiene: ${n:-0} changed file(s) checked ($((SECONDS - t0)) s)"
  t0=$SECONDS
  pc_lint
  pc_say "lint: done ($((SECONDS - t0)) s)"
  if [[ "$PC_FINDINGS" -gt 0 ]]; then
    echo "[pre-push] push refused: $PC_FINDINGS finding(s) above. Fix them, commit, and push again." >&2
    return 1
  fi
  return 0
}
