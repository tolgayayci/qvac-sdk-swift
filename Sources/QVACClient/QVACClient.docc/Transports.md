# Transports

Three `Transport` implementations cover every Apple-platform
deployment target the SDK ships against.

## Overview

A `Transport` is the duplex bytes-channel underneath the bare-rpc
framing layer. QVACClient picks one at construction; everything
above the transport (typed methods, error mapping, streaming) is
identical.

| Transport | Worker lives where | Use |
| --- | --- | --- |
| ``UDSTransport`` | external Bare process Swift dials into | M1 ping fixture / Swift-as-client patterns |
| ``UDSServer`` + accepted `Transport` | external Bare process that connects to Swift | macOS / Linux CLI + server apps (production topology) |
| ``BareKitIPCTransport`` | in-process worklet hosted by `BareKit.framework` | iOS apps + sandboxed macOS apps |

## Picking a transport

Use ``QVACClient/spawning(bareBinary:workerScript:initConfig:runtimeContext:acceptTimeout:)``
when you can spawn a subprocess — typically macOS or Linux CLI apps,
servers, or development setups. The factory opens a UDS server,
forks `bare worker.mjs`, waits for the worker to connect, and runs
the `__init_config` handshake. Tear-down on
``SpawnedClient/close()`` shuts everything in order: client →
worker SIGTERM → UDS server → socket-file unlink.

Use ``QVACClient/embedded(initConfig:runtimeContext:)`` on iOS or
inside a sandboxed macOS app. The factory hosts the worker
**in-process** as a Bare worklet via
``BareKitIPCTransport``. The transport is wired today; the
SPM-resource `qvac-worker.bundle` it loads is the missing piece
(tracked as YK-207 v2). Until the bundle ships, you can construct
``BareKitIPCTransport/init(filename:bundleSource:arguments:)``
directly with your own `bare-pack`-produced bundle.

## The production topology

QVAC's `@qvac/sdk` worker is the **IPC client** — it dials the
host's socket on startup. So when running over UDS:

```
   Swift app                    bare worker.mjs
   ---------                    ---------------
1. UDSServer.listen()
2. spawn bare(worker.mjs)
                                3. bare-net.connect(socketPath)
4. UDSServer.accept()  <-- accepts the worker's connection
5. __init_config handshake
6. ready for QVACClient calls
```

`UDSTransport` (Swift-as-client) is the inverse arrangement — used
by the M1 ping fixture and by patterns where another process owns
the listening socket. Most production code wants the
``UDSServer`` shape, which is what ``QVACClient/spawning(bareBinary:workerScript:initConfig:runtimeContext:acceptTimeout:)``
gives you.

## BareKit on iOS

`BareKit.xcframework` is the iOS-friendly Bare runtime — it embeds
Apple's JavaScriptCore (not V8) and runs the Bare event loop
in-process. ``BareKitIPCTransport`` opens a duplex pipe to the
hosted worklet via the BareKit ObjC SDK.

The xcframework is **not committed**: a setup script
(`scripts/download-barekit.sh`) pulls the JavaScriptCore variant
(~20MB) from the upstream `holepunchto/bare-kit` v2.1.0 release.
`Package.swift` references the local path as a `.binaryTarget`;
SwiftPM consumers run the script once before `swift build`.

## What to test against

The package ships a Bare worker fixture (`Tests/Fixtures/qvac-worker/`)
that runs the real `@qvac/sdk` 0.10.2 worker. Integration tests for
both transports point at it. For embedded-worker tests, see
``BareKitIPCTransport`` — the runtime echo round-trip is parked
behind YK-207 v2's bundle pipeline because JavaScriptCore-flavored
BareKit can't `require('bare-ipc')` from raw `.mjs` source.
