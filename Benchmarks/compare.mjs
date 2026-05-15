// YK-221 — compare Swift vs JS benchmark JSON files.
//
// Usage:
//   node compare.mjs swift.json js.json
//   node compare.mjs swift.json js.json --markdown   # GH-flavored md
//
// Produces a table with overhead percentages. <5% on TTFT is the
// bounty's headline Success Indicator.

import { readFileSync } from "node:fs"

const [swiftPath, jsPath, ...rest] = process.argv.slice(2)
const markdown = rest.includes("--markdown")

if (!swiftPath || !jsPath) {
  process.stderr.write(
    "Usage: node compare.mjs <swift.json> <js.json> [--markdown]\n")
  process.exit(64)
}

const swift = JSON.parse(readFileSync(swiftPath, "utf8"))
const js = JSON.parse(readFileSync(jsPath, "utf8"))

if (swift.bench !== js.bench) {
  process.stderr.write(
    `error: bench mismatch — swift=${swift.bench} js=${js.bench}\n`)
  process.exit(1)
}

const rows = [
  ["mean", swift.latency.meanMs, js.latency.meanMs, "ms"],
  ["p50", swift.latency.p50Ms, js.latency.p50Ms, "ms"],
  ["p95", swift.latency.p95Ms, js.latency.p95Ms, "ms"],
  ["p99", swift.latency.p99Ms, js.latency.p99Ms, "ms"],
  ["stddev", swift.latency.stdDevMs, js.latency.stdDevMs, "ms"],
]
if (swift.throughputPerSecond != null && js.throughputPerSecond != null) {
  rows.push([
    "throughput",
    swift.throughputPerSecond,
    js.throughputPerSecond,
    swift.bench === "completion" ? "tok/s" : "req/s",
  ])
}

const fmt = (n) => n.toFixed(2)

if (markdown) {
  console.log(`### ${swift.bench} — Swift vs JS`)
  console.log("")
  console.log("| Metric | Swift | JS | Δ (Swift - JS) | Overhead |")
  console.log("| --- | --- | --- | --- | --- |")
  for (const [k, s, j, unit] of rows) {
    const delta = s - j
    const overhead = j > 0 ? ((delta / j) * 100) : 0
    const sign = delta >= 0 ? "+" : ""
    console.log(
      `| ${k} | ${fmt(s)} ${unit} | ${fmt(j)} ${unit} | ${sign}${fmt(delta)} ${unit} | ${sign}${overhead.toFixed(2)}% |`)
  }
  console.log("")
  console.log(`Samples: Swift ${swift.latency.count}, JS ${js.latency.count}.`)
  if (swift.model) console.log(`Model: ${swift.model}.`)

  // Headline check.
  const ttftSwift = swift.latency.meanMs
  const ttftJs = js.latency.meanMs
  const headline = ttftJs > 0 ? ((ttftSwift - ttftJs) / ttftJs) * 100 : 0
  if (swift.bench === "completion") {
    const verdict = Math.abs(headline) < 5 ? "✅" : "❌"
    console.log(
      `\n${verdict} **Headline (TTFT mean): ${headline.toFixed(2)}% overhead** — bounty target <5%.`)
  }
} else {
  // Plain text fallback for terminal output.
  console.log(`${swift.bench} — Swift vs JS`)
  for (const [k, s, j, unit] of rows) {
    const delta = s - j
    const overhead = j > 0 ? ((delta / j) * 100) : 0
    console.log(
      `  ${k.padEnd(12)} swift=${fmt(s)}${unit}  js=${fmt(j)}${unit}  Δ=${overhead.toFixed(2)}%`)
  }
}
