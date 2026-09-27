# shell-project fixture

Drives `.github/workflows/shell.yml`.

| path | what it is for |
|---|---|
| `scripts/clean.sh` | clean at `warning`, which the preset's default must accept |
| `bad/warns.sh` | SC2044, a **warning**, so it fails at the shipped default |
| `tests/pass.bats` | a passing bats run |
| `tests-failing/fail.bats` | a failing one, for the leg that must go red |

`bad/` and `tests-failing/` are outside the paths the passing legs check, so
they cannot turn a green leg red by accident.
