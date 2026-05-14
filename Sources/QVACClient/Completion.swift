import Foundation

/// One message in a chat history sent to `completion`. Role values are
/// `"system" | "user" | "assistant" | "tool"` — see
/// [JS SDK chat history](https://docs.qvac.tether.io/sdk/api/#completion)
/// for the canonical list. Free-form here so future role additions
/// don't require a Swift bump.
public struct ChatMessage: Codable, Sendable, Equatable {
  public let role: String
  public let content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }

  public static func system(_ content: String) -> ChatMessage {
    .init(role: "system", content: content)
  }
  public static func user(_ content: String) -> ChatMessage {
    .init(role: "user", content: content)
  }
  public static func assistant(_ content: String) -> ChatMessage {
    .init(role: "assistant", content: content)
  }
}

/// Sampler / generation knobs for `completion`. All optional;
/// `nil` lets the worker apply its default (per loaded model).
///
/// Names mirror the JS SDK's `CompletionOptions` so the wire
/// payload round-trips without translation. Per-model-type extras
/// (e.g. llama.cpp-specific repetition penalty) ride in `extras`.
public struct CompletionOptions: Codable, Sendable, Equatable {
  public var maxTokens: Int?
  public var temperature: Double?
  public var topP: Double?
  public var topK: Int?
  public var seed: UInt64?
  public var stopSequences: [String]?
  public var extras: [String: AnyCodable]?

  public init(
    maxTokens: Int? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    seed: UInt64? = nil,
    stopSequences: [String]? = nil,
    extras: [String: AnyCodable]? = nil
  ) {
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.seed = seed
    self.stopSequences = stopSequences
    self.extras = extras
  }
}

/// One chunk in a streaming completion. The worker emits zero or
/// more `.token(_)` chunks followed by exactly one terminal
/// `.finish(_:_:)` carrying the stop reason + optional stats.
///
/// Decode strategy: each line of the streaming JSON is inspected
/// for a `token` field (→ `.token`), a `finish` field (→ `.finish`),
/// or both (rare; we prefer `.finish` if both present so callers
/// see a clean terminal). Unknown shapes fall back to `.token("")`
/// so an unfamiliar wire variant doesn't blow up the iterator.
public enum CompletionChunk: Sendable, Equatable {
  case token(String)
  case finish(reason: String, stats: CompletionStats?)
}

/// Optional per-completion stats. Fields mirror the JS SDK's
/// `CompletionStats` (free-form `Double?` since llama.cpp metrics
/// vary across models / quantizations).
public struct CompletionStats: Codable, Sendable, Equatable {
  public var promptTokens: Double?
  public var generatedTokens: Double?
  public var totalTimeMs: Double?
  public var tokensPerSecond: Double?

  public init(
    promptTokens: Double? = nil,
    generatedTokens: Double? = nil,
    totalTimeMs: Double? = nil,
    tokensPerSecond: Double? = nil
  ) {
    self.promptTokens = promptTokens
    self.generatedTokens = generatedTokens
    self.totalTimeMs = totalTimeMs
    self.tokensPerSecond = tokensPerSecond
  }
}

/// Blocking-variant aggregate. Built by consuming the streaming
/// variant internally.
public struct CompletionResult: Sendable, Equatable {
  /// Concatenated token text.
  public let text: String
  /// Stop reason from the terminal `.finish` chunk.
  public let finishReason: String
  /// Stats from the terminal `.finish` chunk, if the worker provided any.
  public let stats: CompletionStats?

  public init(text: String, finishReason: String, stats: CompletionStats?) {
    self.text = text
    self.finishReason = finishReason
    self.stats = stats
  }
}

extension QVACClient {
  // MARK: - completion (streaming)

  /// Streaming completion. Routes wire command `completionStream`;
  /// the caller iterates token chunks and gets a terminal `.finish`
  /// when the worker stops generating. Backpressure + cancellation
  /// flow through the YK-199 / YK-200 paths automatically.
  ///
  /// `bufferSize: nil` (default) is unbounded — matches the JS SDK.
  /// For long completions consumed by a slow UI, pass e.g.
  /// `bufferSize: 256` to cap memory at the cost of dropping
  /// oldest chunks under sustained flood (see `docs/backpressure.md`).
  public nonisolated func completion(
    modelId: ModelId,
    history: [ChatMessage],
    options: CompletionOptions = .init(),
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<CompletionChunk, Error> {
    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "history": Self.encodeHistory(history),
      "options": Self.encodeOptions(options),
    ]
    return self.completionStreamMapped(body, bufferSize: bufferSize)
  }

  // MARK: - completion (blocking)

  /// Blocking convenience: consumes the streaming variant
  /// internally and returns a single `CompletionResult` with all
  /// tokens concatenated. Cancellation of the awaiting Task still
  /// propagates to the worker via the YK-200 path.
  public func completion(
    modelId: ModelId,
    history: [ChatMessage],
    options: CompletionOptions = .init()
  ) async throws -> CompletionResult {
    var accumulated = ""
    var finishReason = "unknown"
    var stats: CompletionStats? = nil
    // Disambiguate from the blocking overload by passing the
    // streaming-only `bufferSize` parameter.
    let stream: AsyncThrowingStream<CompletionChunk, Error> = completion(
      modelId: modelId, history: history, options: options, bufferSize: nil)

    for try await chunk in stream {
      switch chunk {
      case .token(let s):
        accumulated += s
      case .finish(let reason, let s):
        finishReason = reason
        stats = s
      }
    }
    return CompletionResult(
      text: accumulated, finishReason: finishReason, stats: stats)
  }

  // MARK: - private helpers

  /// Wraps the underlying `streamResponse<_, AnyCodable>` and maps
  /// each `AnyCodable` chunk to a `CompletionChunk`. Kept private
  /// so the chunk shape can evolve without breaking the public
  /// streaming surface.
  private nonisolated func completionStreamMapped(
    _ body: [String: AnyCodable],
    bufferSize: Int?
  ) -> AsyncThrowingStream<CompletionChunk, Error> {
    let raw: AsyncThrowingStream<AnyCodable, Error> = self.streamResponse(
      command: .completionStream, body, bufferSize: bufferSize)

    return AsyncThrowingStream<CompletionChunk, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let chunk = Self.parseCompletionChunk(rawChunk) {
              continuation.yield(chunk)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  /// Maps a single JSON chunk to a `CompletionChunk`. Pattern:
  ///   `{"finish": "stop", "stats": {...}}` → `.finish(...)`
  ///   `{"token": "hello"}`                 → `.token("hello")`
  ///   anything else                        → nil (silently dropped)
  private static func parseCompletionChunk(_ value: AnyCodable) -> CompletionChunk? {
    guard case .object(let dict) = value.value else { return nil }
    if case .string(let reason) = dict["finish"] {
      let stats: CompletionStats?
      if case .object(let statsDict) = dict["stats"] {
        stats = CompletionStats(
          promptTokens: doubleValue(statsDict["promptTokens"]),
          generatedTokens: doubleValue(statsDict["generatedTokens"]),
          totalTimeMs: doubleValue(statsDict["totalTimeMs"]),
          tokensPerSecond: doubleValue(statsDict["tokensPerSecond"]))
      } else {
        stats = nil
      }
      return .finish(reason: reason, stats: stats)
    }
    if case .string(let token) = dict["token"] {
      return .token(token)
    }
    return nil
  }

  private static func doubleValue(_ v: AnyCodableValue?) -> Double? {
    switch v {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
  }

  private static func encodeHistory(_ history: [ChatMessage]) -> AnyCodable {
    let array: [AnyCodableValue] = history.map { msg in
      .object([
        "role": .string(msg.role),
        "content": .string(msg.content),
      ])
    }
    return AnyCodable(.array(array))
  }

  private static func encodeOptions(_ opt: CompletionOptions) -> AnyCodable {
    var dict: [String: AnyCodableValue] = [:]
    if let v = opt.maxTokens { dict["maxTokens"] = .int(v) }
    if let v = opt.temperature { dict["temperature"] = .double(v) }
    if let v = opt.topP { dict["topP"] = .double(v) }
    if let v = opt.topK { dict["topK"] = .int(v) }
    if let v = opt.seed { dict["seed"] = .double(Double(v)) }
    if let v = opt.stopSequences {
      dict["stopSequences"] = .array(v.map { .string($0) })
    }
    if let extras = opt.extras {
      for (key, value) in extras { dict[key] = value.value }
    }
    return AnyCodable(.object(dict))
  }
}
