# Embedding the QVAC worker (`QVACClient` factories)

`QVACClient` ships two convenience factories that wrap the worker-
spawn + transport + connect + `__init_config` dance. Pick one based
on how your app runs:

| Factory | Use when… | Transport | Status |
| --- | --- | --- | --- |
| **`QVACClient.spawning(bareBinary:workerScript:)`** | macOS / Linux / CLI / server — you can spawn subprocesses freely | `UDSServer` + spawned `bare worker.mjs` | **✅ Ships today (YK-207)** |
| **`QVACClient.embedded()`** | iOS app / macOS app sandbox — can't spawn external processes; need in-process worker | `BareKitIPCTransport` (in-process Bare worklet) | **⏳ Stubbed today; wired in YK-206** |

## `spawning(...)` — production-shape, today

```swift
import QVACClient

let bareBinary = URL(fileURLWithPath:
  "/path/to/qvac-worker/node_modules/.bin/bare")
let workerScript = URL(fileURLWithPath:
  "/path/to/qvac-worker/worker.mjs")

let spawned = try await QVACClient.spawning(
  bareBinary: bareBinary,
  workerScript: workerScript,
  initConfig: QVACInitConfig(loggerLevel: .debug),
  runtimeContext: QVACRuntimeContext())

// spawned.client is a ready-to-use QVACClient (state == .connected,
// __init_config already done).
let response = try await spawned.client.heartbeat()

// Tear down everything (client + subprocess + UDS server +
// socket file) with one call:
await spawned.close()
```

Returned type is `SpawnedClient` — a thin owner of the lifecycle.
`spawned.client` is the `QVACClient` you call methods on.
`spawned.close()` tears down in order: client → process → server →
socket file. Idempotent; the `deinit` also has a best-effort
SIGTERM fallback so a dropped reference doesn't leak the worker.

### `bareBinary` + `workerScript` paths

The factory takes explicit paths so you decide where the worker
lives. The minimum setup (mirrors `Tests/Fixtures/qvac-worker/`):

```bash
mkdir my-qvac-worker && cd my-qvac-worker
npm init -y
npm install @qvac/sdk@0.10.2
cat > worker.mjs <<'EOF'
import "@qvac/sdk/dist/server/worker.js"
EOF
```

Then in Swift:

```swift
let dir = URL(fileURLWithPath: "/path/to/my-qvac-worker")
let spawned = try await QVACClient.spawning(
  bareBinary: dir.appendingPathComponent("node_modules/.bin/bare"),
  workerScript: dir.appendingPathComponent("worker.mjs"))
```

`node_modules/.bin/bare` ships transitively via `@qvac/sdk` →
`bare-runtime`. No global `bare` install is required.

### Topology recap

The QVAC SDK's worker.js calls `bare-net.connect(socketPath)` —
it's the IPC **client**. Swift opens the UDS server first, spawns
the worker pointing at the socket; the worker connects in,
`UDSServer.accept()` returns the wire. `spawning()` does all of
that for you.

## `embedded()` — stubbed today, wired in YK-206

```swift
let client = try await QVACClient.embedded()   // throws today
```

Throws `QVACError.transport(.framingError("...YK-206..."))` until
YK-206 lands. The signature is committed so M3's example app and
DocC tutorials can target it.

### Why deferred

`embedded()` requires:

1. **`bare-kit-swift` dependency** — adds the BareKit.xcframework
   that lets Swift host a Bare worklet in-process. Pin documented in
   `docs/dependencies.md` (`ef26bbd`); waiting on YK-206 to add the
   SPM dep + native framework wiring.
2. **`BareKitIPCTransport`** — server-side `Transport` that talks
   to the worklet's built-in IPC stream rather than a UDS socket.
   Same shape as `UDSAcceptedTransport`, different underlying
   primitive. Owned by YK-206.
3. **Bundled `qvac-worker.bundle`** as an SPM resource (or
   downloaded at first call). The bundle would be produced by
   `bare-pack` over `@qvac/sdk` + the addons; size is the open
   question (LLM + diffusion + whisper add up). When it lands,
   `embedded()` resolves the resource via `Bundle.module.url(...)`.

The full bundling pipeline is the second half of YK-207 and lands
once the BareKit transport (YK-206) is wired — there's no point
shipping a bundle without a transport to feed it.

## Tests

`Tests/QVACClientTests/Integration/SpawningFactoryTest.swift`:

| Test | Asserts |
| --- | --- |
| `testSpawningReturnsConnectedClient` | Full flow: spawn → init → heartbeat against real `@qvac/sdk` |
| `testSpawnedClientCloseTearsDownAll` | Idempotent close; no leak |
| `testEmbeddedFactoryIsStubbedUntilYK206` | Calling `embedded()` throws with a YK-206 reference |
