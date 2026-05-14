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

    init(
      streamCount: Int = 10,
      streamIntervalMs: UInt64 = 5,
      failInitConfig: Bool = false,
      initFailureMessage: String = "init config rejected by test peer"
    ) {
      self.streamCount = streamCount
      self.streamIntervalMs = streamIntervalMs
      self.failInitConfig = failInitConfig
      self.initFailureMessage = initFailureMessage
    }
  }

  private let transport: any Transport
  private let behavior: Behavior
  private var rpc: BareRPC.RPC?
  private var delegate: PeerDelegate?
  private var readTask: Task<Void, Never>?

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

private final class PeerDelegate: BareRPC.RPCDelegate, @unchecked Sendable {
  let transport: any Transport
  let behavior: QVACPeer.Behavior
  weak var rpc: BareRPC.RPC?

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
    let type = decodeType(request.data) ?? ""

    switch type {
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

  private func decodeType(_ data: Data?) -> String? {
    guard let data,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      return nil
    }
    return type
  }
}
