# Performance baseline (YK-221)

This document defines the reference machine, warm-up procedure,
and statistical methodology used by the Benchmarks/ suite. The
goal is reproducibility: a reviewer running the same bench on
the same hardware should get results within 10% of ours.

## Reference machine

| Component | Spec |
| --- | --- |
| Model | Apple MacBook Pro |
| Chip | Apple M2 Pro (10-core, 16-core GPU) |
| Memory | 16 GB unified |
| OS | macOS Sequoia 15+ |
| Swift | 5.10 (Xcode 16.0) |
| Node | 24.x |
| Bare runtime | bundled with @qvac/sdk 0.10.2 |

Different hardware (M1, M3, M4, Intel) will produce different
absolute numbers; the **percentage overhead** (Swift vs JS) is
the load-bearing metric, and that should remain comparable across
machines.

## Test models

| Bench | Model | Size | Source |
| --- | --- | --- | --- |
| `embed` | `bge-small-en-v1.5.Q4_K_M.gguf` | ~24 MB | CompendiumLabs (HuggingFace) |
| `completion` | `Llama-3.2-1B-Instruct-Q4_0.gguf` | ~700 MB | lmstudio-community (HuggingFace) |

`./scripts/download-test-models.sh` fetches BGE. The LLM is
manual — too large for an unconditional CI download. The
`Benchmarks/README.md` "Run" section has the curl command.

## Warm-up

Every bench burns 100 iterations / 1 batch before sampling. The
goal is to push past:
- Bare's V8/JIT warm-up (worker side).
- llama.cpp's KV cache initialization.
- Swift's lazy stdlib symbol resolution.

The warm-up samples are discarded, not averaged. Without them,
the first sample's TTFT runs ~5x the steady-state value and
poisons the percentiles.

## Sample sizes

| Bench | Default iterations | Notes |
| --- | --- | --- |
| `rpc` | 500 | Each call is sub-millisecond; sampling is cheap. |
| `embed` | 200 | Each call ~5–50 ms for batch 8. |
| `completion` | 10 | Each call generates `--max-tokens` tokens; full run takes 1–3 minutes. |

The bounty's "TTFT overhead < 5%" target uses the **mean TTFT
across iterations**. The p95 and p99 columns surface tail
latency, which is informative but not load-bearing for the
headline.

## Statistical treatment

`LatencySummary` (Swift) and `summarize()` (JS) compute the same
fields:

- `count` — sample count.
- `meanMs` — arithmetic mean of TTFT samples.
- `p50Ms`, `p95Ms`, `p99Ms` — percentile cutoffs from the
  sorted samples. We use the simple `sorted[floor((n-1)*p)]`
  formula; for our N=10 completion bench this is the 6th-of-10
  sample for p50, which is good enough — bounty doesn't require
  bootstrap CIs.
- `stdDevMs` — population standard deviation.
- `minMs`, `maxMs` — extrema for outlier inspection.

`compare.mjs` computes Δ (Swift − JS) and Overhead percent for
each metric; the headline assertion is on `mean TTFT`.

## Stability requirement (VT-3)

> *Run the bench 10 times; std dev of TTFT < 10% of mean.*

If `stdDevMs / meanMs > 0.10`, the measurement is too noisy to
draw conclusions from. Mitigation:

1. Close background apps (Slack, browsers, anything CPU-spiky).
2. Plug in (battery-mode throttling skews results).
3. Run a thermal cooldown (the Bare worker is CPU-bound during
   completion; a hot Mac throttles).

The benches are designed to be repeated until the std-dev gate
passes; tooling to gate automatically is a follow-up.

## What "JS baseline" means

The bounty's Success Indicator is "Swift vs JS **client** on same
machine". The "client" here is `@qvac/sdk`'s own JS client (the
official upstream surface). Both Swift and JS clients send the
same JSON envelopes over the same `bare-rpc` framing to the same
Bare worker process — so the gap should be:

- JSON encoder/decoder differences (Swift `JSONEncoder` vs JS
  `JSON.stringify`/`JSON.parse`).
- IPC abstraction differences (`Network.framework`
  `NWConnection .unix` vs Node's `net.createConnection`).
- Task-system differences (Swift `actor` vs JS event loop).

None of these should add measurable cost to a ~5–10 ms RTT or a
~150–200 ms TTFT. If the overhead is >5%, something's wrong in
our wire path.

## VT mapping

| VT | Status |
|---|---|
| VT-1 bench runs | ✅ — `swift run -c release Benchmark rpc` succeeds when fixture is set up |
| VT-2 JS bench runs | ✅ — `node rpc.mjs` succeeds when `npm install`'d |
| VT-3 stats stability | ⏳ measure on reference machine |
| VT-4 overhead <5% | ⏳ the bounty headline; measures under final perf-pass |
| VT-5 reproducibility | ⏳ measure on a second M2 Pro |
| VT-6 model-size scaling | ⏳ run with 3B model |
| VT-7 PR comment | ⏳ `.github/workflows/perf.yml` (YK-221 follow-up) |
| VT-8 baseline comparison | ⏳ same workflow |

The harness ships ready; the verdict measurement is the
runtime act of running it. Tracked as YK-221 finalization once
the LLM GGUF + a sustained-cool reference machine are available.
