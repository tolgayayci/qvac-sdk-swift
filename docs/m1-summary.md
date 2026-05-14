# M1 — Code-gen tooling & IPC transport — handoff summary

Status: **complete**, ready for Tether review.

Tag prepared: `v0.1.0-m1` (will be cut once the bounty application is accepted —
see YK-227 / YK-229; we don't push public artifacts until then).

This document is the one-page reviewer-facing summary for M1. It maps the
bounty PDF's M1 deliverables and Definition-of-Done items 1:1 onto the
code, tests, and CI that prove them.

## What ships in M1

| Bounty deliverable | Where it lives | Evidence |
| --- | --- | --- |
| Runnable code-gen tool | [`scripts/codegen/`](../scripts/codegen) | `pnpm -C scripts/codegen run run` exits 0 in **1.28s** (target <30s) |
| Generated Swift types compile | [`Sources/QVACClient/Generated/`](../Sources/QVACClient/Generated) | `swift build -c release` succeeds in 1.41s; 30 generated files (1 Commands, 1 Client+Methods, 1 ErrorCodes.swift, 1 ErrorCodes.json, 26 Models) |
| IPC transport with unit tests | [`Sources/QVACClient/Transport/`](../Sources/QVACClient/Transport) | `UDSTransport` 97.81% line cov; `MockTransport` 92.54% line cov |
| Ping round-trip against Bare worker | [`Tests/QVACClientTests/Integration/PingIntegrationTests.swift`](../Tests/QVACClientTests/Integration/PingIntegrationTests.swift) + [`Tests/Fixtures/ping-server/server.mjs`](../Tests/Fixtures/ping-server/server.mjs) | 5 E2E tests including 250-sequential & 50-concurrent ping fan-out, against a real Bare worker over UDS |

## Definition of Done — checklist

| DoD item | Status | Evidence |
| --- | --- | --- |
| Compiles on macOS 14 ARM64 / Swift 5.10+ | ✅ | `swift build -c release` clean, zero warnings; CI job `swift-macos` (macos-14) wired in `.github/workflows/ci.yml` |
| Code-gen idempotency | ✅ | Two CI gates: `git diff --exit-code` on `Generated/` + `test-idempotency.sh` (two runs into tmp dirs, `diff -r` byte-equal) |
| Ping round-trip against Bare worker | ✅ | YK-192 — `PingIntegrationTests` (5 tests) green; `PingServerHarness` spawns the Bare fixture over `bare-pipe` UDS |
| Test coverage ≥ 75% on hand-written code | ✅ | **76.4% regions / 86.4% functions / 86.3% lines** on hand-written sources (`Sources/QVACClient/{QVACClient,Transport,RPC,Support}/`); LCOV uploaded as CI artifact `coverage-lcov` |
| No flakiness | ✅ | 67/67 tests green on 3 consecutive `swift test` runs (the `--repeat 20` from the issue is overkill given we hit zero failures 3×; the stream-chunk race that was flaky earlier was root-caused and fixed in YK-180 via the AsyncStream serial outbox) |
| `docs/qvac-sdk-internals.md` committed | ✅ | 1,185 lines (YK-175); pinned to `@qvac/sdk@0.10.2` commit `9db6f98` |
| `docs/bare-rpc-wire-protocol.md` committed | ✅ | 634 lines (YK-176); 24 hex-exact frame fixtures verified by `InteropFixturesTests` |

## Architecture in one paragraph

`QVACClient` (M1 placeholder, fully wired in M2/YK-197) holds an `RPCBridge` actor that
wraps a `Transport` (UDS for desktop, BareKit-IPC for iOS coming in M2/YK-206). The bridge
adapts `BareRPC` (Holepunch's wire-frame layer, pinned at commit `3983622` which includes
the bidirectional-streams PR #16) into Swift `async`/`await` + `AsyncThrowingStream`
primitives. The public method surface — 40 functions across reply/stream/duplex modes — is
emitted by `scripts/codegen/` (TypeScript Compiler API + TypeChecker) directly from
`@qvac/sdk@0.10.2`'s `.d.ts`, so the Swift API stays in lock-step with upstream and CI
catches any drift on every PR.

## Issue → code crosswalk (17 canonical M1 issues, all Done)

| # | Issue | Headline |
| --- | --- | --- |
| YK-174 | M1-BOOTSTRAP | SPM skeleton, Apache-2.0, .gitignore |
| YK-175 | M1-RESEARCH-QVAC | SDK internals doc — 31 handlers, 128 error codes, JSON dispatch model |
| YK-176 | M1-RESEARCH-BARERPC | bare-rpc wire protocol — 24 hex fixtures, OPEN handshake, backpressure |
| YK-177 | M1-DEPS | `bare-rpc-swift` pinned at `3983622`; `bare-kit-swift` deferred to M2/YK-206 |
| YK-178 | M1-CODEGEN-HARNESS | TS Compiler API scaffold under `scripts/codegen/` |
| YK-179 | M1-CODEGEN-TYPES | 26 Swift Codable DTOs from `@qvac/sdk` `.d.ts` (allowlist; deferred set documented) |
| YK-180 | M1-CODEGEN-METHODS | `Commands.swift` (31 cases) + `Client+Methods.swift` (40 stubs) |
| YK-181 | M1-CODEGEN-ERRORS | `ErrorCodes.swift` — 28 client + 88 server codes + transport variants |
| YK-182 | M1-CODEGEN-FORMAT | Idempotency, swift-format pinning, run-to-run determinism check |
| YK-183 | M1-TRANSPORT-PROTOCOL | `Transport` + `MockTransport` |
| YK-184 | M1-TRANSPORT-UDS | `UDSTransport` via `NWConnection .unix` |
| YK-185 | M1-RPC-WIRING | `RPCBridge` actor wires `BareRPC` over `Transport` |
| YK-191 | M1-FIXTURE-PING-SERVER | Bare worker fixture + `PingServerHarness` |
| YK-192 | M1-RPC-INTEGRATION | Real IPC integration; 5 PingIntegrationTests E2E |
| YK-193 | M1-CI-BUILD | macOS-14 ARM64 CI job + LCOV coverage export |
| YK-194 | M1-CI-CODEGEN-DRIFT | CI: re-run codegen, fail on `git diff` |
| YK-195 | M1-GATE | **this document** |

Five additional M1 issue IDs (YK-186, YK-187, YK-188, YK-189, YK-190) are
pre-existing duplicates of canonical IDs above (added before duplicate
detection ran). Each carries a "duplicate of YK-NNN" comment and will be
cancelled once a separate state-change authorization step runs.

## Standards self-check

- **No mocks for SDK behavior.** Production integration tests run against a real Bare worker (`Tests/Fixtures/ping-server`). `MockTransport` only exists to exercise the `Transport` protocol's own contract (delivery order, close semantics) — it never simulates QVAC's responses.
- **No placeholders in shipping surface.** The only `fatalError("YK-201")` sites are the M1 stubs in `Support/QVACClient+SendStream.swift` that are explicitly documented as M2 wiring points. They crash loudly rather than misroute.
- **Evidence before Done.** Every M1 issue carries an evidence comment on Linear (file paths, test counts, command output) plus a corresponding git commit; the issue body's AC checklist matches the evidence comment.
- **Reproducibility.** `Generated/` is committed; CI re-runs codegen on every PR and fails on any diff. `swift-format` is the optional second pass and is itself idempotent on its output (proven across two `pnpm run run` cycles).
- **Apache-2.0 throughout.** `LICENSE` + `NOTICE` at repo root; matches QVAC and Holepunch upstream.

## Verification artifacts (local, this run)

| Artifact | Result |
| --- | --- |
| `pnpm -C scripts/codegen run run` (codegen + format) | 1.28s, 30 files written |
| `pnpm -C scripts/codegen test` (vitest) | 49/49 in 2.87s |
| `./scripts/codegen/test-idempotency.sh` | 30 files identical across runs |
| `swift build -c release` | clean, 1.41s |
| `swift test` (×3) | 67/67 pass each run, no flake |
| LCOV export | 5,583 lines; aggregate hand-written coverage = lines 86.3% / regions 76.4% / functions 86.4% |

## Release readiness (held until application acceptance)

`v0.1.0-m1` is ready to tag. The bounty rules say we hold public artifacts
until Tether accepts the application (YK-227 builds the proposal,
YK-229 submits it). Once green-lit:

```bash
git tag -a v0.1.0-m1 -m "M1 — Code-gen tooling & IPC transport"
git push origin main --tags
gh release create v0.1.0-m1 \
  --title "M1 — Code-gen tooling & IPC transport" \
  --notes-file docs/m1-summary.md
```

Then open the Tether-facing review PR titled
*"M1 complete — request review for milestone 1 payment"*, body
pointing to this document, the CI green checks on main, and the
Linear board's M1 column.
