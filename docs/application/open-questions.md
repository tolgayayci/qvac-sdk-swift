# Open questions for Tether

Prioritized list of questions for the QVAC team, organized by what blocks
which milestone. Each entry follows the same shape:

- **Context** — the constraint or surprise that produced the question
- **Question** — the specific decision we need from you
- **Our proposed answer** — what we've assumed in the meantime (so the
  reply can be yes / no / edit, not "what do you mean?")

Several questions from the original research list are already answered by
M1's implementation work — they appear in §0 (Resolved) with the source of
truth, so this list stays focused on what's still open.

---

## 0. Resolved during M1 (FYI, no answer needed)

| # | Question | Status |
| --- | --- | --- |
| 0.1 | Wire payload encoding (JSON vs `bare-structured-clone`) | **JSON.** Verified by reading every handler in `packages/sdk/server/rpc/handler-registry.ts` and every schema in `packages/sdk/schemas/*.ts`. Documented in `docs/qvac-sdk-internals.md` §8. |
| 0.2 | How to access `SDK_CLIENT_ERROR_CODES` / `SDK_SERVER_ERROR_CODES` | Exported from `@qvac/sdk` npm package directly — `import { SDK_CLIENT_ERROR_CODES, SDK_SERVER_ERROR_CODES } from "@qvac/sdk"`. Used live by `scripts/codegen/src/emit/errors.ts`. |
| 0.3 | Whether request dispatch is by numeric command ID | **No** — dispatch is by the JSON envelope's string `request.type` field. The numeric `command` slot on the bare-rpc layer is a per-call counter that the worker ignores for routing. Documented in `docs/qvac-sdk-internals.md` §6. |
| 0.4 | License | **Apache-2.0**, matching QVAC and Holepunch upstream. `LICENSE` + `NOTICE` at repo root. |

---

## 1. Blocks public release (need before we push the repo)

### 1.1 Repository location

**Context.** Two viable homes for this client:

- **Inside the monorepo** — `tetherto/qvac/packages/sdk-swift/`. The bounty PDF
  language ("inside the @qvac/sdk monorepo … excluded from the npm package")
  reads as if this is the intent.
- **Sibling repo** — `tetherto/qvac-sdk-swift`. Better for Swift Package Index
  discoverability (SPI indexes top-level repos), simpler tagging story
  (`v0.1.0` instead of `swift-v0.1.0`), and shorter SPM URL.

**Question.** Which do you prefer? If sibling, will you create the empty repo
under `tetherto/`, or should we publish under `yk-labs/qvac-sdk-swift` first
and transfer ownership on acceptance?

**Our proposed answer.** Sibling `tetherto/qvac-sdk-swift` because the SPI
listing is a M3 deliverable and a single-package repo is the cleanest path
there. We can publish under our org and transfer if that's easier on your side.

### 1.2 GitHub organization and access

**Context.** We're holding all public artifacts (tag, release, review PR)
until the application is accepted, so we know which org to push to. Once we
know, we can cut `v0.1.0-m1` in seconds — the tag command is in
`docs/m1-summary.md`.

**Question.** What org should the repo live in, and what GitHub username(s)
need write access from your side for reviewing the M1 PR?

**Our proposed answer.** `tetherto/`; the existing QVAC SDK maintainer
group as reviewers.

### 1.3 iOS transport reality

**Context.** The bounty PDF mentions "Unix domain sockets on macOS/Linux,"
but iOS app sandbox prohibits spawning arbitrary subprocesses or connecting
to UDS endpoints outside the app container. Our M1 ship has only the macOS
UDS path; we've designed the M2 transport layer (YK-206) around
`holepunchto/bare-kit-swift` — an in-process Bare worklet — which is the
only viable path on iOS.

**Question.** Confirm the dual-transport architecture is acceptable:
`UDSTransport` for macOS / CLI / server contexts, `BareKitIPCTransport`
(via bare-kit) for iOS apps and macOS apps that want in-process inference?

**Our proposed answer.** Yes, dual transport, single public `Transport`
protocol so callers pick at construction time. M2/YK-206 documents the
BareKit integration and the M3 example app exercises both. The
architecture diagram in the application Notion doc spells this out.

---

## 2. Blocks M2 work (need before we start `completion` and streaming)

### 2.1 Public test worker fixture

**Context.** For M1 we built a minimal Bare worker fixture (PING + ECHO
over `bare-pipe` UDS) and tested against it. M2 needs a real QVAC worker
to exercise `completion`/`embed`/`transcribe` etc. We can build one from
`@qvac/sdk` ourselves (YK-208), but if you maintain one we'd rather track
yours so we stay in sync as the SDK evolves.

**Question.** Do you have a public reference Bare-worker entrypoint we
should target for E2E tests, or should we build our own from `@qvac/sdk`?

**Our proposed answer.** We build our own in YK-208, mirroring the patterns
we observed in `packages/sdk/server/`. Happy to switch to yours if available.

### 2.2 `bare-net.listen(path)` behaviour on macOS

**Context.** While building the M1 fixture (YK-191) we hit this:
`require('bare-net').listen(socketPath, listener)` silently no-ops on
macOS in `bare-runtime@1.28.5` — the `listening` callback never fires
and no socket file is created. We worked around it by using `bare-pipe`
directly (the layer underneath bare-net). Documented in
`Tests/Fixtures/ping-server/server.mjs`.

**Question.** Is `bare-net` over UDS supposed to work on macOS, or is
`bare-pipe` the intended API for UDS-flavored peers? If the former,
we'd value a confirmation so we can file a bug upstream against `bare-net`.

**Our proposed answer.** `bare-pipe` is the intended API for UDS server
peers; `bare-net` is TCP-focused even when given a path argument.

### 2.3 bare-rpc transport-failure surfacing

**Context.** `bare-rpc-swift` has no public method to fail in-flight
continuations when the underlying transport dies (e.g. the worker crashes
mid-request). In M1 we workaround this by injecting a deliberately-malformed
length prefix (`Data([0xFF, 0xFF, 0xFF, 0xFF])`) into `rpc.receive(_:)`
from `RPCBridge` when the read loop exits, which triggers BareRPC's
internal `RPC.fail(.frameTooLarge)` and resumes every pending
continuation with that error.

This is documented in `Sources/QVACClient/RPC/RPCBridge.swift:70-83`.
It works (covered by `PingIntegrationTests`' server-kill-mid-flight test)
but is a workaround, not a clean API.

**Question.** Is this the intended pattern? Or is there a planned
`RPC.failTransport(_:)`-style API on `bare-rpc` / `bare-rpc-swift` we
should switch to once it lands?

**Our proposed answer.** We keep the force-fail injection until upstream
exposes a public hook; happy to upstream a `RPC.fail(_:)` PR to
`bare-rpc-swift` if you'd accept it.

### 2.4 `__init_config` handshake — required or optional?

**Context.** `docs/qvac-sdk-internals.md` documents `__init_config` as
the first request sent over a new connection (command id 1 on the
bare-rpc layer, JSON envelope). The schema is in
`packages/sdk/schemas/__init_config.ts`. The M1 ping fixture doesn't
require it; M2's first real-SDK call (YK-198) will.

**Question.** Is `__init_config` mandatory on every new transport, or
does the worker default-init if it sees a non-init request first? Does
sending an `__init_config` mid-connection re-init, or error?

**Our proposed answer.** Mandatory on first connect; subsequent
`__init_config` errors. We'll implement that and adjust per your reply.

### 2.5 Streaming chunk shapes

**Context.** YK-180 mapped 31 wire commands to 9 stream modes and
2 duplex modes (`docs/qvac-sdk-internals.md` §6). For some — e.g.
`completionStream`, `transcribeStream` — we've inferred chunk shapes
from JS source but not against a live worker.

**Question.** Is there a per-method chunk-shape reference we can cite,
or should we treat the JS source as source-of-truth and report any
mismatch we hit during M2 integration testing?

**Our proposed answer.** JS source is source-of-truth; we report
deltas as issues + fixes when M2 integration tests catch them.

---

## 3. Refines M3 (nice to have, can wait)

### 3.1 Single-model concurrency

**Question.** Can a single Bare worker handle two concurrent
`completion` calls against the same loaded model, or is model access
serialized internally?

**Our proposed answer.** Serialized at the model level; concurrent
calls to different models are fine. The Swift `QVACClient` actor's
serialization-by-default will match.

### 3.2 Cancellation semantics

**Question.** When a Swift caller cancels a `completion` stream
mid-flight, does sending `{ "type": "cancel", "id": <runId> }` reliably
stop the worker mid-token, or only at chunk boundaries? Is there a
maximum cleanup latency we should advertise?

**Our proposed answer.** Token-boundary cancellation; cleanup latency
bounded by one model inference step (~50-200ms on Apple Silicon). We'll
expose this as a caveat in the M3 DocC tutorial.

### 3.3 Backpressure behaviour + `IncomingStream.cork()` upstream

**Context.** `bare-rpc-swift` ships `cork() / uncork()` only on
`OutgoingStream` (producer side). The consumer side (`IncomingStream`)
has no symmetric pair, so a client SDK can't send PAUSE/RESUME flags
back to the producer when its consumer is slow. The bare-rpc wire
protocol supports both directions (PR #13 work) but the Swift surface
doesn't.

YK-199 (M2-BACKPRESSURE) ships consumer-side bounded buffering via
`AsyncStream.bufferingPolicy = .bufferingNewest(N)` as a partial
mitigation — drops oldest chunks under flood, doesn't slow the
producer. See `docs/backpressure.md`.

**Questions.**
- Does the QVAC Bare worker honor the PAUSE flag today (i.e. stop
  generating when paused), or does it buffer-and-drop?
- Are you open to a `IncomingStream.cork() / uncork()` PR against
  `bare-rpc-swift`? The fix is small; we'd ship the flow-controller
  actor on top.

**Our proposed answer.** Worker honors PAUSE by gating its
`request.send()` loop (matches the JS client's behavior); upstream
PR is welcome and we'll send it.

---

## 4. Process

### 4.1 Submission and review flow

**Question.** Once a milestone is ready, do you prefer
(a) a PR against `tetherto/qvac-sdk-swift` titled "Mn ready for review"
with the milestone summary in the PR body, or
(b) a separate channel (Discord, email, Slack) for milestone notifications?

**Our proposed answer.** (a) PR for everything reviewable in-repo;
brief Discord/email ping when the PR opens so it doesn't sit
unobserved.

### 4.2 Communication cadence

**Question.** Are weekly Friday progress updates posted as a GitHub
issue (`weekly-update-w<N>.md`) acceptable, or do you have a preferred
form?

**Our proposed answer.** Yes, weekly GitHub issue. We can also CC a
Discord channel if you have one for grant recipients.

---

## Self-audit (VTs from the issue body)

- **VT-1 — Clarity check.** Each question has a single concrete asker
  ("we need X") with context that names files / line numbers where
  applicable. A reviewer can answer without reading the SDK source first.
- **VT-2 — Self-sufficiency.** Every open question has a proposed
  answer; replies can be yes / no / edit.
- **VT-3 — Priority correctness.** §0 lists what's already resolved
  (so §1 onwards is genuinely outstanding). §1 = "blocks public
  release"; the M1 code itself is shipped locally and only needs §1.1
  + §1.2 answered to push. §2 is what we need before getting deep into
  M2. §3 can wait until M3 implementation starts.
- **VT-4 — No duplicates with bounty PDF.** Repository location, license,
  dual-transport were left ambiguous by the PDF; everything else here is
  finer-grained than the PDF addresses.
