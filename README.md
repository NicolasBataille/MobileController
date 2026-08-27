# MobileController

[![CI](https://github.com/NicolasBataille/MobileController/actions/workflows/ci.yml/badge.svg)](https://github.com/NicolasBataille/MobileController/actions/workflows/ci.yml) [![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

**Status: v0.1.0 (alpha).** The `simprobe` CLI, the Claude Code skill, the benchmark
harness and the DemoApp are all in place and measured on a real simulator. Expect rough
edges; the pinned tool versions below are the only combination tested so far.

Token-efficient tooling for driving an **iOS Simulator** from a Claude Code agent.

## Why

An agent asked to "check that the sheet animates in and the email field accepts input" pays
for that check in *observation tokens*. Measured across seven existing tools, the same screen
costs between 78 and 96,873 tokens to observe — a 1,240x spread — while latency varies only
3x. Observation tokens, not latency, are the dominant cost.

MobileController does **not** reimplement device automation. It adopts
[agent-device](https://github.com/callstackincubator/agent-device) (callstack, MIT) as the
automation engine, used strictly as a CLI invoked from Bash — never as an MCP server — and
ships the three things agent-device does not provide:

1. **A Claude Code skill** encoding an observation escalation ladder and the field-tested
   pitfalls (AZERTY text entry, field clearing, session hygiene, the reaper guard).
2. **`simprobe`** — a small Swift CLI that answers "is the screen settled / did it actually
   animate?" with a *number* and zero images returned, using only `xcrun simctl` and
   CoreGraphics. No private APIs, no Python, no codesigning.
3. **A reproducible benchmark harness** that records host loadavg and a control probe next to
   every measurement, so the numbers survive being read on another machine.

## Pinned compatibility

Everything in this repository was verified against exactly one triple:

| Component | Version |
|---|---|
| agent-device | 0.20.10 |
| Xcode | 26.6 |
| iOS Simulator runtime | 26.5 |

When that drifts, re-run the benchmark before trusting any number here. The one exception is the
two *Measured on…* tables further down: they were regenerated on the optional patched build and say
so in their heading.

## Install

Requires macOS 14+ and a Swift 6.0+ toolchain.

```sh
brew tap NicolasBataille/MobileController https://github.com/NicolasBataille/MobileController
brew trust nicolasbataille/mobilecontroller
brew install simprobe
```

Neither of the first two lines is optional. The tap URL is not, because the repository is not
named `homebrew-simprobe` and without an explicit URL `brew tap` looks for one that does not
exist. The `brew trust` line is not, because Homebrew 6 refuses to load a formula from a
third-party tap until you say so: without it `brew install` stops with *"Refusing to load
formula … from untrusted tap"* and prints the command to run. Read `Formula/simprobe.rb`
before you trust it — it is under fifty lines and it builds from the tagged source tarball.

The formula builds the release tarball from source and installs **both** binaries, `simprobe` and
`simprobe-daemon`. There is no bottle.

From source instead:

```sh
git clone https://github.com/NicolasBataille/MobileController && cd MobileController

swift build -c release --product simprobe   # ~1 min: the CLI alone, one dependency
swift build -c release                      # ~6 min: adds simprobe-daemon and its gRPC stack
```

`.build/release/simprobe` is 2.7 MB and needs only ArgumentParser. `simprobe-daemon` is 38.5 MB
and pulls in 22 transitive packages, which is exactly why it is a **separate product**: build it
only if you want the warm `tap`/`tree` path. Measured clean, on 8 cores: 58 s for the CLI alone,
253 s for both in debug, 347 s for both in release.

Add `.build/release` to your `PATH`, or call the binaries by their full paths — `tap` and `tree`
look for `simprobe-daemon` beside the running `simprobe`, so keep the two together.

The automation engine is installed separately and is not vendored here:

```sh
npm i -g agent-device@0.20.10          # or run it ad hoc: npx agent-device@0.20.10 <command>
```

`simprobe frames` is the one verb with an extra dependency — it reads accessibility frames
through `idb` rather than through a private framework:

```sh
brew install facebook/fb/idb-companion && pip3 install fb-idb
```

Every other verb needs only `xcrun simctl`, and `frames` exits 2 with that install line as its
message when `idb` is absent.

### Optional: patched agent-device build

**0.20.10 stays the baseline.** The skill, the cheatsheet and the pitfalls are pinned to it, and
every number in this README's tables was measured with it unless a table header says otherwise.
The build below is optional, unpublished, and for people who would rather have the fixes now.

Four of the limitations listed under *Known upstream limitations* have fixes proposed upstream.
Those four branches are merged onto upstream `main` on the fork
[`NicolasBataille/agent-device`](https://github.com/NicolasBataille/agent-device), branch
`mobilecontroller/patched`, versioned **`0.20.11-mc.1`** so `agent-device --version` tells the two
builds apart. It is not published to npm; build and install it yourself:

```sh
git clone https://github.com/NicolasBataille/agent-device && cd agent-device
git checkout mobilecontroller/patched
pnpm install && pnpm build
pnpm package:apple-runner:npm                    # REQUIRED: copies the iOS runner source into dist/
pnpm check:package --pack-destination ./pack     # packs with --ignore-scripts, then validates
npm i -g ./pack/agent-device-0.20.11-mc.1.tgz
hash -r && agent-device --version                # -> 0.20.11-mc.1
```

`pnpm package:apple-runner:npm` is not optional. The iOS XCUITest runner ships as Swift *source*,
compiled on the target machine at first `open`; skip that step and the tarball installs a CLI with
no runner.

What changes, against the five items listed under *Known upstream limitations* below:

| Limitation | Under `0.20.11-mc.1` |
|---|---|
| 1 — `close` leaks the device lease (#2031) | Already fixed upstream after 0.20.10 by #2057. PR #2068 additionally makes `DEVICE_IN_USE`'s own recovery hint executable and `session list` report a state dir that exists |
| 2 — `help batch` does not document the step shape (#2062) | **Fixed** (PR #2067). `help batch` prints `{"command":"<name>","input":{...}}` and the batchable set; all three refusals name the shape |
| 3 — no clear-field primitive (#2063) | **Fixed** (PR #2066). `fill <target> ""` clears the field; a *missing* text argument is still refused, by design |
| 4 — `--device <udid>` does not hint at `--udid` (#2064) | **Fixed** (PR #2065). The error answers `Did you mean --udid …?`, and `help commands` grows a `Device Selection` block listing `--udid` |
| 5 — implicit cwd-hash sessions coexist with `--session` (#1394) | **Not fixed.** #2068 makes the implicit session *addressable* by its `cwd:<hash>:<name>` key; it does not merge the two scopes. Keep passing `--session` on every call |

One thing this build does *not* fix: `--level digest --json snapshot -i` grew from 447 B on 0.20.10 to roughly 1.5 KB on the `0.20.11-dev` base this build sits on — larger than plain `snapshot -i` — see the measured tables below.

## Install the skill

`skill/` is a Claude Code skill: `SKILL.md` plus three on-demand reference files. Copy the whole
directory — the references are loaded by relative path, so a copy of `SKILL.md` alone is broken.

```sh
# available in every project, for this user
mkdir -p ~/.claude/skills
cp -r skill ~/.claude/skills/mobilecontroller
```

For one project only, put it under that project's `.claude/skills/` instead:

```sh
mkdir -p /path/to/your-app/.claude/skills
cp -r skill /path/to/your-app/.claude/skills/mobilecontroller
```

A symlink works too (`ln -s "$PWD/skill" ~/.claude/skills/mobilecontroller`) and keeps the skill
in step with this checkout. Either way the agent needs `simprobe` and `agent-device` on its
`PATH`; the skill invokes both by bare name.

| File | Loaded | Contents |
|---|---|---|
| `skill/SKILL.md` | always | Escalation ladder, action rule, session hygiene, five hard don'ts |
| `skill/references/agent-device-cheatsheet.md` | on demand | Every verb and flag at 0.20.10, measured costs |
| `skill/references/pitfalls.md` | on demand | Symptom → cause → workaround, incl. the reaper guard |
| `skill/references/simprobe.md` | on demand | The five verbs, exit codes, `--json` shapes |

## Using `simprobe`

Eight verbs. Every one has a compact human-readable default, a `--json` form, and an exit code
a shell can branch on. `--udid` accepts a UDID or a device name and defaults to the single
booted simulator, so most invocations need no target at all.

Six of them need nothing but Xcode. `frames` needs `idb`; `tap` and `tree` additionally need a
warm daemon started with `simprobe daemon start` — see [The warm daemon](#the-warm-daemon).

Only `shot --out` and `motion --keep-frames` write anything, and they write wherever you point
them: the path is taken as given, a symlink is followed to its target, and an existing file is
overwritten without a prompt.

```
$ simprobe --help
OVERVIEW: Answer 'is the screen settled?' about an iOS Simulator, in numbers not pixels.

USAGE: simprobe <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  wait-stable             Poll a simulator's screen until it stops changing.
  motion                  Report how much a simulator's screen changed over a window of time.
  shot                    Write one screenshot at 1x logical points and report what it cost.
  frames                  List the on-screen accessibility elements with their 1x coordinates.
  devices                 List the simulators on this machine, booted ones first.
  diff                    Compare two image files on the same scale the live verbs use.
  daemon                  Run a warm idb connection so `tap` and `tree` cost milliseconds.
  tap                     Tap an element or a coordinate through the warm daemon.
  tree                    List the on-screen elements through the warm daemon.
```

### `wait-stable [--udid <id>] [--tol 0.5] [--timeout 4s] [--interval 60ms] [--json]`

Captures thumbnails until three consecutive comparisons fall within `--tol`.

```
$ simprobe wait-stable --udid <id>
stable after 1629ms (3 polls, last diff 0.00, tol 0.50)

$ simprobe wait-stable --udid <id> --timeout 1s      # taken during an app launch
not stable after 1017ms (1 poll, last diff 65.51, tol 0.50)
$ echo $?
3

$ simprobe wait-stable --udid <id> --json
{"elapsedMs":1527,"lastDiff":0,"polls":3,"stable":true,"tol":0.5,"udid":"XXXXXXXX-…"}
```

One `simctl` screenshot costs 0.2-1.1 s depending on host load, and a verdict needs four
captures, so a settled screen is reported in 1.5-4 s rather than in the 400 ms the PRD hoped
for. On a loaded machine the default `--timeout 4s` is tight enough that a static screen can be
reported as not stable; raise the timeout rather than lowering `--tol`.

### `motion <ms> [--udid <id>] [--tol 0.5] [--keep-frames <dir>] [--json]`

A diff timeline with **zero image bytes on stdout**. The first capture is a baseline, so the
window starts once there is something to compare against, and every timestamp is measured.

```
$ simprobe motion 2500 --udid <id>          # an app launched ~400 ms in
t=286 0.00, 605 55.66, 838 48.27, 1073 0.01, 1315 0.00, 1553 0.00, 1936 0.00,
   2258 0.27, 2508 0.00  ->  settled@286ms (9 samples, 3.6 fps)

$ simprobe motion 1500 --udid <id> --json   # a screen that never moved
{"fps":2.7,"samples":[{"diff":0,"tMs":279},{"diff":0,"tMs":685},{"diff":0,"tMs":1096},
 {"diff":0,"tMs":1439},{"diff":0,"tMs":1776}],"settledAtMs":279,"tol":0.5}
```

`settledAtMs` is the **first** sample within tolerance, so on a screen that was already quiet
when the window opened it reports that first quiet sample rather than the end of the animation
that followed. Read the timeline, not just the settle point.

`--keep-frames <dir>` is the only path that writes images: one PNG per sample, up to 10 000 of
them. Past that the frames stop and the run says so (`(frames capped at 10000)`, or
`"framesCapped": true` under `--json`); the timeline itself always runs to the end of the window.

### `shot [--udid <id>] [--out shot.jpg] [--width <px>] [--quality 70] [--scale <n>] [--json]`

One screenshot at 1x logical points, so a coordinate read off the image maps 1:1 onto the
accessibility frame. The framebuffer scale is read from `simctl io <udid> enumerate`
(`Preferred UI Scale` on the integrated screen), not hardcoded; `--scale` overrides it.

```
$ simprobe shot --udid <id> --out /tmp/settings.jpg
/tmp/settings.jpg  402x874 @1x  jpeg q70  47.4 KB  ~468 vision tokens  (source 1206x2622, 3.0x)
```

### `frames [--udid <id>] [--interactive] [--point x,y] [--json]`

The coordinates an accessibility snapshot does not give you: every on-screen element with its
frame in the same 1x logical points `shot` writes its image in. Needs `idb` (see Install).

```
$ simprobe frames --udid <id> --interactive
Réglages  402x874
[Content]
  #com.apple.settings.general    Button  "Général"        (16,311 370x52)
  #com.apple.settings.camera     Button  "Appareil photo" (16,415 370x52)
[Bottom y≥754]
  @14                            TextField  "Recherche"   (33,803 336x38)

$ simprobe frames --udid <id> --point 201,389
  #com.apple.settings.accessibility  Button  "Accessibilité"  (16,363 370x52)
```

Elements are named `#accessibilityIdentifier` when the app set one and `@<index>` otherwise;
zero-size and offscreen elements are dropped and labels are cut at 40 characters. `--json`
emits one object per element: `{"ref","type","label","x","y","w","h"}`.

## The warm daemon

`simprobe frames` spends 0.6-1.5 s per call, almost all of it starting an `idb` process and
letting it reconnect to `idb_companion`. `simprobe-daemon` pays that once: it holds a single
gRPC connection to the companion open, and `tap` and `tree` become socket round trips.

It is a **second binary and a second product**, on purpose. gRPC brings 22 transitive packages
along; `simprobe` itself still has exactly one dependency and still builds in under a minute.
`swift build --product simprobe` never compiles any of it. The design and the measurements are
in [`docs/plans/05-warm-daemon.md`](docs/plans/05-warm-daemon.md).

```
$ simprobe daemon start --udid <id>
daemon ready (<id>, tree 15 elements, 1562 ms)

$ simprobe tap "#com.apple.settings.accessibility" --udid <id>
tapped #com.apple.settings.accessibility (220,389) 1.79 ms

$ simprobe tree --udid <id> | head -3
Réglages  440x956
[Top y<120]
  #BackButton    Button  "Réglages"    (20,62 44x44)

$ simprobe daemon status --udid <id>
running (<id>, pid 55572, up 21s)

$ simprobe daemon stop --udid <id>
daemon stopped (<id>)
```

`daemon start` spawns the daemon detached, waits for it to answer, then **smoke-tests both
halves**: a tree with at least one element, and a `simctl` screenshot. The screenshot half is
not decoration — idb's own screenshot breaks once its companion outlives a simulator reboot and
reconnecting does not heal it, which is why capture stays on `simctl` everywhere in this tool.

The daemon exits on its own after `--idle-timeout` (default 10 minutes), writes one JSON line
per event to `$TMPDIR/simprobe/<udid>.log`, and records its pid beside its socket. `daemon stop`
is the only thing here that ever signals a process, and it signals only a pid its own daemon
wrote down whose executable still matches — a recycled pid from a stale file is discarded, not
killed.

### `tap <#id | @index | x,y> [--udid <id>] [--wait-stable] [--json]`

Takes the refs `frames` and `tree` print. A `#id` or `@index` is resolved against a fresh tree
and the tap lands on the centre of that element's frame; `x,y` taps blind and costs no tree read.

A coordinate tap is swallowed silently by anything drawn over it — a keyboard, a sheet, a modal
— on this engine and on XCUITest alike. `--wait-stable` chains `simprobe wait-stable` onto the
tap so the result is verified rather than assumed, and its exit code (3 on timeout) becomes the
command's.

### `tree [--udid <id>] [--interactive] [--json]`

The output `frames` prints, from the daemon instead of from an `idb` process — same parser, same
banding, same refs.

> **Never compare node counts across engines.** idb's tree is leaner by design than XCUITest's
> and skips elements `agent-device snapshot` reports. Diffing the two counts, or using either to
> prove an element is *absent*, produces confident nonsense.

### Measured: daemon versus `agent-device`, iPhone 17 Pro Max / iOS 26.5

Wall time of the whole command from the shell — process start, socket, and the call — using the
release binaries, loadavg 7 on 8 cores. The process floor (`/usr/bin/true`) was ~2 ms.

| Operation | `agent-device` | `simprobe` + daemon | daemon-side |
|---|---:|---:|---:|
| Tap an element | `press` ~1.0-1.5 s | **16 ms** | 1.8 ms |
| Read the tree | `snapshot -i` ~0.3-0.5 s | **82 ms**, 1.9 KB | ~70 ms |
| 20x (tap + tree) | ~26-40 s | **2.05 s** (102 ms/iter) | — |
| Daemon cold start | — | 1.56 s, once | — |

The honest headline is not the per-command ratio: a real loop also waits for the UI, and the
[coexistence test](docs/plans/04-warm-daemon-spike.md) measured a mixed loop at **526 ms/iter
against 1433 ms/iter** for pure agent-device — **2.7x**, both 10/10 correct, with an XCUITest
session live on the same simulator throughout.

### When to use which

`agent-device` stays the default. It owns sessions, refs that survive a relayout, `fill`, and it
is the engine the skill's escalation ladder is written around. Reach for the daemon when the same
screen is observed and acted on **many times in a row** — that is where 16 ms and 82 ms beat a
second per step. It is not a replacement: no session, no text entry, a leaner tree, and a hard
dependency on `idb_companion`.

### `devices [--booted] [--json]`

The pinning `agent-device` lacks: its `--device` matches names only, and duplicate names are
common. Feed the UDID column to `agent-device --udid`.

```
$ simprobe devices
BOOTED  iPhone 17          iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPhone 17 Pro      iOS 26.5   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
        iPad Pro 13-inch   iOS 26.4   XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
3 devices, 1 booted
```

### `diff <before> <after> [--tol 0.5] [--json]`

```
$ simprobe diff /tmp/home.jpg /tmp/home.jpg
diff 0.00  (40x87 gray, tol 0.50)  ->  same

$ simprobe diff /tmp/settings.jpg /tmp/home.jpg
diff 64.36  (40x87 gray, tol 0.50)  ->  different
$ echo $?
4
```

### Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success, and for `diff` "same within tolerance" |
| 1 | Usage or invalid arguments |
| 2 | Environment: `simctl` or `idb` missing or failing, no booted simulator, ambiguous `--udid`, no daemon running (`daemonUnavailable`) |
| 3 | `wait-stable` timed out before the screen settled |
| 4 | `diff` exceeded tolerance |
| 5 | Capture or decode failure |

Under `--json`, errors are printed on **stdout** as `{"error":{"code":2,"kind":…,"message":…}}`
so a caller parsing stdout never has to scrape stderr. Without `--json` the message goes to
stderr and stdout stays empty.

## Measured on an 8-core Apple Silicon Mac, Xcode 26.6, iPhone 17 Pro / iOS 26.5, agent-device 0.20.11-mc.1

**These two tables were measured with agent-device `0.20.11-mc.1`** (the optional patched build
above), not with the pinned 0.20.10. Everything else in this README, and the skill, still describe
0.20.10. One row differs between the two builds and it is called out under the settings table.

Regenerate both tables with one command each:

```sh
bench/run.sh --target settings --repeat 3
bench/run.sh --target demoapp  --repeat 3
```

> **Read ratios, not absolutes.** wall_ms inflates 2-10x when loadavg_1m rises
> above roughly 2x the core count of the machine that produced the row, so
> compare control_probe_ms across rows first: if it moved with wall_ms the host
> was loaded, and only a step whose wall_ms moved while control_probe_ms held
> steady is a real regression. est_tokens is stdout_bytes/4 - an estimate of
> observation cost, not a token count.

Host `loadavg_1m` sat between 4.6 and 5.2 on 8 cores through the settings run and
between 5.2 and 9.2 through the demoapp run - loaded, but below the ~2x-cores
line where wall clock starts to lie. `control_probe_ms` held between 167 and
345 ms (settings) and 165 and 363 ms (demoapp), which is what says so
independently: it reaches the same simulator without going through agent-device.
Both tables are trimmed to the one-off rows plus one representative repeat of
three; the full CSV is in `bench/out/<timestamp>/results.csv`.

`ad` and `sp` are the wrappers in `bench/lib/flow.sh` - they add `--udid` and
`--session` to every call, which is why no UDID appears in the `cmd` column.

### `--target settings` - Apple Settings, the app nobody controls

| flow | step | cmd | wall_ms | stdout_bytes | est_tokens | loadavg_1m | control_probe_ms | exit_code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| settings-observe-act | 0-open_cold | ad open com.apple.Preferences | 1419 | 87 | 21 | 4.93 | 345 | 0 |
| settings-observe-act | 0-close_cold | ad close | 122 | 14 | 3 | 4.93 | 208 | 0 |
| settings-observe-act | r2-open_warm | ad open com.apple.Preferences | 1163 | 87 | 21 | 4.77 | 175 | 0 |
| settings-observe-act | r2-digest_snapshot | ad --level digest --json snapshot -i | 276 | 1515 | 378 | 4.77 | 204 | 0 |
| settings-observe-act | r2-interactive_snapshot | ad snapshot -i | 274 | 851 | 212 | 4.77 | 184 | 0 |
| settings-observe-act | r2-full_snapshot | ad snapshot | 271 | 3152 | 788 | 4.77 | 182 | 0 |
| settings-observe-act | r2-press_row | ad press text=Général | 839 | 33 | 8 | 4.77 | 177 | 0 |
| settings-observe-act | r2-wait_stable | sp wait-stable --timeout 6s | 1267 | 56 | 14 | 4.71 | 184 | 0 |
| settings-observe-act | r2-press_row_settle | ad press text=Général --settle | 3198 | 1491 | 372 | 4.71 | 196 | 0 |
| settings-observe-act | r2-simprobe_shot | sp shot --out bench/out/20260827T021835/settings-shot-r2.jpg | 469 | 164 | 41 | 4.81 | 196 | 0 |
| settings-observe-act | r2-agent_screenshot | ad screenshot --out bench/out/20260827T021835/settings-screenshot-r2.png | 450 | 106 | 26 | 4.81 | 181 | 0 |
| settings-observe-act | r2-close | ad close | 121 | 14 | 3 | 4.81 | 198 | 0 |

**The digest rung is not the cheap rung on this build.** Read across
`stdout_bytes`: **1515 B digest, 851 B interactive, 3152 B full** for one and
the same screen. The digest is *larger* than `snapshot -i`, which inverts the
ladder's first two rungs. The 0.20.10 table this replaces read **447 B digest,
851 B interactive, 3152 B full** on the same flow - and the interactive and full
rows are byte-identical across the two runs, which is what rules out "different
screen" as the explanation. On `0.20.11-mc.1` the `--json` payload comes back
pretty-printed inside a `{"success":true,"data":{…}}` envelope; re-serialised
compact (`| jq -c`) the same 20-ref payload is 945 B, so indentation accounts
for roughly 570 B of the growth and the payload itself for the rest. It is not the patched build's
doing: `git diff --name-only b1ee2a777..HEAD` on the merged branches touches no
snapshot, rendering or JSON source file - only `package.json` and `server.json`,
the version bump. It arrived upstream somewhere between 0.20.10 and
`0.20.11-dev`; exactly where is not established here, since 0.20.10 is not
installed on this host. **Measure the digest
against `snapshot -i` on your own screen before assuming rung 1 is cheaper**, and
pipe it through `jq -c` if you keep it.

Acting is nearly free at 33 B; `press --settle` costs **1491 B and 3198 ms**
against **33 B and 839 ms** bare, because the settled diff comes back with it.
Use it when the diff *is* the verification, not when the next step re-observes.

The two screenshots are the same picture: the one-line paths on stdout are 164 B
and 106 B, but the files are 47 KB (`simprobe shot`, 402x874 at 1x, ~468 vision
tokens) and 92 KB. What a model pays for is the image, not the line.

`0-open_cold` is the first open of the run, not the first open the machine ever
did: on a device that has never hosted the runner it also builds and installs
the XCUITest runner, tens of seconds that this row does not show. The Settings
row is addressed by label and Settings is localised, hence `text=Général` here -
set `BENCH_SETTINGS_ROW` in `bench/local.env` to match your device's language.

### `--target demoapp` - the same ladder against a known 300 ms transition

| flow | step | cmd | wall_ms | stdout_bytes | est_tokens | loadavg_1m | control_probe_ms | exit_code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| demoapp-observe-act | 0-open | ad open dev.mobilecontroller.demoapp | 1338 | 94 | 23 | 5.22 | 280 | 0 |
| demoapp-observe-act | r2-tab_list | ad press id=tabBar.list | 673 | 33 | 8 | 7.20 | 178 | 0 |
| demoapp-observe-act | r2-wait_stable_list | sp wait-stable --timeout 6s | 1222 | 56 | 14 | 7.50 | 242 | 0 |
| demoapp-observe-act | r2-interactive_snapshot | ad snapshot -i | 315 | 1065 | 266 | 7.50 | 172 | 0 |
| demoapp-observe-act | r2-tab_form | ad press id=tabBar.form | 813 | 33 | 8 | 7.50 | 175 | 0 |
| demoapp-observe-act | r2-wait_stable_form | sp wait-stable --timeout 6s | 1211 | 56 | 14 | 7.50 | 184 | 0 |
| demoapp-observe-act | r2-fill_textfield | ad fill id=form.textField example.com | 2464 | 16 | 4 | 9.22 | 170 | 0 |
| demoapp-observe-act | r2-get_echo | ad get attrs id=form.echoLabel | 262 | 305 | 76 | 9.22 | 173 | 0 |
| demoapp-observe-act | r2-get_echo_value | ad get attrs id=form.echoLabel | 107 | 305 | 76 | 9.22 | 173 | 0 |
| demoapp-observe-act | r2-press_clear | ad press id=form.clearButton | 904 | 38 | 9 | 9.22 | 176 | 0 |
| demoapp-observe-act | r2-wait_stable_clear | sp wait-stable --timeout 6s | 1251 | 56 | 14 | 9.22 | 179 | 0 |
| demoapp-observe-act | r2-get_echo_cleared | ad get attrs id=form.echoLabel | 271 | 301 | 75 | 8.81 | 176 | 0 |
| demoapp-observe-act | r2-dismiss_keyboard | ad keyboard return | 1499 | 23 | 5 | 8.81 | 176 | 0 |
| demoapp-observe-act | r2-tab_home | ad press id=tabBar.home | 787 | 33 | 8 | 8.81 | 182 | 0 |
| demoapp-observe-act | r2-wait_stable_home | sp wait-stable --timeout 6s | 1208 | 56 | 14 | 8.81 | 192 | 0 |
| demoapp-observe-act | r2-press_animate_motion | bench_flow_press_then_motion id=home.animateButton 1500 | 1978 | 115 | 28 | 8.66 | 167 | 0 |

`r2-press_animate_motion` is the row the DemoApp exists for. The tap runs in the
background inside that step so the 300 ms transition happens *inside* the
capture window; a foreground `press` returns only after the runner acknowledges
it, ~1.5 s later, by which time there is nothing left to measure. The three
timelines, verbatim:

```
r1: t=215 0.16, 440 22.64, 673 12.08, 906 0.04, 1140 0.00, 1373 0.00, 1611 0.00  ->  settled@906ms (7 samples, 4.3 fps)
r2: t=214 0.16, 452 27.10, 691 7.59, 925 0.09, 1158 0.00, 1391 0.00, 1625 0.00  ->  settled@925ms (7 samples, 4.3 fps)
r3: t=409 0.50, 726 31.90, 1026 0.16, 1325 0.00, 1626 0.00  ->  settled@1026ms (5 samples, 3.3 fps)
```

Non-zero samples at ~8-32 against a floor of 0.00-0.50, then quiet: a 300 ms
animation caught inside the capture window, three times out of three. `r3` shows
what the sampling rate costs - at 3.3 fps the whole transition fell into a
*single* ~300 ms window (`726 31.90`) instead of straddling two. The animation
did not change; the cadence did. Note what `settled@` says - 906-1026 ms - and
what it means: the first *quiet* sample, one cadence after the motion ended, not
the end of the animation. Read the whole timeline; `settled@` alone would be off
by 300 ms here, and on a screen that was already still it is simply the first
sample.

`ad get attrs` rather than `ad get text`: on a label carrying both, `get text`
returns the accessibility label (`Echo`) while the echoed value lives in
`value`. `r2-get_echo_value` is the step that asserts it - it was
`r2-is_echo_text` (`ad is text id=form.echoLabel example.com`) until this run,
which fails with `expected="example.com" actual="Echo"` for exactly that reason:
`is text` compares the label too. `r2-dismiss_keyboard` is there because after a
`fill` the keyboard covers the tab bar, and a press on a tab then reports
`Tapped id=tabBar.home` and changes nothing - `agent-device keyboard dismiss` is
unsupported on iOS, so the return key is the way out.

The published rows are repeat 2 of three. In this run repeat 1's first press
missed (`Selector did not match: id=tabBar.list`, exit 1) because the app was
still launching and its tree was still truncated to 16 nodes of the settled 42 -
the fourth hard don't in the skill, reproduced live. The unmeasured warm-up
snapshot the flow takes after `open` does not always cover it.

## Documentation

The design is written down before the code:

- [PRD](docs/plans/01-prd.md) — problem, goals, measured baseline, acceptance targets.
- [Architecture](docs/plans/02-architecture.md) — repo layout, module split, CLI surface,
  exit codes.
- [Task list](docs/plans/03-task-list.md) — phased tasks with their TDD red steps.
- [Warm daemon spike](docs/plans/04-warm-daemon-spike.md) — the feasibility and latency study,
  including the coexistence test against a live XCUITest session.
- [Warm daemon design](docs/plans/05-warm-daemon.md) — why the daemon is a second product, the
  wire protocol, and the build-time budget behind that split.

## Known upstream limitations (agent-device 0.20.10)

Observed while building and benchmarking this project. The skill's `references/pitfalls.md`
carries the workaround for each; reported upstream on
[callstack/agent-device](https://github.com/callstack/agent-device) (2026-08-26). Items 1-4 are
fixed in the optional [patched build](#optional-patched-agent-device-build); on the pinned
0.20.10 all five are live.

1. [#2031 (comment)](https://github.com/callstack/agent-device/issues/2031#issuecomment-5430618009), fix proposed in [PR #2068](https://github.com/callstack/agent-device/pull/2068) — `close` reports success but does not release the device lease, so the next `open`
   fails with `DEVICE_IN_USE` unless the same `--session` is reused. Fixed upstream after 0.20.10
   (#2057); on 0.20.10 use the workaround below.
2. [#2062](https://github.com/callstack/agent-device/issues/2062), fix proposed in [PR #2067](https://github.com/callstack/agent-device/pull/2067) — `help batch` and its errors do not document the step shape or the batchable
   set; press/fill are batchable with the `{"command","input"}` shape (see pitfalls).
3. [#2063](https://github.com/callstack/agent-device/issues/2063), fix proposed in [PR #2066](https://github.com/callstack/agent-device/pull/2066) — `fill @ref ""` is rejected with `INVALID_ARGS`; there is no clear-field primitive.
4. [#2064](https://github.com/callstack/agent-device/issues/2064), fix proposed in [PR #2065](https://github.com/callstack/agent-device/pull/2065) — `--device <udid>` fails with `DEVICE_NOT_FOUND` without hinting at `--udid`, which
   exists but is missing from the global-flags help.
5. [#1394 (comment)](https://github.com/callstack/agent-device/issues/1394#issuecomment-5430618195) — The implicit cwd-hash session name coexists with an explicit `--session`, so two
   shells in different directories silently drive two sessions on one device.

## Future work

- **Planned for v0.3: warm action daemon** (GO after the coexistence test — see [docs/plans/04-warm-daemon-spike.md](docs/plans/04-warm-daemon-spike.md)) — a warm gRPC connection to `idb_companion` cuts tap/tree/screenshot latency by roughly 340x/9x/6x (375→1.1 ms, 623→70 ms, 320→55 ms) and is private-API-free; the mixed-engine test (idb HID taps alongside an open agent-device/XCUITest session) passed, with a mixed observe-act loop running **2.7x faster** than pure agent-device (526 vs 1433 ms/iter).

## Credits

- [agent-device](https://github.com/callstackincubator/agent-device) by callstack — MIT.
  MobileController is a complement to it, not a fork of it.

## Licence

MIT — see [LICENSE](LICENSE).
