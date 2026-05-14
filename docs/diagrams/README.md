# Architecture diagram

Source of truth: [`architecture.mmd`](./architecture.mmd) (Mermaid).
Rendered exports — re-generated on every commit that touches the source:

| Format | Use | File |
| --- | --- | --- |
| **SVG** (transparent bg) | README, DocC catalog, application Notion doc | [`architecture.svg`](./architecture.svg) |
| **PNG 1600×N** (white bg) | Bounty application form, slide decks, chat previews | [`architecture.png`](./architecture.png) |
| **Mermaid source** | This page (renders inline on GitHub) | below |

## Inline render

GitHub renders Mermaid natively in `.md` files, so the source below stays
in lock-step with the rendered exports.

```mermaid
%%{ init: { "theme": "neutral", "flowchart": { "htmlLabels": false, "curve": "linear" } } }%%
flowchart TB
  %% Color-blind-friendly Okabe-Ito palette
  classDef app        fill:#56B4E9,stroke:#1B4965,stroke-width:1.5px,color:#0B2638
  classDef swift      fill:#E6E6E6,stroke:#444,stroke-width:1.2px,color:#000
  classDef transport  fill:#E69F00,stroke:#7C5500,stroke-width:1.5px,color:#1F1300
  classDef framing    fill:#CC79A7,stroke:#612845,stroke-width:1.5px,color:#1F0813
  classDef bare       fill:#009E73,stroke:#003A2A,stroke-width:1.5px,color:#E8FFF7
  classDef addon      fill:#999999,stroke:#333,stroke-width:1.2px,color:#0F0F0F

  subgraph L1[" Your app "]
    AppCLI["macOS / Linux CLI<br/>or daemon"]:::app
    AppGUI["SwiftUI app<br/>iOS or macOS"]:::app
  end

  subgraph L2[" QVACClient — public Swift surface "]
    Client["QVACClient (actor)<br/>40 methods<br/>async / AsyncThrowingStream"]:::swift
    Models["Generated DTOs<br/>26 Codable types"]:::swift
    Errors["QVACError<br/>+ 116 wire codes"]:::swift
  end

  subgraph L3[" Framing — bare-rpc-swift "]
    Bridge["RPCBridge (actor)<br/>send  /  streamResponse"]:::framing
    RPC["BareRPC.RPC<br/>length-prefixed framing<br/>OPEN / DATA / END / PAUSE"]:::framing
  end

  subgraph L4[" Transport — dual "]
    UDS["UDSTransport<br/>NWConnection .unix<br/>macOS  /  Linux"]:::transport
    BareKit["BareKitIPCTransport<br/>in-process worklet<br/>iOS  /  macOS apps<br/>YK-206 / M2"]:::transport
  end

  subgraph L5[" Bare worker (Node / Bare runtime) "]
    ExtBare["External Bare process<br/>spawned by the app"]:::bare
    EmbBare["Embedded Bare worklet<br/>bundled SPM resource"]:::bare
    QVACSDK["@qvac/sdk<br/>handler-registry<br/>31 request types"]:::bare
  end

  subgraph L6[" QVAC native addons "]
    LLM["LLM<br/>llama.cpp"]:::addon
    Diff["Diffusion<br/>Stable Diffusion"]:::addon
    Whisper["Whisper<br/>+ TTS"]:::addon
    OCR["OCR / Translate<br/>Bergamot"]:::addon
    RAG["RAG<br/>embeddings + index"]:::addon
  end

  AppCLI --> Client
  AppGUI --> Client
  Client --> Models
  Client --> Errors
  Client --> Bridge
  Bridge --> RPC
  RPC --> UDS
  RPC --> BareKit
  UDS -. "unix socket" .-> ExtBare
  BareKit -. "in-proc pipe" .-> EmbBare
  ExtBare --> QVACSDK
  EmbBare --> QVACSDK
  QVACSDK --> LLM
  QVACSDK --> Diff
  QVACSDK --> Whisper
  QVACSDK --> OCR
  QVACSDK --> RAG
```

## Layer guide

| # | Layer | What lives here | Status |
| --- | --- | --- | --- |
| 1 | **Your app** — CLI, daemon, SwiftUI app | The caller. Just `import QVACClient`. | n/a |
| 2 | **QVACClient public surface** | 40 async methods + 26 generated `Codable` DTOs + `QVACError` (116 wire codes mapped) | M1: surface complete; M2: bodies wired through to RPCBridge |
| 3 | **Framing — bare-rpc-swift** | `RPCBridge` actor adapts `BareRPC.RPC` (length-prefixed frames + OPEN/DATA/END/PAUSE stream flags) into async/await and `AsyncThrowingStream` | M1 shipped |
| 4 | **Transport — dual** | `UDSTransport` (Network.framework `NWConnection .unix`, macOS+Linux); `BareKitIPCTransport` (in-process worklet via `holepunchto/bare-kit-swift`, iOS+macOS apps) — both implement the same `Transport` protocol so M2/M3 code paths are platform-agnostic | UDS shipped in M1 (YK-184); BareKit lands in M2 (YK-206) |
| 5 | **Bare worker** | The QVAC SDK running on Bare runtime. External process (spawned by your app) when paired with UDS; embedded worklet (bundled SPM resource) when paired with BareKit | M1: PING fixture for IPC tests; M2: real worker (YK-208) bundled as resource (YK-207) |
| 6 | **QVAC native addons** | LLM (llama.cpp), Diffusion (Stable Diffusion), Whisper + TTS, OCR + Bergamot translation, RAG embeddings | Upstream — we don't touch these |

## Re-generating exports

```bash
npx -p @mermaid-js/mermaid-cli@10.9.1 mmdc \
  -i docs/diagrams/architecture.mmd \
  -o docs/diagrams/architecture.svg \
  -b transparent

npx -p @mermaid-js/mermaid-cli@10.9.1 mmdc \
  -i docs/diagrams/architecture.mmd \
  -o docs/diagrams/architecture.png \
  -b white -w 1600
```

Pin `@mermaid-js/mermaid-cli@10.9.1` so SVG byte-output is reproducible
across hosts (matches the codegen idempotency stance from YK-182).
