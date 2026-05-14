import Darwin
import Foundation
import Network

/// Server-side counterpart to `UDSTransport`. Opens a Unix domain
/// socket as a listener, accepts the first inbound connection, and
/// exposes the accepted connection as a `Transport`.
///
/// **Why a server-side transport.** The real QVAC Bare worker uses
/// `bare-net.connect(socketPath)` (see `@qvac/sdk` `worker-core.js` →
/// `createIPCClient`) — i.e. the worker is the IPC **client** that
/// connects OUT to a server-side socket the Swift host opens. In
/// production:
///
/// 1. Swift app opens `UDSServer` on a temp socket path.
/// 2. Swift spawns `bare worker.js '{"QVAC_IPC_SOCKET_PATH": "/tmp/..."}'`.
/// 3. Worker connects to the socket; `UDSServer.accept()` resolves.
/// 4. The accepted connection is wrapped as a `Transport` and
///    handed to `RPCBridge` / `QVACClient`.
///
/// **Why POSIX, not `NWListener`.** `NWListener` doesn't natively
/// support `AF_UNIX` endpoints — setting `requiredLocalEndpoint`
/// to `.unix(path:)` returns `EINVAL` from the listener. We use
/// BSD sockets (`socket`/`bind`/`listen`/`accept`) directly, then
/// hand the accepted file descriptor to `NWConnection` (which DOES
/// work as a client on `.unix` endpoints — same trick `UDSTransport`
/// already uses) by adopting the fd. Once accepted, the wire bytes
/// flow through Network.framework just like `UDSTransport`.
///
/// Single-connection by design — the QVAC worker is one process,
/// one connection. After `accept()` resolves the listening socket
/// is closed; reconnect requires a new `UDSServer`.
public actor UDSServer {
  public enum ServerError: Error, Sendable {
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case acceptTimedOut(seconds: TimeInterval)
    case notListening
  }

  private let socketPath: String
  private var listenFD: Int32 = -1
  private var acceptedTransport: UDSAcceptedTransport?

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  /// Bind to the socket, start listening. Removes any stale socket
  /// file at the path first (server crashes leave the file behind).
  public func listen() async throws {
    if FileManager.default.fileExists(atPath: socketPath) {
      try? FileManager.default.removeItem(atPath: socketPath)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw ServerError.bindFailed(path: socketPath, errno: errno)
    }

    // Path must fit in sun_path (104 bytes on Darwin).
    guard socketPath.utf8.count < 104 else {
      _ = Darwin.close(fd)
      throw ServerError.bindFailed(path: socketPath, errno: ENAMETOOLONG)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(socketPath.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) {
      $0.withMemoryRebound(to: Int8.self, capacity: 104) { dst in
        for (i, byte) in pathBytes.enumerated() where i < 103 {
          dst[i] = Int8(bitPattern: byte)
        }
        dst[min(pathBytes.count, 103)] = 0  // null-terminate
      }
    }

    let bindResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let err = errno
      _ = Darwin.close(fd)
      throw ServerError.bindFailed(path: socketPath, errno: err)
    }

    guard Darwin.listen(fd, 1) == 0 else {
      let err = errno
      _ = Darwin.close(fd)
      try? FileManager.default.removeItem(atPath: socketPath)
      throw ServerError.listenFailed(errno: err)
    }

    self.listenFD = fd
  }

  /// Wait for the worker to connect. Returns the accepted connection
  /// as a `Transport` ready for `RPCBridge` to use.
  public func accept(timeout: TimeInterval = 30.0) async throws -> any Transport {
    guard listenFD >= 0 else { throw ServerError.notListening }
    let fd = self.listenFD

    // Run blocking accept() on a background thread, race against
    // a timeout Task. Using a synchronous accept in a Task wraps
    // cleanly; the only thread-safety concern is closing fd from
    // the timeout side, which we do via the OneShot guard.
    let acceptedFD: Int32 = try await withCheckedThrowingContinuation { cont in
      let oneShot = OneShot()
      DispatchQueue.global().async {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let accepted = withUnsafeMutablePointer(to: &clientAddr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.accept(fd, $0, &addrLen)
          }
        }
        if accepted >= 0 {
          if oneShot.tryFire() {
            cont.resume(returning: accepted)
          } else {
            // Lost the race to the timeout — close the orphan.
            _ = Darwin.close(accepted)
          }
        } else {
          let err = errno
          // EBADF means we closed fd from the timeout side; treat
          // as the cancel-from-timeout race, not a real failure.
          if err == EBADF {
            return
          }
          if oneShot.tryFire() {
            cont.resume(throwing: ServerError.acceptFailed(errno: err))
          }
        }
      }

      Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if oneShot.tryFire() {
          // Close the listen fd to unblock the accept() blocking call.
          _ = Darwin.close(fd)
          cont.resume(throwing: ServerError.acceptTimedOut(seconds: timeout))
        }
      }
    }

    // Close the listening socket — we accept exactly one connection.
    if listenFD >= 0 {
      _ = Darwin.close(listenFD)
      self.listenFD = -1
    }

    // Wrap the accepted fd as an NWConnection by adopting it. The
    // approach below: build an NWConnection bound to a duplicate
    // of the fd. Actually NWConnection doesn't directly accept an
    // existing fd; we use a Darwin-based transport instead.
    let transport = UDSAcceptedTransport(fd: acceptedFD)
    self.acceptedTransport = transport
    return transport
  }

  /// Tear down listener + accepted connection + remove socket file.
  /// Idempotent.
  public func close() async {
    if listenFD >= 0 {
      _ = Darwin.close(listenFD)
      listenFD = -1
    }
    if let t = acceptedTransport {
      await t.close()
      acceptedTransport = nil
    }
    try? FileManager.default.removeItem(atPath: socketPath)
  }

  /// One-shot atomic flag — supports `tryFire()` returning `true`
  /// exactly once across concurrent callers. Mirrors the same
  /// helper in `UDSTransport.swift`.
  private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
      lock.lock(); defer { lock.unlock() }
      if fired { return false }
      fired = true
      return true
    }
  }
}

/// `Transport` wrapping a Darwin file descriptor produced by
/// `UDSServer.accept()`. Uses a background dispatch queue for
/// blocking `read()` / `write()` calls; bytes flow through
/// `AsyncThrowingStream` to match the rest of the `Transport`
/// protocol shape.
final class UDSAcceptedTransport: Transport, @unchecked Sendable {
  private let inner: FDActor
  let incoming: AsyncThrowingStream<Data, Error>

  init(fd: Int32) {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>
      .makeStream(bufferingPolicy: .unbounded)
    self.incoming = stream
    self.inner = FDActor(fd: fd, continuation: continuation)
    Task { await self.inner.startReadLoop() }
  }

  func open() async throws { try await inner.markOpen() }
  func close() async { await inner.close() }
  func send(_ data: Data) async throws { try await inner.write(data) }
  var state: TransportState { get async { await inner.currentState } }
}

private actor FDActor {
  private let fd: Int32
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private(set) var currentState: TransportState = .open  // ready at construction
  private var didOpen = false
  private var didClose = false

  init(fd: Int32, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.fd = fd
    self.continuation = continuation
  }

  func markOpen() async throws {
    guard !didOpen else { throw TransportError.alreadyOpen }
    didOpen = true
  }

  func startReadLoop() {
    let fd = self.fd
    let cont = self.continuation
    let stateRef = StateRef()

    DispatchQueue.global().async { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 16_384)
      while !stateRef.closed.load() {
        let n = buffer.withUnsafeMutableBufferPointer { buf in
          Darwin.read(fd, buf.baseAddress, buf.count)
        }
        if n > 0 {
          let data = Data(bytes: buffer, count: n)
          cont.yield(data)
        } else if n == 0 {
          // Peer closed.
          cont.finish()
          Task { await self?.markPeerClosed() }
          return
        } else {
          // n < 0 — error
          let err = errno
          if err == EINTR { continue }
          if err == EBADF || err == ECONNRESET {
            cont.finish()
          } else {
            cont.finish(throwing: TransportError.readFailed(
              underlying: POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)))
          }
          Task { await self?.markPeerClosed() }
          return
        }
      }
    }

    // Tell the read loop the actor is closing.
    Task { [weak self] in
      while !(await self?.didCloseLoaded() ?? true) {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      stateRef.closed.store(true)
    }
  }

  func markPeerClosed() {
    currentState = .closed
  }

  fileprivate func didCloseLoaded() -> Bool { didClose }

  func write(_ data: Data) async throws {
    guard case .open = currentState else { throw TransportError.notOpen }
    return try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global().async {
        let result = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> ssize_t in
          var total: ssize_t = 0
          while total < data.count {
            let n = Darwin.write(self.fd, buf.baseAddress!.advanced(by: total),
              data.count - total)
            if n < 0 {
              if errno == EINTR { continue }
              return -1
            }
            total += n
          }
          return total
        }
        if result < 0 {
          cont.resume(throwing: TransportError.writeFailed(
            underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)))
        } else {
          cont.resume()
        }
      }
    }
  }

  func close() {
    guard !didClose else { return }
    didClose = true
    currentState = .closing
    _ = Darwin.close(fd)
    currentState = .closed
    continuation.finish()
  }
}

private final class StateRef: @unchecked Sendable {
  let closed = AtomicBool()
}

private final class AtomicBool: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
  func store(_ v: Bool) { lock.lock(); defer { lock.unlock() }; value = v }
}
