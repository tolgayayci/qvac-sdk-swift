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

    init(
      streamCount: Int = 10,
      streamIntervalMs: UInt64 = 5,
      failInitConfig: Bool = false,
      initFailureMessage: String = "init config rejected by test peer",
      loadedModelId: String? = "test-model-abc"
    ) {
      self.streamCount = streamCount
      self.streamIntervalMs = streamIntervalMs
      self.failInitConfig = failInitConfig
      self.initFailureMessage = initFailureMessage
      self.loadedModelId = loadedModelId
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
}
