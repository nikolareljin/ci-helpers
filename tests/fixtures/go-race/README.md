# go-race

`racy/` holds a test with a data race. It passes under plain `go test` and
fails under `go test -race`. `self-test-compiled.yml` runs the Go presets'
default `test_command` against it to prove the default runs with `-race`.
