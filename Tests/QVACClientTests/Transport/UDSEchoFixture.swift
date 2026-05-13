#if canImport(Network)
  import Foundation
  import Network

  /// In-process Unix-socket echo server used by `UDSTransportTest`.
  ///
  /// Spawns a `NWListener` on a temp socket path; every inbound connection
  /// reads chunks and echoes them straight back. Pure Swift — no `socat` or
  /// other external binary required, which keeps CI portable.
  final class UDSEchoFixture: @unchecked Sendable {
    let socketPath: String
    private let listener: NWListener
    private let queue: DispatchQueue

    init() throws {
      let tmp = NSTemporaryDirectory()
      let name = "qvac-test-\(UUID().uuidString.prefix(8)).sock"
      let path = (tmp as NSString).appendingPathComponent(name)
      self.socketPath = path

      // Clear stale path if present from a previous run.
      try? FileManager.default.removeItem(atPath: path)

      let endpoint = NWEndpoint.unix(path: path)
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = endpoint

      let listener = try NWListener(using: params)
      self.listener = listener
      self.queue = DispatchQueue(
        label: "qvac.uds.echo.\(UUID().uuidString.prefix(8))",
        qos: .userInitiated)

      let q = self.queue
      listener.newConnectionHandler = { connection in
        connection.start(queue: q)
        UDSEchoFixture.echoLoop(connection)
      }

      let readyExpectation = DispatchSemaphore(value: 0)
      listener.stateUpdateHandler = { state in
        if case .ready = state {
          readyExpectation.signal()
        }
      }
      listener.start(queue: queue)
      _ = readyExpectation.wait(timeout: .now() + .seconds(5))
    }

    private static func echoLoop(_ connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, isComplete, error in
        if let data, !data.isEmpty {
          connection.send(content: data, completion: .contentProcessed { _ in })
        }
        if isComplete || error != nil {
          connection.cancel()
        } else {
          echoLoop(connection)
        }
      }
    }

    func stop() {
      listener.cancel()
      try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit { stop() }
  }
#endif
