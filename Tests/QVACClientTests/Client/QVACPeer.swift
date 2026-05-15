import BareRPC
import Foundation

@testable import QVACClient

/// In-process peer that talks the QVAC JSON-envelope wire format — i.e.
/// dispatches on the incoming request's `type` field, just like the real
/// `@qvac/sdk` worker does. Lives entirely in the test bundle.
///
/// Behavior:
///   - `"heartbeat"` → reply `{ "type": "heartbeat", "number": <ts> }`
///   - `"loggingStream"` → open a response stream and emit
///     `Behavior.streamCount` `{ "index": N }` chunks at
///     `Behavior.streamIntervalMs` intervals, then close.
///   - anything else (e.g. `"__hang__"`) → never reply (used to drive
///     in-flight-cancel tests).
///
/// Mirrors the production wire model — JSON envelope dispatched by
/// `type` — so QVACClient tests exercise the same code paths the real
/// worker will hit.
final class QVACPeer: @unchecked Sendable {
  struct Behavior: Sendable {
    var streamCount: Int = 10
    var streamIntervalMs: UInt64 = 5
    /// When `true`, the peer replies `{success: false, error: ...}` to
    /// `__init_config` — exercises the YK-198 failure path.
    var failInitConfig: Bool = false
    /// Optional error message attached when `failInitConfig` is true.
    var initFailureMessage: String = "init config rejected by test peer"
    /// ModelId returned by `loadModel` requests. Set per-test for the
    /// happy path; if `nil`, `loadModel` replies with an SDK error
    /// frame (`code: modelNotFound`).
    var loadedModelId: String? = "test-model-abc"
    /// Documents the rag search stub returns hits for, in order. Each
    /// element produces one hit with descending score
    /// (`1.0 - 0.1*index`). YK-212.
    var ragSeededDocuments: [String] = []
    /// Workspaces the rag listWorkspaces stub returns. YK-213.
    var ragWorkspaces: [WorkspaceEntry] = []

    /// Workspace entry returned by the listWorkspaces stub.
    struct WorkspaceEntry: Sendable, Equatable {
      let name: String
      let open: Bool
      init(name: String, open: Bool = true) {
        self.name = name
        self.open = open
      }
    }

    init(
      streamCount: Int = 10,
      streamIntervalMs: UInt64 = 5,
      failInitConfig: Bool = false,
      initFailureMessage: String = "init config rejected by test peer",
      loadedModelId: String? = "test-model-abc",
      ragSeededDocuments: [String] = [],
      ragWorkspaces: [WorkspaceEntry] = []
    ) {
      self.streamCount = streamCount
      self.streamIntervalMs = streamIntervalMs
      self.failInitConfig = failInitConfig
      self.initFailureMessage = initFailureMessage
      self.loadedModelId = loadedModelId
      self.ragSeededDocuments = ragSeededDocuments
      self.ragWorkspaces = ragWorkspaces
    }
  }

  private let transport: any Transport
  private let behavior: Behavior
  private var rpc: BareRPC.RPC?
  private var delegate: PeerDelegate?
  private var readTask: Task<Void, Never>?

  /// Records every cancel-runId the peer has been asked about. Used
  /// by YK-200 tests to assert worker-side cancel propagation.
  var cancelledRunIds: [String] {
    get async { await delegate?.cancelledRunIds ?? [] }
  }

  init(transport: any Transport, behavior: Behavior = .init()) {
    self.transport = transport
    self.behavior = behavior
  }

  func start() async throws {
    try await transport.open()
    let delegate = PeerDelegate(transport: transport, behavior: behavior)
    let rpc = BareRPC.RPC(delegate: delegate)
    self.delegate = delegate
    self.rpc = rpc
    delegate.rpc = rpc

    let transportRef = transport
    readTask = Task {
      do {
        for try await chunk in transportRef.incoming {
          if Task.isCancelled { break }
          await rpc.receive(chunk)
        }
      } catch {}
    }
  }

  func close() async {
    readTask?.cancel()
    readTask = nil
    rpc = nil
    delegate = nil
    await transport.close()
  }
}

/// Note: the actor-isolated accessor on `QVACPeer` reads through to
/// `cancelStore.value` so tests can `await peer.cancelledRunIds`.
private actor CancelStore {
  private(set) var value: [String] = []
  func append(_ id: String) { value.append(id) }
}

private final class PeerDelegate: BareRPC.RPCDelegate, @unchecked Sendable {
  let transport: any Transport
  let behavior: QVACPeer.Behavior
  weak var rpc: BareRPC.RPC?

  private let cancelStore = CancelStore()
  var cancelledRunIds: [String] {
    get async { await cancelStore.value }
  }

  private let outboxContinuation: AsyncStream<Data>.Continuation
  private let outboxTask: Task<Void, Never>

  init(transport: any Transport, behavior: QVACPeer.Behavior) {
    self.transport = transport
    self.behavior = behavior
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    self.outboxContinuation = continuation
    self.outboxTask = Task { [transport] in
      for await data in stream {
        try? await transport.send(data)
      }
    }
  }

  deinit {
    outboxContinuation.finish()
    outboxTask.cancel()
  }

  func rpc(_ rpc: BareRPC.RPC, send data: Data) {
    outboxContinuation.yield(data)
  }

  func rpc(_ rpc: BareRPC.RPC, didReceiveRequest request: BareRPC.IncomingRequest) async throws {
    let body = decodeBody(request.data)
    let type = (body?["type"] as? String) ?? ""

    switch type {
    case "cancel":
      // YK-200 — record the runId so tests can verify cancel
      // propagation, then reply with a CancelResponse-shaped success.
      if let runId = body?["runId"] as? String {
        await cancelStore.append(runId)
      }
      let reply: [String: Any] = [
        "type": "cancel",
        "success": true,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
      await request.reply(data)

    case "translate":
      // YK-205. Stream partial fragments, then a final {text:...}.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      let final: [String: Any] = ["text": "Bonjour"]
      let data = (try? JSONSerialization.data(withJSONObject: final)) ?? Data()
      var withNewline = data
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "diffusionStream":
      // YK-205. Three progress events then a final completed image.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      for i in 1...3 {
        let body: [String: Any] = ["step": i, "totalSteps": 3]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
      }
      let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG magic
      let finalBody: [String: Any] = [
        "completed": ["image": pngBytes.base64EncodedString()]
      ]
      let finalData = (try? JSONSerialization.data(withJSONObject: finalBody)) ?? Data()
      var withNewline = finalData
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "ocrStream":
      // YK-205. Emit a single {text, regions} chunk and end.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      let body: [String: Any] = [
        "text": "QVAC ROCKS",
        "regions": [
          ["text": "QVAC", "bbox": [10.0, 20.0, 80.0, 30.0], "confidence": 0.98],
          ["text": "ROCKS", "bbox": [100.0, 20.0, 90.0, 30.0], "confidence": 0.97],
        ],
      ]
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      var withNewline = data
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "downloadAsset":
      // YK-205. Three progress events + completed.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      for done in [256, 512, 1024] {
        let body: [String: Any] = ["bytesDone": done, "bytesTotal": 1024]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
      }
      let finalBody: [String: Any] = ["localPath": "/tmp/qvac-test-asset.bin"]
      let finalData = (try? JSONSerialization.data(withJSONObject: finalBody)) ?? Data()
      var withNewline = finalData
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "transcribe":
      // YK-204. Open response stream and emit a couple of partial
      // transcripts then a terminal final.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      let partials = ["hello", "hello world"]
      for p in partials {
        let body: [String: Any] = ["partial": p]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
      }
      let finalBody: [String: Any] = [
        "final": ["text": "hello world", "segments": []]
      ]
      let finalData = (try? JSONSerialization.data(withJSONObject: finalBody)) ?? Data()
      var withNewline = finalData
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "textToSpeech":
      // YK-204. Emit 3 audio chunks (stub PCM bytes).
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      let chunks = [
        Data([0x01, 0x02, 0x03, 0x04]),
        Data([0x05, 0x06, 0x07, 0x08]),
        Data([0x09, 0x0A, 0x0B, 0x0C]),
      ]
      for chunk in chunks {
        let body: [String: Any] = ["audio": chunk.base64EncodedString()]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
      }
      await stream.end()

    case "rag":
      // YK-212. Sub-dispatch on `operation`. Mirrors the
      // discriminated-union shape in @qvac/sdk's rag schema.
      let operation = (body?["operation"] as? String) ?? ""
      switch operation {
      case "chunk":
        // Stub: 1 chunk per input character group of length 4.
        let docs = Self.stringArray(body?["documents"]) ?? []
        var chunks: [[String: Any]] = []
        for (di, doc) in docs.enumerated() {
          let strides = stride(from: 0, to: doc.count, by: 4)
          for (ci, start) in strides.enumerated() {
            let from = doc.index(doc.startIndex, offsetBy: start)
            let to = doc.index(from, offsetBy: min(4, doc.count - start))
            chunks.append([
              "id": "doc-\(di)-chunk-\(ci)",
              "content": String(doc[from..<to]),
            ])
          }
        }
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "chunk",
          "success": true,
          "chunks": chunks,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "search":
        // Stub: returns one hit per input document the test seeded
        // via behavior.ragSeededDocuments. Score = 1.0 - 0.1*index.
        let topK = (body?["topK"] as? Int) ?? 5
        let seeded = behavior.ragSeededDocuments
        let hits: [[String: Any]] = seeded.prefix(topK).enumerated().map { i, doc in
          [
            "id": "doc-\(i)",
            "content": doc,
            "score": 1.0 - 0.1 * Double(i),
          ]
        }
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "search",
          "success": true,
          "results": hits,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "ingest":
        let withProgress = (body?["withProgress"] as? Bool) ?? false
        let docs = Self.stringArray(body?["documents"]) ?? []
        let workspace = (body?["workspace"] as? String) ?? "default"
        let processed: [[String: Any]] = docs.enumerated().map { i, _ in
          ["status": "fulfilled", "id": "ingest-\(i)"]
        }
        let final: [String: Any] = [
          "type": "rag",
          "operation": "ingest",
          "success": true,
          "processed": processed,
          "droppedIndices": [Int](),
        ]
        if withProgress {
          guard let stream = await request.createResponseStream() else {
            await request.reject("could not open stream", code: "E_STREAM", errno: -1)
            return
          }
          // Three progress frames then the final reply.
          let stages = ["chunking", "embedding", "indexing"]
          for (i, stage) in stages.enumerated() {
            let body: [String: Any] = [
              "type": "rag:progress",
              "operation": "ingest",
              "workspace": workspace,
              "stage": stage,
              "current": (i + 1) * docs.count / stages.count,
              "total": docs.count,
              "timestamp": Date().timeIntervalSince1970 * 1000.0,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            var withNewline = data
            withNewline.append(0x0A)
            await stream.write(withNewline)
          }
          let finalData = (try? JSONSerialization.data(withJSONObject: final)) ?? Data()
          var withNewline = finalData
          withNewline.append(0x0A)
          await stream.write(withNewline)
          await stream.end()
        } else {
          let data = (try? JSONSerialization.data(withJSONObject: final)) ?? Data()
          await request.reply(data)
        }

      case "saveEmbeddings":
        // YK-213. Accept the documents and reply with one fulfilled
        // entry per input, echoing the input id.
        let docs = (body?["documents"] as? [[String: Any]]) ?? []
        let processed: [[String: Any]] = docs.enumerated().map { i, d in
          let id = (d["id"] as? String) ?? "saved-\(i)"
          return ["status": "fulfilled", "id": id]
        }
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "saveEmbeddings",
          "success": true,
          "processed": processed,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "deleteEmbeddings":
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "deleteEmbeddings",
          "success": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "reindex":
        let withProgress = (body?["withProgress"] as? Bool) ?? false
        let workspace = (body?["workspace"] as? String) ?? "default"
        let final: [String: Any] = [
          "type": "rag",
          "operation": "reindex",
          "success": true,
          "result": ["reindexed": true, "details": ["chunks": 42]],
        ]
        if withProgress {
          guard let stream = await request.createResponseStream() else {
            await request.reject("could not open stream", code: "E_STREAM", errno: -1)
            return
          }
          for (i, stage) in ["preparing", "rebuilding", "swapping"].enumerated() {
            let body: [String: Any] = [
              "type": "rag:progress",
              "operation": "reindex",
              "workspace": workspace,
              "stage": stage,
              "current": i + 1,
              "total": 3,
              "timestamp": Date().timeIntervalSince1970 * 1000.0,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            var withNewline = data
            withNewline.append(0x0A)
            await stream.write(withNewline)
          }
          let finalData = (try? JSONSerialization.data(withJSONObject: final)) ?? Data()
          var withNewline = finalData
          withNewline.append(0x0A)
          await stream.write(withNewline)
          await stream.end()
        } else {
          let data = (try? JSONSerialization.data(withJSONObject: final)) ?? Data()
          await request.reply(data)
        }

      case "listWorkspaces":
        let workspaces: [[String: Any]] = behavior.ragWorkspaces.map {
          ["name": $0.name, "open": $0.open]
        }
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "listWorkspaces",
          "success": true,
          "workspaces": workspaces,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "closeWorkspace":
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "closeWorkspace",
          "success": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      case "deleteWorkspace":
        let reply: [String: Any] = [
          "type": "rag",
          "operation": "deleteWorkspace",
          "success": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)

      default:
        let reply: [String: Any] = [
          "type": "rag",
          "operation": operation,
          "success": false,
          "error": "test peer: unimplemented rag operation \(operation)",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        await request.reply(data)
      }

    case "pluginInvoke":
      // YK-214. Echo the `params` back as `result` so generic
      // round-trip tests can pass any Encodable shape and get the
      // same shape back. The `handler` field is recorded on the
      // behavior so tests can assert the routing.
      let handler = (body?["handler"] as? String) ?? ""
      let params = body?["params"] as Any?  // arbitrary shape
      let reply: [String: Any] = [
        "type": "pluginInvoke",
        "result": Self.routePluginEcho(
          handler: handler, params: params, behavior: behavior),
      ]
      let data = (try? JSONSerialization.data(
        withJSONObject: reply, options: [.fragmentsAllowed])) ?? Data()
      await request.reply(data)

    case "pluginInvokeStream":
      // YK-214. Emit `behavior.streamCount` chunks, then a terminal
      // chunk with `done: true`. Each chunk's `result` is
      // `{index: N, echoed: <params>}`.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      let params = body?["params"] as Any?
      let total = behavior.streamCount
      for i in 0..<total {
        var resultDict: [String: Any] = ["index": i]
        if let params { resultDict["echoed"] = params }
        let body: [String: Any] = [
          "type": "pluginInvokeStream",
          "result": resultDict,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
      }
      // Terminal frame with done:true.
      let finalBody: [String: Any] = [
        "type": "pluginInvokeStream",
        "result": ["index": total, "done": true],
        "done": true,
      ]
      let finalData = (try? JSONSerialization.data(withJSONObject: finalBody)) ?? Data()
      var withNewline = finalData
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "embed":
      // YK-203. Reply with `{type:"embed", success: true, embedding: [[...],
      // [...]]}`. The stub vector is just `[Double(i)]` per input — enough
      // to verify the shape mapping (single-vector vs batch).
      let texts = (body?["text"] as? [Any]) ?? []
      let vectors: [[Double]] = texts.enumerated().map { i, _ in
        [Double(i), Double(i) * 0.5, Double(i) * 0.25]
      }
      let reply: [String: Any] = [
        "type": "embed",
        "success": true,
        "embedding": vectors,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
      await request.reply(data)

    case "completionStream":
      // YK-202. Emit `behavior.streamCount` `{token: "tok-<i>"}` chunks
      // followed by a terminal `{finish: "stop", stats: {...}}`.
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      for i in 0..<behavior.streamCount {
        let chunk: [String: Any] = ["token": "tok-\(i)"]
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
        if behavior.streamIntervalMs > 0 {
          try? await Task.sleep(nanoseconds: behavior.streamIntervalMs * 1_000_000)
        }
      }
      let finishBody: [String: Any] = [
        "finish": "stop",
        "stats": [
          "generatedTokens": Double(behavior.streamCount),
          "totalTimeMs": Double(behavior.streamCount * 5),
        ],
      ]
      let finishData = (try? JSONSerialization.data(withJSONObject: finishBody)) ?? Data()
      var withNewline = finishData
      withNewline.append(0x0A)
      await stream.write(withNewline)
      await stream.end()

    case "loadModel":
      // YK-201. Reply with `{modelId, type: "loadModel"}` on the
      // happy path; emit a wire SDK error frame (code 52001 =
      // MODEL_NOT_FOUND) when `loadedModelId` is nil.
      let body: [String: Any]
      if let id = behavior.loadedModelId {
        body = ["type": "loadModel", "modelId": id]
      } else {
        body = [
          "type": "error",
          "code": 52002,  // QVACServerErrorCode.modelNotFound
          "name": "MODEL_NOT_FOUND",
          "message": "test peer: loadedModelId is nil",
        ]
      }
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      await request.reply(data)

    case "unloadModel":
      // YK-201. Reply with the UnloadModelResponse shape
      // (`{type: "unloadModel", success: true, modelId: <echoed>}`).
      let runIdEcho = body?["modelId"] as? String ?? ""
      let reply: [String: Any] = [
        "type": "unloadModel",
        "success": true,
        "modelId": runIdEcho,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
      await request.reply(data)

    case "__init_config":
      // YK-198 handshake. Test peer ignores the config payload itself
      // (we don't validate worker-side config in unit tests) and
      // replies success unless `failInitConfig` is set.
      let body: [String: Any]
      if behavior.failInitConfig {
        body = ["success": false, "error": behavior.initFailureMessage]
      } else {
        body = ["success": true]
      }
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      await request.reply(data)

    case "heartbeat":
      let body: [String: Any] = [
        "type": "heartbeat",
        "number": Date().timeIntervalSince1970,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      await request.reply(data)

    case "loggingStream":
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      for i in 0..<behavior.streamCount {
        let chunk: [String: Any] = ["index": i]
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)
        await stream.write(withNewline)
        if behavior.streamIntervalMs > 0 {
          try? await Task.sleep(nanoseconds: behavior.streamIntervalMs * 1_000_000)
        }
      }
      await stream.end()

    default:
      // Hang: never reply. Used by VT-6 to test in-flight settlement
      // on `close()`.
      return
    }
  }

  func rpc(_ rpc: BareRPC.RPC, didReceiveEvent event: BareRPC.IncomingEvent) async {}
  func rpc(_ rpc: BareRPC.RPC, didFailWith error: Error) {}

  private func decodeBody(_ data: Data?) -> [String: Any]? {
    guard let data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  /// `documents` is either `String` or `[String]` on the wire. This
  /// always returns `[String]` for the rag test stubs.
  static func stringArray(_ value: Any?) -> [String]? {
    if let arr = value as? [String] { return arr }
    if let one = value as? String { return [one] }
    return nil
  }

  /// Compute the response body for a `pluginInvoke` request.
  /// Defaults to echoing `params` so generic-type round-trip tests
  /// see the same shape they sent. Special handlers wedge in
  /// alternate behaviors for specific test scenarios.
  static func routePluginEcho(
    handler: String,
    params: Any?,
    behavior: QVACPeer.Behavior
  ) -> Any {
    switch handler {
    case "uppercase":
      // If params is a String, return its uppercase. Used by the
      // typed-args round-trip test.
      if let s = params as? String { return s.uppercased() }
      if let dict = params as? [String: Any], let text = dict["text"] as? String {
        return ["text": text.uppercased()]
      }
      return params ?? NSNull()
    case "fail":
      // Surface an error by returning a `success: false`-like shape.
      // (Plugin failures land via the standard error path; this is
      // a soft-failure echo for client-side decoding tests.)
      return ["failed": true]
    default:
      // Default: echo params back. Falls back to `null` if params
      // were omitted (no-args case).
      return params ?? NSNull()
    }
  }
}
