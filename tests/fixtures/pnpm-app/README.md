# pnpm-app fixture

Drives `pnpm.yml` and `pnpm-scan.yml` at their shipped defaults: `pnpm install
--frozen-lockfile`, then `pnpm run --if-present lint`, `pnpm run test`,
`pnpm run build`.

`pnpm-lock.yaml` is committed because `--frozen-lockfile` is what the preset
runs, and a repository without one meets `ERR_PNPM_NO_LOCKFILE` on its first
run. The refusal leg asserts exactly that, so the message a first adopter sees
stays the one the docs quote.

No dependencies. Each script leaves a marker under `.marks/`, and the legs pass
an `extra_command` that refuses to pass unless every step left one.
