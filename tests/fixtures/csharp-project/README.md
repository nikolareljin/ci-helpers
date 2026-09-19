# csharp-project fixture

Exists because the C# preset's defaults could not succeed on any repository in
the fleet, and nothing noticed — no repository had ever called them.

What this tree reproduces:

- **`MSB1011` on a bare `dotnet build`.** The directory holds `Solution.sln` and
  `App.csproj`. That fails *because the base names differ*: with `App.sln` beside
  `App.csproj` the SDK picks the solution silently and succeeds. The C# repository
  this preset was repaired for is in the failing case, and the `project` input is
  what resolves it. A fixture named the obvious way would prove nothing.
- **A lint default that can pass.** The source is formatted, so
  `dotnet format Solution.sln --verify-no-changes` exits 0.
- **A lint default that still fails.** Adding an unformatted file makes the same
  command exit 2. Both directions are asserted deliberately: the previous
  default failed on *everything*, so a fixture proving only failure would have
  looked healthy against a broken gate.

Do not set `EnableDefaultCompileItems=false` here. An earlier version of this
fixture did, to keep the root project from claiming a subdirectory's sources,
and the effect was that `dotnet format` only ever saw one file — the lint
assertion passed no matter what was added. A fixture that cannot see its own
subject is worse than no fixture.
