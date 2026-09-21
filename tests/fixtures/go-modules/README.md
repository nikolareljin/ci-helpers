# go-modules

Three modules for the `modules` input on `go.yml`, one of them deliberately
without a single Go file.

| directory | holds | proves |
|---|---|---|
| `api` | a package and its test | a leg runs in its own module, not the repository root |
| `worker` | a package and its test | a second leg runs, and `worker`'s test would fail if it ran against `api` |
| `empty` | `go.mod` alone | `go vet` and `go test` exit 1 on "no packages"; the preset must skip, not fail |

`empty` is not a mistake to be tidied away. One Go consumer in the fleet has a
module in exactly this state, and it is why the preset guards its commands
rather than trusting `./...` to match something.
