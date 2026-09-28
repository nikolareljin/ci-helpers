# node-app fixture

Drives `node.yml` and `react.yml` against their **shipped defaults**: nothing in
the self-test legs overrides `lint_command`, `test_command` or `build_command`,
so a default that could not work would fail the run rather than sit unexercised.

Zero dependencies, with `package-lock.json` committed. The lockfile is what
`npm ci` needs and what the engine's cache probe looks for, so it is part of
what the fixture proves.

Each script writes a marker under `.marks/`. The legs pass `extra_command`,
which runs after build and refuses to pass unless all three are there: a step
that silently stopped running otherwise looks exactly like one that passed.
