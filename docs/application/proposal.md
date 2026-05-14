# QVAC SDK — Native Swift Client

**Bounty proposal — Tether Grants #2885283454**
Drafted 2026-05-14 · Deadline 2026-06-24 · Total: 3,000 USDt across 3 milestones

> **Native Swift client for Tether's QVAC SDK — bringing local AI to iOS and macOS apps without a JS bridge.**

This document is the bounty proposal artifact requested by the application
form's "website" field. It's structured as a 12-section reviewer-facing
brief: who, why, how, when, and what's already done. Read time: **~12 minutes**.

Paste this file into a Notion page; Notion's markdown import preserves the
structure. The corresponding source-of-truth markdown lives at
`docs/application/proposal.md` in the (currently private) implementation
repo — the proposal page on Notion is the public mirror, kept in sync at
submission time.

---

## 1. Hero

> A native Swift package — `import QVACClient` — that gives iOS and
> macOS apps first-class access to QVAC's on-device AI (completion,
> embeddings, transcription, translation, TTS, OCR, diffusion, RAG,
> plugins) through a code-generated, idiomatically async/await + actor
> public surface. Dual-transport from day one: Unix domain sockets for
> macOS/Linux contexts, in-process Bare worklet for iOS apps. Apache-2.0,
> Swift Package Manager native, Swift Package Index listed.

**Clone-to-first-token target: under 10 minutes on a fresh macOS 14
machine** (`git clone` → `swift build` → `swift test` runs the ping
fixture against a real Bare worker).

---

## 2. Why this bounty (and why us)

The QVAC mission — "stable intelligence" running locally, on open
infrastructure, user-owned — only matters if it reaches developers
where they are. Swift is the largest native developer ecosystem after
Android. Right now there's no first-class path for an iOS or macOS app
to use the QVAC SDK without going through React Native, a JS bridge,
or hand-rolling a UDS client. Closing that gap unlocks a meaningful
new surface for Tether's local AI vision.

The author is a full-stack web3 developer comfortable across TypeScript
production systems, Swift concurrency (actors + `AsyncThrowingStream`),
JS runtime work, and the Bare/Pear ecosystem. The lead-up to this
application was spent reading the QVAC SDK source end-to-end, the
Holepunch ecosystem's `bare-rpc-swift` + `bare-kit-swift` packages, and
the bare-rpc wire protocol byte-by-byte — and then building M1
end-to-end against a real Bare worker fixture so the proposal isn't
speculation. (See §3, §7, and §12.)

---

## 3. Bounty understanding

The bounty PDF asks for a Swift Package Manager library, code-generated
from `@qvac/sdk`'s type declarations, that wires Swift `async`/`await`
to the QVAC Bare worker over an IPC transport, faithfully exposing every
public SDK method as an idiomatic Swift surface. Acceptance criteria:
the code-gen is idempotent (CI fails on `git diff` after re-run), the
client compiles on macOS 14 ARM64 with Swift 5.10+, IPC transport has
unit tests, ping round-trip works against a real Bare worker.

What we're delivering goes one step further on iOS specifically: the
bounty PDF describes "Unix domain sockets on macOS/Linux" but the
iOS sandbox prohibits arbitrary subprocesses and external UDS endpoints.
The plan treats this as a design constraint — `Transport` is a protocol
with two concrete implementations: `UDSTransport` (macOS / desktop /
Linux servers) and `BareKitIPCTransport` (in-process Bare worklet via
`holepunchto/bare-kit-swift`, for iOS apps and macOS apps that want
embedded inference). Same public API both sides; the M3 example app
exercises both. See §4.

---

## 4. Architecture

![QVACClient architecture — 6 layers from your app down to QVAC native addons](https://raw.githubusercontent.com/<org>/<repo>/main/docs/diagrams/architecture.svg)

> When pasting into Notion, upload `docs/diagrams/architecture.png`
> directly — Notion handles binary embeds better than the raw GitHub
> URL until the repo is public.

Six layers, top to bottom:

| # | Layer | What lives here |
| --- | --- | --- |
| 1 | **Your app** | CLI / daemon / SwiftUI app. Just `import QVACClient`. |
| 2 | **QVACClient public surface** | Actor with 40 async methods (one per `@qvac/sdk` public function), 26 generated `Codable` DTOs, `QVACError` mapping 116 wire codes (28 client + 88 server + transport variants). |
| 3 | **Framing** | `RPCBridge` actor adapts [`bare-rpc-swift`](https://github.com/holepunchto/bare-rpc-swift) (length-prefixed binary frames, OPEN/DATA/END/PAUSE stream flags, cork/uncork backpressure) into Swift `async`/`await` + `AsyncThrowingStream`. |
| 4 | **Transport (dual)** | `UDSTransport` via `Network.framework` `NWConnection .unix` for macOS/Linux/server contexts; `BareKitIPCTransport` via `holepunchto/bare-kit-swift` for iOS+macOS app contexts. Both implement the same `Transport: Sendable` protocol. |
| 5 | **Bare worker** | `@qvac/sdk` running on the Bare runtime. External process (paired with UDS) or embedded worklet (paired with BareKit, bundled as SPM resource). Dispatches by string `request.type` over JSON envelopes — confirmed by reading the handler-registry source. |
| 6 | **QVAC native addons** | LLM (llama.cpp), Diffusion, Whisper + TTS, OCR + Bergamot translate, RAG. Upstream — we don't touch these. |

**Why this matters.** The transport boundary is the only platform-
specific code path in the entire client. Every other layer (codegen
output, `RPCBridge`, `QVACClient` actor, generated DTOs, error mapping)
is shared between macOS, iOS, Linux, and any future platform Swift
ships on.

---

## 5. De-risk

This bounty is closer to "wire two well-maintained Swift libraries to a
generated, typed QVAC client" than to "implement a wire protocol from
scratch." Key existing assets:

| Dependency | Status | What it gives us |
| --- | --- | --- |
| [`holepunchto/bare-rpc-swift`](https://github.com/holepunchto/bare-rpc-swift) | Active, main HEAD pinned at commit `3983622` | Frame layer + stream flags + bidirectional streams (PR #16 merged) + cork/uncork backpressure (PR #13). Saves writing a wire-protocol parser. |
| [`holepunchto/bare-kit-swift`](https://github.com/holepunchto/bare-kit-swift) | Active, intended pin `ef26bbd` | `BareKit.xcframework` wrapper exposing the Bare runtime + worklet APIs to Swift. Required for the iOS in-process transport. |
| [`holepunchto/compact-encoding-swift`](https://github.com/holepunchto/compact-encoding-swift) | Active | Transitive dep of bare-rpc-swift; binary varint encoding. |
| `@qvac/sdk@0.10.2` (npm) | Stable | The TypeScript source we generate from — exports the SDK error code tables directly, so codegen reads them with a single `import { SDK_*_ERROR_CODES }`. |

What we're building on top: a TypeScript-Compiler-API code-generation
pipeline that walks `@qvac/sdk` `.d.ts` and emits Swift `Codable` DTOs +
a `QVACCommand` enum + `Client+Methods.swift` extension stubs; an
`RPCBridge` actor that wraps bare-rpc-swift; a `UDSTransport` /
`BareKitIPCTransport` pair; a `QVACClient` actor; and the test fixtures
that prove each layer against a real Bare worker.

---

## 6. Approach

### Code generation — TypeScript Compiler API, not quicktype / Sourcery

We use the official TypeScript Compiler API + TypeChecker to walk
`@qvac/sdk`'s `.d.ts` and emit Swift. The alternatives:

- **quicktype** generates from JSON samples — wrong direction; we want
  types to drive samples, not vice-versa, and many SDK shapes are
  Zod-inferred unions that JSON samples can't capture losslessly.
- **Sourcery** works on Swift, not TypeScript — wrong language end.
- **Manual hand-rolled types** — the SDK has 31 handlers, 116 error
  codes, and 138 exported types; hand-rolling them means a drift
  problem every time `@qvac/sdk` bumps.

The TypeScript Compiler API + TypeChecker gives us full type-info
resolution, including `z.infer<>` Zod inference, discriminated unions,
union flattening, and intersection types. **Output is deterministic
and idempotent** — sorted by name everywhere, no env-derived content,
explicit `\n` line endings. CI's `codegen-drift` job re-runs the
generator and fails on any `git diff` against `Sources/QVACClient/Generated/`.

### Swift concurrency

- `QVACClient` is an actor — serializes calls by default, avoids
  data races at the public boundary.
- One-shot methods return `async throws -> Response`.
- Streaming methods return `AsyncThrowingStream<Chunk, Error>` —
  cancellation in the consumer ripples down to the Bare worker via
  the QVAC `cancel` command.
- `RPCBridge` is also an actor; it owns the `BareRPC.RPC` instance
  and serializes outbound writes via an `AsyncStream`-backed serial
  outbox (FIFO ordering across the actor → transport boundary —
  matters for stream END frames not racing ahead of DATA frames).

### Backpressure

`bare-rpc-swift` ships `PAUSE`/`RESUME` stream-flow flags. The consumer
side of every `AsyncThrowingStream` maps natural Swift back-pressure
(slow `for try await` body) to `BareRPC.OutgoingStream.cork()` /
`uncork()` so the worker stops generating tokens when downstream is
saturated. Mapped end-to-end in M2 (YK-199).

---

## 7. Milestone plan

| Milestone | Allocation | Window | Status |
| --- | --- | --- | --- |
| **M1** — Code-gen tooling & IPC transport | 800 USDt | week 1–2 | **shipped locally; ready to push on acceptance** |
| **M2** — Core API surface | 1000 USDt | week 3–4 | planned |
| **M3** — RAG, plugins, docs, distribution | 1200 USDt | week 5–6 | planned |

### M1 — already shipped locally

Held private until application acceptance, then pushed and tagged
`v0.1.0-m1`. See `docs/m1-summary.md` for the gate evidence and the
exact command sequence.

| What | Where | Numbers |
| --- | --- | --- |
| Code-gen pipeline | `scripts/codegen/` | TypeScript Compiler API, ~1.3s wall-clock; 30 generated files; 49/49 vitest pass; idempotency proven by `test-idempotency.sh` (two-runs-into-tmp-dirs `diff -r`) |
| Generated outputs | `Sources/QVACClient/Generated/` | `Commands.swift` (31 cases), `Client+Methods.swift` (40 method stubs), `ErrorCodes.swift` (28 + 88 + transport variants), `Models/` (26 `Codable` DTOs) |
| Transport | `Sources/QVACClient/Transport/` | `Transport: Sendable` protocol, `UDSTransport` via `NWConnection .unix` (97.81% line cov), `MockTransport` for testing the protocol contract (92.54% line cov) |
| RPC bridge | `Sources/QVACClient/RPC/RPCBridge.swift` | actor wrapping `BareRPC.RPC`; 79% region / 86% line cov |
| Integration | `Tests/QVACClientTests/Integration/PingIntegrationTests.swift` | 5 E2E tests against a real Bare worker fixture — PING / 250 sequential / 50 concurrent / bridge close / server-kill-mid-flight |
| CI | `.github/workflows/ci.yml` | 3 jobs: codegen-ts (Ubuntu, vitest + smoke), swift-macos (macOS-14 ARM64, build + test + LCOV coverage upload), codegen-drift (Ubuntu, two-gate diff check) |
| Docs | `docs/` | `qvac-sdk-internals.md` (1,185 lines — pinned `@qvac/sdk@0.10.2` commit `9db6f98`), `bare-rpc-wire-protocol.md` (634 lines — 24 hex-exact frame fixtures), `dependencies.md`, `codegen.md`, `codegen-deferred.md`, `m1-summary.md`, `application/{open-questions,form-answers,proposal}.md` |
| Aggregate test count | `swift test` | 67 / 67 pass, zero flake across 3 consecutive runs |
| Coverage on hand-written code | LCOV | lines **86.3%** / regions **76.4%** / functions **86.4%** (excludes generated output) |

### M2 — Core API surface

Planned 17 issues (YK-196 → YK-211). Headline:

- Wire `QVACClient` actor through to `RPCBridge` (YK-197); replace the M1 `fatalError("YK-201")` stubs in `Support/QVACClient+SendStream.swift` with real `send` / `streamResponse` delegations.
- `__init_config` handshake (YK-198) — first request on every new connection per `docs/qvac-sdk-internals.md` §5.
- Per-method work: `completion` streaming + blocking (YK-202), `transcribe`/`transcribeStream` (YK-203), `textToSpeech`/`Stream` (YK-204), `translate`/`ocr`/`diffusion`/`upscale` (YK-205).
- Cancellation: Swift `Task.cancel()` → worker `cancel` command → `CancellationError` surface (YK-200).
- Backpressure via cork/uncork (YK-199).
- iOS transport — `BareKitIPCTransport` via `bare-kit-swift` (YK-206), bundled worker as SPM resource (YK-207), iOS-17 simulator CI (YK-210).
- Real-worker E2E test suite (YK-208 fixture + YK-209 tests).
- M2 gate (YK-211).

### M3 — RAG, plugins, docs, distribution

Planned 13 issues (YK-212 → YK-224). Headline:

- RAG: `ragIngest`, `ragSearch`, `ragChunk` (YK-212); `ragSaveEmbeddings` + 5 admin ops (YK-213).
- Plugins: `invokePlugin` + `invokePluginStream` generic over `Encodable`/`Decodable` (YK-214).
- DocC: catalog with 95%+ symbol coverage (YK-215), 2 tutorials — Quickstart + Build a Streaming Chat (YK-216), GitHub Pages publishing (YK-217).
- SwiftUI streaming-chat example app — macOS + iOS targets, demonstrates cancellation (YK-218).
- README final polish with badges + quickstart + benchmark numbers (YK-219).
- Swift Package Index listing (YK-220).
- Benchmark suite proving <5% Swift-vs-JS overhead (YK-221).
- Final integration (YK-222), release v0.1.0 (YK-223), M3 gate + submission (YK-224).

---

## 8. Differentiators

What makes this proposal stand apart from a generic "wire two libraries
together" bid:

1. **Dual-transport from day one.** Most bounty respondents see "Unix
   domain sockets on macOS/Linux" in the PDF and ship a UDS-only
   client, then discover the iOS sandbox blocks them. The architecture
   here surfaces that constraint as a design choice, not a surprise.
2. **Code-gen reads the actual `@qvac/sdk` `.d.ts`** via TypeScript
   Compiler API + TypeChecker — not JSON samples (quicktype), not Swift
   stubs (Sourcery), not hand-rolled types. The drift problem becomes
   a CI failure, not a bug report.
3. **M1 is shipped, not promised.** Application is rate-limited by
   review velocity, not by my keyboard. The proposal links to a one-page
   M1 summary that maps every bounty DoD item to a commit and a test
   run.
4. **Real Bare worker integration in M1.** Not a mock-only ping —
   `PingIntegrationTests` spawns a Bare process over `bare-pipe` UDS
   and does 250 sequential + 50 concurrent round-trips, plus a
   server-kill-mid-flight test that exercises the transport-failure
   force-fail path documented in §9 below.
5. **Bug found and worked around upstream.** Discovered that
   `bare-net.listen(path)` silently no-ops on macOS in `bare-runtime@1.28.5`.
   Working fix using `bare-pipe` directly; the open-questions doc flags
   it for upstream resolution.
6. **`bare-rpc-swift` transport-failure injection.** The library has
   no public way to fail in-flight continuations when the transport
   dies; the workaround (injecting a deliberately-malformed
   `0xFFFFFFFF` length prefix into `rpc.receive`) is documented in the
   source and tested. Open question flagged for clean upstream API.
7. **Coverage above the self-imposed gate.** 86.3% line / 76.4% region
   on hand-written code. Generated output excluded from coverage to
   avoid inflating the number.
8. **Idempotent code-gen + two-gate CI.** Gate 1 = `git diff
   --exit-code` against committed `Generated/`. Gate 2 = `test-idempotency.sh`
   runs codegen twice into separate tmp dirs and asserts `diff -r`.
   Catches non-determinism even if drifted state was committed.
9. **Swift concurrency done right.** Actor-isolated public client,
   `AsyncThrowingStream` for streaming methods, AsyncStream-backed
   serial outbox for the actor → transport boundary (FIFO write order
   guarantees that fixed a stream-chunk race in M1).
10. **Pinned everything.** `bare-rpc-swift@3983622`, `@qvac/sdk@0.10.2`,
    `typescript@5.9.3`, `tsx@4.21.0`, `node@24`, `pnpm@10.30.2`,
    `swift-format` from Xcode 16, `mermaid-cli@10.9.1` for diagrams.
    Floating ranges are how reproducibility dies — `docs/dependencies.md`
    documents the policy.
11. **Apache-2.0 throughout** — matches QVAC + Holepunch upstream;
    no license-compat surprises.
12. **Swift Package Index in scope.** Not just "a library that compiles" —
    M3 includes the `.spi.yml`, badge in README, and the SPI submission
    PR. Discoverable by Swift devs from day one of v0.1.0.

---

## 9. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- | --- |
| R1 | **`@qvac/sdk` API drift mid-bounty** (a 0.11 release before delivery) | Medium | Medium | All pins are exact; bumping is a coordinated process documented in `docs/dependencies.md`. Codegen will catch any breaking change as a CI drift failure. |
| R2 | **`bare-kit-swift` integration takes longer than budgeted** (M2/YK-206) | Medium | High | UDS path is already shipped + tested in M1, so all M2 method work can land against UDS first; BareKit is the last M2 issue. Worst case: M2 lands UDS-complete + BareKit deferred to early M3. |
| R3 | **Bare-pipe edge cases on Linux** (M2 needs Linux CI for the codegen job, but UDS-on-Linux isn't M1-required) | Low | Low | Codegen job already runs on `ubuntu-latest`. UDS test job pinned to `macos-14` for M1; Linux UDS tests added in M2 only if needed. |
| R4 | **Bug in `bare-rpc-swift` we'd need fixed upstream** | Medium | Medium | Already happened once (transport-failure surfacing — §8/#6). Pattern: file an issue + ship a documented workaround in our code so we're not blocked on upstream merge cadence. |
| R5 | **SwiftUI example app (M3/YK-218) scope creep** | Medium | Low | Example app is bounded to "streaming chat + cancel button" — no agent loops, no plugin demo, no RAG demo (those live as separate test suites). Hard-cap at 1 view + 1 view-model + 1 message-row component. |

---

## 10. Open questions

12 prioritized questions live in `docs/application/open-questions.md`
(in the implementation repo). Headline by tier:

- **Blocks public release (3 questions)** — repo location
  (`tetherto/qvac-sdk-swift` vs `tetherto/qvac` subdir),
  GitHub org + reviewer access, iOS dual-transport confirmation.
- **Blocks M2 (5 questions)** — public worker fixture availability,
  `bare-net.listen` macOS bug, bare-rpc-swift transport-failure API,
  `__init_config` handshake semantics, streaming chunk shapes.
- **Refines M3 (3 questions)** — single-model concurrency, cancellation
  latency caveats, backpressure honor semantics.
- **Process (2 questions)** — milestone-PR vs separate channel for
  submission, weekly progress-update cadence.

Each question is paired with a proposed answer so a reply can be
yes/no/edit — fastest possible Tether-side overhead.

---

## 11. Commitments

| | |
| --- | --- |
| **License** | Apache-2.0 throughout. Matches QVAC + Holepunch upstream. |
| **Apache-2.0 NOTICE files** | Maintained for every transitive Apache-2.0 dep. |
| **Distribution** | Swift Package Manager native; M3 includes Swift Package Index `.spi.yml` + submission PR. |
| **Performance overhead vs JS reference** | Target <5% on round-trip latency for ping + `embed`; benchmark suite in M3 (YK-221) measures and reports it. |
| **Test discipline** | All milestones gated by a verification issue (YK-195 / YK-211 / YK-224) that walks every DoD item with linked evidence. |
| **Progress cadence** | Weekly Friday update (or the cadence you prefer — see open-questions §4.2). |
| **Communication** | GitHub issues + PRs for reviewable artifacts; Discord/email ping when something needs attention. |
| **Privacy / data handling** | No telemetry, no analytics, no network calls beyond the user's chosen transport. |
| **Demo video per milestone** | Loom or asciinema; embedded in each milestone-gate issue. |

---

## 12. Public progress

While the implementation repo stays private until application acceptance
(no leaked artifacts before Tether says "go"), the Linear project board
is read-only-shareable. Reviewers can watch issues move through
Backlog → In Progress → Done in real time and read evidence comments on
each issue.

Linear project: [QVAC SDK — Swift Client (Tether Bounty)](https://linear.app/yk-labs/project/qvac-sdk-swift-client-tether-bounty)
Public read-only view: `<TO BE ATTACHED at YK-229 submit>`

---

## Appendix — How this proposal was assembled

This document is the markdown source for the public Notion proposal.
The implementation repo has these companion artifacts that the proposal
references:

| Doc | What it covers |
| --- | --- |
| `docs/qvac-sdk-internals.md` | 1,185 lines. SDK wire model: 31 request types, 116 error codes, `__init_config` handshake, per-method shapes. Pinned to `@qvac/sdk@0.10.2` commit `9db6f98`. |
| `docs/bare-rpc-wire-protocol.md` | 634 lines. Byte-level frame layout, OPEN handshake, PAUSE/RESUME backpressure, end-of-stream vs destroy, 24 hex-exact fixtures verified by `InteropFixturesTests`. |
| `docs/dependencies.md` | Pin policy + dependency tree + swift-format/Node/pnpm version requirements. |
| `docs/codegen.md` | How to run the codegen pipeline; recovery steps when CI's drift check fires. |
| `docs/codegen-deferred.md` | The set of `@qvac/sdk` types currently routed through `AnyCodable`; drained by M2/M3 codegen passes. |
| `docs/m1-summary.md` | M1 reviewer-facing handoff: bounty deliverables × evidence × commit references. |
| `docs/diagrams/architecture.{mmd,svg,png}` | The diagram embedded in §4. Mermaid source + rendered exports. |
| `docs/application/open-questions.md` | The 12 questions referenced in §10. |
| `docs/application/form-answers.md` | The application form's prepared answers. |

All of these will be visible on the public repo from the first commit
post-acceptance.
