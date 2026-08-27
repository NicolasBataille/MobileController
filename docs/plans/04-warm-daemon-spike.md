# Spike: warm gRPC daemon to `idb_companion`, in Swift

Feasibility/latency spike for replacing per-call `idb`/CLI round-trips with a long-lived Swift process holding one gRPC connection to `idb_companion` over its unix domain socket. Device: an iPhone simulator, iOS 26.5 (UDID `<udid>`), app `com.apple.Preferences`. Host: macOS 26.5.2, Xcode 26.6, Swift 6.3.3, idb 1.5.0.b3, companion build 2026-08-19, on a shared, loaded box (baseline loadavg 11–22) — treat absolute ms as this-machine numbers.

**Question:** would a warm gRPC daemon talking directly to `idb_companion` be fast enough, deterministic enough, and cheap enough (build footprint, private-API exposure) to justify adding it to `simprobe` as a second capture/input transport alongside the existing `simctl`-based one?

## Feasibility

grpc-swift v2 works end to end, no dead end. Key trick: generate the protobuf/gRPC stubs **from the installed client's own descriptor**, not upstream `main`'s `idb.proto` (which has grown fields unknown to companion 1.5.0.b3, e.g. `AccessibilityInfoRequest.marker`, `Format.COMPLETE`) — dump `idb.grpc.idb_pb2.DESCRIPTOR` to a `FileDescriptorSet` and feed it to `protoc --descriptor_set_in`, wire-compatible by construction with whatever companion is actually installed. Codegen: 1.1 s for 14,234 lines / 614 KB of generated Swift. All calls worked first try: `describe` (device info), `accessibility_info` (backs `idb ui describe-all`, not `describe`), `hid` (client-streaming press DOWN + UP), `screenshot` — over `withGRPCClient(transport: .http2NIOPosix(target: .unixDomainSocket(...)), transportSecurity: .plaintext)`. ~110 lines of hand-written Swift.

## Measured latency

Warm = 20 calls in one long-lived process after warm-up; cold = one whole process per action, median of 10. Process floor (`/usr/bin/true`) = 6.7 ms.

| Operation | `idb` CLI cold | warm client cold (1/call) | **warm client warm** | fb-idb Python warm |
|---|---:|---:|---:|---:|
| HID tap | 375 ms | 31 ms | **1.1 ms** (min 0.5, p90 2.4) | 1.2 ms |
| AX tree (`describe-all`) | 623 ms | 481 ms (min 254, max 3907) | **70 ms** (min 59, p90 87) | 104 ms |
| screenshot | 320 ms (`simctl io`) | 148 ms | **55 ms** (422 KB PNG, 1320×2868) | 73 ms |

Tap is ~340x faster warm, ~12x faster even cold-per-process (the `hid` RPC returns once the companion accepts the events; the UI reaction is separate — what `wait-stable` is for). Cold-per-process tree is wildly variable (254–3907 ms), an argument for the daemon beyond just process-start cost. Swift beats warm Python ~1.5x on tree/screenshot (protobuf decode, no GIL); they tie on tap, which is I/O bound.

## Tap determinism

**12/12, deterministic.** Read tree, tap the centre of a row's `frame`, poll until two consecutive trees are identical, assert the row is gone, `#BackButton` exists, and the new heading matches the row label. Four Settings rows × 3 repeats = 12/12 correct destination, 0 misses, 0 stray dialogs, median 2 extra polls. Coordinates are logical points; `describe` reports a 3.0x scale factor, matching the architecture doc's assumption that a 1x screenshot lines up 1:1 with AX frames (not compared against XCUITest — unavailable for this spike). A probe that slept a fixed delay instead of waiting for stability reproduced a known hazard in a new shape: a *merged* tree with rows from both the root and pushed screen — duplication, not just truncation.

## Tree richness

| Screen | elements | bytes | `AXUniqueId` | `AXLabel` | `AXValue` | `frame` | `enabled` |
|---|---:|---:|---:|---:|---:|---:|---:|
| Settings root | 16 | 6,732 | 13 (81%) | 15 | 0 | 16 | 16 |
| Accessibility | 17 | 7,799 | 8 (47%) | 16 | 0 | 17 | 17 |

Identifiers are real and stable (e.g. `com.apple.settings.accessibility`, `HOVERTEXT_TITLE`, `BackButton`) — `#id` selection is viable, label as fallback; `frame` on 100% of nodes means tap point = frame centre with no extra query. **`AXValue` is null everywhere on Settings** — row state is folded into the label instead (e.g. "Survol de texte, Non"), so an `#id → value` selector can't rely on `AXValue`; `traits` carries structure instead (`BackButton`, `Header`, `Scrollable`, `TextOperationsAvailable`).

## Build / dependency footprint, and private-API status

- **22** transitive SwiftPM packages (grpc-swift-2, nio-transport, nio-protobuf, swift-nio ×5, nio-ssl, nio-http2, swift-certificates, swift-crypto, asn1, collections, algorithms, atomics, numerics, http-types, …), plus three brew packages (`protoc-gen-grpc-swift`, `swift-protobuf`, `protobuf`).
- Clean release build: **≈19 minutes wall** on the loaded spike machine, dominated by **BoringSSL (~850 C++ units)** pulled in transitively by `swift-nio-ssl` — for a socket that only ever speaks **plaintext**.
- Incremental rebuild (our file only): 8.1 s. Binary: 36.0 MB unstripped, 19.4 MB stripped.
- Codesigning: ad-hoc/linker-signed, runs as-is; no entitlements, no notarisation, no `disable-library-validation`.
- Private APIs: **none.** `grep -riE "dlopen|AXPTranslator|SimulatorKit|CoreSimulator"` over the spike sources and `Package.swift` returns zero hits; `otool -L` links only libSystem, Foundation, CoreFoundation, Security, Network, CryptoKit, libc++/libz. Passes the repo's hygiene gate unchanged.

## Integration sketch

```
simprobe daemon start [--udid X]  # detached; ensures idb_companion is up (spawning it
                                   # ourselves if needed); holds one GRPCClient; smoke-checks
                                   # (tree >= 10 elements); writes a pidfile
simprobe daemon stop  [--udid X]  # the only process simprobe would ever kill: its own,
                                   # via its own pidfile
simprobe tree | tap <#id|x,y> | shot | wait-stable | motion
```

Client verbs would connect to a per-UDID unix socket, autostarting the daemon when absent and retrying once; cold warm-client latency (~31 ms/tap) means a missing daemon degrades gracefully instead of failing outright. `SimProbeCore` stays pure; this adds one adapter beside the existing `simctl` one (`wait-stable` at 55 ms/frame vs ~200 ms today: 3.6x faster poll loop, same state machine) — a second transport to the same data, not a pluggable-backend decision; `simctl` capture stays the sole default/fallback.

## Verdict: LATER — build it for v0.2, not now

The engineering risk is gone: grpc-swift v2 builds on Swift 6.3/macOS 26, talks to companion 1.5.0.b3 over the unix socket, private-API-free and signing-free. The win beats the forecast — tap 375 → 1.1 ms, tree 623 → 70 ms, screenshot 320 → 55 ms, taps landing 12/12 deterministically. But it's not free and not v1: 22 transitive packages and a ~19-minute clean build (BoringSSL, for a plaintext socket) against simprobe's current single dependency; a 19–36 MB binary against ~2 MB; a daemon lifecycle, socket and stale-pidfile story; a hard dependency on `idb_companion` being installed and connected.

**The one condition that flips this to GO:** the mixed-engine test passes — an agent-device/XCUITest session open on the same simulator while idb HID taps land, and a snapshot through that session still returns a correct tree afterward — **not yet tested**: the XCUITest-based harness was unavailable on this machine, and an XCUITest session's own accessibility connection is the single biggest unknown (some Xcode betas are reported to silently no-op touches while such a session is open). simprobe sits *beside* agent-device, so a daemon that poisons its session is worse than a slow-but-safe CLI call. Run that test as soon as the harness is available; if it passes, build it — everything else here is already measured and works.
