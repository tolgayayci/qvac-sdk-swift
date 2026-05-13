# Dependency Pinning Policy

`QVACClient` deliberately pins every external SPM and npm dependency to a
specific revision so codegen output and integration-test behavior are
reproducible across machines, across CI runs, and across milestone gates.

## Current pins (M1)

| Dependency | Pin | Why |
| --- | --- | --- |
| `bare-rpc-swift` (SPM, GitHub) | `revision: "3983622"` (main HEAD as of YK-176) | Frame layer for the IPC duplex. This commit is `feat: bidirectional streams (#16)` and includes the backpressure / cork-uncork work from PR #13 (merged at `8405c6f`). No tagged releases exist yet — re-evaluate on next upstream tag. |
| `bare-kit-swift` (SPM, GitHub) | `revision: "ef26bbd"` (main HEAD) | Resolved + pinned in `Package.resolved` for stability. NOT linked from the `QVACClient` target in M1 — it requires a separate native `BareKit` framework (built from `holepunchto/bare-kit`) that is not delivered via SPM. The dep is promoted to a real link in **YK-206** (`M2-TRANSPORT-BAREKIT — BareKitIPCTransport`). |
| `@qvac/sdk` (npm, codegen only) | `0.10.2` (exact) | Pinned in `scripts/codegen/package.json`. Drives every generated Swift file under `Sources/QVACClient/Generated/`. Bumping is a coordinated process: re-run codegen, refresh `docs/qvac-sdk-internals.md` (YK-175), re-verify all M1 VTs. |
| `typescript` (npm, codegen only) | `5.9.3` (exact) | Matches the version upstream `tetherto/qvac` uses to build `@qvac/sdk`; avoids inferring different types from the same source. |
| `tsx` (npm, codegen only) | `4.21.0` (exact) | TypeScript-aware Node CLI runner for the codegen harness. |
| `vitest` (npm, codegen only) | `1.6.1` (exact) | Test runner for the codegen harness. |
| `@types/node` (npm, codegen only) | `22.10.6` (exact) | Type stubs aligned to Node 22 LTS used in CI. |

The exact list of recursive dependencies (with their sub-pins) lives in:
- `Package.resolved` — Swift / SPM side
- `scripts/codegen/pnpm-lock.yaml` — Node / pnpm side

Both files are committed and treated as primary review artifacts: a PR that
modifies them without a matching CHANGELOG / migration note will be flagged.

## Resolved dependency tree

Snapshot from `swift package show-dependencies` at M1:

```
QVACClient
├── BareRPC      (holepunchto/bare-rpc-swift @ 3983622)
│   └── CompactEncoding   (holepunchto/compact-encoding-swift @ main)
└── BareKit      (holepunchto/bare-kit-swift @ ef26bbd)   [resolved, not linked]
```

## Version-bump policy

| Trigger | Required follow-up |
| --- | --- |
| Upstream `@qvac/sdk` minor bump | Re-run codegen (`pnpm run run` in `scripts/codegen/`). Re-verify `docs/qvac-sdk-internals.md` byte counts. Run full Swift test suite. Update CHANGELOG. |
| Upstream `bare-rpc-swift` change | Re-run `swift test` against the new revision. Re-verify the byte-exact hex fixtures in `docs/bare-rpc-wire-protocol.md` §9 — any frame layout change must be caught here. |
| Upstream `bare-kit-swift` change | (M2+) Re-run YK-206 integration tests on iOS Simulator + macOS. |
| Major version bump on **any** dep | RFC required: open an issue, update this doc, and run a milestone-gate verification (YK-195 / YK-211 / YK-224) before merging. |

## Why we don't use `from: "x.y.z"` ranges

Two reasons:

1. **Pre-1.0 upstreams**. `bare-rpc-swift` and `bare-kit-swift` are both
   pre-tag projects. SPM's `from:` requires a semver tag; without one, only
   `revision:` and `branch:` work.
2. **Codegen drift sensitivity**. The CI codegen-drift check (YK-194) fails
   on any non-empty `git diff` after re-running codegen. Floating ranges
   would produce non-deterministic generated output, breaking CI for
   unrelated reasons.

When a dep cuts a stable tag, we revisit and consider switching to
`from: "x.y.z"` only if its semver contract is enforceable.

## Network requirements at build time

- `swift package resolve` fetches both SPM packages from GitHub. Air-gapped
  CI must mirror `holepunchto/bare-rpc-swift` and `holepunchto/bare-kit-swift`.
- `pnpm install` (in `scripts/codegen/`) fetches from the npm registry. Same
  mirroring constraint applies.
- `bare-kit-swift` does NOT download a binary framework via SPM. Wiring up
  the native `BareKit` framework happens at YK-206 and will document its
  own provisioning steps then.
