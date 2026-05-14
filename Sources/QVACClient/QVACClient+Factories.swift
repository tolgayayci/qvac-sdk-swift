#if canImport(Network) && !os(iOS)
  import Foundation

  /// Convenience factories that handle the worker-spawn + transport-
  /// wire-up + connect+init dance, returning a ready-to-use
  /// `QVACClient`. Two flavors:
  ///
  /// - `spawning(...)` — desktop / server / CLI. Opens a UDS server,
  ///   spawns `bare worker.mjs` pointing at it, awaits the worker's
  ///   IPC-client connection, runs `__init_config`. Ships today.
  ///   Matches the production topology (`@qvac/sdk` worker is the
  ///   IPC client; Swift is the server).
  /// - `embedded(...)` — iOS / macOS app. In-process Bare worklet via
  ///   `bare-kit-swift` and a bundled `qvac-worker.bundle` SPM
  ///   resource. **Stubbed today** — wired in YK-206 (`BareKitIPCTransport`).
  ///   See `docs/embedding.md`.
  extension QVACClient {

    /// Spawn the worker as a child process and connect over UDS.
    ///
    /// Caller provides paths to:
    /// - `bareBinary`: the Bare runtime binary (typically
    ///   `<workerDir>/node_modules/.bin/bare` after `npm install`).
    /// - `workerScript`: the `.mjs` entry that imports
    ///   `@qvac/sdk/dist/server/worker.js`. See
    ///   `Tests/Fixtures/qvac-worker/worker.mjs` for the canonical
    ///   one-liner.
    ///
    /// Returns a ready-to-use `QVACClient`. `__init_config` has
    /// already run when this returns.
    ///
    /// The caller owns lifecycle — when `close()` is called on the
    /// returned client, the worker subprocess is also terminated.
    public static func spawning(
      bareBinary: URL,
      workerScript: URL,
      initConfig: QVACInitConfig? = nil,
      runtimeContext: QVACRuntimeContext? = QVACRuntimeContext(),
      acceptTimeout: TimeInterval = 30.0
    ) async throws -> SpawnedClient {
      let socketPath = Self.makeTmpSocketPath()
      let server = UDSServer(socketPath: socketPath)
      try await server.listen()

      // Spawn the worker after listen() so the socket exists.
      let process = Process()
      process.executableURL = bareBinary
      let configJSON = #"{"QVAC_IPC_SOCKET_PATH": "\#(socketPath)"}"#
      process.arguments = [workerScript.path, configJSON]
      process.currentDirectoryURL = workerScript.deletingLastPathComponent()

      // Capture stdout/stderr so a failed spawn surfaces a readable
      // message rather than a black box. SpawnedClient retains them.
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.standardInput = Pipe()

      do {
        try process.run()
      } catch {
        await server.close()
        throw QVACError.transport(.framingError(
          "QVACClient.spawning: failed to start `bare`: \(error)"))
      }

      // Wait for the worker to connect.
      let transport: any Transport
      do {
        transport = try await server.accept(timeout: acceptTimeout)
      } catch {
        process.terminate()
        await server.close()
        let stderr = String(
          data: stderrPipe.fileHandleForReading.availableData,
          encoding: .utf8) ?? ""
        throw QVACError.transport(.framingError(
          "QVACClient.spawning: worker didn't connect: \(error)" +
          (stderr.isEmpty ? "" : "\nworker stderr:\n\(stderr)")))
      }

      let client = QVACClient(
        transport: transport,
        initConfig: initConfig,
        runtimeContext: runtimeContext)

      do {
        try await client.connect()
      } catch {
        process.terminate()
        await server.close()
        throw error
      }

      return SpawnedClient(
        client: client, process: process, server: server)
    }

    /// In-process Bare worklet via `BareKitIPCTransport` (YK-206).
    /// Loads a `bare-pack`-bundled QVAC worker (the
    /// `qvac-worker.bundle` SPM resource produced by the second
    /// half of YK-207) and connects to it without any subprocess.
    ///
    /// **Half-wired today.** The `BareKitIPCTransport` exists and
    /// works as a `Transport`; the missing piece is the bundled
    /// `qvac-worker.bundle` SPM resource that gives it a real
    /// QVAC worker to host. Until that ships, this throws — but
    /// the M3 example-app + DocC tutorials can already target the
    /// signature. Pass a `bundleSource: Data` explicitly to
    /// `BareKitIPCTransport(filename:bundleSource:)` to skip this
    /// factory and run against your own bundle today.
    public static func embedded(
      initConfig: QVACInitConfig? = nil,
      runtimeContext: QVACRuntimeContext? = QVACRuntimeContext()
    ) async throws -> QVACClient {
      // Resolving the bundled qvac-worker.bundle is the next step:
      //   guard let bundleURL = Bundle.module.url(
      //     forResource: "qvac-worker", withExtension: "bundle") else { ... }
      //   let source = try Data(contentsOf: bundleURL)
      //   let transport = BareKitIPCTransport(
      //     filename: "qvac-worker", bundleSource: source)
      //   let client = QVACClient(
      //     transport: transport,
      //     initConfig: initConfig,
      //     runtimeContext: runtimeContext)
      //   try await client.connect()
      //   return client
      throw QVACError.transport(.framingError(
        "QVACClient.embedded() needs the qvac-worker.bundle SPM resource (YK-207 v2). " +
        "Today: construct BareKitIPCTransport(filename:bundleSource:) with your own " +
        "bare-pack-bundled .bundle, OR use QVACClient.spawning(bareBinary:workerScript:) " +
        "on macOS/Linux. See docs/barekit.md + docs/embedding.md."))
    }

    // MARK: - private

    private static func makeTmpSocketPath() -> String {
      let tmp = NSTemporaryDirectory() as NSString
      let name = "qvac-spawned-\(UUID().uuidString.prefix(8)).sock"
      let path = tmp.appendingPathComponent(name)
      try? FileManager.default.removeItem(atPath: path)
      return path
    }
  }

  /// `QVACClient` paired with the subprocess that hosts its worker
  /// and the `UDSServer` accepting that worker's IPC connection.
  /// Calling `close()` tears all three down in order: client →
  /// process → server → socket file.
  ///
  /// Returned by `QVACClient.spawning(...)`. Acts as a thin wrapper
  /// — forward `.client.heartbeat(...)` etc. to the underlying
  /// `QVACClient` directly; `SpawnedClient` only owns lifecycle.
  public final class SpawnedClient: @unchecked Sendable {
    public let client: QVACClient
    private let process: Process
    private let server: UDSServer
    private var didClose = false
    private let closeLock = NSLock()

    init(client: QVACClient, process: Process, server: UDSServer) {
      self.client = client
      self.process = process
      self.server = server
    }

    /// Tear down: close the QVACClient (which sends `__shutdown__`
    /// once YK's M2-RPC-CODEC adds that path; today it just closes
    /// the bridge), SIGTERM the worker, close the UDS server, remove
    /// the socket file.
    public func close() async {
      let alreadyClosed = closeLock.withLock { () -> Bool in
        if didClose { return true }
        didClose = true
        return false
      }
      if alreadyClosed { return }

      await client.close()
      if process.isRunning {
        if let stdin = process.standardInput as? Pipe {
          try? stdin.fileHandleForWriting.close()
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
      await server.close()
    }

    deinit {
      if !didClose {
        // Best-effort sync cleanup; the async close() above is the
        // documented teardown path. This catches deinit-without-close
        // (test leaks, scope-exit before close) so the subprocess
        // doesn't linger.
        if process.isRunning {
          process.terminate()
        }
      }
    }
  }

  // MARK: - NSLock helper

  extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
      lock()
      defer { unlock() }
      return try body()
    }
  }

#endif
