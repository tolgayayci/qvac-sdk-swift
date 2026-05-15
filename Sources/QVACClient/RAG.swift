import Foundation

// MARK: - Types

/// A single workspace within the worker's RAG store. Workspaces
/// isolate ingested documents — search and reindex are scoped to
/// one workspace. Names are sanitized server-side via
/// `safePathComponent`; only POSIX-safe characters are allowed.
///
/// `nil` workspace falls back to the worker's `DEFAULT_WORKSPACE`.
public typealias WorkspaceId = String

/// A document chunk in the RAG store. `id` is server-generated
/// when ingest assigns one; for `ragChunk` (pure tokenizer pass)
/// the id is a deterministic content hash.
public struct RAGChunk: Codable, Sendable, Equatable {
  public let id: String
  public let content: String
}

/// One search hit returned by `ragSearch`. `score` is the
/// retrieval score from the backend — for the hyperdb store this
/// is cosine similarity in `[0, 1]`, higher = closer.
public struct RAGSearchHit: Codable, Sendable, Equatable {
  public let id: String
  public let content: String
  public let score: Double
}

/// Chunking strategy. `character` splits at a fixed character count
/// with optional overlap; `paragraph` splits at paragraph breaks
/// (double newline) and falls back to character when a paragraph
/// exceeds `chunkSize`.
public enum ChunkStrategy: String, Sendable, Codable {
  case character
  case paragraph
}

/// Token granularity used by the chunker before the strategy
/// applies. `character` counts UTF-16 code units (matches JS);
/// `word`, `token`, `sentence`, `line` split on those boundaries.
public enum SplitStrategy: String, Sendable, Codable {
  case character
  case word
  case token
  case sentence
  case line
}

/// Knobs for `ragChunk` and the chunking pass inside `ragIngest`.
/// All fields optional — the worker fills sensible defaults
/// (chunkSize ≈ 512 characters, no overlap, paragraph strategy).
public struct ChunkOptions: Sendable, Equatable {
  public var chunkSize: Int?
  public var chunkOverlap: Int?
  public var chunkStrategy: ChunkStrategy?
  public var splitStrategy: SplitStrategy?

  public init(
    chunkSize: Int? = nil,
    chunkOverlap: Int? = nil,
    chunkStrategy: ChunkStrategy? = nil,
    splitStrategy: SplitStrategy? = nil
  ) {
    self.chunkSize = chunkSize
    self.chunkOverlap = chunkOverlap
    self.chunkStrategy = chunkStrategy
    self.splitStrategy = splitStrategy
  }
}

/// Per-document outcome from `ragIngest`. `status == .fulfilled`
/// means the chunk was embedded and stored; `.rejected` carries
/// the worker-side reason in `error`.
public struct RAGProcessedItem: Codable, Sendable, Equatable {
  public enum Status: String, Codable, Sendable {
    case fulfilled
    case rejected
  }
  public let status: Status
  public let id: String?
  public let error: String?
}

/// Aggregate result of `ragIngest`. `processed` lines up with the
/// chunks the worker produced (one entry per chunk); the input
/// `documents` array maps one-to-many to chunks when the chunker
/// runs. `droppedIndices` lists the indices in `documents` whose
/// content was empty or unprocessable, so the caller can audit
/// what didn't make it in.
public struct RAGIngestResult: Codable, Sendable, Equatable {
  public let processed: [RAGProcessedItem]
  public let droppedIndices: [Int]
}

/// One frame from `ragIngestStream`. `.progress(...)` flows while
/// the worker is chunking/embedding/saving (one event roughly per
/// `progressInterval` ms, throttled server-side); `.completed(...)`
/// is the terminal frame carrying the final `RAGIngestResult`.
///
/// The streaming variant is for long ingests (many documents or
/// large ones) where the caller wants a progress bar. For shorter
/// ingests, the blocking `ragIngest(...)` returns the result
/// directly.
public enum RAGIngestEvent: Sendable, Equatable {
  case progress(stage: String, current: Int, total: Int, timestamp: Double)
  case completed(RAGIngestResult)
}

// MARK: - Methods

extension QVACClient {

  // MARK: ragChunk

  /// Run the worker's chunker on the input text(s) without
  /// embedding or storing anything. Useful for previewing the
  /// chunk boundaries the same pipeline `ragIngest` would use.
  ///
  /// `documents` accepts either one string or many; the worker
  /// normalizes both to a flat chunk list, so the return shape
  /// is always `[RAGChunk]`.
  public func ragChunk(
    documents: [String],
    options: ChunkOptions = .init()
  ) async throws -> [RAGChunk] {
    guard !documents.isEmpty else {
      throw QVACError.transport(
        .framingError("ragChunk requires non-empty documents"))
    }

    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("chunk")),
      "documents": Self.documentsValue(documents),
    ]
    if let opts = Self.chunkOptionsValue(options) {
      body["chunkOpts"] = opts
    }

    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeRagChunks(response)
  }

  /// Single-string overload. Returns the chunks the worker would
  /// produce for one document.
  public func ragChunk(
    text: String,
    options: ChunkOptions = .init()
  ) async throws -> [RAGChunk] {
    try await ragChunk(documents: [text], options: options)
  }

  // MARK: ragIngest

  /// Ingest documents into a RAG workspace: chunk, embed, save.
  /// Blocking variant — returns the final `RAGIngestResult` when
  /// the worker finishes. Use `ragIngestStream(...)` for progress.
  ///
  /// `modelId` is the embedding model loaded via `loadModel` (e.g.
  /// `bge-small-en-v1.5`). `workspace` defaults to the worker's
  /// `DEFAULT_WORKSPACE` when `nil`. `chunk: false` skips the
  /// chunker — required when `documents` are already pre-chunked.
  public func ragIngest(
    modelId: ModelId,
    workspace: WorkspaceId? = nil,
    documents: [String],
    chunk: Bool = true,
    chunkOpts: ChunkOptions = .init()
  ) async throws -> RAGIngestResult {
    guard !documents.isEmpty else {
      throw QVACError.transport(
        .framingError("ragIngest requires non-empty documents"))
    }

    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("ingest")),
      "modelId": AnyCodable(.string(modelId)),
      "documents": Self.documentsValue(documents),
      "chunk": AnyCodable(.bool(chunk)),
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }
    if let opts = Self.chunkOptionsValue(chunkOpts) {
      body["chunkOpts"] = opts
    }

    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeIngestResult(response)
  }

  /// Streaming ingest. Yields `.progress(...)` frames as the worker
  /// reports them and finishes with one `.completed(result)` frame.
  /// Caller-side `break` or `Task.cancel()` terminates the stream;
  /// see `docs/cancellation.md` for the worker-side cancel rules.
  ///
  /// `progressInterval` is the minimum wall-clock spacing (ms)
  /// between progress frames; the worker throttles server-side and
  /// this is purely a hint.
  public nonisolated func ragIngestStream(
    modelId: ModelId,
    workspace: WorkspaceId? = nil,
    documents: [String],
    chunk: Bool = true,
    chunkOpts: ChunkOptions = .init(),
    progressInterval: Int? = nil,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<RAGIngestEvent, Error> {
    AsyncThrowingStream<RAGIngestEvent, Error> { continuation in
      let task = Task {
        guard !documents.isEmpty else {
          continuation.finish(throwing: QVACError.transport(
            .framingError("ragIngest requires non-empty documents")))
          return
        }
        var body: [String: AnyCodable] = [
          "operation": AnyCodable(.string("ingest")),
          "modelId": AnyCodable(.string(modelId)),
          "documents": Self.documentsValue(documents),
          "chunk": AnyCodable(.bool(chunk)),
          "withProgress": AnyCodable(.bool(true)),
        ]
        if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }
        if let opts = Self.chunkOptionsValue(chunkOpts) {
          body["chunkOpts"] = opts
        }
        if let progressInterval {
          body["progressInterval"] = AnyCodable(.int(progressInterval))
        }

        let raw: AsyncThrowingStream<AnyCodable, Error> =
          self.streamResponse(command: .rag, body, bufferSize: bufferSize)
        do {
          for try await rawChunk in raw {
            if let event = Self.parseRagIngestEvent(rawChunk) {
              continuation.yield(event)
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

  // MARK: ragSearch

  /// Retrieve top-K most similar chunks for `query` from
  /// `workspace`. `modelId` is the same embedding model used at
  /// ingest time — different models produce incompatible vector
  /// spaces, so swapping it mid-workspace returns garbage.
  ///
  /// `topK` is the number of hits returned (default 5);
  /// `candidates` (`n` in the wire protocol) is the number of
  /// nearest-neighbor candidates the backend pulls before re-
  /// scoring — higher `candidates` trades latency for recall.
  public func ragSearch(
    modelId: ModelId,
    workspace: WorkspaceId? = nil,
    query: String,
    topK: Int = 5,
    candidates: Int = 3
  ) async throws -> [RAGSearchHit] {
    guard !query.isEmpty else {
      throw QVACError.transport(
        .framingError("ragSearch requires non-empty query"))
    }
    guard topK > 0 else {
      throw QVACError.transport(
        .framingError("ragSearch topK must be > 0, got \(topK)"))
    }
    guard candidates > 0 else {
      throw QVACError.transport(
        .framingError("ragSearch candidates must be > 0, got \(candidates)"))
    }

    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("search")),
      "modelId": AnyCodable(.string(modelId)),
      "query": AnyCodable(.string(query)),
      "topK": AnyCodable(.int(topK)),
      "n": AnyCodable(.int(candidates)),
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }

    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeRagHits(response)
  }

  // MARK: - private helpers

  /// `documents` accepts either one string or many in the wire
  /// schema. We always send the array form for predictability.
  private static func documentsValue(_ docs: [String]) -> AnyCodable {
    AnyCodable(.array(docs.map { .string($0) }))
  }

  private static func chunkOptionsValue(_ opts: ChunkOptions) -> AnyCodable? {
    var dict: [String: AnyCodableValue] = [:]
    if let v = opts.chunkSize { dict["chunkSize"] = .int(v) }
    if let v = opts.chunkOverlap { dict["chunkOverlap"] = .int(v) }
    if let v = opts.chunkStrategy { dict["chunkStrategy"] = .string(v.rawValue) }
    if let v = opts.splitStrategy { dict["splitStrategy"] = .string(v.rawValue) }
    return dict.isEmpty ? nil : AnyCodable(.object(dict))
  }

  private static func decodeRagChunks(_ response: AnyCodable) throws -> [RAGChunk] {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/chunk response is not an object: \(response.value)"))
    }
    try Self.assertRagSuccess(dict, operation: "chunk")
    guard case .array(let arr) = dict["chunks"] else {
      throw QVACError.transport(
        .decodingFailed("rag/chunk response missing `chunks` array"))
    }
    return try arr.map { v in
      guard case .object(let c) = v else {
        throw QVACError.transport(
          .decodingFailed("rag/chunk entry is not an object: \(v)"))
      }
      guard case .string(let id) = c["id"], case .string(let content) = c["content"]
      else {
        throw QVACError.transport(
          .decodingFailed("rag/chunk entry missing id or content: \(c)"))
      }
      return RAGChunk(id: id, content: content)
    }
  }

  private static func decodeRagHits(_ response: AnyCodable) throws -> [RAGSearchHit] {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/search response is not an object: \(response.value)"))
    }
    try Self.assertRagSuccess(dict, operation: "search")
    guard case .array(let arr) = dict["results"] else {
      throw QVACError.transport(
        .decodingFailed("rag/search response missing `results` array"))
    }
    return try arr.map { v in
      guard case .object(let h) = v else {
        throw QVACError.transport(
          .decodingFailed("rag/search hit is not an object: \(v)"))
      }
      guard case .string(let id) = h["id"], case .string(let content) = h["content"]
      else {
        throw QVACError.transport(
          .decodingFailed("rag/search hit missing id or content: \(h)"))
      }
      let score: Double
      switch h["score"] {
      case .double(let d): score = d
      case .int(let i): score = Double(i)
      default:
        throw QVACError.transport(
          .decodingFailed("rag/search hit missing/invalid score: \(h)"))
      }
      return RAGSearchHit(id: id, content: content, score: score)
    }
  }

  internal static func decodeIngestResult(_ response: AnyCodable) throws -> RAGIngestResult {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/ingest response is not an object: \(response.value)"))
    }
    try Self.assertRagSuccess(dict, operation: "ingest")
    return try Self.decodeIngestResultBody(dict)
  }

  private static func decodeIngestResultBody(
    _ dict: [String: AnyCodableValue]
  ) throws -> RAGIngestResult {
    guard case .array(let arr) = dict["processed"] else {
      throw QVACError.transport(
        .decodingFailed("rag/ingest response missing `processed` array"))
    }
    let processed: [RAGProcessedItem] = try arr.map { v in
      guard case .object(let p) = v else {
        throw QVACError.transport(
          .decodingFailed("rag/ingest processed entry is not an object: \(v)"))
      }
      guard case .string(let s) = p["status"],
        let status = RAGProcessedItem.Status(rawValue: s)
      else {
        throw QVACError.transport(
          .decodingFailed("rag/ingest processed entry missing/invalid status: \(p)"))
      }
      var id: String?
      if case .string(let v) = p["id"] { id = v }
      var error: String?
      if case .string(let v) = p["error"] { error = v }
      return RAGProcessedItem(status: status, id: id, error: error)
    }
    var dropped: [Int] = []
    if case .array(let dropArr) = dict["droppedIndices"] {
      dropped = dropArr.compactMap { v in
        if case .int(let i) = v { return i }
        if case .double(let d) = v { return Int(d) }
        return nil
      }
    }
    return RAGIngestResult(processed: processed, droppedIndices: dropped)
  }

  /// Asserts `success: true` on a rag reply envelope. Surfaces the
  /// worker-side `error` string when the operation failed.
  private static func assertRagSuccess(
    _ dict: [String: AnyCodableValue],
    operation: String
  ) throws {
    if case .bool(false) = dict["success"] {
      var message = "rag/\(operation) failed"
      if case .string(let err) = dict["error"] {
        message += ": \(err)"
      }
      throw QVACError.transport(.framingError(message))
    }
  }

  private static func parseRagIngestEvent(_ value: AnyCodable) -> RAGIngestEvent? {
    guard case .object(let dict) = value.value else { return nil }

    // Progress frames carry `type: "rag:progress"`.
    if case .string(let t) = dict["type"], t == "rag:progress" {
      var stage = ""
      if case .string(let s) = dict["stage"] { stage = s }
      let current = Self.intFrom(dict["current"]) ?? 0
      let total = Self.intFrom(dict["total"]) ?? 0
      let timestamp: Double = {
        if case .double(let d) = dict["timestamp"] { return d }
        if case .int(let i) = dict["timestamp"] { return Double(i) }
        return 0
      }()
      return .progress(
        stage: stage, current: current, total: total, timestamp: timestamp)
    }

    // Final reply: `{type: "rag", operation: "ingest", success, processed, droppedIndices}`.
    if case .string(let t) = dict["type"], t == "rag",
      case .string(let op) = dict["operation"], op == "ingest"
    {
      do {
        try assertRagSuccess(dict, operation: "ingest")
        let result = try decodeIngestResultBody(dict)
        return .completed(result)
      } catch {
        // Defer the throw to the stream consumer by letting the
        // outer Task surface it via continuation.finish(throwing:).
        // The non-progress non-completed shape returns nil so the
        // raw stream's iterator stops mid-way without a `completed`.
        return nil
      }
    }
    return nil
  }

  private static func intFrom(_ value: AnyCodableValue?) -> Int? {
    switch value {
    case .int(let i): return i
    case .double(let d): return Int(d)
    default: return nil
    }
  }
}
