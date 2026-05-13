#if canImport(Network) && !os(iOS)
  import Foundation

  /// Spawns the `Tests/Fixtures/ping-server/` Bare worker as a subprocess and
  /// exposes a single Unix-domain-socket path that the test can connect to.
  ///
  /// The harness:
  /// 1. Locates the fixture directory by walking up from `#filePath` to the
  ///    package root, then into `Tests/Fixtures/ping-server/`.
  /// 2. Picks a unique socket path under `NSTemporaryDirectory()`.
  /// 3. Spawns `node_modules/.bin/bare server.mjs <socket-path> [--debug]`.
  /// 4. Reads stdout until it sees `FIXTURE_READY <path>` (the fixture's
  ///    single source of truth for "listening" — more reliable than
  ///    poll-statting the inode).
  /// 5. On `stop()`, sends `SIGTERM`, awaits exit, removes the socket.
  ///
  /// `pnpm install` is the responsibility of the test author or CI — the
  /// harness fails fast with a clear message if `node_modules/.bin/bare` is
  /// missing.
  final class PingServerHarness: @unchecked Sendable {
    let socketPath: String
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let readyDeadlineSeconds: TimeInterval

    private(set) var stderrLog: String = ""

    /// Boots the fixture and waits for its `FIXTURE_READY` line. Throws if
    /// the process can't be spawned, the binary is missing, or the readiness
    /// signal doesn't arrive within `readyTimeoutSeconds`.
    init(debug: Bool = false, readyTimeoutSeconds: TimeInterval = 5.0) throws {
      self.readyDeadlineSeconds = readyTimeoutSeconds

      let fixtureDir = PingServerHarness.fixtureDirectory
      let bareBinary = fixtureDir.appendingPathComponent("node_modules/.bin/bare")
      let serverScript = fixtureDir.appendingPathComponent("server.mjs")

      guard FileManager.default.isExecutableFile(atPath: bareBinary.path) else {
        throw HarnessError.fixtureNotInstalled(
          path: bareBinary.path,
          remedy: "Run `npm install` in Tests/Fixtures/ping-server/")
      }
      guard FileManager.default.fileExists(atPath: serverScript.path) else {
        throw HarnessError.fixtureNotInstalled(
          path: serverScript.path,
          remedy: "server.mjs is missing from the fixture")
      }

      let tmp = NSTemporaryDirectory() as NSString
      let socketName = "qvac-ping-\(UUID().uuidString.prefix(8)).sock"
      self.socketPath = tmp.appendingPathComponent(socketName)
      // Pre-clean any stale inode at the chosen path.
      try? FileManager.default.removeItem(atPath: self.socketPath)

      let proc = Process()
      proc.executableURL = bareBinary
      var args = [serverScript.path, self.socketPath]
      if debug { args.append("--debug") }
      proc.arguments = args
      proc.currentDirectoryURL = fixtureDir

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      proc.standardOutput = stdoutPipe
      proc.standardError = stderrPipe
      proc.standardInput = Pipe()  // open so the fixture's stdin EOF shutdown trigger fires on stop()

      self.process = proc
      self.stdoutPipe = stdoutPipe
      self.stderrPipe = stderrPipe

      try proc.run()

      // Block until FIXTURE_READY appears on stdout, or we hit the deadline.
      try waitForReady()
    }

    func stop() {
      if process.isRunning {
        // Closing stdin triggers the fixture's graceful-shutdown branch (via
        // its `io.in.on('end', ...)` handler). Fall back to SIGTERM if it's
        // still alive after a short grace window.
        if let stdin = process.standardInput as? Pipe {
          try? stdin.fileHandleForWriting.close()
        }
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
      try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit { stop() }

    // MARK: - readiness

    enum HarnessError: Error, CustomStringConvertible {
      case fixtureNotInstalled(path: String, remedy: String)
      case readinessTimedOut(stderr: String)
      case processExitedEarly(code: Int32, stderr: String)

      var description: String {
        switch self {
        case .fixtureNotInstalled(let path, let remedy):
          return "PingServerHarness: missing \(path). \(remedy)"
        case .readinessTimedOut(let err):
          return "PingServerHarness: FIXTURE_READY not seen within deadline.\nstderr:\n\(err)"
        case .processExitedEarly(let code, let err):
          return "PingServerHarness: fixture exited (code=\(code)) before ready.\nstderr:\n\(err)"
        }
      }
    }

    private func waitForReady() throws {
      let handle = stdoutPipe.fileHandleForReading
      let deadline = Date().addingTimeInterval(readyDeadlineSeconds)
      var buffer = ""
      while Date() < deadline {
        if !process.isRunning {
          let err = drainStderr()
          throw HarnessError.processExitedEarly(code: process.terminationStatus, stderr: err)
        }
        // Non-blocking-ish read: availableData returns 0 if EOF, otherwise
        // the bytes currently available without further reads.
        let chunk = handle.availableData
        if chunk.isEmpty {
          Thread.sleep(forTimeInterval: 0.025)
          continue
        }
        if let text = String(data: chunk, encoding: .utf8) {
          buffer += text
          if buffer.contains("FIXTURE_READY \(socketPath)") {
            return
          }
        }
      }
      let err = drainStderr()
      throw HarnessError.readinessTimedOut(stderr: err)
    }

    private func drainStderr() -> String {
      let data = stderrPipe.fileHandleForReading.availableData
      let text = String(data: data, encoding: .utf8) ?? ""
      stderrLog += text
      return stderrLog
    }

    // MARK: - directory lookup

    private static var fixtureDirectory: URL {
      // #filePath resolves to .../Tests/QVACClientTests/Helpers/PingServerHarness.swift.
      // Walk up to the package root, then descend into Tests/Fixtures/ping-server/.
      let thisFile = URL(fileURLWithPath: #filePath)
      let root = thisFile
        .deletingLastPathComponent()  // Helpers/
        .deletingLastPathComponent()  // QVACClientTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // <repo root>
      return root.appendingPathComponent("Tests/Fixtures/ping-server")
    }
  }
#endif
