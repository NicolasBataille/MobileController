# Upstream: agent-device

MobileController pins [agent-device](https://github.com/callstackincubator/agent-device)
**0.20.10** as its automation engine. This file records the limitations found while
building and benchmarking against it, and how to build the interim patched CLI that
carries the fixes before they reach a release.

## Known limitations (agent-device 0.20.10)

Observed while building and benchmarking this project. The skill's
[`pitfalls.md`](../skill/references/pitfalls.md) carries the workaround for each; all
five were reported upstream on
[callstack/agent-device](https://github.com/callstack/agent-device) (2026-08-26).
Items 1-4 are fixed in the [patched build](#optional-a-patched-agent-device-build);
on the pinned 0.20.10 all five are live. Each fix below is merged upstream but not
yet in a released version, so until the next agent-device release ships, the workaround
or the patched build is the way through.

1. [#2031 (comment)](https://github.com/callstack/agent-device/issues/2031#issuecomment-5430618009), merged upstream 2026-08-27 in [PR #2068](https://github.com/callstack/agent-device/pull/2068) — `close` reports success but does not release the device lease, so the next `open`
   fails with `DEVICE_IN_USE` unless the same `--session` is reused. Fixed upstream after 0.20.10
   (#2057); on 0.20.10 use the workaround in `pitfalls.md`.
2. [#2062](https://github.com/callstack/agent-device/issues/2062) (closed), merged upstream 2026-08-27 in [PR #2067](https://github.com/callstack/agent-device/pull/2067) — `help batch` and its errors do not document the step shape or the batchable
   set; press/fill are batchable with the `{"command","input"}` shape (see pitfalls).
3. [#2063](https://github.com/callstack/agent-device/issues/2063) (closed), merged upstream 2026-08-27 in [PR #2066](https://github.com/callstack/agent-device/pull/2066) — `fill @ref ""` is rejected with `INVALID_ARGS`; there is no clear-field primitive.
4. [#2064](https://github.com/callstack/agent-device/issues/2064) (closed), merged upstream 2026-08-27 in [PR #2065](https://github.com/callstack/agent-device/pull/2065) — `--device <udid>` fails with `DEVICE_NOT_FOUND` without hinting at `--udid`, which
   exists but is missing from the global-flags help.
5. [#1394 (comment)](https://github.com/callstack/agent-device/issues/1394#issuecomment-5430618195) — The implicit cwd-hash session name coexists with an explicit `--session`, so two
   shells in different directories silently drive two sessions on one device.

## Optional: a patched agent-device build

**0.20.10 stays the baseline.** The skill, the cheatsheet and the pitfalls are pinned to it, and
every published number was measured with it unless a table header says otherwise.
The build below is optional, unpublished, and for people who would rather have the fixes now.

Four of the limitations listed above have fixes merged upstream
(2026-08-27); they are not in any released version yet (npm's latest is still 0.20.10), so this
build remains an interim until the next agent-device release ships them. Those four branches are
also merged onto upstream `main` on the fork
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

What changes, against the five items listed above:

| Limitation | Under `0.20.11-mc.1` |
|---|---|
| 1 — `close` leaks the device lease (#2031) | Already fixed upstream after 0.20.10 by #2057. PR #2068 additionally makes `DEVICE_IN_USE`'s own recovery hint executable and `session list` report a state dir that exists |
| 2 — `help batch` does not document the step shape (#2062) | **Fixed** (PR #2067). `help batch` prints `{"command":"<name>","input":{...}}` and the batchable set; all three refusals name the shape |
| 3 — no clear-field primitive (#2063) | **Fixed** (PR #2066). `fill <target> ""` clears the field; a *missing* text argument is still refused, by design |
| 4 — `--device <udid>` does not hint at `--udid` (#2064) | **Fixed** (PR #2065). The error answers `Did you mean --udid …?`, and `help commands` grows a `Device Selection` block listing `--udid` |
| 5 — implicit cwd-hash sessions coexist with `--session` (#1394) | **Not fixed.** #2068 makes the implicit session *addressable* by its `cwd:<hash>:<name>` key; it does not merge the two scopes. Keep passing `--session` on every call |

One thing this build does *not* fix: `--level digest --json snapshot -i` grew from 447 B on 0.20.10 to roughly 1.5 KB on the `0.20.11-dev` base this build sits on — larger than plain `snapshot -i` — see [`benchmarks.md`](benchmarks.md).

