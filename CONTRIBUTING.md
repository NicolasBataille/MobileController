# Contributing

Thanks for looking. The project is pre-alpha; the surface still moves.

## Ground rules

- **Tests first.** Every change ships with a test that failed before it. See
  [docs/plans/03-task-list.md](docs/plans/03-task-list.md) for the phase each task belongs to.
- **No private APIs.** No `dlopen`, no `AXPTranslator`, no `SimulatorKit`. CI greps for them.
- **Never `pkill` a simulator process.** Reaping the in-simulator test runner poisons
  accessibility device-wide for every tool until the simulator is rebooted. Teardown is
  `agent-device close`, then `agent-device daemon stop`.
- **Nothing personal in the repo.** No absolute `/Users/...` paths, no simulator UDIDs, no
  private bundle identifiers, no committed screenshots. Machine-specific settings belong in
  the git-ignored `bench/local.env` or in `SIMPROBE_*` environment variables.

## Before you open a pull request

```sh
swift build
swift test --enable-code-coverage
swift format lint --recursive Sources Tests
./scripts/hygiene-check.sh
```

## Cutting a release

The Homebrew formula lives in this repository (`Formula/simprobe.rb`) rather than in a separate
tap, so it is not bumped for you. After the tag is pushed:

```sh
./scripts/bump-formula.sh v0.2.0      # rewrites url + sha256 from the real tarball
brew style Formula/simprobe.rb
```

then commit `Formula/simprobe.rb` with a `build:` message. A formula left on the previous tag
still installs cleanly — it just installs the previous binary, silently. Re-running the script
on the tag the formula already carries is a no-op, so a reviewer can check the bump by running
it and seeing no diff.

## Commit messages

Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
Scope with the module where it helps, e.g. `feat(core): mean absolute difference`.

## Style

Immutable `struct`s with `let` fields, typed `Error` enums, functions under 50 lines, files
under 800. No force-unwraps in library code.
