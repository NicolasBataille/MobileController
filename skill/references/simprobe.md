# simprobe — the pixel probe

Six verbs, no session, no daemon, no private APIs. Five of them need nothing but `xcrun simctl` +
CoreGraphics; `frames` additionally shells out to `idb`, which is installed separately. Each has a
compact default line, a `--json` form (one line, sorted keys, byte-stable), and an exit code a shell can
branch on. `--udid` takes a UDID **or** a device name, defaulting to the single booted simulator.

## When to reach for simprobe over `agent-device wait stable`

| | `agent-device wait stable` | `simprobe wait-stable` / `motion` |
|---|---|---|
| Measures | accessibility-tree quiescence | **pixels** (40x87 gray, mean absolute difference) |
| Sees implicit SwiftUI animation, crossfade, Canvas/Lottie | no (no AX identity) | yes |
| Needs | an open session: daemon + `xcodebuild test-without-building` + in-sim runner | only `simctl` |
| Works before `open`, after a crash, in teardown | no | yes |
| Usable as a benchmark control | no — it lives inside the tool being measured | yes, independent |

Tree questions ("has the row appeared?") → agent-device `--settle` / `wait stable`. Rendering questions
("has the sheet finished sliding in?"), or no session to lean on → simprobe. A verdict costs four
`simctl` captures at 0.2-1.1 s each depending on host load, so a settled screen is reported in
**1.5-4 s**, not 400 ms; on a loaded machine the default `--timeout 4s` can report a static screen as
not stable — **raise `--timeout`, never lower `--tol`.**

## `wait-stable [--udid <id>] [--tol 0.5] [--timeout 4s] [--interval 60ms] [--json]`

Captures until **three consecutive** comparisons fall within `--tol`. Durations take a bare number of
ms or an `ms`/`s` suffix: `250`, `60ms`, `1.5s`. `--interval 60ms` means "no artificial delay" — the
real cadence is capture-bound.

```
$ simprobe wait-stable --udid <udid>
stable after 180ms (3 polls, last diff 0.01, tol 0.50)          # exit 0
$ simprobe wait-stable --udid <udid> --timeout 1s               # still moving
not stable after 300ms (5 polls, last diff 255.00, tol 0.50)    # exit 3
$ simprobe wait-stable --udid <udid> --json
{"elapsedMs":180,"lastDiff":0.01,"polls":3,"stable":true,"tol":0.5,"udid":"<udid>"}
```

## `motion <duration> [--udid <id>] [--tol 0.5] [--keep-frames <dir>] [--json]`

A diff timeline with **zero image bytes on stdout**. The first capture is a baseline, not a sample, so
the window starts once there is something to compare against; every timestamp is measured, never
assumed. Always exits **0** — a timeline is data, not a verdict. There is no `--interval`; only
`--keep-frames <dir>` writes images, one `frame-<t>ms.png` per sample.

```
$ simprobe motion 600 --udid <udid>
t=205 1.00, 410 1.00, 615 0.01  ->  settled@615ms (3 samples, 4.9 fps)
$ simprobe motion 600 --udid <udid> --json
{"fps":4.9,"samples":[{"diff":1,"tMs":205},{"diff":1,"tMs":410},{"diff":0.01,"tMs":615}],"settledAtMs":615,"tol":0.5}
```

| Diff | Reading the timeline |
|---:|---|
| `0.00`-`0.03` | Idle. A screen with a perpetual micro-animation never repeats exactly, so it floors here, not at 0. Exact-hash equality does **not** work: 12/12 frames measured distinct. |
| `~0.4` | Tail of a transition, already visually finished. |
| `~11` | A real full-screen transition. |

Default `--tol 0.5` sits between them and separates idle from transition by ~350x. `settledAtMs` is the
**first** sample within tolerance — on a screen already quiet when the window opened, that is the first
quiet sample, **not** the end of an animation that started later, so read the whole timeline. It is
`null` in JSON (the key is always present) when nothing settled. `fps` comes from the actual
first/last timestamps; a `simctl` screenshot costs ~200 ms, capping the real cadence near 5 fps.

## `shot [--udid <id>] [--out shot.jpg] [--width <px>] [--quality 70] [--scale <n>] [--json]`

One JPEG at **1x logical points**, so a coordinate read off the image maps 1:1 onto the accessibility
frame, at about a ninth of the raw 3x framebuffer's vision tokens: ~470-510 vision tokens depending
on screen (402x874 -> 468, 420x912 -> 510) vs ~4,200 at 3x. The cost is a property of the screen,
not a constant - the summary line reports the one that applies. Scale is read from `simctl io <udid>
enumerate` (`Preferred UI Scale`), not hardcoded; `--scale` skips that call. A `--width` above the
source pixel width is rejected (exit 1), and so is a `--quality` outside 1-100. Bytes vary with
content; the token estimate does not.

```
$ simprobe shot --udid <udid> --out /tmp/s.jpg
/tmp/s.jpg  402x874 @1x  jpeg q70  47.4 KB  ~468 vision tokens  (source 1206x2622, 3.0x)
$ simprobe shot --udid <udid> --out /tmp/s.jpg --json
{"bytes":48537,"estimatedVisionTokens":468,"height":874,"path":"/tmp/s.jpg","quality":70,"scale":3,"sourceHeight":2622,"sourceWidth":1206,"udid":"<udid>","width":402}
```

## `frames [--udid <id>] [--interactive] [--point x,y] [--json]`

**The coordinates an accessibility snapshot does not give you.** `agent-device snapshot` names elements
and says what they are, but never says *where* they are; `shot` shows where things are but not what they
are called. `frames` prints both, in the same 1x logical points `shot` writes its image in — so a frame
printed here and a pixel read off that image are the same coordinate, and `idb ui tap <x> <y>` lands on it.

One line per element, banded by vertical position. An element is named `#accessibilityIdentifier` when
the app set one, because that survives a relayout, and `@<index>` otherwise — the index is its position
in what idb returned, so `--interactive` and `--point` never renumber it. Zero-size and offscreen
elements are dropped, labels are cut at 40 **characters** (`こんばんは` is five), and the type is the same
short vocabulary the snapshot uses: `Button`, `Text`, `TextField`, `Image`, `Switch`, `Other`.

```
$ simprobe frames --udid <id>          # Settings, 17 elements, 1,815 B (~454 tokens), ~8 s
Réglages  402x874
[Top y<120]
  @2                                         Other      ""                                          (0,0 402x874)
[Content]
  @1                                         Text       "Réglages"                                  (16,120 147x41)
  #com.apple.settings.general                Button     "Général"                                   (16,311 370x52)
[Bottom y≥754]
  @14                                        TextField  "Recherche"                                 (33,803 336x38)
```

`--interactive` keeps only what can be acted on — buttons, fields and switches, and only while they are
enabled (1,307 B on the same screen). `--point x,y` describes the single element under a point, with no
header and no band:

```
$ simprobe frames --udid <id> --point 201,389
  #com.apple.settings.accessibility  Button  "Accessibilité"  (16,363 370x52)
$ simprobe frames --udid <id> --json
[{"h":874,"label":"","ref":"@2","type":"Other","w":402,"x":0,"y":0}, …]
```

**Needs `idb`** — `brew install facebook/fb/idb-companion && pip3 install fb-idb`. Without it the verb
exits **2** with that line as the message (`kind: dependencyMissing`), never a stack trace. The companion
auto-spawns, but the first call after a simulator boots fails with *"No translation object returned for
simulator"*; `frames` retries once through an explicit `idb connect <udid>`, which is why a cold first
run costs a few seconds more than the ~1.5 s a warm one does. A screen still animating gives a truncated
tree here exactly as it does through agent-device — settle first.


## `devices [--booted] [--platform ios|watchos|tvos|visionos|all] [--json]`

The pinning agent-device lacks (`--device` matches names only). Booted first, then newest runtime,
then name; runtimes are ordered by version number, so `iOS 26.5` outranks `iOS 9.0`. `--platform`
defaults to `all`: narrow it to `ios` before reading the first entry, or a booted Apple Watch wins.

```
$ simprobe devices
BOOTED  iPad Pro 13-inch   iOS 26.4   SIM-UDID-PLACEHOLDER-C
        iPhone 17          iOS 26.5   SIM-UDID-PLACEHOLDER-A
        iPhone 17 Pro      iOS 26.5   SIM-UDID-PLACEHOLDER-B
3 devices, 1 booted
$ simprobe devices --booted --platform ios --json
[{"available":true,"booted":true,"name":"iPad Pro 13-inch","runtime":"iOS 26.4","udid":"<udid>"}]
```

## `diff <before> <after> [--tol 0.5] [--json]`

Both files go through the same 40x87 grayscale thumbnail the live verbs use, so a `diff` reading is
directly comparable with a `wait-stable` one. Exit 4 when they differ, so `&&` reads naturally.

```
$ simprobe diff base.png now.png && echo unchanged
diff 0.00  (40x87 gray, tol 0.50)  ->  same
$ simprobe diff base.png other.png --json
{"diff":64.36,"same":false,"size":"40x87","tol":0.5}
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success — and for `diff`, "same within tolerance" |
| 1 | Usage or invalid arguments (unknown flag, unknown verb, `--width` over the source width) |
| 2 | Environment: `simctl` or `idb` missing or failing, no booted simulator, ambiguous or unknown `--udid` |
| 3 | `wait-stable` timed out before the screen settled |
| 4 | `diff` exceeded `--tol` |
| 5 | Capture or decode failure (unreadable image, frame size mismatch) |

3 and 4 are **results**, not errors: the result line is already on stdout. 1, 2 and 5 are errors — without
`--json` the message goes to **stderr** (`simprobe: could not read an image at missing.png`) and stdout stays
empty; with `--json` the envelope `{"error":{"code":5,"kind":"imageUnreadable","message":"…"}}` goes to
**stdout**, so a caller parsing stdout never scrapes stderr. `kind` is a stable discriminator:
`invalidArgument`, `simctlUnavailable`, `simctlFailed`, `noBootedDevice`, `ambiguousDevice`,
`deviceNotFound`, `captureFailed`, `frameFailure`, `imageUnreadable`, `dependencyMissing`, `idbFailed`.
