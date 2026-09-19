# Agent Notes — Documentation Discipline

Scope
-----

These instructions apply to the entire repository.

Goal
----

Keep the documentation in `./docs` up to date whenever code changes. Every function and module exposed by `lib/*.sh` and the loader (`helpers.sh`) must be documented with purpose, parameters, return values, environment variables, dependencies, and examples when appropriate.
Also keep script usage docs updated when scripts under `scripts/` change (e.g., include/update patterns and examples).

When to update docs
-------------------

- Adding, renaming, or removing a module in `lib/`.
- Adding, changing, or removing a function in any existing module or in `helpers.sh`.
- Changing behavior, defaults, required environment variables, or external dependencies of any function.
- Adding or changing scripts under `scripts/` that are referenced in docs (e.g., `include.sh`, `update.sh`, usage patterns).

What to update
--------------

- `docs/modules/<module>.md` —
  - Add/adjust function entries (Purpose, Signature, Args, Returns, Env, Dependencies, Examples).
- `docs/api.md` —
  - Ensure the module is listed (add/remove as needed).
- `docs/README.md` —
  - Update the module overview list if modules were added/removed/renamed.
- `docs/usage.md` —
  - Update examples if function signatures or behaviors changed in a user-visible way.
  - Update script patterns and snippets when `scripts/` changes.

Checklist (run before finishing a change)
----------------------------------------

1) Generate a quick function inventory and compare with docs:

```bash
echo "Functions per module:" && for f in lib/*.sh; do \
  bn=$(basename "$f"); echo "  - $bn"; \
  sed -n '1,400p' "$f" | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)\s*\{' | sed 's/().*$//' | sed 's/^/      • /'; \
done
```

2) For any new/changed functions, update `docs/modules/<module>.md`.

3) If a new module was added, create `docs/modules/<module>.md` and update `docs/api.md`, `docs/README.md` (module overview), **and the `nav:` list in `mkdocs.yml`**.

   `make lint-docs` catches a missing module page or api.md entry. It cannot see
   the nav — `mkdocs build --strict` is what fails on a `docs/*.md` that no nav
   entry points at, via `validation.nav.omitted_files`. Run `make docs-check`
   before opening the PR, or CI will find it for you.

4) If behavior changed in examples, update relevant scripts in `scripts/` and cross-check `docs/usage.md`.

Style
-----

- Keep docs concise but complete. Prefer bullets and short sections. Include small code examples where useful.
- Use the following structure for each function when relevant:
  - Function name
  - Purpose
  - Signature and arguments (with defaults)
  - Returns/Exit codes
  - Environment variables used
  - External dependencies
  - Example(s)

Validation
----------

- Where possible, run `make examples` to sanity-check behavior. Avoid adding hard dependencies just for docs.

## Bash version policy

**bash 3.2 is the floor, not the target.** Write every new module and script so
it runs on 3.2; it then runs on 4 and 5 as well, which is where it will actually
run most of the time. `./dev` deliberately prefers a newer bash and falls back to
`/bin/bash` last.

The floor exists because macOS ships bash 3.2 as `/bin/bash` and always will —
bash 4 moved to GPLv3. A library that needs bash 4 is a library every Mac user
must install something to use.

Two gates enforce this, and both must pass:

```bash
bash tests/portability_test.sh   # static: bash-4-only and GNU-only constructs
make test-bash32                 # the suite under a real bash 3.2, in Docker
```

`portability_test.sh` scans tracked **and untracked** files, so a new script is
checked before it is committed.

Use `require_bash4 <feature>` only when something is genuinely impossible on
3.2 — in practice, a function receiving an associative array from the caller.
Use `bash_at_least <major> [minor]` when a newer bash merely enables a better
path. Never let a bash-4 construct through silently: a wrong value is worse than
a refusal that names the remedy.

Full detail, including what to write instead of each bash-4 feature, is in
`docs/bash-compatibility.md`. Keep that page in step with any change here.

## The About page

`docs/about.md` is hand-maintained. Nothing generates it and nothing may.

1. Public, non-fork, non-archived repositories only.
2. Prefer a repository's own documentation site over its GitHub URL.
3. No private repository names, account ids, hostnames, tokens, e-mail
   addresses, customer or personal data, or internal roadmap.
4. Nothing outside this repository is read at build time. The site must build
   from a clean clone of this repository plus PyPI, and nothing else.

To refresh — by hand, reviewed, and pasted in; **never** as a build step:

```bash
gh repo list nikolareljin --visibility public --source --no-archived \
  --limit 300 --json name,description,homepageUrl
```

Then confirm every link still returns 200:

```bash
grep -oE 'https://[^)]+' docs/about.md | sort -u | while read -r u; do
  printf '%s  %s\n' "$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 10 "$u")" "$u"
done
```

These rules live here rather than in `docs/about.md` because Python-Markdown
passes HTML comments straight through into the published page source.
