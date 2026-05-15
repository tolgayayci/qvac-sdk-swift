import Foundation
import QVACClient

// MARK: - Stats

/// Fixed-precision summary of a sample sequence in milliseconds.
/// Same shape as the JS counterpart so `compare.mjs` can diff
/// them mechanically without unit conversion.
struct LatencySummary: Codable {
  let count: Int
  let meanMs: Double
  let p50Ms: Double
  let p95Ms: Double
  let p99Ms: Double
  let stdDevMs: Double
  let minMs: Double
  let maxMs: Double

  init(samplesMs: [Double]) {
    let sorted = samplesMs.sorted()
    self.count = sorted.count
    let mean = sorted.reduce(0, +) / Double(max(sorted.count, 1))
    self.meanMs = mean
    self.p50Ms = sorted.percentile(0.50)
    self.p95Ms = sorted.percentile(0.95)
    self.p99Ms = sorted.percentile(0.99)
    let variance = sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(sorted.count, 1))
    self.stdDevMs = sqrt(variance)
    self.minMs = sorted.first ?? 0
    self.maxMs = sorted.last ?? 0
  }
}

extension Array where Element == Double {
  fileprivate func percentile(_ p: Double) -> Double {
    guard !isEmpty else { return 0 }
    let idx = Int(Double(count - 1) * p)
    return self[idx]
  }
}

struct BenchResult: Codable {
  let lang: String
  let bench: String
  let model: String?
  let totalDurationMs: Double
  let latency: LatencySummary
  /// Bench-specific throughput. For `completion`: tokens/sec.
  /// For `embed`: items/sec. For `rpc`: requests/sec.
  let throughputPerSecond: Double?
}

// MARK: - Common fixture lookup

func fixturePaths() -> (URL, URL) {
  let env = ProcessInfo.processInfo.environment
  if let bare = env["QVAC_BARE_BIN"], let worker = env["QVAC_WORKER_MJS"] {
    return (URL(fileURLWithPath: bare), URL(fileURLWithPath: worker))
  }
  let here = URL(fileURLWithPath: #filePath)
  let repoRoot = here
    .deletingLastPathComponent()  // Benchmark/
    .deletingLastPathComponent()  // Sources/
    .deletingLastPathComponent()  // Benchmarks/
    .deletingLastPathComponent()  // repo root
  let fixture = repoRoot.appendingPathComponent("Tests/Fixtures/qvac-worker")
  return (
    fixture.appendingPathComponent("node_modules/.bin/bare"),
    fixture.appendingPathComponent("worker.mjs")
  )
}

func modelPath(_ envKey: String, defaultName: String) -> String {
  if let p = ProcessInfo.processInfo.environment[envKey] {
    return p
  }
  let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
  return "\(home)/Library/Caches/qvac-tests/models/\(defaultName)"
}

func nowMs() -> Double {
  Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

func writeResult(_ r: BenchResult, to path: String?) throws {
  let enc = JSONEncoder()
  enc.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try enc.encode(r)
  if let path {
    try data.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write("Wrote \(path)\n".data(using: .utf8)!)
  } else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
  }
}

// MARK: - RPC overhead bench

/// Pure round-trip — `heartbeat` is the cheapest reply handler in
/// `@qvac/sdk`. Measures Swift→worker→Swift latency with no
/// inference work in the middle, so the result is pure framing /
/// codec / IPC cost.
func runRPC(iterations: Int, outputPath: String?) async throws {
  let (bare, worker) = fixturePaths()
  let spawned = try await QVACClient.spawning(
    bareBinary: bare, workerScript: worker)
  defer { Task { await spawned.close() } }

  // Warm-up — 100 heartbeats so the worker's V8/JIT settles.
  for _ in 0..<100 {
    _ = try await spawned.client.heartbeat()
  }

  var samples: [Double] = []
  samples.reserveCapacity(iterations)
  let total0 = nowMs()
  for _ in 0..<iterations {
    let t0 = nowMs()
    _ = try await spawned.client.heartbeat()
    samples.append(nowMs() - t0)
  }
  let totalMs = nowMs() - total0
  let throughput = Double(iterations) / (totalMs / 1000.0)

  let result = BenchResult(
    lang: "swift",
    bench: "rpc",
    model: nil,
    totalDurationMs: totalMs,
    latency: LatencySummary(samplesMs: samples),
    throughputPerSecond: throughput)
  try writeResult(result, to: outputPath)
}

// MARK: - Embed throughput bench

func runEmbed(iterations: Int, batchSize: Int, outputPath: String?) async throws {
  let bgePath = modelPath("BGE_MODEL_PATH", defaultName: "bge-small-en-v1.5.Q4_K_M.gguf")
  guard FileManager.default.fileExists(atPath: bgePath) else {
    FileHandle.standardError.write(
      "BGE model not found at \(bgePath). Run ./scripts/download-test-models.sh.\n"
        .data(using: .utf8)!)
    exit(2)
  }

  let (bare, worker) = fixturePaths()
  let spawned = try await QVACClient.spawning(
    bareBinary: bare, workerScript: worker)
  defer { Task { await spawned.close() } }

  let modelId = try await spawned.client.loadModel(
    modelSrc: bgePath, modelType: "embeddings")
  defer { Task { try? await spawned.client.unloadModel(modelId) } }

  // Warm-up — one batch.
  let warmInputs = (0..<batchSize).map { "warm-up token \($0)" }
  _ = try await spawned.client.embed(modelId: modelId, input: warmInputs)

  var samples: [Double] = []
  samples.reserveCapacity(iterations)
  let total0 = nowMs()
  for i in 0..<iterations {
    let inputs = (0..<batchSize).map { j in "iteration \(i) input \(j)" }
    let t0 = nowMs()
    _ = try await spawned.client.embed(modelId: modelId, input: inputs)
    samples.append(nowMs() - t0)
  }
  let totalMs = nowMs() - total0
  let throughput = Double(iterations * batchSize) / (totalMs / 1000.0)

  let result = BenchResult(
    lang: "swift",
    bench: "embed",
    model: "bge-small-en-v1.5.Q4_K_M",
    totalDurationMs: totalMs,
    latency: LatencySummary(samplesMs: samples),
    throughputPerSecond: throughput)
  try writeResult(result, to: outputPath)
}

// MARK: - Completion streaming bench

/// Measures **TTFT** (time-to-first-token) per run + **tokens/sec**
/// over the full generation. Run with `--iterations N` to repeat.
func runCompletion(iterations: Int, maxTokens: Int, outputPath: String?) async throws {
  let llmPath = modelPath(
    "LLM_MODEL_PATH",
    defaultName: "Llama-3.2-1B-Instruct-Q4_0.gguf")
  guard FileManager.default.fileExists(atPath: llmPath) else {
    FileHandle.standardError.write(
      """
      LLM model not found at \(llmPath). Download manually:
        curl -L 'https://huggingface.co/lmstudio-community/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_0.gguf' \\
          -o \(llmPath)

      """.data(using: .utf8)!)
    exit(2)
  }

  let (bare, worker) = fixturePaths()
  let spawned = try await QVACClient.spawning(
    bareBinary: bare, workerScript: worker)
  defer { Task { await spawned.close() } }

  let modelId = try await spawned.client.loadModel(
    modelSrc: llmPath, modelType: "llm")
  defer { Task { try? await spawned.client.unloadModel(modelId) } }

  // Warm-up — short completion to settle the JIT + KV cache.
  // bufferSize: nil picks the nonisolated streaming overload
  // (the blocking one returns CompletionResult, not a stream).
  let warmStream: AsyncThrowingStream<CompletionChunk, Error> =
    spawned.client.completion(
      modelId: modelId,
      history: [.user("Hi.")],
      options: CompletionOptions(maxTokens: 8, seed: 42),
      bufferSize: nil)
  for try await _ in warmStream {}

  var ttfts: [Double] = []
  var tokenCounts: [Int] = []
  var fullDurations: [Double] = []

  let total0 = nowMs()
  for _ in 0..<iterations {
    let runStart = nowMs()
    var firstTokenAt: Double?
    var tokens = 0
    let stream: AsyncThrowingStream<CompletionChunk, Error> =
      spawned.client.completion(
        modelId: modelId,
        history: [.user("Write a short haiku about a Swift program.")],
        options: CompletionOptions(maxTokens: maxTokens, seed: 42),
        bufferSize: nil)
    for try await chunk in stream {
      if case .token = chunk {
        if firstTokenAt == nil { firstTokenAt = nowMs() }
        tokens += 1
      }
    }
    let endAt = nowMs()
    if let ft = firstTokenAt { ttfts.append(ft - runStart) }
    tokenCounts.append(tokens)
    fullDurations.append(endAt - runStart)
  }
  let totalMs = nowMs() - total0
  let totalTokens = tokenCounts.reduce(0, +)
  let throughput = Double(totalTokens) / (totalMs / 1000.0)

  let result = BenchResult(
    lang: "swift",
    bench: "completion",
    model: "Llama-3.2-1B-Instruct-Q4_0",
    totalDurationMs: totalMs,
    latency: LatencySummary(samplesMs: ttfts),
    throughputPerSecond: throughput)
  try writeResult(result, to: outputPath)
}

// MARK: - Argument parsing

@main
struct BenchmarkMain {
  static func main() async throws {
    let args = CommandLine.arguments.dropFirst()
    let bench = args.first ?? "rpc"
    var iterations = 200
    var batchSize = 8
    var maxTokens = 64
    var outputPath: String?

    var idx = args.index(after: args.startIndex)
    while idx < args.endIndex {
      let arg = args[idx]
      switch arg {
      case "--iterations":
        idx = args.index(after: idx)
        if idx < args.endIndex { iterations = Int(args[idx]) ?? iterations }
      case "--batch":
        idx = args.index(after: idx)
        if idx < args.endIndex { batchSize = Int(args[idx]) ?? batchSize }
      case "--max-tokens":
        idx = args.index(after: idx)
        if idx < args.endIndex { maxTokens = Int(args[idx]) ?? maxTokens }
      case "--out":
        idx = args.index(after: idx)
        if idx < args.endIndex { outputPath = args[idx] }
      default:
        break
      }
      idx = args.index(after: idx)
    }

    switch bench {
    case "rpc":
      try await runRPC(iterations: iterations, outputPath: outputPath)
    case "embed":
      try await runEmbed(
        iterations: iterations,
        batchSize: batchSize,
        outputPath: outputPath)
    case "completion":
      try await runCompletion(
        iterations: iterations,
        maxTokens: maxTokens,
        outputPath: outputPath)
    default:
      FileHandle.standardError.write(
        """
        Unknown bench '\(bench)'. Available: rpc | embed | completion.

        Examples:
          swift run -c release Benchmark rpc --iterations 1000 --out rpc-swift.json
          swift run -c release Benchmark embed --iterations 200 --batch 8
          swift run -c release Benchmark completion --iterations 10 --max-tokens 128

        """.data(using: .utf8)!)
      exit(64)
    }
  }
}
