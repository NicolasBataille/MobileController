# Benchmarks

Every number MobileController publishes comes from `bench/`, which records wall
time, stdout bytes, an estimated token count, host load and an independent
control probe for each step. This file holds the full tables; the README carries
a compact extract. The harness itself — flags, flows, columns, dry-run mode — is
documented in [`../bench/README.md`](../bench/README.md).

## Reproducing

```sh
bench/run.sh --target settings --repeat 3
bench/run.sh --target demoapp  --repeat 3
```

`run.sh` prints the path of the rendered markdown table and nothing else. The
full CSV of a run lands in `bench/out/<timestamp>/results.csv`.

## Measured on an 8-core Apple Silicon Mac, Xcode 26.6, iPhone 17 Pro / iOS 26.5, agent-device 0.20.11-mc.1

**Both tables below were measured with agent-device `0.20.11-mc.1`** — the optional
patched build described in [`upstream.md`](upstream.md) — not with the pinned
0.20.10. The README, and the skill, otherwise describe 0.20.10. One row differs
between the two builds and it is called out under the settings table.

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


## The warm daemon versus `agent-device`, iPhone 17 Pro Max / iOS 26.5

Wall time of the whole command from the shell — process start, socket, and the call — using the
release binaries, loadavg 7 on 8 cores. The process floor (`/usr/bin/true`) was ~2 ms.

| Operation | `agent-device` | `simprobe` + daemon | daemon-side |
|---|---:|---:|---:|
| Tap an element | `press` ~1.0-1.5 s | **16 ms** | 1.8 ms |
| Read the tree | `snapshot -i` ~0.3-0.5 s | **82 ms**, 1.9 KB | ~70 ms |
| 20x (tap + tree) | ~26-40 s | **2.05 s** (102 ms/iter) | — |
| Daemon cold start | — | 1.56 s, once | — |

The honest headline is not the per-command ratio: a real loop also waits for the UI, and the
[coexistence test](plans/04-warm-daemon-spike.md) measured a mixed loop at **526 ms/iter
against 1433 ms/iter** for pure agent-device — **2.7x**, both 10/10 correct, with an XCUITest
session live on the same simulator throughout.

### When to use which

`agent-device` stays the default. It owns sessions, refs that survive a relayout, `fill`, and it
is the engine the skill's escalation ladder is written around. Reach for the daemon when the same
screen is observed and acted on **many times in a row** — that is where 16 ms and 82 ms beat a
second per step. It is not a replacement: no session, no text entry, a leaner tree, and a hard
dependency on `idb_companion`.
