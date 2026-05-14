# Real QVAC Bare worker fixture (`Tests/Fixtures/qvac-worker/`)

YK-208 ships a production-shape integration test fixture: the **real
`@qvac/sdk` Bare worker** spawned as a subprocess, connected over a
Unix domain socket the Swift host opens first.

## Why production-shape

The `@qvac/sdk` server (`@qvac/sdk/dist/server/worker.js` and
`worker-core.js`) is the IPC **client**:

```js
// @qvac/sdk/dist/server/rpc/create-server.js
export function createIPCClient(socketPath, options) {
  const socket = connect(socketPath);   // ← connects OUT
  return new RPC(socket, handleRequest);
}
```

So the Swift host must be the **server**: open a UDS socket, then
spawn the worker pointing at it. The M1 `ping-server` fixture
inverted this (Swift = client, fixture = listener) as a shortcut
for the framing tests, but production needs the inverse.

## Files

| File | Purpose |
| --- | --- |
| `Tests/Fixtures/qvac-worker/package.json` | Pins `@qvac/sdk@0.10.2` (matches the codegen pin in `scripts/codegen/`) |
| `Tests/Fixtures/qvac-worker/worker.mjs` | One-liner: `import "@qvac/sdk/dist/server/worker.js"` — delegates to the SDK's actual worker entry which registers all built-in plugins (llm, embeddings, whisper, parakeet, nmt, tts, ocr, diffusion) and calls `createIPCClient(socketPath)` |
| `Tests/Fixtures/qvac-worker/package-lock.json` | Locked deps for reproducible `npm ci` |
| `Tests/Fixtures/qvac-worker/.gitignore` | Ignores `node_modules/` and stale `.sock` files |

## Swift side — `UDSServer` + `QVACWorkerHarness`

| File | Purpose |
| --- | --- |
| `Sources/QVACClient/Transport/UDSServer.swift` | POSIX `socket`/`bind`/`listen`/`accept` server. NWListener doesn't natively support `.unix` endpoints (returns `EINVAL`), so we use BSD sockets directly and wrap the accepted fd as a `Transport`. Single-connection by design. |
| `Tests/QVACClientTests/Helpers/QVACWorkerHarness.swift` | Lifecycle: opens `UDSServer` on a tmp socket, spawns `bare worker.mjs '{"QVAC_IPC_SOCKET_PATH": "..."}'`, awaits `server.accept()` (the ready signal — the worker has connected and `createIPCClient` succeeded), exposes the accepted `Transport` for `RPCBridge` / `QVACClient` |

## Tests using it

`Tests/QVACClientTests/Integration/QVACWorkerHarnessTest.swift`
covers the topology + lifecycle invariants:

- `testWorkerBootsAndAnswersHeartbeat` — full flow: harness boots
  the real worker → Swift `connect()` sends `__init_config` to the
  real SDK dispatcher → `heartbeat()` round-trips a real
  `HeartbeatResponse`.
- `testHarnessStopRemovesSocket` — SIGTERM via stdin-close;
  socket file removed; no leak.
- `testTwoHarnessesCoexist` — two harnesses in parallel against
  two workers; distinct socket paths; both heartbeats succeed.

Real-inference VTs (load a model, run a completion, etc.) require
model weights and live in **YK-209 (M2-INTEGRATION-TESTS)** which
adds the download step.

## Running locally

```bash
cd Tests/Fixtures/qvac-worker
npm ci                    # ~50s first run; installs @qvac/sdk + transitive Bare deps

# Run the harness tests
swift test --filter QVACWorkerHarnessTest
```

CI runs the same `npm ci` step in `.github/workflows/ci.yml` →
`swift-macos` job.

## When `npm ci` fails

Most likely causes:

- **Node version** — the package requires Node ≥ 22. Run
  `node --version` and bump if needed.
- **Native addons** — `@qvac/sdk` pulls in `bare-runtime`,
  `qvac-fabric-*` addons that need a working C/C++ toolchain.
  On macOS, Xcode command-line tools usually cover this; on
  Linux you may need `apt-get install build-essential`.
- **Network** — `npm ci` fetches from the npm registry. Air-gapped
  CI must mirror.

## Limitation note

The fixture only proves the **transport + dispatch** layer end-to-end
— no model is loaded by `worker.mjs` itself. The SDK's `loadModel`
handler runs but won't find a model unless tests download one (which
is YK-209's responsibility, not this fixture's).
