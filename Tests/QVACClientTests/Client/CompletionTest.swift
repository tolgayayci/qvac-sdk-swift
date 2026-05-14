import Foundation
import XCTest

@testable import QVACClient

/// YK-202 — typed `completion` wrappers (streaming + blocking).
/// Tests exercise the wire-shape mapping + the blocking aggregation
/// path against an extended `QVACPeer` that fakes the
/// `completionStream` reply (N `{token: ...}` chunks + terminal
/// `{finish: "stop", stats: {...}}`). Real-worker E2E (deterministic
/// output, TTFT, throughput parity) → YK-209 / YK-221.
final class CompletionTest: XCTestCase {

  private func makePair(
    behavior: QVACPeer.Behavior = .init(streamCount: 5, streamIntervalMs: 0)
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - Streaming

  /// Token chunks decoded in order; terminal `.finish` arrives last.
  func testStreamingYieldsTokensThenFinish() async throws {
    let (client, peer) = try await makePair(
      behavior: .init(streamCount: 8, streamIntervalMs: 0))
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var collectedTokens: [String] = []
    var sawFinish = false
    var finalReason: String?

    for try await chunk in client.completion(
      modelId: "test-model",
      history: [.user("hello")],
      options: CompletionOptions(maxTokens: 8))
    {
      switch chunk {
      case .token(let t):
        XCTAssertFalse(sawFinish, "token after finish — wire ordering violation")
        collectedTokens.append(t)
      case .finish(let reason, _):
        sawFinish = true
        finalReason = reason
      }
    }

    XCTAssertEqual(collectedTokens, (0..<8).map { "tok-\($0)" })
    XCTAssertEqual(finalReason, "stop")
  }

  /// Cancellation during stream emits a worker `cancel` (covered by
  /// `CancellationTest`; this verifies it works through the
  /// `completion` wrapper specifically, not just `loggingStream`).
  func testStreamingCancellationEmitsCancelCommand() async throws {
    let (client, peer) = try await makePair(
      behavior: .init(streamCount: 1000, streamIntervalMs: 1))
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var collected = 0
    for try await chunk in client.completion(
      modelId: "test-model", history: [.user("long prompt")])
    {
      if case .token = chunk {
        collected += 1
        if collected >= 3 { break }
      }
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    let cancelled = await peer.cancelledRunIds
    XCTAssertGreaterThanOrEqual(cancelled.count, 1, "cancel should reach peer")
  }

  // MARK: - Blocking

  /// Convenience aggregator. Concatenates tokens + carries forward
  /// the terminal stats.
  func testBlockingAggregatesAllTokens() async throws {
    let (client, peer) = try await makePair(
      behavior: .init(streamCount: 5, streamIntervalMs: 0))
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let result: CompletionResult = try await client.completion(
      modelId: "test-model",
      history: [.system("You are a helpful assistant."), .user("Say hi")],
      options: CompletionOptions(maxTokens: 5, temperature: 0.7, seed: 42))

    XCTAssertEqual(result.text, "tok-0tok-1tok-2tok-3tok-4")
    XCTAssertEqual(result.finishReason, "stop")
    XCTAssertEqual(result.stats?.generatedTokens, 5.0)
  }

  // MARK: - Options round-trip

  /// All option fields encode (the peer doesn't validate them; we
  /// just verify the call doesn't throw on the encode path).
  func testCompletionOptionsRoundTrip() async throws {
    let (client, peer) = try await makePair(
      behavior: .init(streamCount: 1, streamIntervalMs: 0))
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let opts = CompletionOptions(
      maxTokens: 200,
      temperature: 0.9,
      topP: 0.95,
      topK: 50,
      seed: 1234,
      stopSequences: ["\n\n", "###"],
      extras: ["repeatPenalty": AnyCodable(.double(1.1))])

    let result = try await client.completion(
      modelId: "test", history: [.user("test")], options: opts)
    XCTAssertEqual(result.text, "tok-0")
  }

  // MARK: - ChatMessage convenience inits

  func testChatMessageRoleConvenienceInits() {
    XCTAssertEqual(ChatMessage.system("hi").role, "system")
    XCTAssertEqual(ChatMessage.user("hi").role, "user")
    XCTAssertEqual(ChatMessage.assistant("hi").role, "assistant")
  }
}
