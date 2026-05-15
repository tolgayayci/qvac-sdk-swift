// YK-221 JS counterpart: pure heartbeat RTT.
//
// Run:
//   node rpc.mjs --iterations 1000 --out rpc-js.json
//
// Connects directly to a spawned bare worker.mjs over a UDS
// socket using @qvac/sdk's client transport. Same wire as the
// Swift client; differences are framing-codec only.

import { spawn } from "node:child_process"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

import { createClient } from "@qvac/sdk/dist/client/index.js"

const here = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(here, "../..")
const workerScript = path.join(
  repoRoot, "Tests/Fixtures/qvac-worker/worker.mjs")
const bareBin = path.join(
  repoRoot, "Tests/Fixtures/qvac-worker/node_modules/.bin/bare")

const args = parseArgs(process.argv.slice(2))
const iterations = args.iterations ?? 200
const outPath = args.out

const sockDir = mkdtempSync(path.join(tmpdir(), "qvac-bench-"))
const sockPath = path.join(sockDir, "rpc.sock")

const client = await createClient(sockPath)
const worker = spawn(
  bareBin,
  [workerScript, JSON.stringify({ QVAC_IPC_SOCKET_PATH: sockPath })],
  { stdio: ["pipe", "ignore", "ignore"] })

await client.ready()

// Warm-up.
for (let i = 0; i < 100; i++) await client.heartbeat()

const samples = []
const total0 = process.hrtime.bigint()
for (let i = 0; i < iterations; i++) {
  const t0 = process.hrtime.bigint()
  await client.heartbeat()
  samples.push(Number(process.hrtime.bigint() - t0) / 1e6)
}
const totalMs = Number(process.hrtime.bigint() - total0) / 1e6
const throughput = iterations / (totalMs / 1000)

const result = {
  lang: "js",
  bench: "rpc",
  model: null,
  totalDurationMs: totalMs,
  latency: summarize(samples),
  throughputPerSecond: throughput,
}

const payload = JSON.stringify(result, null, 2)
if (outPath) {
  writeFileSync(outPath, payload + "\n")
  process.stderr.write(`Wrote ${outPath}\n`)
} else {
  process.stdout.write(payload + "\n")
}

await client.close()
worker.kill("SIGTERM")
process.exit(0)

// ----------------------------------------------------------------

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === "--iterations") out.iterations = Number(argv[++i])
    else if (arg === "--out") out.out = argv[++i]
  }
  return out
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b)
  const mean = sorted.reduce((s, x) => s + x, 0) / sorted.length
  const variance =
    sorted.reduce((s, x) => s + (x - mean) ** 2, 0) / sorted.length
  const pct = (p) => sorted[Math.floor((sorted.length - 1) * p)]
  return {
    count: sorted.length,
    meanMs: mean,
    p50Ms: pct(0.5),
    p95Ms: pct(0.95),
    p99Ms: pct(0.99),
    stdDevMs: Math.sqrt(variance),
    minMs: sorted[0],
    maxMs: sorted[sorted.length - 1],
  }
}
