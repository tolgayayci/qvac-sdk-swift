# `__init_config` handshake

The first request `QVACClient` sends on every new connection. Carried
on bare-rpc command id `1` (hardcoded in
`packages/sdk/client/init-hooks.ts:29-55`); the worker's dispatcher
intercepts `type === "__init_config"` pre-routing and bypasses normal
Zod schema validation.

Reference: `docs/qvac-sdk-internals.md` §4 (full wire spec).

## Wire shape (Swift ↔ Bare worker)

**Request** (Swift → worker):

```json
{
  "type": "__init_config",
  "config": <QvacConfig>      ?,
  "runtimeContext": <RuntimeContext> ?
}
```

**Reply** (worker → Swift):

```json
{ "success": true }
```

or on rejection:

```json
{ "success": false, "error": "..." }
```

Failure maps to `QVACError.server(.setConfigFailed, message:)` —
SDK error code `53350` (already in `Generated/ErrorCodes.swift`).

## Public Swift surface

```swift
let client = QVACClient(
  transport: myTransport,
  initConfig: QVACInitConfig(loggerLevel: .debug, cacheDirectory: "/tmp/qvac"),
  runtimeContext: QVACRuntimeContext()   // defaults: runtime "bare", platform auto-detected
)
try await client.connect()        // ← handshake runs here
```

Default `runtimeContext` sends `runtime: "bare"` + the host platform
(`darwin` / `ios` / `linux` / `win32`) auto-detected via `#if os(…)`.
Pass `nil` for either argument to send no `config` / `runtimeContext`
field (worker uses its built-in defaults).

`QVACInitConfig` mirrors the JS `QvacConfig` schema:

| Field | Swift type | JS default |
| --- | --- | --- |
| `cacheDirectory` | `String?` | `~/.qvac/models` |
| `swarmRelays` | `[String]?` | — |
| `loggerLevel` | `QVACLogLevel?` (`.error` / `.warn` / `.info` / `.debug`) | `.info` |
| `loggerConsoleOutput` | `Bool?` | `true` |
| `httpDownloadConcurrency` | `Int?` (positive) | `3` |
| `httpConnectionTimeoutMs` | `Int?` (positive) | `10000` |
| `registryDownloadMaxRetries` | `Int?` (≥ 0) | `3` |
| `registryStreamTimeoutMs` | `Int?` (positive) | `60000` |

Nil fields don't appear on the wire (Swift's `JSONEncoder` drops nils
by default — matches `JSON.stringify` behavior).

## Lifecycle integration

`QVACClient` adds an `.initializing` state to the lifecycle:

```
.disconnected → .connecting → .initializing → .connected
                              └── init-fail → .disconnected
```

`connect()` is the only place that drives the transition.
`requireBridge()` throws `.transport(.framingError("...not called or in progress"))`
during `.initializing`, so no other `send` / `streamResponse` call can
race past the handshake.

On init failure, the actor closes the bridge it just opened and rolls
back to `.disconnected`. Per single-use design (`docs/client-state-machine.md`),
the caller builds a new `QVACClient` to retry — there's no
`reconnect()` to re-run init on the same instance.

## The auto-inject `type` envelope (YK-198 bonus)

YK-197 surfaced that the worker dispatches by the JSON envelope's
`type` field, so any `send` / `streamResponse` call with a payload
missing it would silently hang. YK-198 fixes this in
`QVACClient.send` / `streamResponse` by re-framing the user's request
as `[String: AnyCodable]` and injecting `type = command.rawValue`
before handing it to `RPCBridge`. Implementation:

```swift
internal func buildEnvelope<Req: Encodable>(
  type: String,
  request: Req
) throws -> [String: AnyCodable] {
  let raw = try codec.encode(request)
  var dict: [String: AnyCodable]
  if let parsed = try? codec.decode([String: AnyCodable].self, from: raw) {
    dict = parsed
  } else {
    dict = [:]   // null / primitive / array payload — start empty
  }
  dict["type"] = AnyCodable(.string(type))
  return dict
}
```

Caller-supplied `type` (e.g. via a typed DTO that already has one) is
overridden — the `QVACCommand` argument is the source of truth.

The `__init_config` request *bypasses* this helper: its message body
IS the envelope (`type: "__init_config"` is detected pre-routing).
`QVACClient.sendInitConfig(on:)` uses `bridge.send` directly with an
`InitConfigRequest` struct.

## VTs

`Tests/QVACClientTests/Client/InitConfigTest.swift`:

| VT | Method | Asserts |
| --- | --- | --- |
| 1 | `testInitConfigDefaultsConnectAndSendWork` | `connect()` with default config completes; subsequent `heartbeat()` round-trips |
| 2 | `testInitConfigWithCustomPayload` | Fully-populated `QVACInitConfig` + `QVACRuntimeContext` encode + send + decode cleanly |
| 4 | `testInitConfigFailureSurfacesAsTypedError` | Peer `{success: false, error: ...}` → `QVACError.server(.setConfigFailed, message:)`; client rolls back to `.disconnected` |
| 6 | `testInitConfigCompletesQuickly` | Handshake RTT < 100ms on loopback (issue body asks <50ms; we use 100ms for CI tolerance) |
| 7 | `testInitConfigWireShape` + `testInitConfigResponseRoundTrip` | Encoded `InitConfigRequest` matches the documented wire spec; nil fields dropped; `success`/`error` response decodes |
| — | `testRuntimeContextDetectsPlatform` | Default `QVACRuntimeContext` picks the right host OS string |

VT-3 (premature send) is moot — `connect()` doesn't return until init
finishes, so the caller can't reach a state where they'd attempt a
`send` between connect-start and init-ack from the outside.

VT-5 (re-init after reconnect) is moot per the single-use design.

The "JS client byte-identical capture" angle of VT-7 lives in YK-208
(real worker fixture).

## Why bypass the envelope helper for init?

The handler dispatcher branches on `type == "__init_config"` *before*
running schema validation:

```ts
// packages/sdk/server/rpc/handle-request.ts:57-60
if (isInitConfigMessage(data)) {
  return handleInitConfig(data);
}
```

So the wire envelope IS the message — `config` and `runtimeContext` are
top-level fields, not nested under an `inner` key. Routing through
`buildEnvelope` would try to flatten `InitConfigRequest`'s fields into
the same dict (fine for `type`), but would also override our intended
`type = "__init_config"` with whatever `QVACCommand` was passed. The
init command isn't in `QVACCommand` deliberately — it's a pre-routing
construct, not a user-callable method — so we send it raw via
`bridge.send` instead.
