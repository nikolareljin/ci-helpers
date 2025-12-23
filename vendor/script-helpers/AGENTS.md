# Agent Notes — Documentation Discipline

Scope
-----

These instructions apply to the entire repository.

Goal
----

Keep the documentation in `./docs` up to date whenever code changes. Every function and module exposed by `lib/*.sh` and the loader (`helpers.sh`) must be documented with purpose, parameters, return values, environment variables, dependencies, and examples when appropriate.

When to update docs
-------------------

- Adding, renaming, or removing a module in `lib/`.
- Adding, changing, or removing a function in any existing module or in `helpers.sh`.
- Changing behavior, defaults, required environment variables, or external dependencies of any function.

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

3) If a new module was added, create `docs/modules/<module>.md` and update `docs/api.md` and `docs/README.md` (module overview).

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

