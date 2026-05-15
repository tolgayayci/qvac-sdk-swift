# Benchmarks (YK-221)

Side-by-side **Swift vs JS** benchmark suite for the bounty's
headline Success Indicator:

> *Streaming completion latency overhead Swift vs JS client on
> the same machine < 5%.*

## Layout

```
Benchmarks/
├── Package.swift              # SPM exec target (path dep to ../)
├── Sources/Benchmark/main.swift  # rpc | embed | completion benches
├── js/
│   ├── package.json           # @qvac/sdk 0.10.2 pin
│   ├── rpc.mjs                # JS counterpart: heartbeat RTT
│   ├── embed.mjs              # JS counterpart: batched embed
│   └── completion.mjs         # JS counterpart: streaming completion
├── compare.mjs                # diff swift.json vs js.json
└── README.md                  # this file
```

The Swift and JS benches both:
- spawn the same `Tests/Fixtures/qvac-worker` Bare worker;
- load the same GGUF model (or none, for `rpc`);
- use the same prompt + seed for `completion`;
- write a unified JSON shape so `compare.mjs` produces a
  one-table diff.

## Three benches

| Bench | What it measures | Model needed |
| --- | --- | --- |
| `rpc` | `heartbeat()` round-trip — pure framing + codec + IPC cost. | none |
| `embed` | Batched `embed()` throughput. | BGE-Small-EN-v1.5 (24 MB) |
| `completion` | TTFT + tokens/sec for streaming completion. Bounty headline. | Llama-3.2-1B-Instruct (~700 MB) |

## Run

```bash
# One-time setup.
cd ..
./scripts/download-barekit.sh
./scripts/download-test-models.sh        # pulls BGE; LLM is manual.
cd Tests/Fixtures/qvac-worker && npm install

# Swift side.
cd ../../../Benchmarks
swift build -c release
swift run -c release Benchmark rpc --iterations 500 --out rpc-swift.json
swift run -c release Benchmark embed --iterations 200 --batch 8 \
  --out embed-swift.json
swift run -c release Benchmark completion --iterations 10 \
  --max-tokens 64 --out completion-swift.json

# JS side.
cd js
npm install
node rpc.mjs --iterations 500 --out ../rpc-js.json
node embed.mjs --iterations 200 --batch 8 --out ../embed-js.json
node completion.mjs --iterations 10 --max-tokens 64 \
  --out ../completion-js.json
cd ..

# Compare.
node compare.mjs rpc-swift.json rpc-js.json --markdown
node compare.mjs embed-swift.json embed-js.json --markdown
node compare.mjs completion-swift.json completion-js.json --markdown
```

## Expected shape

`compare.mjs --markdown` for the completion bench prints
something like:

```markdown
### completion — Swift vs JS

| Metric | Swift | JS | Δ (Swift - JS) | Overhead |
| --- | --- | --- | --- | --- |
| mean | 187.34 ms | 182.71 ms | +4.63 ms | +2.53% |
| p50 | 184.21 ms | 180.05 ms | +4.16 ms | +2.31% |
| p95 | 213.40 ms | 207.18 ms | +6.22 ms | +3.00% |
| p99 | 232.55 ms | 224.12 ms | +8.43 ms | +3.76% |
| stddev | 12.84 ms | 11.50 ms | +1.34 ms | +11.65% |
| throughput | 42.10 tok/s | 43.45 tok/s | -1.35 tok/s | -3.10% |

Samples: Swift 10, JS 10.
Model: Llama-3.2-1B-Instruct-Q4_0.

✅ **Headline (TTFT mean): +2.53% overhead** — bounty target <5%.
```

Actual numbers measured under YK-221 finalization; today's
commit ships the harness, not the verdict.

## CI integration

`.github/workflows/perf.yml` (deferred to YK-221 finalization)
will run the bench on every push to `main` against a pinned model
(uploaded once to a release artifact, fetched on each run) and
post the comparison table as a PR comment.

The headline assertion lives in `compare.mjs`'s exit code: it
returns non-zero when the completion TTFT mean overhead exceeds
5%, so the CI run fails-fast on regressions.

## Methodology

See [`docs/perf/baseline.md`](../docs/perf/baseline.md) for the
reference machine spec, warm-up procedure, and statistical
treatment.

## Why JS as the baseline

The bounty's Success Indicator is "Swift vs JS client on same
machine". JS is the existing `@qvac/sdk` client target; matching
its TTFT (within 5%) proves the Swift wrapper adds no meaningful
overhead beyond what's inherent to the wire path.

The wire path is identical: both clients send the same JSON
envelopes over the same Bare worker process, so the gap should be
just `JSONEncoder/JSONDecoder` Swift overhead vs `JSON.parse` JS
overhead — a few microseconds in either direction.
