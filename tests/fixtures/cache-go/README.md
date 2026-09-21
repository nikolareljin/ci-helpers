# go cache fixture

A module with a `go.sum`, so the engine's lockfile probe enables the Go cache and
`actions/setup-go` is handed a real `cache-dependency-path`.

It exists because Go is the fleet's most-used preset and its cache path had never run:
the self-test exercised node and python only. `setup-go` already defaults its own `cache`
to true, so a wrong `cache-dependency-path` here would fail every Go consumer at once.

`go.sum` is empty on purpose — the module has no dependencies. The probe only needs the
file to exist, and the action only needs to hash it.
