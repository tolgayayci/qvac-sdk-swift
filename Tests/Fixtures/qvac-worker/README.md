# `Tests/Fixtures/qvac-worker/`

Real `@qvac/sdk` Bare worker used by `QVACClientTests` integration
tests (YK-208). The harness (`QVACWorkerHarness.swift`) is the IPC
**server**; this worker is the IPC **client** that connects to it,
matching production topology.

## Layout

| File | Purpose |
| --- | --- |
| `package.json` | Pins `@qvac/sdk@0.10.2` (matches the codegen pin) |
| `worker.mjs` | Imports `@qvac/sdk/dist/server/worker.js` (registers all built-in plugins, calls `createIPCClient` per `QVAC_IPC_SOCKET_PATH`); writes `FIXTURE_READY` to stdout after import |
| `package-lock.json` | Locked deps for reproducibility |

## Manual run

```bash
# install deps once
cd Tests/Fixtures/qvac-worker && npm ci

# open a UDS server somewhere first (the harness does this from Swift)
nc -lU /tmp/qvac-test.sock &

# spawn the worker
bare worker.mjs '{"QVAC_IPC_SOCKET_PATH": "/tmp/qvac-test.sock"}'
```

The worker logs `🐻 Hello from Bare` and `Running in desktop mode,
connecting to IPC socket: /tmp/qvac-test.sock` from `@qvac/sdk`'s own
logger, then `Connected to IPC server` once the socket accepts.

## Model dependencies

`worker.mjs` registers all built-in plugins but loads NO models on
startup — model load is per-request via the SDK's `loadModel`
handler. Tests that exercise inference download a model in their
setup phase; the fixture itself only needs `@qvac/sdk` + native
addons.

Some native addons (llm.cpp, diffusion, whisper) carry their own
build/install steps via npm — see the upstream addon READMEs if
`npm ci` fails on a specific platform.

## Topology mismatch with the M1 PING fixture

`Tests/Fixtures/ping-server/` is the inverse — that fixture is the
*listener* and the Swift `UDSTransport` connects to it. That mirror
was M1's pragmatic shortcut to demo the bare-rpc framing without
needing a UDS server in Swift. M2 onwards uses this real-worker
fixture + `UDSServer` for production-shape integration tests; the
PING fixture remains for the M1 transport/framing regression
coverage.
