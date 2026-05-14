# BareKit transport (`BareKitIPCTransport`)

YK-206 — the third `Transport` implementation, sitting alongside the
two UDS variants. Used by iOS apps and sandboxed macOS apps that
can't spawn subprocesses; runs the QVAC Bare worker **in-process**
via `BareKit.xcframework`.

## Why a third transport

| Transport | Worker lives | Use |
| --- | --- | --- |
| `UDSTransport` | external Bare process Swift dials into | M1 ping fixture / Swift-as-client patterns |
| `UDSServer` + `UDSAcceptedTransport` | external Bare process that connects to Swift | macOS / Linux CLI + server apps (YK-208 production topology) |
| **`BareKitIPCTransport`** | **in-process worklet** hosted by BareKit.framework | **iOS apps, sandboxed macOS apps** |

iOS forbids spawning child processes; macOS App Sandbox forbids it
too for most distribution paths. The QVAC SDK's worker.js must run
inside the host app. `BareKit.framework` provides exactly that —
it's Apple's app-friendly Bare runtime.

## BareKit.framework provisioning

`BareKit.xcframework` isn't trivially SPM-installable from a single
release URL. It ships inside `holepunchto/bare-kit`'s
[`prebuilds.zip`](https://github.com/holepunchto/bare-kit/releases)
release asset (which contains both V8 and JavaScriptCore variants).

This repo includes a helper script:

```bash
./scripts/download-barekit.sh
```

That script downloads `prebuilds.zip` from the pinned `v2.1.0`
release, extracts the **JavaScriptCore variant** (~20MB, uses
Apple's built-in JS engine — much smaller than the V8 variant's
~353MB on macOS), and stages it at `Vendor/BareKit.xcframework/`.
Gitignored; never committed.

The xcframework variants:

| Variant | macOS slice size | iOS slice size | Use |
| --- | --- | --- | --- |
| `apple-javascriptcore/BareKit.xcframework` | ~6MB | ~2.8MB | **Default** — pinned in `download-barekit.sh` |
| `apple/BareKit.xcframework` | ~135MB | ~32MB | Full V8 — only needed if a model requires V8-specific APIs (none do today) |

`Package.swift` references the local path via `.binaryTarget(name: "BareKit", path: "Vendor/BareKit.xcframework")`. SPM consumers run the download script once before `swift build`.

## SPM target layout

Three new SPM targets in `Package.swift`:

```
.binaryTarget(name: "BareKit", path: "Vendor/BareKit.xcframework")
    ↑ the Apple-provided .xcframework

.target(name: "BareKitBridge", dependencies: ["BareKit"], ...)
    ↑ inlined from holepunchto/bare-kit-swift; one-line bridging
      header pulling in BareKit/BareKit.h

.target(name: "BareKitWrapper", dependencies: ["BareKitBridge"], ...)
    ↑ inlined from bare-kit-swift; `Worklet` + `IPC` Swift wrappers

.target(name: "QVACClient", dependencies: [..., "BareKitWrapper"], ...)
    ↑ uses Worklet + IPC via BareKitWrapper
```

Why inline the wrappers (vs depending on `bare-kit-swift`):
`bare-kit-swift`'s `BareKitBridge` target uses `.linkedFramework("BareKit")`
which only resolves correctly when the framework is in the linker's search
path — coordinating that with a SPM dep is fragile. Inlining ~100 lines of
Swift+ObjC avoids the coordination, keeps everything in our Package.swift,
and `NOTICE` carries the upstream Apache-2.0 attribution.

## Public API

```swift
public final class BareKitIPCTransport: Transport, @unchecked Sendable {
  public init(
    filename: String = "qvac",
    bundleSource: Data,
    arguments: [String] = []
  )

  public func open() async throws
  public func send(_ data: Data) async throws
  public func close() async
  public var state: TransportState { get async }
  public var incoming: AsyncThrowingStream<Data, Error>
}
```

`bundleSource: Data` is the bytes of a `bare-pack`-produced `.bundle`
file. The constructor:

1. Builds a `Worklet` and starts it with the bundle (BareKit
   evaluates the JS in the in-process worklet thread).
2. Wraps the worklet's `BareIPC` duplex pipe.
3. Spawns a background Task that drains `IPC.read()` into the
   transport's `AsyncThrowingStream<Data, Error>`.
4. `send(_:)` forwards to `IPC.write(data:)`.

Lifecycle is single-use (same as `QVACClient` itself): `close()`
calls `IPC.close()` + `worklet.terminate()`. A new transport
requires a new instance.

## Today's status

| AC | Status |
|---|---|
| `BareKitIPCTransport` conforms to `Transport` | ✅ — `swift build` clean; `testTransportProtocolConformance` enforces |
| `BareKit.xcframework` linked | ✅ — `scripts/download-barekit.sh` + `.binaryTarget` in Package.swift |
| All 10 VTs green on macOS + iOS | ⏳ — runtime tests require the `bare-pack`-bundled QVAC worker (YK-207 v2). The JavaScriptCore variant of BareKit can't `require('bare-ipc')` from raw `.mjs` sources; needs `bare-pack` to inline everything into a single `.bundle` |
| Worklet suspend/resume | Not exposed today; iOS-only optimization for app-background recovery. Lands when the M3 example app needs it. |
| Documentation | This file. |

## What's deferred (waiting on bundle pipeline)

- **Echo round-trip test** (VT-1, VT-2) — `testEchoRoundTrip` is currently `XCTSkip`'d because the raw `worklet.mjs` can't resolve `require('bare-ipc')` inside BareKit. `bare-pack` produces a bundle where every require is inlined; once that's in place the existing test wires immediately.
- **`QVACClient.embedded()` factory** — signature shipped (YK-207), body throws until the SPM-resource `qvac-worker.bundle` exists.
- **iOS Simulator CI** (VT-8) — YK-210 adds `xcodebuild -destination 'platform=iOS Simulator...'` to the CI matrix. The transport itself is iOS-ready; just need the runner.
- **Suspend/resume + repeated start/stop memory** (VT-6, VT-10) — production-ready features for the M3 example app; not a M2 deliverable.

## The bundle pipeline (YK-207 v2)

To finish wiring `embedded()`:

1. `scripts/bundle-worker/` — Node script that `npm install`s
   `@qvac/sdk` + addons, writes an entry that calls the SDK's
   `worker.js`, runs `bare-pack` to produce `qvac-worker.bundle`.
2. `Sources/QVACClient/Resources/qvac-worker.bundle` — committed
   binary (or fetched via a setup script if size is prohibitive).
3. `Package.swift` `resources: [.copy("Resources/qvac-worker.bundle")]`.
4. `embedded()` body resolves via `Bundle.module.url(...)`.

Whether the bundle is committed or fetched depends on its size
(LLM + diffusion + whisper addons could blow past SPM resource
sanity limits). The `apple-javascriptcore` BareKit variant is
20MB on its own; the bundle could easily add another 100MB.
Decision deferred to YK-207 v2 once we measure.
