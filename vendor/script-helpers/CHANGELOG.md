Changelog

This project uses Keep a Changelog style and aims to follow Semantic Versioning for tagged releases.

## 2026-09-12 — v0.28.0

### Fixed
- **`changelog_extract` returned the wrong version's section.** The header match
  was `index(line, want) > 0`, a plain substring test, so asking for `0.2.0`
  selected a `## 2026-09-10 — v10.2.0` header — `10.2.0` contains `0.2.0` — and
  the release notes for one version were silently the body of another. A version
  now has to match whole: the character before it must not be a digit or a dot,
  and the character after it must not be anything a version continues with — a
  digit, a letter, `.`, `-` or `+` — so `0.2.0` also no longer selects a
  `v0.2.0-rc.1` section. Every regex metacharacter in the version is escaped, not
  only the dots, so `1.0.0+build.1` matches its own header. The pattern reaches
  awk through `ENVIRON` rather than `-v`, because `-v` processes escape sequences
  and turned `0\.2\.0` back into `0.2.0` — unescaped, plus a warning on every run.
  `YYYY-MM-DD — vX.Y.Z`, `[X.Y.Z] - YYYY-MM-DD` and a bare version all still
  match.

  Finding a section and extracting it are now one awk pass. They were two
  regexes, and the second only accepted a bare `## X.Y.Z` header because GNU grep
  lets `^` match mid-pattern.

- **`changelog_new_section` skipped a version it was a substring of.** Its "already
  has a section" test was the same substring match, so with a `v10.2.0` section
  present, adding `0.2.0` logged success, returned 0 and wrote nothing. It uses the
  same whole-version rule as `changelog_extract`.

- **The PowerShell mirror had both bugs, and CI could not see them.**
  `ps/lib/changelog.ps1` still matched with `$line.Contains($bare)`, and its
  `changelog_new_section` check had no leading boundary, so `0.2.0` selected and
  was shadowed by `v10.2.0` there too. It now uses the same whole-version rule.
  CI only parsed and imported the PowerShell files, so it now also runs
  `ps/tests/*_test.ps1`; `ps/tests/changelog_test.ps1` fails on the old mirror.

### Added
- **`scripts/release_notes.sh` — one implementation of the release body.**
  The CHANGELOG section for the version if there is one; otherwise the commit
  subjects since the **previous** tag; otherwise, for a first release, the whole
  history.

  The previous tag is found with `git describe --tags --abbrev=0 --exclude
  "$TAG"`, restricted to version-shaped tags, and that `--exclude` is the whole
  point. `ci-helpers` inlined the same generator into three workflows, each
  resolving the start of the range with a bare `git describe --tags --abbrev=0`
  run from a checkout **of the tag being released** — which returns the tag it is
  standing on. The range was always
  `X..X`, always empty, and every release body was the literal
  `* No changes listed.`; nine repositories and four years of releases say so.
  The composite action those three were inlined from took a `since_tag` input and
  did not have the bug. `--exclude` rather than `"$TAG^"`: `^` fails on a tag at a
  root commit and silently follows only the first parent of a merge.

  There is no bare placeholder. When nothing is found the body names the version
  and the source that was consulted, because "this release changed nothing", "the
  range was computed wrongly" and "nobody wrote a changelog entry" must not print
  the same sentence.

  The ways the range could still come out empty or wrong are closed too. Floating
  tags such as `production`, which sit on the release commit, are not taken for
  the previous release. A `vX.Y.Z` tag is used when `--tag` is not given. A
  shallow clone, which `actions/checkout` produces by default, makes the commit
  fallback exit 1 and name `fetch-depth: 0` instead of presenting one commit as a
  first release, and a failing `git log` is an error rather than an empty body.
  `--output` is relative to the caller, not to `--repo`. An option with no value
  or a malformed `--version` returns 2 with a message, in both scripts.

  A CHANGELOG section with no entries is not used as the body; the commits are,
  with a warning. For a final release, pre-release tags are not the previous
  release, so `0.2.0` is described from `0.1.0` rather than from `0.2.0-rc.1`; a
  pre-release is still described from the nearest version tag. A clone with no
  tags other than the release tag lists the whole history with a warning that
  the tags may not have been fetched, instead of calling it a first release.

- **`changelog_has_entries` — a section existing is not a release written up.**
  Returns 0 only when a section body has a line that is neither blank nor a
  heading. The template `changelog_new_section` writes, a header over four empty
  `###` headings, returns 1. That template is what `./dev release X` produces in
  consumer repositories.

- **`scripts/check_changelog_section.sh` — a release must have been written up.**
  On a `release/X.Y.Z` branch, fail when the CHANGELOG has no section for that
  version, or a section with no entries; a no-op anywhere else, so it is safe on
  every pull request. Checked only for existence, the untouched template passed
  and was then published as the release body: four headings and nothing else. Wired into
  `make lint-docs` beside `changelog_check_header`, which only ever inspected the
  newest header and so passed a release branch whose version was never described.

- **`tests/release_notes_test.sh`.** Fixture repositories covering a tag on HEAD
  (the regression, pinned directly), notes generated before the tag exists, the
  changelog winning over the range, a version absent from the changelog falling
  back, the prefix collision in both directions, a first release, an empty result,
  `--output` (including a relative path with `--repo`), floating tags, `v`-prefixed
  tags, a shallow clone, a clone without tags, pre-release tags before a final
  release, an empty template section, a failing `git log` (through a `git` shim,
  since nothing else reaches that branch), malformed arguments, and the gate's
  states including a pre-release section offered for the final version. Each
  guard was reverted in turn and the suite confirmed to fail on it; the `git log`
  guard had survived that until the shim test was added.

## 2026-09-10 — v0.27.0

### Fixed
- **`tests/portability_test.sh` — the portability gate could not see a non-Bash
  script.** Candidate files were filtered with `head -n1 "$f" | grep -q bash`,
  so a script whose first line did not contain the word never reached any check.
  That is exactly the set the shebang check below it exists to catch: `#!/bin/sh`,
  `#!/bin/zsh` and a file with no shebang at all were dropped before it ran, and
  the `shebang is not '#!/usr/bin/env bash'` branch could only ever fire on a
  shebang that already said bash. A gate blind to its own subject reports PASS
  for the case it was written for. Files are now classified by shebang, with a
  `*.sh` name standing in when there is none. The interpreter is compared by
  name rather than by a `*sh` suffix, because `pwsh` ends in one and this
  repository ships a PowerShell library — so do `tclsh` and `wish`. Anything the
  classifier cannot resolve to an interpreter — a bare `#!`, `#!/usr/bin/env`
  with no command, `env` carrying options (`-S`, `-i`, `-u VAR`,
  `--ignore-environment`, an assignment such as `env FOO=bar bash`) — is
  *included* rather than dropped, so the shebang check names it. A file with no
  shebang is included when its name says `.sh` *or* when it lives where the
  entry points live (`bin/`, the git hooks, `templates/dev-cli/dev`), since
  those are collected on purpose and were still being dropped — and the shebang
  check now errors on a file that has none at all, which is what those files
  were being kept for. The same locations are kept when the shebang names
  something else entirely: `templates/dev-cli/dev` as `#!/usr/bin/env python3`
  was dropped before the check that exists to say so. `rbash` counts
  as bash; `#! /bin/sh` with a space after the magic is a shebang, not an empty
  interpreter; and a `.sh` file whose shebang names python or perl is reported
  rather than dropped, since the name and the shebang disagree. Failing toward inspection is the whole point: every narrower
  version of this filter opened a new hole somewhere else. The scanned
  set is unchanged today (114 files) — the defect was latent, and would have
  been paid by whoever added the first `#!/bin/sh` script.

- **`lib/help.sh` — rendering help left a dozen variables in the caller.**
  `get_script_metadata` writes its results with `printf -v "${prefix}_${key}"`,
  which creates a *global* unless some frame already declares the name. Callers
  that pass their own prefix are choosing that; `_help__render` passes a fixed
  `_shlib_help_meta` prefix nobody asked for, so any script calling `show_help`,
  `display_help` or `print_help` silently gained `_shlib_help_meta_name`,
  `_shlib_help_meta_usage` and ten more — plus `line`, from an undeclared loop
  variable in `_help__print_block`. These libraries are sourced into other
  people's scripts, so each of those is a name that can quietly clobber theirs.
  Fixed by declaring the fixed field set `local` one frame above the call:
  bash locals are dynamically scoped, so the assignments land in that frame and
  disappear on return — no cleanup path to forget, and nothing newer than bash
  3.2, with the name list built from `_HELP_META_FIELDS` at both ends so a field
  added later cannot quietly start leaking again. `tests/scope_test.sh` now
  exercises the three renderers, not just the collector, which is why the leak
  survived a test written to catch exactly it.

- **`helpers.sh` — the bash-3 advisory told Linux hosts to use Homebrew.** The
  one-time note printed when the library loads under bash 3.x ended with
  "On macOS: brew install bash" regardless of where it was running, so a
  minimal container or an old enterprise Linux with a dated bash was pointed at
  a tool it does not have. The remedy is chosen by `$OSTYPE` now: Homebrew on
  macOS, the package manager elsewhere.

- **Three runners resolved the library root after `cd`-ing into the project.**
  `local_test_gradle.sh`, `local_test_python.sh` and `local_test_rust.sh` built
  a path from `${BASH_SOURCE[0]}` *after* changing directory. That variable
  holds whatever the caller typed — `scripts/local_test_rust.sh` for the
  documented invocation — so with any `--dir` the lookup went to
  `<project>/scripts/..` and the helper could not be sourced at all
  (`cd: scripts/..: No such file or directory`). Each resolves `SH_ROOT` before
  the first `cd` now.

- **`scripts/preflight.sh --dir <sub>` resolved its own later paths as
  `sub/sub/...`.** `PROJECT_DIR` was kept exactly as given, so after `cd`-ing
  into `sub` every later `"$PROJECT_DIR/$dir"` — the iOS stack's `pubspec.yaml`
  test, `in_dir`, the runner arguments — was built from a relative value that
  no longer meant anything from the new working directory. The runners happened
  to survive because they re-anchor a relative path on the git root; nothing
  else did, so a valid nested project was skipped or failed. `PROJECT_DIR` is
  absolute from the `cd` onward.

- **`scripts/local_test_bash32.sh` — the offline skip map named one test that
  needs git while four others use it.** `needs_for` was kept by hand, so
  `hub_test.sh`, `install_dev_cli_test.sh`, `portability_test.sh`,
  `runner_dir_test.sh` and `adb_wireless_test.sh` ran without git when the
  bootstrap could not reach the network and failed for a missing tool — under
  exactly the name this runner exists to keep off bash 3.2. The requirement is
  read out of each test file now, with comments stripped first so a tool named
  in prose is not mistaken for a dependency — a skipped test is lost coverage,
  the same failure pointed the other way. The hand-written case adds only what
  a scan cannot see: `apt-get`, which no test invokes but `docker_install`
  requires, and an opt-out for the portability gate, which runs git when it is
  there and falls back to `find` when it is not.

- **`scripts/install_dev_cli.sh` — `--shims dev` replaced the entry point with
  a shim that ran itself.** Every compatibility shim delegates to `./dev`, so a
  shim *named* `dev` moved the real entry point to `dev.pre-dev-cli` and wrote
  `exec "$(dirname "$0")/dev" dev "$@"` in its place: an exec loop, with the
  file it needed already moved aside. A name containing a path separator would
  likewise have written outside the repository root. Shim names are now
  validated as a whole list before the first write of any kind — `dev`,
  `dev.ps1`, `scripts`, `.`, `..` and anything with a `/` are refused with exit
  2 — so a rejected invocation leaves the repository exactly as it found it;
  the first version of this check ran after the entry point had already been
  installed. The pre-write pass also refuses a destination that is a symlink
  (`-e` is false for a dangling one, so the write would have followed it and
  created the shim wherever it pointed, outside the repository included), an
  existing directory (`--shims .git` moved `.git` to `.git.pre-dev-cli` and
  replaced it with a file), and the reserved `*.pre-dev-cli` suffix (which
  would have displaced the caller's original backup). The message uses
  `readlink` is called without `--`, the form both GNU and BSD accept; BSD
  `readlink` on macOS is the one that rejects GNU's `--`. The same guard
  covers the installer's own destinations (`dev`, `scripts/cli.sh`, the
  PowerShell counterparts): a dangling symlink at one of those is neither `-f`
  nor `-e`, so `install_file` reached `cp`, which followed it and wrote the
  template outside the repository. The guard walks the parent components too: a
  consumer whose `scripts/` is a symlink out of the tree left
  `scripts/cli.sh` neither a symlink nor a directory, so the check passed and
  the `mkdir -p` and `cp` followed the parent link — measured, the old
  installer exited 0 having written outside the repository.

- **`lib/ios.sh` — a simulator was reported as unbootable moments after being
  booted.** `simctl boot` returns when the boot *starts*; the device then sits
  in `Booting` for several seconds and does not appear in
  `simctl list devices booted` until it reaches `Booted`. `ios_boot_simulator`
  returned at the same moment, so `ios_resolve_device`'s very next lookup found
  nothing and printed "'X' is not a booted simulator" about a simulator it had
  just successfully started — worse on a cold simulator, which is when the
  caller most needed it. It now waits for the state the caller is about to ask
  for (`IOS_BOOT_TIMEOUT`, default 60s). The wait checks the listing's exit
  status before its output, so a `simctl` that breaks after the boot command is
  reported as that rather than as a timeout, and it checks once *at* the
  deadline, so a device that boots on the last second counts. `tests/ios_test.sh`
  models the `Booting` window and the broken listing, and fails without either.
  `IOS_BOOT_TIMEOUT` is validated as a whole number before the loop and refused
  with exit 2: `10s` in an arithmetic test errors on every iteration, so the
  deadline was never reached. All-digit is not sufficient either — bash reads a
  leading zero as octal, so `08` and `09` were the same error — and the value is
  normalised to base 10.

- **`templates/dev-cli/cli.sh` — a relative export-options plist named two
  different files in a nested project.** `./dev deploy ios --release` validates
  `IOS_EXPORT_OPTIONS_PLIST` from the repository root, then hands it to
  `ios_build_release`, which re-checks it after `cd`-ing into the Flutter
  project. In the layout the shared dev CLI assumes — the app under `mobile/`
  or `app/` — those are different directories, so a relative path either died on
  a path that had just validated, or resolved to whichever plist sat inside the
  project and signed with that. The path is now made absolute at the point it is
  validated.

- **`scripts/preflight.sh --dir <sub>` looked for every stack under the git
  root instead of under `<sub>`.** Stack directories are detected relative to
  the directory preflight was pointed at, but the `local_test_*` runners resolve
  `--dir` against `git rev-parse --show-toplevel`, so `preflight --dir sub` in
  a repository reported `Directory not found: <root>/app` for a stack that was
  at `sub/app`. preflight now hands the runners an absolute path, and all seven
  runners (`flutter`, `gradle`, `node`, `python`, `go`, `rust`, `php`) honour
  one as given; a relative `--dir` still means what it always meant. The first
  version of this change updated four of the seven, which would have broken
  every ordinary Flutter, Gradle and PHP preflight with `<root>/<root>/<stack>`;
  caught in review, and each runner is now probed with both forms.

- **`scripts/preflight.sh` — `--quick` reported an iOS build that never ran.**
  `check_ios` already passes `--skip-analyze --skip-test`, because those belong
  to the flutter check for the same directory, so the build *is* the step. Under
  `--quick` it added `--skip-build` as well and still called the result a passed
  "ios build" — `ci_ios.sh` was left running `flutter pub get` and nothing else.
  `--quick` now skips the step and says why.

- **`scripts/preflight.sh` — a Rust project failed the run on unactionable
  advice.** `check_rust` gated on `cargo` being on `PATH`, but
  `local_test_rust.sh` runs against *rustup's* toolchain, because that is what
  CI compiles with. On a machine with a distribution cargo and no rustup it
  refused, advising `--any-cargo` — which preflight had no way to pass on. And
  `cargo` on `PATH` is not a precondition at all in the default case: the runner
  resolves rustup's toolchain before it looks at `PATH`, prepending
  `~/.cargo/bin` itself, so demanding cargo up front turned away a machine the
  runner handles unaided. `cargo` is now required only for `--any-cargo`;
  otherwise the precondition is rustup, and either one missing is a skip naming
  both remedies, the way every other absent toolchain here is handled.
  `PREFLIGHT_RUST_ANY_CARGO=true` turns the skip back into a real check against
  `PATH`'s cargo. rustup being installed with no cargo for the selected toolchain
  (`stable` never added) is the same kind of state and is the same skip, naming
  both remedies — the `rustup toolchain install` to run and the
  `PREFLIGHT_RUST_ANY_CARGO` opt-in — rather than a failed step.

- **`scripts/local_test_bash32.sh` — `--test` ignored the tool-skip rules the
  suite relies on.** The single-test path ran the file directly rather than
  through the runner, so `--test tests/docker_install_test.sh` failed for want
  of `apt-get`, and `--test tests/git_branches_test.sh` failed for want of git
  whenever the bootstrap could not reach the network — reporting a missing tool
  as a bash 3.2 defect, which is what the skip rules exist to prevent. Both
  paths now share one runner, and the path is normalised before the skip lookup
  so `--test ./tests/x.sh` is treated the same as `--test tests/x.sh`. A stopped daemon and a missing image are also
  reported as themselves -- with the command to run, and the documented exit
  code 3 -- instead of surfacing a registry error that reads like the suite is
  broken. `--shell` gets those checks too; it used to reach `docker run`
  directly and answer an unpullable image with `cannot attach stdin to a
  TTY-enabled container`.

## 2026-09-09 — v0.26.0

### Added
- **`lib/rust.sh` — the Rust toolchain a gate compiles with.** CI installs Rust
  through `dtolnay/rust-toolchain@stable`, which is rustup's stable. A
  workstation often also carries a distribution cargo that comes first on
  `PATH` and is years older, and the errors that produces name the lockfile
  rather than the compiler:

      error: lock file version 4 requires `-Znext-lockfile-bump`
      feature `edition2024` is required

  So the search goes to the dependency tree while the toolchain is the
  problem — and a local gate saying "this is what CI would have run" is saying
  something false, which is worse than having no gate.

  `rust_toolchain_ci_uses [toolchain]` puts that rustup toolchain's cargo first —
  `stable` by default, asked for **by name** rather than through `rustup which
  cargo`, which follows a developer's default or override and may be nightly —
  and **says so when that differs from what `PATH` offered**, naming both versions; it refuses with an
  actionable message rather than falling back to the older one silently.
  `rust_toolchain_report` prints the same facts without touching `PATH`.

  Promoted from a consumer that had solved it privately, so every Rust
  repository can have it. Same shape as a snap Flutter resolving `.dart_tool`
  for a project the dev SDK was building.

### Changed
- **`scripts/local_test_rust.sh` resolves the toolchain before it looks for
  cargo.** It previously took whatever `command -v cargo` returned. New
  `--any-cargo` opts out for a repository that genuinely targets the system
  toolchain.

## 2026-09-09 — v0.25.0

### Fixed
- macOS support, which had never worked and which no test could have caught.
  The audit behind this release found three independent problems, none of which
  fails loudly: `/bin/bash` on macOS is 3.2, BSD userland is not GNU userland,
  and the iOS half of this library had no callers.

- **bash 3.2.** The library now runs unchanged on the shell macOS ships. The 13
  `mapfile` calls became the while-read loop already used in `lib/ports.sh`; the
  associative arrays in `lib/ports.sh` and `lib/ollama.sh` became indexed ones,
  which is what they always were in effect; and `get_script_metadata` no longer
  returns its result through a bash 4.3 nameref. That last one mattered most:
  every `--help` path in this library was dead on a stock Mac, with no fallback.

  The `lib/ollama.sh` lookup was keyed by a `printf '%04d'` tag. As an array
  subscript `"0010"` is an arithmetic expression read as **octal**, so model
  selection collided from the tenth model on. It is keyed by the integer now.

  `templates/dev-cli/dev` ran `exec bash`, which resolves bash from `PATH` and
  discards the file's own `#!/usr/bin/env bash`. It now prefers a bash 4+ where
  one exists and falls back to 3.2 where none does. Generated shims delegate to
  `./dev` instead of duplicating that resolver into every consuming repo.

  `helpers.sh` refuses anything older than 3.2 and, on 3.x, prints a one-time
  advisory to stderr — never stdout, and only to a terminal, so it cannot
  corrupt a helper whose output is parsed or fill a CI log.

  Three functions still require bash 4 because they take an associative array
  *from the caller* — `select_distro`, `select_multiple_distros`, `download_iso`.
  They now say so through `require_bash4` rather than returning wrong values.

  A ninth of the same shape sat in a bash regex rather than in grep:
  `[[ $line =~ ^#( |\t)(.*) ]]` in `lib/help.sh`. Bash's ERE has no `\t`
  escape, so a tab-indented script header lost every continuation line and
  rendered no `Parameters:` block at all -- no error, no match, exactly like the
  grep patterns. It is `[[:space:]]` now, one character wide, because the rest
  of a block's indentation is reproduced as written. `portability_test.sh` bans
  `\t` inside `[[ =~ ]]`, and `help_test.sh` carries a tab-indented fixture
  written with printf so no reformatting can quietly make it pass.

- **BSD userland.** Eight `grep` patterns used GNU `\s` or `\b`. BSD grep does
  not reject those; it simply never matches them, so each one silently did
  nothing on macOS. `add_to_etc_hosts` therefore concluded "absent" every time
  and appended a duplicate `/etc/hosts` line on every call, and the docs linter
  reported every function as undocumented, which made `make lint-docs`
  impossible to pass on a Mac. Also fixed: `md5sum` in a test (absent on macOS),
  `base64 -d` (older macOS spells it `-D`, and the failure blamed the caller's
  input), `mktemp --suffix` (whose fallback dropped the extension that ffmpeg's
  `palettegen` infers its format from), and a generated Homebrew wrapper that
  hardcoded `#!/bin/bash` — on the one platform where that is always 3.2.

- **Empty arrays under `set -u`.** bash 3.2 treats `"${arr[@]}"` on an empty
  array as an unbound variable; bash 4.4 made it safe. `scripts/preflight.sh`
  aborted on its own argument parsing, and `scripts/lint_docs.sh` on any module
  with no functions. Both now use the `"${arr[@]+"${arr[@]}"}"` form already
  present elsewhere in this repo, as do the Homebrew packaging scripts, which
  by definition only ever run on a Mac.

- `get_os` matched only `linux-gnu*`, so it returned `unknown` on Alpine
  (`linux-musl`) and Termux (`linux-android`), sending `docker_install`, `deps`
  and `certs` down their do-nothing branches. It now matches any `linux*`, and
  reads `$OSTYPE` defensively so a caller under `set -u` is not aborted.

- Everything released in 0.24.1 is carried forward here, so 0.25.0 is a
  superset of it. `scripts/install_dev_cli.sh` no longer destroys the caller's
  original script when `--shims` runs twice: the backup was an unconditional
  `mv "$dest" "$dest.pre-dev-cli"`, and on a second run `$dest` is the shim the
  previous run wrote, so the move replaced the original -- the only copy -- with
  our generated three-line shim. An existing `.pre-dev-cli` is now kept and the
  current file removed instead, and that removal is guarded on the
  `# Compatibility shim. Use ./dev ...` marker so only a shim this script wrote
  is ever discarded. `rm`, `mv`, `cp` and `chmod` pass `--` before the path, so
  a shim name beginning with a dash cannot be read as an option. Covered by
  `tests/install_dev_cli_test.sh`, whose cases fail on the respective unfixed
  code and which asserts the installer's exit status rather than discarding it.
  That test's shim assertion keys on the `# Compatibility shim. Use ./dev ...`
  marker the installer's own re-run guard greps for, not on `scripts/cli.sh`:
  the shim this release writes delegates to `./dev`, so the original assertion
  passed on 0.24.1 and failed the moment the two changes met.

### Added
- `lib/os.sh`: `is_macos`, `is_linux`, `bash_major`, `bash_at_least` and
  `require_bash4`. The library branched on `get_os` in five modules without ever
  having a predicate for it, and had no bash-version guard anywhere at all.

- `./dev deploy ios --release` requires `IOS_EXPORT_OPTIONS_PLIST`, and says so
  before it starts building. Without a plist `ios_build_release` falls back to
  `flutter build ios --release --no-codesign`, which writes an unsigned `.app`
  and nothing at all under `build/ios/ipa`. The install step globs that
  directory newest-first, so an `.ipa` from an earlier signed build was picked
  up and pushed to the device -- a stale binary installed with every step
  reporting success. Gated by `tests/dev_deploy_ios_test.sh`, which watches the
  build and install steps rather than the exit status, since nothing on that
  path ever returned non-zero.

- `get_script_metadata` refuses an unreadable script file up front, returning 2
  and naming the path. Left to the redirection on its read loop, a missing file
  failed inside `lib/help.sh`, so a caller under `set -e` was aborted with a
  raw "No such file or directory" citing this library and a line number rather
  than the path it passed in. A directory was worse: the redirection succeeds,
  `read` fails without assigning, and the loop condition then aborted on
  `line: unbound variable` under `set -u`. `line` is initialised for that
  reason too. `display_help` already guarded this; `get_script_metadata` is
  public API and is called directly.

- **iOS is reachable.** `lib/ios.sh` and `scripts/ci_ios.sh` were complete,
  correct and called by nothing: `ios_install` and `ios_launch` had no callers,
  `preflight` had no `ios` stack, and `verb_deploy` was hard-wired to `adb`, so
  `./dev deploy ios` silently built and installed an Android APK.

  `deploy`, `run` and `build` now branch on the target word. `deploy ios`
  resolves a booted simulator, builds, installs and launches; `build ios
  --release` goes through `ios_build_release`, so the signed-IPA path is
  reachable from `./dev` for the first time. New: `ios_resolve_device`,
  `ios_resolve_physical_device`, `ios_bundle_id` and `ios_artifact` — the last
  two are what `ios_install` and `ios_launch` needed to be callable at all, and
  the two resolvers exist separately because a debug deploy installs a simulator
  `.app` through simctl while a release deploy installs a signed `.ipa` through
  devicectl onto real hardware. Resolving a simulator for the latter cannot work. `flutter_build` gained
  `--simulator`, because `flutter build ios` targets a physical device and the
  `.app` it produces cannot be installed on a simulator.

  `preflight` gained an `ios` stack, detected from a Flutter project with an
  `ios/` directory or a `Podfile`, which finally gives `ci_ios.sh` a caller. Off
  macOS it reports SKIP with a reason rather than failing. `check_flutter` no
  longer builds an APK unconditionally: without an `android/` directory or an
  Android SDK it skips that step, so preflight on a Mac stops demanding a
  toolchain the repository never asked for.

- The portability gate also refuses an unescaped `*(` in a parameter expansion.
  It is not a bash-4 problem but the same silent shape: `*(` is the extglob
  "zero or more" operator, so `${line##*(}` parses differently in a caller that
  ran `shopt -s extglob` and returns the wrong text with no error to notice.

- `tests/scope_test.sh`: these helpers are sourced into other people's scripts,
  so an undeclared loop variable becomes a global in the caller. The while-read
  loops that replaced `mapfile` introduced exactly that across five modules;
  every affected variable is now declared, and the test asserts a call leaves no
  trace behind.

- `tests/dev_shim_test.sh`, covering which bash the shim selects: it prefers 4+,
  accepts 3.2, and refuses 3.0 and 3.1 rather than committing to an interpreter
  helpers.sh will reject a moment later. The rule is impossible to exercise from
  Linux by hand, where every candidate is bash 5.

- `tests/portability_test.sh`, a blocking static gate for GNU-only utilities and
  bash-4-only syntax. CI has always run shellcheck with `|| true`, so nothing
  here could fail a build; every rule in this gate was verified to fire by
  introducing the construct it bans and watching it fail.

- `scripts/local_test_bash32.sh` and `make test-bash32`: the whole suite under a
  real bash 3.2 in Docker, so the constraint is verifiable from a Linux box.
  Tests whose subject is a missing tool are reported as SKIPPED, because a test
  that fails for want of `git` says nothing about bash 3.2.

- A macOS CI job (`.github/workflows/ci-macos.yml`) running the suite explicitly
  under `/bin/bash`. GitHub's macOS runners also carry a modern bash, so the
  legacy shell has to be named or the job proves nothing. It is path-filtered to
  shell changes: GitHub bills macOS runners at a 10x minute multiplier, and
  the absence of any macOS job is why all of the above stood for 23 releases.

- Tests for `lib/help.sh`, `lib/os.sh`, `lib/hosts.sh` and preflight detection.
  `lib/help.sh` had none, and it is the file this release changes most.

### Changed
- **`get_script_metadata` takes a variable-name prefix, not an associative array.**
  `get_script_metadata ./x.sh meta` now sets `meta_name`, `meta_usage` and so on
  instead of filling `meta[...]` through a nameref. Callers of `show_help`,
  `print_help` and `display_help` are unaffected, and their output is unchanged.
  Only direct callers of `get_script_metadata` need to move from `${meta[usage]}`
  to `$meta_usage`. It returns `2` when the prefix is missing or is not a valid
  shell variable name, rather than emitting one `printf` error per field and
  leaving the caller half-populated state to diagnose. Its arguments, and
  `add_to_etc_hosts`', are defaulted rather than bare: under `set -u` a bare
  `"$2"` aborts the caller on the expansion itself, before the function can
  return the error code it documents.

- `add_to_etc_hosts` compares whitespace-separated tokens exactly instead of
  interpolating the domain into a `grep` pattern, and skips comment lines. A
  hostname carries its own dots into a regex, where `.` matches any character,
  so `demo.local` was "found" in a file holding only `demoXlocal` and the real
  entry was then never added. It also honours `HOSTS_FILE` and writes directly
  when the file is writable, falling back to `sudo tee`. The presence test was wrong on macOS and
  nothing could demonstrate it, because exercising it meant editing the real
  `/etc/hosts` as root.

- `Makefile` uses the `bash` on `PATH` rather than `/bin/bash`, which on macOS is
  3.2 whatever the developer has installed. Bash 3.2 coverage is now an explicit
  target rather than an accident of platform.

- preflight's "tool is not installed" skips name a platform-appropriate fix, so a
  Mac is no longer told to run `apt install`.


## 2026-09-08 — v0.24.1

### Fixed
- `scripts/install_dev_cli.sh` no longer destroys the original script when
  `--shims` is run twice. The backup was an unconditional
  `mv "$dest" "$dest.pre-dev-cli"`, but on a second run `$dest` is the shim the
  previous run wrote, so the move replaced the caller's original — the only
  copy of it — with our generated three-line shim. An existing
  `.pre-dev-cli` backup is now kept and the current file removed instead.

  That removal is guarded: only a shim this script wrote is discarded, matched
  on its `# Compatibility shim. Use ./dev ...` marker. If `.pre-dev-cli` exists
  for some other reason and the root file is a real script, the backup slot
  that would have saved it is already taken, so there is no move that does not
  lose a file -- the shim is skipped with a warning and both files are left
  alone. `rm`, `mv`, `cp` and `chmod` now also pass `--` before the path, so a
  shim name that begins with a dash cannot be read as an option. Covered by
  `tests/install_dev_cli_test.sh`, whose cases fail on the respective unfixed
  code and which asserts the installer's exit status rather than discarding it.

## 2026-09-02 — v0.24.0

### Added
- `lib/git_branches.sh` and `scripts/prune_branches.sh`: branch maintenance that
  any repository vendoring these helpers can run. `git branch --merged` only sees
  merges that produced a merge commit, so a repository that squash-merges
  accumulates branches it will never list and people delete by hand. The
  squash case is detected by rebuilding the commit a squash merge would have
  produced and asking `git cherry` whether that patch is already upstream.

  The costly mistake is the other one: a branch whose work landed and which
  then received new commits still has something to lose. Both tests look at
  the branch tip as it stands, so a commit added after the merge fails both —
  the protection falls out of the check rather than being a rule to remember.
  It is a dry run by default, refuses the base branch, the current branch, a
  branch checked out in another worktree, protected names including
  `release/*`, and anything holding commits its upstream does not. `--base`
  accepts `main`, `origin/main` or a full ref and normalises before comparing,
  because an un-normalised base matches no local branch and stops being
  recognised as the base. The squash probe carries its own throwaway identity:
  `git commit-tree` refuses to run without one, and where there is none the
  probe would fail silently and report every squash-merged branch as unmerged.
  A probe that cannot run now reports `unknown` rather than `unmerged` — both
  keep the branch, but only one of them means the question was answered.
- `tests/git_branches_test.sh`: a fixture repository covering merge-commit,
  squash, never-merged and unrelated histories — and the case the file exists
  for, a branch squash-merged and then committed to again, which must survive.

### Changed
- `scripts/git-hooks/pre-push` returns immediately when a push contains only
  ref deletions. There are no new commits for a test suite to have an opinion
  about, and running one is the kind of latency that teaches people to reach
  for `--no-verify` — pruning three merged branches otherwise ran the full
  gate three times. Skipped only when every ref in the push is a deletion.
- Comments and module docs name `iso-forge` rather than `burn-iso`, following the
  rename of the repository these helpers were first written for. No behavior changed.


## 2026-08-22 — v0.23.0

- Added: `lib/hub.sh`, corpus-hub setup for capture clients. Every client of
  the corpus hub was told to reach it at a typed `HUB_URL` and nothing
  checked the key, told anyone the hub was behind, or made a hub exist on a
  fresh machine beyond printing "clone the other repository". One module
  both clients import: `hub_setup_dialog` asks whether the hub is **local**
  (clone it when absent and run the hub's own `./start --configure-superuser`
  and `./install-service` -- never compose) or **remote** (URL and key),
  proves the answer (`hub_probe` on `/v1/service`; `hub_check_key` on an
  authenticated read, where a 401 is reported as a wrong key and not as a
  missing hub), and writes `HUB_MODE`, `HUB_URL`, `HUB_API_KEY` and the hub's
  `HUB_INSTANCE_ID` with an in-place, symlink-safe `hub_write_env`.
  `hub_offer_update` compares the running version with the newest tag and,
  to a person and in local mode only, offers to exec the hub's own
  `./update`. Three renderers behind one set of prompts: `dialog` when
  installed on a terminal, plain `read -p` otherwise, and no prompt at all
  without a terminal -- a systemd unit or CI run fails naming the variable it
  wanted instead of waiting on a read forever. The clone URL is an argument;
  the library names no repository. `tests/hub_test.sh` runs it against a
  fake hub and stubbed hub scripts.

## 2026-08-09 — v0.22.0

- Added: wireless-adb helpers in `lib/adb.sh`. A phone on the desk is not always
  a phone on a cable, and `adb connect` has three sharp edges that every project
  rediscovers separately — tcpip mode is lost on reboot and the failure looks
  identical to a wrong address; Android 11+ "Wireless debugging" allocates a
  random port per session so a hard-coded 5555 quietly stops working; and
  `adb connect` exits 0 on a bare TCP handshake, so success is not evidence a
  device is usable.
  The address comes from `DEV_DEVICE` — the existing dev-cli convention for
  which device, and what `--device` sets, so one variable covers both which
  device and where to connect; a USB serial there has no colon and is correctly
  not treated as an address. `ANDROID_DEVICE_IP` / `_PORT` stay supported as an
  explicit split form.
  `adb_wireless_addr`, `adb_wireless_attached`, `adb_wireless_connect`,
  `adb_wireless_disconnect`, `adb_wireless_enable`, `adb_wireless_setup`,
  `adb_wireless_write_env` and `adb_wireless_recovery_hint`.
  `adb_wireless_connect` confirms against `adb devices` rather than trusting the
  exit status, and treats `offline` / `unauthorized` as not attached.
  `adb_wireless_setup` does the whole cable-to-wireless handover in one call and
  prints the address for a caller to store; `adb_wireless_write_env` upserts it
  into a gitignored env file as `DEV_DEVICE` without disturbing anything else
  in that file.
- Security: `adb_wireless_write_env` validates the host and port before writing.
  An env file is SOURCED by the shell that reads it, so whatever lands in it is
  executed. A newline in the value injected an extra line —
  `adb_wireless_write_env .env "$(printf '203.0.113.1\nFOO=$(id)')"` wrote a
  literal `FOO=$(id)` line, and sourcing ran it. The value is not always
  hand-typed: `adb_wireless_setup` takes it from `adb shell ip ...`, i.e. from
  whatever the attached device prints. Validation is at the sink, so every
  caller is covered. `adb_wireless_valid_host` / `adb_wireless_valid_port` are
  exported for callers that want to check earlier.
- Added: `scripts/check_no_private_ips.sh`. Wireless adb makes a device's LAN
  address part of daily work, and it then wants to end up in a README, a test
  fixture or a CI file. This fails on any RFC 1918 literal in a **tracked** file.
  Boundaries are spelled `(^|[^0-9.])` rather than `\b`, which is a GNU/PCRE
  extension and not POSIX ERE — under BSD grep the pattern would quietly match
  nothing and the gate would report success while checking for nothing at all.
  It scans tracked files and ignores untracked and gitignored files, so the env
  file the address is supposed to live in is never flagged — a gate that fired
  there would only teach people to skip it. RFC 5737 documentation ranges,
  loopback and `.local` names are allowed, because those are what a tracked
  example should use.

## 2026-08-09 — v0.21.0

- Fixed: `CHANGELOG.md`'s release headers did not match the format this library
  itself defines and checks. `lib/changelog.sh` exists because `ci-helpers`
  extracts release notes by finding a `## YYYY-MM-DD — vX.Y.Z` heading and
  silently falls back to an auto-generated commit list when it cannot — and
  every heading in this file was `## [X.Y.Z] - YYYY-MM-DD`, so every release
  published here has been getting the fallback. The twenty existing headings
  are converted and `make lint-docs` now runs `changelog_check_header`, since
  nothing ran it, which is how a checker shipped by this repository came to be
  failing on this repository.

- Changed: comments and examples now describe what a helper does rather than
  naming the project a convention was taken from. Several compatibility
  shims were labelled with the name of the codebase whose call shape they
  match, and one example invocation and one changelog line named specific
  projects. None of it was load-bearing — no code read those names — and a
  reader of this repository learns more from "takes a single combined command
  string" than from the name of a codebase they cannot see. This library is
  meant to be self-contained and readable on its own terms.

## 2026-07-31 — v0.20.0
- Fixed: `local_test_python.sh` ran only pytest, while `preflight` labelled the step "lint + test". A repo that moved its CI local therefore lost its Python lint gate without a word about it — the shape of failure this family exists to prevent. It now runs `ruff check .` whenever the project configures ruff (`[tool.ruff]` in `pyproject.toml`, or `ruff.toml`/`.ruff.toml`), and treats configured-but-not-installed as a failure rather than a skip: a gate the project declared and that never ran must not report green. A full (non-`--quick`) run installs ruff first.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` did not configure git hooks. In a repo that has deleted its build workflows the `pre-push` hook is the only remaining gate, and `core.hooksPath` lives in the untracked `.git/config` — so every clone but the one the migration was done on had no gate at all. `install` now runs `setup-hooks.sh`, in both shells.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` ran `python3 -m pip install -r requirements.txt` against the system interpreter, which a PEP 668 host refuses outright, aborting `./dev install`. It now resolves the same project-local `.venv` that `local_test_python.sh` uses, and installs the `dev` extra so preflight's tools are present.
- Fixed: `dev_stack_dir` returned success with empty output when a stack was absent — awk exits 0 when it matches nothing — so the `|| echo .` fallback at every call site was dead code and an empty directory reached `android_build`/`flutter_build`. It now returns 1.
- Fixed: `--device` / `--user` as the final argument killed `./dev` silently. `shift 2` with one argument left returns non-zero and `set -e` ended the process before the validation below could name the missing value. Both options now check for an operand first.
- Fixed: `templates/dev-cli/cli.ps1` could throw before doing anything. `[string[]]$Rest` is `$null` rather than an empty array when nothing follows the verb, and `Set-StrictMode -Version Latest` makes `$Rest.Count` a terminating error. Also `Verb-Devices` referenced `$IsMacOS`, which does not exist in Windows PowerShell 5.1 (same StrictMode rule), and imported an `ios` module that has no PowerShell implementation — a hard error on macOS instead of the "no simulators" notice it intended. All three are guarded, and PowerShell `Verb-Install` gained the python/node parity the Bash verb already had.
- Added: PowerShell parity for the Windows story. `ps/lib/docker_install.ps1` mirrors the Bash module function-for-function (`install_docker`, `ensure_docker`, `docker_ready`, `docker_install_status`, `docker_report_state`, `docker_start_daemon`, `wait_for_docker_daemon`), with switch parameters (`-Yes`, `-DryRun`, `-NoStart`, `-TimeoutSec`) in place of the flags and identical exit codes. Plus `ps/scripts/install_docker.ps1`, the counterpart to `bin/install-docker`. Windows is the primary target — Docker Desktop is the mechanism there, not a convenience — so it gets full support (`winget` → Chocolatey → official installer, TLS 1.2 forced for Windows PowerShell 5.1, `$ProgressPreference` silenced so the download is not ~10× slower, and a non-elevated warning rather than an opaque UAC failure). macOS is Homebrew-cask only and Linux defers to the Bash module by design, rather than maintaining two implementations of package-manager detection and the `docker` group.
- Added: `ps/lib/serve.ps1` and `ps/lib/svg.ps1` — PowerShell counterparts for the modules added in 0.17.0 and 0.18.0, which shipped Bash-only. `serve_static_site` uses `TcpClient` for the free-port probe (`Get-NetTCPConnection` is Windows-only) and keeps the same python3 → python → `npx http-server` preference and return codes. `svg_rasterizer` prefers `magick` over the legacy `convert` on Windows and refuses to match `convert.exe` from the system directory — that is the FAT-to-NTFS conversion utility, not ImageMagick.
- Fixed: `ps/scripts/tag_release.ps1` could not be parsed, so the script was unusable. `"Invalid version in $File: $version"` parses `$File:` as a scoped variable reference (the `$env:PATH` form); it needs `${File}`. Pre-existing on `main`.
- Added: a `powershell` CI job that parses every `ps/**/*.ps1` and imports every module. PowerShell had never been built or linted in CI, which is how the `tag_release.ps1` syntax error shipped unnoticed. The Bash `lint-and-examples` job now also runs `make test`, which it previously did not.
- Note: `ios` remains Bash-only on purpose. It drives Xcode, `xcrun` and `simctl`, which exist only on macOS; the Bash module already no-ops elsewhere via its `ios_available` gate, so a PowerShell mirror would be a file full of stubs. `ollama` and `package_publish` are also still Bash-only, but predate this change and were left alone.

- Added: `docker_install` module (`lib/docker_install.sh`) — gets Docker onto a bare machine, so a project bootstrap can go from nothing to a working `docker compose` without sending the operator off to read platform-specific install docs. Companion to `docker`, which assumes Docker already exists. Installs Docker Engine + the compose v2 plugin on Linux (Docker's official `apt`/`dnf`/`yum` repositories; distribution packages on openSUSE and Arch), Docker Desktop on macOS (Homebrew cask, else the official `.dmg` for the detected CPU) and on Windows (`winget` → Chocolatey → official silent installer, from Git Bash/MSYS2), and detects WSL explicitly, explaining Docker Desktop-with-integration versus Engine-in-distro before installing either. Detection helpers (`docker_cli_installed`, `docker_daemon_running`, `docker_compose_v2_available`, `docker_ready`, `docker_install_status`, `docker_report_state`), the installer (`install_docker`, `ensure_docker`), and the reusable pieces (`docker_start_daemon`, `docker_add_user_to_group`, `wait_for_docker_daemon`). Plus a CLI wrapper `bin/install-docker` (adds `--check`) and `tests/docker_install_test.sh`, which is detection- and dry-run-only so `make test` never installs anything.

  Behaviour worth knowing: `install_docker` is **idempotent** — a working Docker returns 0 having changed nothing. When the CLI exists but the daemon does not answer it **starts what is already installed** before considering an install, because a closed Docker Desktop is the common case and reinstalling is the wrong fix. It prints its plan and asks before modifying the system (`--yes` skips, `--dry-run` shows without doing, `--no-start` and `--no-group` narrow the scope). Exit `3` means installed-but-daemon-not-up, which on Linux is almost always the `docker` group change not applying to the current shell — the module says so rather than leaving the caller guessing. Apt derivatives are mapped onto their upstream (Mint/Pop!_OS/neon/Zorin/elementary → `ubuntu`, Raspbian/Kali/Parrot → `debian`) and the repository line prefers `UBUNTU_CODENAME` over `VERSION_CODENAME`, since the latter is the derivative's own release name and 404s against Docker's repository.
- Added: `android` module (`lib/android.sh`) — the build side of Android, counterpart to `adb`, which owns everything that happens on an already-running device. SDK discovery (`android_sdk_root`, `android_available`, `android_sdk_tool`, searching the SDK's several layouts and versioned `build-tools` newest-first), bootstrap (`android_ensure_sdk` accepting licenses and installing platform-tools/platform/build-tools), building (`android_gradlew`, `android_build` — one spelling of the debug/release toggle where consuming repos had four, and `android_artifact`, which distinguishes "not built yet" from "built and here it is"), signing (`android_sign` via `apksigner` or `jarsigner`, with the keystore from a file or base64-decoded out of an environment variable, and an opt-in `--allow-unsigned` debug-signed fallback so a local build proceeds without release credentials), and emulators (`android_avd_list`, `android_avd_create`, `android_emulator_start` waiting on boot completion, `android_emulator_stop`). Loads the `gradle` and `adb` modules itself, so `shlib_import android` is sufficient.
- Added: `flutter` module (`lib/flutter.sh`) — `flutter_resolve_sdk` finds Flutter in the places a non-interactive shell's PATH misses (a snap, a tarball under `$HOME`, fvm), which consuming repos had solved by pasting the same candidate-path loop into every script that needed it. Plus `flutter_available`, `flutter_run_cmd` (the single point where SDK resolution lives), `flutter_pub_get`, `flutter_analyze`, `flutter_format_check`, `flutter_test`, `flutter_build` (defaulting to `--release`, since a mode-less Flutter build is a debug build and that is rarely what a build function's caller means), `flutter_devices` (with a `jq`-free fallback), and `flutter_resolve_device`, which refuses to guess between two connected devices.
- Added: `gradle` module (`lib/gradle.sh`) — `gradle_available`, `gradle_wrapper`, `gradle_run`, `gradle_lint`, `gradle_test`, `gradle_assemble`, `gradle_clean`. Prefers the project's `./gradlew` over a system `gradle`, because the wrapper pins the version and a system `gradle` does not. Kept separate from `android` so a plain JVM host component need not import an Android toolchain to run `test`.
- Added: `screencap` module (`lib/screencap.sh`) — screenshots and screen video from a device, emulator or simulator, for README media, store listings and bug reports. `screencap_available`, `screencap_shot`, `screencap_record`, `screencap_record_stop`, `screencap_frame` and `screencap_gif` (two-pass with a generated palette, because a single-pass GIF from video is visibly dithered). Two device limits are reported rather than hidden: `screenrecord` caps a clip at 180 seconds, so longer requests are chunked and concatenated instead of silently truncated; and a physical iOS device cannot be recorded without Xcode driving it, which returns 3 with an explanation rather than appearing to succeed. Generated names land in `docs/screenshots/`, overridable with `SCREENCAP_DIR`.
- Added: `manifest` module (`lib/manifest.sh`) — `manifest_kind`, `manifest_detect`, `manifest_read_version`, `manifest_write_version`, `manifest_android_version_code` and `manifest_sync_version`, across `pubspec.yaml`, `build.gradle[.kts]`, `VERSION`, `package.json` and `pyproject.toml`. A phone app states its version in three places at once and they drift; `manifest_sync_version` is the "one release, one number" operation. A pubspec's `+build` counter is preserved and the Play Store `versionCode` is recomputed from semver; a non-semver input returns 2 rather than emitting a wrong `versionCode`, which the Play Store rejects only after the upload.
- Added: `changelog` module (`lib/changelog.sh`) — `changelog_check_header`, `changelog_extract` and `changelog_new_section`. The `## YYYY-MM-DD — vX.Y.Z` header is load-bearing: `ci-helpers` extracts release notes by finding that section, and any other shape silently falls back to an auto-generated commit list. The checker calls out an ASCII hyphen where the em-dash belongs, which is the common near-miss.
- Added: `scripts/preflight.sh` — one command that runs every check CI would have run: lint, format, tests, build and a secret scan. It detects `(stack, directory)` pairs rather than a single stack at the repo root, which is what lets it replace a multi-job workflow in a repo with an app in `android/` and a host in `host/`; a repo can pin the list with a `.preflight` file when autodetection picks up a directory CI never built. A skipped check is reported separately from a passing one, so an absent toolchain cannot look green. Carries the same local-only guard as the other `ci_*.sh` runners.
- Added: `scripts/local_test_gradle.sh` — the missing member of the `local_test_*` family, autodetecting Android task names from the applied Gradle plugin.
- Added: `scripts/install_dev_cli.sh` and `templates/dev-cli/` — one `./dev` verb set for every consuming repo: `install build run test preflight deploy devices screenshot record logs clean update release`. A verb a repo cannot honour prints why and exits 0 rather than being absent, because a missing verb is indistinguishable from a typo. `_bootstrap.sh` is copied rather than sourced from the library, since locating the library is the thing it does, and it self-heals an uninitialized submodule. Repo-specific behaviour goes in `scripts/project.sh`, so `cli.sh` stays refreshable from the template. The installer leaves old root scripts as thin shims.
- Added: `adb_install` takes `--user <id>`, defaulting to `0` (the device owner), and passes it through to `adb`. Plus `adb_installed_for_user` and `adb_install_verified`. An unqualified `adb install` can land a package in a profile the shell cannot subsequently read: on a device with a work profile or Samsung Secure Folder the install prints `Success` and exits 0, `pm list packages` fails with `SecurityException: Shell does not have permission to access user <id>`, and the app is absent from the launcher and unstartable by `am start`. Every signal says the install worked, so the symptom reads as an app fault rather than a deploy fault. Pinning the user prevents the common case; `adb_install_verified` prevents the class, because an installer's exit code asserts that adb accepted the command, not that the app is usable. Note that `adb shell` exits 0 even when the command inside it failed, so the check reads the output rather than the status. `android_package_name` supplies the package name to verify, preferring `aapt` on the built artifact since that is the only source accounting for `applicationIdSuffix` and flavors.
- Changed: `scripts/git-hooks/pre-push` now detects Gradle and Android projects — whose absence previously produced "No test runner detected" and a green push — and delegates to `preflight --quick` when it is available. It distinguishes "preflight is not installed" from "preflight failed", so a failing check can never fall through to a weaker one and let the push pass.
- Added: PowerShell companions for every new module (`ps/lib/{android,flutter,gradle,screencap,manifest,changelog}.ps1`) plus `ps/scripts/preflight.ps1` and `ps/scripts/local_test_gradle.ps1`. The PowerShell preflight is native rather than shelling out, so the same verbs work in Windows PowerShell with no Git Bash present.

## 2026-07-26 — v0.19.0
- Added: `ios` module (`lib/ios.sh`) — an iOS device/simulator toolkit, the counterpart to `adb`. Discover hardware and simulators (`ios_list_devices`, `ios_list_simulators`, `ios_booted_simulators`), control simulators (`ios_boot_simulator`, `ios_shutdown_simulators`), install and launch builds (`ios_install` for `.app`/`.ipa`, `ios_launch`), and build a Flutter release (`ios_build_release`: a signed IPA with an ExportOptions plist, otherwise an unsigned iOS app). macOS-only: every function no-ops on other hosts (`ios_available` gate) so callers degrade cleanly. Plus `scripts/ci_ios.sh`, a host-based analyze/test/build runner (Apple's toolchain runs only on macOS, so unlike the Docker-based `ci_*.sh` helpers it has no image and exits early elsewhere).

## 2026-07-25 — v0.18.0
- Added: `svg` module (`lib/svg.sh`) to rasterize SVG art to PNG for app logos and launcher icons. `svg_rasterize <in.svg> <out.png> [size]` renders a square PNG (default 1024px), preferring Inkscape and falling back to ImageMagick (`magick`/`convert`); `svg_rasterize_sizes` emits one PNG per size for icon sets; `svg_rasterizer` reports the available tool. Plus a CLI wrapper `bin/svg-rasterize` and a `tests/svg_test.sh` smoke test (auto-picked up by `make test`). Extracted from an application's icon-generation flow so the rasterizing step is defined once here rather than per project.

## 2026-07-21 — v0.17.0
- Added: `serve` module (`lib/serve.sh`) with `serve_static_site <dir> [port]` to preview a static/GitHub-Pages directory locally — auto-picks a free port (default `8000`), prefers `python3 -m http.server`, falls back to `python` (`http.server` on Python 3 or `SimpleHTTPServer` on Python 2) then `npx http-server`. Plus a CLI wrapper `bin/serve-pages` and a `tests/serve_test.sh` smoke test (also runnable via new `make test` target).
- Added: PHP/Laravel support for the local test runner and `pre-push` hook. New `scripts/local_test_php.sh` runs `composer install` (skipped with `--quick`), Laravel Pint style checks when available, and the suite via `php artisan test` (falling back to `vendor/bin/phpunit`); `SKIP_PHP_TESTS=1` gives a style-only run for pre-push without a local database. In the `pre-push` hook, `composer.json` is authoritative so Laravel apps that also ship a `package.json` for Vite run their PHP suite instead of falling through to the Node runner.
- Changed: release automation now reuses the shared ci-helpers reusable workflows instead of hand-rolled logic. `auto-tag-release.yml` (on merge of a `release/X.Y.Z` PR to `main`) calls `ci-helpers/auto-tag-release.yml@production` to detect+tag the version, `create-github-release.yml@production` to publish the Release in the same run, and moves the `production` branch. Removes the bespoke `release-tag.yml` and `auto-tag.yml`.
- Added: `adb` module — a multi-device-safe Android Debug Bridge toolkit (Bash `lib/adb.sh` + PowerShell `ps/lib/adb.ps1`). Inspect devices (`adb_list_devices` table of serial/model/Android OS/API level/IP; `adb_device_status`, `adb_device_api`, `adb_android_version`, `adb_device_ip`), install apps (`adb_install`, `adb_install_all`, `adb_uninstall`), copy files (`adb_push`, `adb_pull`), and debug (`adb_shell`, `adb_logcat`, `adb_clear_logcat`, `adb_battery_level`, `adb_screen_on`). Every command targets `adb -s <serial>` so it works with more than one device attached. Plus a reusable CLI wrapper `scripts/adb_tool.sh`.
- Added: CI helper scripts for Node, Python, Flutter, Gradle, Go, and basic security checks.
- Added: `scripts/pin_production.sh` to fast-forward the production branch to a release tag.
- Added: `scripts/check_release_version.sh` to verify release versions before tagging or publishing.
- Added: `--version` and `--image` parameters to all `ci_*.sh` scripts for Docker image tag and full image override.

## 2026-06-12 — v0.14.0
- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpers` now always loads `logging` first unconditionally; previously it skipped the pre-load when `logging` appeared anywhere in the caller's list, leaving other modules without logging if they were listed before it.
- Fixed: `ps/lib/help.ps1` — `get_script_metadata` and `_Help_Render` now guard against empty/null `$ScriptFile` (interactive use with no `SHLIB_CALLER_SCRIPT`) instead of throwing on `Test-Path` and `Path::GetFileName(null)`.
- Fixed: `ps/lib/traps.ps1` — `enable_strict_mode` uses `Set-Variable -Scope 1` to write `ErrorActionPreference` into the immediate caller's scope rather than `$Global:`, so it no longer leaks strict mode into the wider PowerShell session.
- Fixed: `ps/scripts/ci_go.ps1`, `ci_node.ps1`, `ci_python.ps1`, `ci_rust.ps1` — `-UseDocker` mode now calls `check_docker` before invoking Docker; previously a missing/stopped Docker daemon produced a generic "command not found" error instead of the structured diagnostic from the helper.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now unregisters and re-registers by `SourceIdentifier` instead of storing the `PSEventJob.Id` as a subscription ID; `PSEventJob.Id` is the job ID, not the subscription ID expected by `Unregister-Event -SubscriptionId`, so the previous code could leave duplicate exit handlers on repeated calls.
- Fixed: `ps/lib/logging.ps1` — stderr path in `_Shlib_WriteColor` now guards ANSI codes with `[Console]::IsErrorRedirected`; previously `2>file` or `2>&1` captured raw escape codes even though the stdout path was already guarded.
- Fixed: `ps/lib/logging.ps1` — `_Shlib_WriteColor` now checks `[Console]::IsOutputRedirected` before the ANSI flag; previously the redirect branch was unreachable when ANSI was enabled, so redirected streams (files, pipelines) received raw escape codes instead of plain text.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now passes the handler via `-MessageData` and reads it as `$event.MessageData` inside the action block; the previous approach stored the handler in a `$script:` variable that is invisible in the separate runspace used by event actions.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the Bash API: takes a variable *name* and an optional default, returning the env var's value or the default when unset/empty. The internal `$VAR`/`${VAR}` expansion logic used by `load_env` is extracted into `expand_env_refs`.
- Fixed: `ps/lib/version.ps1` — `version_bump` now throws explicitly when `BumpType` is empty and creates the parent directory of `VersionFile` when it does not exist.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` now throws on an empty `$Cmd`, and uses splatting (`@rest`) to forward arguments so the call works correctly for both native executables and PowerShell functions.
- Fixed: `ps/lib/env.ps1` — `load_env` now uses `foreach`/`continue` instead of `ForEach-Object`/`return`; the old form exited the function on the first blank line or comment instead of skipping only that line.
- Fixed: `ps/lib/packaging.ps1` — `pkg_load_metadata` same fix: `ForEach-Object { return }` was exiting the function early on blank/comment lines.
- Fixed: `ps/lib/docker.ps1` — `check_docker` normalises each element of `docker info 2>&1` output to a string before joining, so ErrorRecord objects in mixed-type arrays do not produce a garbled error message in PS 5.1.
- Fixed: `ps/lib/certs.ps1` — `generate_self_signed_cert` no longer exports a PFX by default. PFX export is now opt-in: pass `-PfxPassword <SecureString>` to write the private-key bundle; the public `.cer` is always written. Prevents accidental unprotected private-key files on disk.
- Fixed: `ps/lib/traps.ps1` — `$_SHLIB_EXIT_SOURCE` now holds the literal string `'PowerShell.Exiting'` instead of `[PsEngineEvent]::Exiting`; the enum stringifies to `"Exiting"` which does not match the engine event's actual `SourceIdentifier`, so the exit handler would never fire (and could not be unregistered).
- Fixed: `ps/lib/env.ps1` — `get_project_root` now checks the filesystem root itself for `.git` after the traversal loop exits; previously the root path was never evaluated, causing incorrect fallback to `$StartDir` on drive-root repos.
- Fixed: `ps/lib/version.ps1` — `version_bump` success message now logs the original version string (including prefix/suffix like `v1.2.0-rc1`) instead of the stripped core after prefix/suffix mutation.
- Fixed: `ps/lib/file.ps1` — `create_directory` now returns `$true` on success and `$false` on failure (via `try/catch` with `-ErrorAction Stop`); previously it returned `$null` on all paths, making success checks unreliable.
- Fixed: `ps/lib/env.ps1` — `expand_env_refs` now expands unset `$VAR`/`${VAR}` references to empty string instead of leaving the literal placeholder, matching Bash `load_env` behaviour.
- Removed: `ps/lib/file.ps1` — `ensure_dir` helper removed; it was undocumented, absent from the Bash `lib/file.sh` API, and fully covered by `create_directory`.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the full Bash API with an optional third `$EnvFile` parameter; when the process env var is unset it falls back to reading the key from that file (default `.env`), matching the Bash `resolve_env_value(key, default, env_file)` signature.
- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpersAll` now loads `logging` first before iterating `Get-ChildItem` output; filesystem ordering is non-deterministic so the previous code could load other modules before `logging`, breaking any module that logs during import.
- Fixed: `ps/lib/help.ps1` — `show_usage` now uses `Write-Output` instead of `Write-Host` so help text can be redirected or captured by callers.
- Fixed: `ps/lib/file.ps1` — `download_file` now marks `$Url` as mandatory and wraps `Invoke-WebRequest` in `try/catch` returning `$true`/`$false`, consistent with `create_directory` and `verify_checksum`.
- Fixed: `ps/lib/hosts.ps1` — `add_hosts_entry` now checks only active (non-comment) lines when testing whether an entry already exists; previously a commented-out domain (`# 127.0.0.1 example.com`) would falsely prevent adding a real entry. `remove_hosts_entry` likewise now preserves comment lines even when they mention the domain.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` env-file fallback now uses the same parsing logic as `load_env` (handles `export` prefix, whitespace around `=`, and quote stripping) instead of a bare `StartsWith` that missed all those forms.
- Fixed: `ps/lib/help.ps1` — `_Help_PrintInline` and `_Help_PrintBlock` now use `Write-Output` for the non-colored fallback path so all help output is redirectable, consistent with the earlier `show_usage` fix.
- Fixed: `ps/lib/file.ps1` — `download_file` now pipes `Invoke-WebRequest` to `Out-Null` and suppresses the PS progress bar (`$ProgressPreference = 'SilentlyContinue'`) for the duration of the call; previously the response object leaked into the pipeline and the progress UI was noisier than the Bash equivalent.
- Fixed: `ps/lib/dialog.ps1` — `dialog_download_file` now pipes `Invoke-WebRequest` to `Out-Null`; previously the response object was emitted to the pipeline, potentially interfering with callers.
- Fixed: `ps/lib/ports.ps1` — `get_port_conflicts_json` wraps `$conflicts` in `@()` before `ConvertTo-Json` so a single-conflict result is always a JSON array `[{...}]` instead of a bare object `{...}`; without this PS unwraps a one-element array to a scalar.
- Fixed: `ps/lib/file.ps1` — `verify_checksum` now guards against missing/unreadable files with an explicit `Test-Path` check and `try/catch` around `Get-FileHash`, returning `$false` with a structured error message instead of surfacing raw cmdlet exceptions.
- Fixed: `ps/scripts/ci_rust.ps1` — in `-UseDocker` mode, `-Manifest` paths are now translated to container-relative `/work/<rel>` paths; passing an absolute Windows path or a path outside `-Workdir` now fails with a clear error rather than silently breaking cargo inside the container.

- Added: PowerShell companion library (`ps/`) for native Windows support without WSL.
  - `ps/helpers.ps1` — loader with `Import-ScriptHelpers` function (mirrors `helpers.sh` / `shlib_import`).
  - 19 PowerShell modules in `ps/lib/` mirroring all core Bash lib modules:
    `logging`, `os`, `env`, `file`, `deps`, `help`, `version`, `docker`, `ports`, `json`,
    `browser`, `traps`, `python`, `clipboard`, `dialog`, `certs`, `hosts`, `ci_defaults`, `packaging`.
  - `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — CI runners that work natively on Windows (no Docker required); pass `-UseDocker` for Docker Desktop mode. `-UseDocker` honours `-Quick` and `-SkipTest` in Python CI.
  - `ps/scripts/bump_version.ps1`, `tag_release.ps1` — version management for Windows.
  - `ps/scripts/example_logging.ps1` — demonstration script.
  - PS 5.1 (Windows built-in) and PS 7+ both supported.
  - `deps.ps1` uses `winget` → `choco` → `scoop` for package installation.
  - `ports.ps1` uses `Get-NetTCPConnection` replacing `lsof`/`ss`/`netstat`.
  - `certs.ps1` uses Windows Certificate Store (`New-SelfSignedCertificate`, `Import-Certificate`).
  - `hosts.ps1` targets `C:\Windows\System32\drivers\etc\hosts` (requires admin elevation).
  - `dialog.ps1` uses `Read-Host`-based prompts (Windows has no ncurses `dialog` binary).
- Fixed: `ps/helpers.ps1` — imported functions now survive into the caller's scope (`New-Module + Import-Module -Global`; previously dot-source inside a function discarded them on return).
- Fixed: `ps/scripts/*.ps1` — `SCRIPT_HELPERS_DIR` auto-detection now resolves to the repo root correctly (scripts live two levels below root, not one).
- Fixed: `ps/scripts/ci_node.ps1` — removed PS 7-only `??` null-coalescing operator; defaults to `node:22-alpine` when `CI_NODE_IMAGE` is unset.
- Fixed: `ps/scripts/ci_rust.ps1` — replaced `Invoke-Expression` with splatted `cargo` args to prevent injection from paths with spaces.
- Fixed: `ps/scripts/tag_release.ps1` — version regex now rejects trailing garbage while accepting pre-release suffixes (e.g. `1.2.3-rc1`).
- Fixed: `ps/lib/docker.ps1` — `docker_compose` now correctly invokes `docker-compose` binary when the plugin form is unavailable; `2>/dev/null` replaced with `2>$null`; CRLF-safe output splitting.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` no longer passes a null arg when the command is a single token.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` unregisters the previous subscription before registering a new one, preventing duplicate exit handlers.
- Fixed: `ps/lib/file.ps1`, `ps/lib/dialog.ps1` — `-UseBasicParsing` gated to PS 5.1 only (removed deprecation warning on PS 7+).
- Fixed: `ps/lib/python.ps1` — `py` launcher now always passes `-3` when detecting version and creating venvs.
- Fixed: `ps/lib/deps.ps1`, `ps/lib/json.ps1` — replaced `command_exists` calls with `Get-Command` to remove hidden cross-module dependency.
- Fixed: `ps/lib/hosts.ps1` — domain existence checks and removal now use word-boundary regex to avoid false matches on substrings.
- Fixed: `ps/lib/help.ps1` — `show_usage` and `parse_common_args` now recognise `-h`/`--help`, `-v`/`--verbose`, `-d`/`--debug` aliases matching the Bash `help.sh` API; header-separator regex updated from `^#-{3,}` to `^#\s*-{3,}` to match the spaced `# ----` form used by all PS scripts.
- Fixed: `ps/lib/env.ps1` — `load_env` now calls `resolve_env_value` so `FOO=$BAR` references in `.env` files are expanded (the function existed but was never wired up).
- Fixed: `ps/lib/logging.ps1` — `log_info`/`log_warn`/`log_error`/`log_debug` now emit ANSI colour on stderr when the terminal supports it (`$_SHLIB_ANSI`); previously colour was silently dropped on the stderr path.
- Fixed: `ps/lib/dialog.ps1` — `dialog_menu` marks `$Items` as `[Parameter(Mandatory)]` to fail fast instead of infinite-looping when omitted; `dialog_input` return uses `$(if …)` subexpression for PS 5.1 compatibility.
- Fixed: `ps/lib/docker.ps1` — `get_docker_compose_cmd` now pre-checks Docker CLI existence before probing plugin availability.
- Fixed: `ps/lib/packaging.ps1` — `to_camel_case` guards empty parts and single-char segments; `pkg_join_list` uses `-join` operator instead of `Join-String` (PS 5.1 compatible; `Join-String` requires PS 6.2+).
- Fixed: `ps/lib/deps.ps1` — `winget install` uses query form (no `--id`) so generic names like `curl`, `git`, `jq` work without vendor-qualified IDs.
- Fixed: `ps/lib/browser.ps1` — `check_port_open` calls `EndConnect()` after `WaitOne` to surface refused connections; `WaitOne` alone returns `$true` on any completion, including failure.
- Fixed: `ps/lib/version.ps1` — `Set-Content` uses `-Encoding ascii` so the `VERSION` file stays Bash-readable (PS 5.1 default encoding is UTF-16 LE).
- Fixed: `ps/lib/hosts.ps1` — `Add-Content` and `Set-Content` use `-Encoding ascii` to preserve the ANSI format required by the Windows hosts parser.
- Fixed: `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — Docker mode invokes executables directly (no `sh -c`) eliminating shell injection from user-controlled parameters.
- Fixed: `ps/scripts/ci_node.ps1` — `*Cmd` parameters changed to `string[]` token arrays for correct handling of arguments containing spaces or quotes.
- Fixed: `ps/scripts/ci_python.ps1` — `$TestCmd` changed to `string[]`; Docker pip install now skips when `requirements.txt` is absent, matching native mode behaviour.
- Fixed: `ps/scripts/bump_version.ps1` — missing `BumpType` now exits with code 1 (usage error) instead of 0.
- Added: `ps/lib/packaging.ps1` — `pkg_*` functions mirroring the Bash `packaging.sh` public API: `pkg_load_metadata`, `pkg_require_vars`, `pkg_trim`, `pkg_join_list`, `pkg_quote_list`, `pkg_render_lines`, `pkg_classify_name`, `pkg_guess_version`.

## 2026-05-21 — v0.13.0
- Changed: `scripts/git-hooks/pre-commit` — hardened for universal use across all repos:
  - Blocks accidental `.env` / `.env.*` file commits.
  - Docs lint (`lint_docs.sh`) skipped gracefully when the script is absent.
  - Release version check runs only on `release/*` branches (not on every commit).
- Added: `scripts/git-hooks/pre-push` — language-aware test runner (Node/Python/Go/Rust/Flutter) with auto-detection. Runs before every push; skip with `--no-verify` only when justified.
- Added: `scripts/setup-hooks.sh` — one-liner hook installer. Uses `.githooks/` when both shared hook entry points are overridden, otherwise falls back to `scripts/script-helpers/scripts/git-hooks/`, then `scripts/git-hooks/`.
- Added: `scripts/local_test_node.sh` — install + test for Node/npm projects (`--quick`, `--workspace`).
- Added: `scripts/local_test_python.sh` — venv-aware pytest runner that installs `requirements.txt` when present (`--quick`, `--dir`).
- Added: `scripts/local_test_go.sh` — `go vet` + `go test` across all modules (`--quick`, `--module`).
- Added: `scripts/local_test_rust.sh` — `cargo check` + `cargo clippy` + `cargo test` (`--quick`, `--manifest`).
- Added: `scripts/local_test_flutter.sh` — `flutter analyze` + `flutter test` (`--quick`, `--dir`).

## 2026-04-11 — v0.12.2
- Added: `scripts/check_release_tag.sh` so reusable workflows can perform release-tag checks via shared shell logic.
- Added: `scripts/ci_pimcore_bundle_check.sh` for reusable Pimcore bundle CI orchestration.
- Added: `scripts/ci_wp_plugin_check.sh` for reusable WordPress plugin-check CI orchestration.
- Added: `scripts/ci_gitleaks_report.sh` to normalize and evaluate Gitleaks SARIF output in reusable workflows.

## 2026-03-20 — v0.12.1
- Changed: Ollama model selection now uses a `dialog --menu` browser instead of the older radiolist/manual-entry flow.
- Changed: Ollama model browsers now default to official un-namespaced library models, sorted alphabetically, with a reusable parsed menu cache valid for 30 minutes.
- Changed: `ollama_dialog_select_size` now returns a distinct cancel status so callers can return to model selection instead of implicitly reusing an old size.
- Fixed: Ollama selector cache generation can be reused safely across repeated opens within the same session and across launches while the cache is still fresh.
- Fixed: Ollama selector cache refreshes now write atomically and ignore empty/stale cache files instead of reusing corrupted menu data.
- Fixed: Ollama size-selection warnings now go to stderr so stdout-only callers do not corrupt captured values.
- Added: dialog-based Ollama pull progress UI for runtime pulls, including model/layer/progress/speed/ETA parsing.
- Fixed: Dialog pull progress now cleans up background pulls on cancel and bounds progress-log parsing to the recent tail of the log file.

## 2026-02-13 — v0.12.0
- Added: Ollama runtime helpers in `lib/ollama.sh` for local/docker execution (`ollama_runtime_*`) and shared model ref builder (`ollama_model_ref`).
- Added: `is_wsl` helper in `lib/os.sh` for reusable WSL/WSL2 detection.
- Added: `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` support in `lib/dialog.sh` to optionally suppress popup error dialogs from `dialog_download_file`.
- Docs: Updated README and module docs for Ollama runtime helpers, WSL detection, and dialog error-popup controls.
- Docs: Added missing `ollama_model_ref_safe` API entry in `docs/modules/ollama.md` to match exported helper aliases.

## 2026-02-01 — v0.11.1
- Changed: Ollama model index preparation now reuses an existing JSON when present and resolves Python 3 via `python3` or `python` (3.x). Adds apt-based installs for `python3-bs4`/`python3-requests` with a non-fatal `apt-get update` fallback.
- Docs: Updated Ollama module docs and README to cover Python resolution and dependency handling.
- Fixed: Skip `pip` requirement when `apt-get` can install Python deps.
- Fixed: Fail fast if Python deps fail to install and verify deps after install.
- Added: `python` module for resolving Python 3 and ensuring local virtualenvs.
- Added: `OLLAMA_MODELS_REPO_REF` to pin the models repo before executing its scripts.
- Fixed: pip installs for Ollama deps avoid `--user` when running as root.
- Fixed: Validate Ollama model index JSON before falling back after a failed refresh.
- Fixed: Validate venv Python executables before returning from `python_ensure_venv`.
- Added: `--digest` parameter to `ci_flutter.sh` for supply-chain image pinning.
- Added: `--gitleaks-digest` parameter to `ci_security.sh` for supply-chain image pinning.
- Added: `lib/ci_defaults.sh` module — centralized Docker image version defaults for all CI scripts. No more `:latest` tags; all images use pinned versions. Overridable via CLI flags or environment variables.
- Changed: CI helper scripts default to Docker and refuse to run when `CI=true` (local-only).
- Changed: Docker cache mounts in all `ci_*.sh` scripts now target `/tmp/` paths with corresponding env vars (`NPM_CONFIG_CACHE`, `PIP_CACHE_DIR`, `PUB_CACHE`, `GRADLE_USER_HOME`, `GOMODCACHE`) to avoid permission issues with non-root UIDs.
- Changed: `ci_python.sh` Docker mode now chains install and test commands in a single container so pip-installed packages persist for the test step.
- Changed: `ci_security.sh` uses `--python-version`, `--node-version`, `--gitleaks-version` with defaults; `--*-image` overrides take precedence.
- Changed: `ci_security.sh` computes `ABS_WORKDIR` inside Docker/no-Docker branches for consistency with other CI scripts.
- Fixed: `pin_production.sh` now resets local production branch from remote before merge, with fallback for first-run when remote production does not yet exist.
- Fixed: `check_release_version.sh` RC warning message is now clearer about when a pre-existing base tag is expected.
- Fixed: Consistent Docker-not-found error messages across all `ci_*.sh` scripts.
- Docs: Added CI helper usage notes and production-branch release guidance.
- Docs: Clarified that `check_release_version.sh` works in both local hooks and CI pipelines.
- Docs: Added `--version`, `--image`, and `--digest` examples to usage guide.

## 2026-01-11 — v0.10.0
- Added: Cross-distro packaging scaffolds (Debian, RPM, Arch, Homebrew) with shared metadata templates.
- Added: Packaging helper module and scripts to render templates and build RPM/Arch artifacts.
- Added: Packaging docs covering structure, build commands, signing notes, and install commands.
- Changed: Auto-tag workflow now opens a PR for VERSION bumps instead of pushing directly to protected `main`.
- Changed: Tag existence checks now verify exact refs to avoid false matches (e.g., `0.10.0` vs `0.1.0`).

## 2026-01-08 — v0.9.1
- Added: `lib/package_publish.sh` for shared Debian/PPA publishing helpers.
- Added: package publish example script.
- Changed: packaging scripts now use shared helpers via `shlib_import`.
- Changed: download dialog gauge uses fixed sizing and no-shadow to avoid visual artifacts.
- Added: Debian packaging helpers (`scripts/build_deb_artifacts.sh`, `scripts/ppa_upload.sh`).
- Added: Homebrew packaging helpers (`scripts/build_brew_tarball.sh`, `scripts/gen_brew_formula.sh`, `scripts/publish_homebrew.sh`).

## 2025-12-26 — v0.9.0
- Changed: Unified script help rendering across `display_help`, `print_help`, and `show_help` with a shared renderer.
- Changed: `-h/--help` now prefers script-level header help when the caller script is known.
- Fixed: Header parsing now only reads the top comment block and captures parameter lines reliably without pulling unrelated script comments.

## 2025-12-20 — v0.8.0
- Added: `version` module (`version_bump`, `version_compare`) with support for optional version file paths and preserving prefixes/suffixes.
- Changed: `scripts/bump_version.sh` now delegates to `version_bump` and accepts `-f/--file`.
- Changed: `version_compare` now returns -1/0/1 (surfaced as 255/0/1 in shells) and keeps higher codes for errors (2 missing args, 3 invalid format).
- Docs: Added module docs and usage examples for version helpers.

## 2025-12-16 — v0.7.0
- Changed: Docker checks now distinguish missing CLI, stopped daemon, and permission errors for clearer guidance (2025-12-16).

## 2025-12-16 — v0.6.0
- Changed: `init_include` now finds the caller project root reliably and keeps debug logging safe under `set -e` (2025-12-16).

## 2025-11-27 — v0.5.0
- Added: `docker_status` in `lib/docker.sh` to show running containers and cross-check services from the current directory's `docker-compose.yml`, marking statuses with glyphs (✅ running, 💥 failed, ✖️ not running). Includes example `scripts/example_docker_status.sh` and updates to README/Makefile (2025-11-27).
- Changed: Tweak download notification messages for clarity in the dialog gauge (2025-11-05).

## 2025-11-03 — v0.3.0
- Added: Dialog-based download progress gauge via `dialog_download_file`, showing percent, size, speed, and ETA. Integrated into `file.sh::download_file` with automatic fallback to `curl`/`wget` when needed (2025-11-03).
- Added: Example scripts for downloads, dialog input, logging, env, Docker Compose, and JSON helpers; `make examples` target to run demos (2025-11-03).
- Changed: On download failures, display a `dialog` error with exit code and recent output before falling back to non-interactive download (2025-11-03).
- Docs: Expanded README with usage, compatibility notes, and `DOWNLOAD_USE_DIALOG` behavior (2025-11-03).

## 2025-10-22 — v0.2.0
- Added: Ollama helpers (`lib/ollama.sh`) and model installer script (`scripts/install_ollama_model.sh`) to install and manage models via dialog selection or CLI (2025-10-18).
- Added: `CHANGELOG.md` to document notable changes (2025-10-17).
- Added: `scripts/bump_version.sh` to bump semantic version string in `VERSION` (2025-10-22).
- Changed: README install instructions and guidance for using this repo as a Git submodule (2025-10-18, 2025-10-22).
- Maintenance: Purged `RELEASE_CHECKLIST.md` from history; updated version metadata (2025-10-17, 2025-10-22).
- Docs: Unified script help headers across `scripts/*` for consistent usage output (2025-10-22).

## 2025-10-17 — v0.1.0
- Initial release: Bootstrapped reusable Bash helpers with loader `helpers.sh` and core modules: `logging.sh`, `dialog.sh`, `os.sh`, `deps.sh`, `docker.sh`, `file.sh`, `json.sh`, `env.sh`, `ports.sh`, `browser.sh`, `traps.sh`, `certs.sh`, `hosts.sh`, `clipboard.sh`, and `help.sh` (2025-10-17).
- Added: Tag and release automation (`scripts/tag_release.sh`) (2025-10-17).

---

Historical notes prior to this changelog may be incomplete or summarized retroactively.
