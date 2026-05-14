#if canImport(Network) && !os(iOS)
  import Foundation

  @testable import QVACClient

  /// YK-208 — spawns `Tests/Fixtures/qvac-worker/` as a subprocess
  /// running the **real** `@qvac/sdk` Bare worker. Production
  /// topology: Swift opens the UDS server first, worker connects
  /// in as IPC client (`createIPCClient` in `worker-core.js`).
  ///
  /// Flow:
  /// 1. Resolve the fixture dir + Bare binary; fail-fast with a
  ///    clear remedy if `npm install` hasn't been run.
  /// 2. Allocate a tmp socket path.
  /// 3. Open `UDSServer` on it (listener is ready).
  /// 4. Spawn `bare worker.mjs '{"QVAC_IPC_SOCKET_PATH": "..."}'`.
  /// 5. Wait for `server.accept()` — that's the ready signal (the
  ///    worker has connected, the SDK has called `createIPCClient`,
  ///    and the wire is up).
  /// 6. Expose the accepted `Transport` for `RPCBridge` to use.
  ///
  /// Teardown sends SIGTERM (which triggers @qvac/sdk's
  /// `shutdownBareDirectWorker` cleanup path) and removes the
  /// socket file.
  final class QVACWorkerHarness: @unchecked Sendable {
    let socketPath: String
    private(set) var transport: (any Transport)?
    private let server: UDSServer
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe

    init(
      acceptTimeout: TimeInterval = 30.0
    ) async throws {
      let fixtureDir = Self.fixtureDirectory
      let bareBinary = fixtureDir.appendingPathComponent("node_modules/.bin/bare")
      let workerScript = fixtureDir.appendingPathComponent("worker.mjs")

      guard FileManager.default.isExecutableFile(atPath: bareBinary.path) else {
        throw HarnessError.fixtureNotInstalled(
          path: bareBinary.path,
          remedy: "Run `npm install` in Tests/Fixtures/qvac-worker/")
      }
      guard FileManager.default.fileExists(atPath: workerScript.path) else {
        throw HarnessError.fixtureNotInstalled(
          path: workerScript.path, remedy: "worker.mjs is missing")
      }

      let tmp = NSTemporaryDirectory() as NSString
      let socketName = "qvac-worker-\(UUID().uuidString.prefix(8)).sock"
      self.socketPath = tmp.appendingPathComponent(socketName)
      try? FileManager.default.removeItem(atPath: socketPath)

      // Open the UDS server BEFORE spawning the worker — the
      // worker calls connect() immediately on startup.
      let server = UDSServer(socketPath: socketPath)
      try await server.listen()
      self.server = server

      // Spawn the worker. argv[2] is the JSON config the SDK's
      // env.js reads (it parses argv[2] as JSON, ignores env vars
      // for this — see @qvac/sdk/dist/server/env.js initEnv()).
      let proc = Process()
      proc.executableURL = bareBinary
      let configJSON = #"{"QVAC_IPC_SOCKET_PATH": "\#(socketPath)"}"#
      proc.arguments = [workerScript.path, configJSON]
      proc.currentDirectoryURL = fixtureDir

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      proc.standardOutput = stdoutPipe
      proc.standardError = stderrPipe
      proc.standardInput = Pipe()

      self.process = proc
      self.stdoutPipe = stdoutPipe
      self.stderrPipe = stderrPipe

      do {
        try proc.run()
      } catch {
        await server.close()
        throw HarnessError.spawnFailed(error)
      }

      // Wait for the worker to connect. If the process exits
      // before connecting, surface the stderr for diagnosis.
      do {
        let transport = try await server.accept(timeout: acceptTimeout)
        self.transport = transport
      } catch {
        if !proc.isRunning {
          let err = drainStderr()
          await server.close()
          throw HarnessError.processExitedEarly(
            code: proc.terminationStatus, stderr: err)
        }
        let err = drainStderr()
        // Worker is still running but didn't connect — likely
        // listener never became ready, or the worker mis-routed.
        proc.terminate()
        await server.close()
        throw HarnessError.acceptFailed(
          underlying: error, stderr: err)
      }
    }

    func stop() async {
      if process.isRunning {
        if let stdin = process.standardInput as? Pipe {
          try? stdin.fileHandleForWriting.close()
        }
        // Brief grace for @qvac/sdk's shutdown handlers to run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
      await server.close()
      transport = nil
    }

    var stderrLog: String {
      drainStderr()
    }

    private func drainStderr() -> String {
      let data = stderrPipe.fileHandleForReading.availableData
      return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - errors

    enum HarnessError: Error, CustomStringConvertible {
      case fixtureNotInstalled(path: String, remedy: String)
      case spawnFailed(any Error)
      case processExitedEarly(code: Int32, stderr: String)
      case acceptFailed(underlying: any Error, stderr: String)

      var description: String {
        switch self {
        case .fixtureNotInstalled(let path, let remedy):
          return "QVACWorkerHarness: missing \(path). \(remedy)"
        case .spawnFailed(let err):
          return "QVACWorkerHarness: failed to spawn bare process: \(err)"
        case .processExitedEarly(let code, let err):
          return
            "QVACWorkerHarness: worker exited (code=\(code)) before connecting.\nstderr:\n\(err)"
        case .acceptFailed(let err, let stderr):
          return
            "QVACWorkerHarness: accept() failed: \(err)\nworker stderr:\n\(stderr)"
        }
      }
    }

    // MARK: - directory lookup

    private static var fixtureDirectory: URL {
      let thisFile = URL(fileURLWithPath: #filePath)
      let root = thisFile
        .deletingLastPathComponent()  // Helpers/
        .deletingLastPathComponent()  // QVACClientTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // <repo root>
      return root.appendingPathComponent("Tests/Fixtures/qvac-worker")
    }
  }
#endif
