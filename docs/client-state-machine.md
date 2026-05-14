# `QVACClient` lifecycle state machine

Five lifecycle states, transitioned only inside the `QVACClient` actor.

```
                ┌────────────────┐
                │  disconnected  │  (init state)
                └────────┬───────┘
                connect()│
                         ▼
                ┌────────────────┐  start fails
                │   connecting   │ ─────────────►  back to .disconnected
                └────────┬───────┘   (caller retries)
                start ok │
                         ▼
                ┌────────────────┐
                │    connected   │  (send / streamResponse allowed)
                └────────┬───────┘
                  close()│
                         ▼
                ┌────────────────┐
                │    closing     │  (transient — bridge.close in flight)
                └────────┬───────┘
                         ▼
                ┌────────────────┐
                │     closed     │  (single-use; reconnect requires
                └────────────────┘   building a new QVACClient instance)
```

## Allowed transitions per public call

| Current state | `connect()` | `close()` | `send` / `streamResponse` |
| --- | --- | --- | --- |
| `disconnected` | → `connecting` → `connected` (or back on fail) | → `closed` (no I/O) | throws `transport(.framingError)` |
| `connecting` | throws `transport(.framingError)` (caller race) | → `closing` (in-flight connect will observe on completion) | throws (bridge not ready) |
| `connected` | no-op (returns) | → `closing` → `closed` | normal path |
| `closing` | throws `transport(.transportClosed)` | no-op (returns) | throws `transport(.transportClosed)` |
| `closed` | throws `transport(.transportClosed)` | no-op (returns) | throws `transport(.transportClosed)` |

## Why single-use

Reconnecting after `close()` would require:

- Re-running `__init_config` (YK-198 territory) — which means saved init
  config has to be replayed
- Re-establishing the worker handshake (which may carry one-shot tokens)
- Rebuilding the `RPCBridge` (cheap, but easy to forget — better to make
  the user build a new client instance)

The simpler model — single-use client, build a new one for each
connection — eliminates a class of "stale state survives reconnect" bugs
without losing functionality. M2/M3 method work doesn't rely on
reconnect.

## In-flight requests at the moment `close()` is called

Bare-rpc-swift currently has no public hook to fail pending continuations,
and `Task.cancel()` on a hanging `rpc.request` does not propagate. This
is flagged as open question §2.3 in `docs/application/open-questions.md`
and tracked for YK-200 (M2-CANCEL). The supported in-M1 path — letting
the transport die first so the read loop's force-fail injection wakes
pending continuations — is covered by
`PingIntegrationTests.testKillingServerMidFlightFailsFast`.

## Tests

`Tests/QVACClientTests/Client/QVACClientTest.swift` covers 7 of the 8
issue-body VTs against `LoopbackTransport` + an in-process `QVACPeer`
that speaks the same JSON envelope the real worker does:

| VT | What it asserts |
| --- | --- |
| 1 | `connect()` → `heartbeat()` → `close()` round-trip; state machine transitions visible via `client.state` |
| 2 | 100 concurrent `heartbeat()` requests complete cleanly |
| 3 | `streamResponse` delivers all expected chunks |
| 4 | `close()` × 2 is idempotent — second call no-ops |
| 5 | `connect()` after `close()` throws `.transport(.transportClosed)` |
| 6 | **deferred** — needs upstream `BareRPC.RPC.fail(_:)` API |
| 7 | Send before `connect()` throws `.transport(.framingError)` |
| 8 | Cross-actor `async let` doesn't deadlock |

VT-6 (in-flight settle on close) waits on the bare-rpc upstream work;
real-worker coverage of the same property lives in
`PingIntegrationTests`.
