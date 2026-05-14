# QVACClient — native Swift client for Tether's QVAC SDK

<!-- The badge URL resolves once the repo is pushed under its final org/name.
     Placeholder for now; tracked by YK-227 (proposal) / YK-229 (submit). -->
[![ci](https://github.com/qvac-swift/QVACClient/actions/workflows/ci.yml/badge.svg)](https://github.com/qvac-swift/QVACClient/actions/workflows/ci.yml)

A Swift Package Manager library that gives macOS and iOS apps first-class, type-safe access
to the [QVAC SDK](https://github.com/tetherto/qvac)'s on-device AI capabilities — text
completion, embeddings, transcription, translation, text-to-speech, OCR, diffusion, RAG,
and custom plugins — without going through React Native or a JS bridge.

> **Status: pre-release (M1 in progress).** No usable public API yet — surface lands
> across milestones M1 → M3. See [`CHANGELOG.md`](./CHANGELOG.md) for the per-milestone
> shipping plan and the project's [Linear board](https://linear.app/yk-labs/project/qvac-sdk-swift-client-tether-bounty)
> for live status. Tracking issue range: **YK-174 → YK-229** (16 M1, 16 M2, 13 M3, 5 application).

## Plan

| Milestone | Target | Headline deliverables |
| --- | --- | --- |
| **M1** | 2026-05-25 | Code-gen pipeline + IPC transport (UDS + Bare-kit); `loadModel`/`unloadModel`/`heartbeat`/`embed` working against a real Bare worker fixture. |
| **M2** | 2026-06-08 | Full method surface (completion + streaming, transcribe/transcribeStream, translate, ocr, diffusion/upscale, textToSpeech/Stream, lifecycle). |
| **M3** | 2026-06-22 | RAG (9 ops) + plugins, DocC catalog + tutorials, SwiftUI example app, Swift Package Index listing, v0.1.0 release. |

## Architecture (sketch)

```
+-------------------------+              IPC duplex (UDS or Bare-kit)              +-------------------+
|   Your Swift app        |  <----------------------------------------------->     |  Bare worker      |
|                         |                                                        |  (qvac/sdk        |
|   import QVACClient     |       bare-rpc framing (binary frames)                 |   plugins +       |
|                         |        +                                               |   native addons)  |
|   let client = QVACClient.embedded()                                             |                   |
|   try await client.loadModel(...)                                                |                   |
|   for try await event in client.completion(...) { ... }                          |                   |
+-------------------------+                                                        +-------------------+
```

- **Transport layer**: `Transport` protocol (YK-183) with `UDSTransport` (Network.framework
  `NWConnection .unix`) for desktop and `BareKitIPCTransport` for embedded iOS worklets.
- **Frame layer**: [`bare-rpc-swift`](https://github.com/holepunchto/bare-rpc-swift) — pinned to
  main and re-validated by our own fixture tests against the JS reference (`docs/bare-rpc-wire-protocol.md`).
- **Protocol layer**: JSON envelopes over bare-rpc, dispatched by string `request.type`
  (see `docs/qvac-sdk-internals.md`).
- **API layer**: generated from the upstream TypeScript declarations of `@qvac/sdk` by a Node
  tool (`scripts/codegen/`, YK-178+). CI enforces zero-diff regeneration on every PR.

## Public API target

The Swift surface is a faithful (and idiomatically async/await + actor-based) port of
[the @qvac/sdk method list](https://docs.qvac.tether.io/sdk/api/):

`completion`, `embed`, `transcribe`, `transcribeStream`, `textToSpeech`, `textToSpeechStream`,
`translate`, `ocr`, `diffusion`, `upscale`, `loadModel`, `unloadModel`, `heartbeat`,
`getModelInfo`, `getLoadedModelInfo`, `deleteCache`, `cancel`, `loggingStream`,
`ragIngest`, `ragSearch`, `ragChunk`, `ragSaveEmbeddings`, `ragDeleteEmbeddings`,
`ragReindex`, `ragListWorkspaces`, `ragCloseWorkspace`, `ragDeleteWorkspace`,
`invokePlugin`, `invokePluginStream`, `modelRegistryList`, `modelRegistrySearch`,
`modelRegistryGetModel`, `suspend`, `resume`, `state`, `startQVACProvider`, `stopQVACProvider`,
`finetune`, `downloadAsset`, `close`.

## Documentation

- **[`docs/qvac-sdk-internals.md`](./docs/qvac-sdk-internals.md)** — full SDK wire model:
  request type registry (31 handlers), error code tables (4 ranges, 128 codes), `__init_config`
  handshake, per-method request/response shapes.
- **[`docs/bare-rpc-wire-protocol.md`](./docs/bare-rpc-wire-protocol.md)** — byte-level frame
  layout, OPEN handshake, PAUSE/RESUME backpressure, end-of-stream vs destroy semantics,
  byte-exact hex fixtures.

## Building locally

```bash
swift --version       # expects 5.10+
swift build           # zero warnings
swift test            # smoke + doc-baseline tests
```

## License

Apache-2.0 (matches QVAC and Holepunch upstream). See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
