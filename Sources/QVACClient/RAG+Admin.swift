import Foundation

// MARK: - Types

/// A pre-computed embedding ready to save into a RAG workspace —
/// bypasses the worker's embedding model so callers who already
/// have vectors (from a third-party model, a cached pipeline, etc.)
/// can store them directly.
///
/// `embeddingModelId` is purely informational on the wire — it
/// labels which model produced the vector so subsequent searches
/// can decide whether to mix vectors across models. Validation is
/// the caller's responsibility.
public struct RAGEmbeddedDocument: Sendable, Equatable {
  public let id: String
  public let content: String
  public let embedding: [Double]
  public let embeddingModelId: String
  public let metadata: [String: AnyCodable]?

  public init(
    id: String,
    content: String,
    embedding: [Double],
    embeddingModelId: String,
    metadata: [String: AnyCodable]? = nil
  ) {
    self.id = id
    self.content = content
    self.embedding = embedding
    self.embeddingModelId = embeddingModelId
    self.metadata = metadata
  }
}

/// Workspace info entry from `ragListWorkspaces`. `open == true`
/// means the workspace is currently warm in the worker's memory;
/// `false` means it's persisted on disk but not loaded.
public struct RAGWorkspaceInfo: Codable, Sendable, Equatable {
  public let name: String
  public let open: Bool
}

/// Result of `ragReindex` — `reindexed: true` if anything actually
/// changed (e.g. embedding model version bumped, vectors rebuilt).
/// `details` is a worker-defined dictionary for diagnostics.
public struct RAGReindexResult: Sendable, Equatable {
  public let reindexed: Bool
  public let details: [String: AnyCodable]?

  public init(reindexed: Bool, details: [String: AnyCodable]? = nil) {
    self.reindexed = reindexed
    self.details = details
  }
}

/// One frame from `ragReindexStream`. Same shape as `RAGIngestEvent`
/// — progress events while the worker rebuilds the index, then a
/// terminal `.completed(...)` with the result.
public enum RAGReindexEvent: Sendable, Equatable {
  case progress(stage: String, current: Int, total: Int, timestamp: Double)
  case completed(RAGReindexResult)
}

// MARK: - Methods

extension QVACClient {

  // MARK: ragSaveEmbeddings

  /// Save pre-computed embeddings directly into a workspace,
  /// skipping the worker's embedding model. Returns per-document
  /// `RAGProcessedItem` entries — `fulfilled` for accepted vectors,
  /// `rejected` (with `error`) for malformed ones.
  ///
  /// `modelId` is optional here — the schema only requires it when
  /// no cached RAG instance exists for the workspace. Pass it if
  /// the workspace is brand-new and the caller wants to choose
  /// which embedding model the workspace is associated with.
  public func ragSaveEmbeddings(
    workspace: WorkspaceId? = nil,
    modelId: ModelId? = nil,
    documents: [RAGEmbeddedDocument]
  ) async throws -> [RAGProcessedItem] {
    guard !documents.isEmpty else {
      throw QVACError.transport(
        .framingError("ragSaveEmbeddings requires non-empty documents"))
    }

    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("saveEmbeddings")),
      "documents": AnyCodable(.array(documents.map(Self.embeddedDocValue))),
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }
    if let modelId { body["modelId"] = AnyCodable(.string(modelId)) }

    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeRagProcessedList(response, operation: "saveEmbeddings")
  }

  // MARK: ragDeleteEmbeddings

  /// Delete embeddings by id. Unknown ids are silently ignored
  /// server-side (delete is idempotent — re-deleting the same id
  /// is a no-op, not an error).
  public func ragDeleteEmbeddings(
    workspace: WorkspaceId? = nil,
    ids: [String]
  ) async throws {
    guard !ids.isEmpty else {
      throw QVACError.transport(
        .framingError("ragDeleteEmbeddings requires at least one id"))
    }

    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("deleteEmbeddings")),
      "ids": AnyCodable(.array(ids.map { .string($0) })),
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }

    let response: AnyCodable = try await send(command: .rag, body)
    try Self.assertRagOperationSuccess(response, operation: "deleteEmbeddings")
  }

  // MARK: ragReindex

  /// Blocking reindex — returns the final result. Use
  /// `ragReindexStream(...)` for progress on large stores.
  public func ragReindex(
    workspace: WorkspaceId? = nil
  ) async throws -> RAGReindexResult {
    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("reindex"))
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }

    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeReindexResult(response)
  }

  /// Streaming reindex. Same `progress → completed` shape as
  /// `ragIngestStream(...)`. Caller-side cancel via `Task.cancel()`
  /// or `break`-out-of-loop tears the stream down.
  public nonisolated func ragReindexStream(
    workspace: WorkspaceId? = nil,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<RAGReindexEvent, Error> {
    AsyncThrowingStream<RAGReindexEvent, Error> { continuation in
      let task = Task {
        var body: [String: AnyCodable] = [
          "operation": AnyCodable(.string("reindex")),
          "withProgress": AnyCodable(.bool(true)),
        ]
        if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }

        let raw: AsyncThrowingStream<AnyCodable, Error> =
          self.streamResponse(command: .rag, body, bufferSize: bufferSize)
        do {
          for try await rawChunk in raw {
            if let event = Self.parseRagReindexEvent(rawChunk) {
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

  // MARK: workspace management

  /// List all workspaces the worker knows about. Includes both
  /// open (warm) and closed (on-disk) workspaces.
  public func ragListWorkspaces() async throws -> [RAGWorkspaceInfo] {
    let body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("listWorkspaces"))
    ]
    let response: AnyCodable = try await send(command: .rag, body)
    return try Self.decodeWorkspaceList(response)
  }

  /// Close (and optionally delete) a workspace. Closing releases
  /// the in-memory index and any open file handles; the workspace
  /// can be reopened later by a subsequent `ragIngest` or
  /// `ragSearch`. `deleteOnClose: true` is shorthand for "close
  /// then delete in one round-trip".
  public func ragCloseWorkspace(
    workspace: WorkspaceId? = nil,
    deleteOnClose: Bool = false
  ) async throws {
    var body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("closeWorkspace"))
    ]
    if let workspace { body["workspace"] = AnyCodable(.string(workspace)) }
    if deleteOnClose {
      body["deleteOnClose"] = AnyCodable(.bool(true))
    }

    let response: AnyCodable = try await send(command: .rag, body)
    try Self.assertRagOperationSuccess(response, operation: "closeWorkspace")
  }

  /// Permanently delete a workspace and all its persisted data.
  /// Backing files are removed; can't be undone. Unlike
  /// `closeWorkspace`, this is destructive even if the workspace
  /// is closed at the time of the call.
  public func ragDeleteWorkspace(
    workspace: WorkspaceId
  ) async throws {
    guard !workspace.isEmpty else {
      throw QVACError.transport(
        .framingError("ragDeleteWorkspace requires non-empty workspace name"))
    }
    let body: [String: AnyCodable] = [
      "operation": AnyCodable(.string("deleteWorkspace")),
      "workspace": AnyCodable(.string(workspace)),
    ]
    let response: AnyCodable = try await send(command: .rag, body)
    try Self.assertRagOperationSuccess(response, operation: "deleteWorkspace")
  }

  // MARK: - private helpers

  private static func embeddedDocValue(_ doc: RAGEmbeddedDocument) -> AnyCodableValue {
    var dict: [String: AnyCodableValue] = [
      "id": .string(doc.id),
      "content": .string(doc.content),
      "embedding": .array(doc.embedding.map { .double($0) }),
      "embeddingModelId": .string(doc.embeddingModelId),
    ]
    if let metadata = doc.metadata {
      dict["metadata"] = .object(metadata.mapValues { $0.value })
    }
    return .object(dict)
  }

  private static func decodeRagProcessedList(
    _ response: AnyCodable,
    operation: String
  ) throws -> [RAGProcessedItem] {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/\(operation) response is not an object"))
    }
    try assertRagSuccessDict(dict, operation: operation)
    guard case .array(let arr) = dict["processed"] else {
      throw QVACError.transport(
        .decodingFailed("rag/\(operation) response missing `processed` array"))
    }
    return try arr.map { v in
      guard case .object(let p) = v else {
        throw QVACError.transport(
          .decodingFailed("rag/\(operation) processed entry is not an object"))
      }
      guard case .string(let s) = p["status"],
        let status = RAGProcessedItem.Status(rawValue: s)
      else {
        throw QVACError.transport(
          .decodingFailed("rag/\(operation) entry missing/invalid status"))
      }
      var id: String?
      if case .string(let v) = p["id"] { id = v }
      var error: String?
      if case .string(let v) = p["error"] { error = v }
      return RAGProcessedItem(status: status, id: id, error: error)
    }
  }

  private static func decodeWorkspaceList(
    _ response: AnyCodable
  ) throws -> [RAGWorkspaceInfo] {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/listWorkspaces response is not an object"))
    }
    try assertRagSuccessDict(dict, operation: "listWorkspaces")
    guard case .array(let arr) = dict["workspaces"] else {
      throw QVACError.transport(
        .decodingFailed("rag/listWorkspaces missing `workspaces` array"))
    }
    return try arr.map { v in
      guard case .object(let w) = v else {
        throw QVACError.transport(
          .decodingFailed("rag/listWorkspaces entry is not an object"))
      }
      guard case .string(let name) = w["name"], case .bool(let open) = w["open"]
      else {
        throw QVACError.transport(
          .decodingFailed("rag/listWorkspaces entry missing name/open: \(w)"))
      }
      return RAGWorkspaceInfo(name: name, open: open)
    }
  }

  private static func decodeReindexResult(
    _ response: AnyCodable
  ) throws -> RAGReindexResult {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/reindex response is not an object"))
    }
    try assertRagSuccessDict(dict, operation: "reindex")
    return try decodeReindexResultBody(dict)
  }

  private static func decodeReindexResultBody(
    _ dict: [String: AnyCodableValue]
  ) throws -> RAGReindexResult {
    guard case .object(let res) = dict["result"] else {
      throw QVACError.transport(
        .decodingFailed("rag/reindex response missing `result` object"))
    }
    var reindexed = false
    if case .bool(let v) = res["reindexed"] { reindexed = v }
    var details: [String: AnyCodable]?
    if case .object(let d) = res["details"] {
      details = d.mapValues { AnyCodable($0) }
    }
    return RAGReindexResult(reindexed: reindexed, details: details)
  }

  private static func parseRagReindexEvent(_ value: AnyCodable) -> RAGReindexEvent? {
    guard case .object(let dict) = value.value else { return nil }

    if case .string(let t) = dict["type"], t == "rag:progress" {
      var stage = ""
      if case .string(let s) = dict["stage"] { stage = s }
      let current = intFrom(dict["current"]) ?? 0
      let total = intFrom(dict["total"]) ?? 0
      let timestamp: Double = {
        if case .double(let d) = dict["timestamp"] { return d }
        if case .int(let i) = dict["timestamp"] { return Double(i) }
        return 0
      }()
      return .progress(
        stage: stage, current: current, total: total, timestamp: timestamp)
    }

    if case .string(let t) = dict["type"], t == "rag",
      case .string(let op) = dict["operation"], op == "reindex"
    {
      do {
        try assertRagSuccessDict(dict, operation: "reindex")
        return .completed(try decodeReindexResultBody(dict))
      } catch {
        return nil
      }
    }
    return nil
  }

  /// Asserts `success: true` on any rag-reply envelope dict.
  /// Shared between RAG-core and RAG-admin operations.
  internal static func assertRagSuccessDict(
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

  /// Generic "did the rag operation succeed" check for void replies
  /// (closeWorkspace, deleteWorkspace, deleteEmbeddings).
  private static func assertRagOperationSuccess(
    _ response: AnyCodable,
    operation: String
  ) throws {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("rag/\(operation) response is not an object"))
    }
    try assertRagSuccessDict(dict, operation: operation)
  }
}
