// A module that deliberately depends on a version with a published advisory,
// so the govulncheck leg in self-test.yml can be shown to fail. A checker for
// vulnerabilities is easy to write so that it finds none; this is what proves
// it does not.
//
// Do not bump golang.org/x/text here. The advisory is the point.
module example.com/govulncheck-fixture

go 1.21

require golang.org/x/text v0.3.0
