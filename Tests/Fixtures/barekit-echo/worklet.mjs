// YK-206 — minimal Bare worklet for BareKitIPCTransport tests.
//
// Reads frames from BareKit's BareIPC and writes them straight back.
// Just enough to verify the transport's read/write/close cycle works
// in-process (no QVAC SDK, no models — that's YK-209 / `embedded()`
// once the qvac-worker.bundle ships).
//
// Loaded by `BareKitIPCTransport(filename:bundleSource:)`. The
// bundle is produced by `bare-pack` so this single source file
// becomes a self-contained .bundle the worklet can run.

const BareIPC = require('bare-ipc')

const ipc = new BareIPC()
ipc.on('data', (data) => {
  ipc.write(data)
})
ipc.on('end', () => {
  Bare.exit(0)
})
