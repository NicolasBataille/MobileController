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

## Commit messages

Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
Scope with the module where it helps, e.g. `feat(core): mean absolute difference`.

## Style

Immutable `struct`s with `let` fields, typed `Error` enums, functions under 50 lines, files
under 800. No force-unwraps in library code.
