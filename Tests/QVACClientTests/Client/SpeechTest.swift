import Foundation
import XCTest

@testable import QVACClient

/// YK-204 — typed speech wrappers (`transcribe`, `transcribeStream`,
/// `textToSpeech`, `textToSpeechStream`). Tests verify request shape
/// + chunk parsing against the extended `QVACPeer`. Real Whisper /
/// Kokoro validation → YK-209.
final class SpeechTest: XCTestCase {

  private func makePair() async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - transcribe

  /// One-shot transcribe accumulates the stream → final Transcript.
  func testTranscribeAccumulatesToTranscript() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])  // dummy bytes
    let transcript = try await client.transcribe(
      modelId: "test-whisper", audio: audio)
    XCTAssertEqual(transcript.text, "hello world")
  }

  /// Streaming yields partials then a terminal final.
  func testTranscribeStreamYieldsPartialsThenFinal() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var partials: [String] = []
    var finals: [Transcript] = []

    for try await delta in client.transcribeStream(
      modelId: "test-whisper", audio: Data([0x01, 0x02]))
    {
      switch delta {
      case .partial(let s): partials.append(s)
      case .final(let t): finals.append(t)
      }
    }

    XCTAssertEqual(partials, ["hello", "hello world"])
    XCTAssertEqual(finals.count, 1)
    XCTAssertEqual(finals.first?.text, "hello world")
  }

  /// TranscribeOptions round-trip (peer ignores the values but we
  /// verify the encode path doesn't break).
  func testTranscribeOptionsRoundTrip() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let opts = TranscribeOptions(
      language: "fr",
      task: "translate",
      withTimestamps: true,
      extras: ["beamSize": AnyCodable(.int(5))])
    let transcript = try await client.transcribe(
      modelId: "test-whisper", audio: Data([0x01]), options: opts)
    XCTAssertEqual(transcript.text, "hello world")
  }

  // MARK: - textToSpeech

  /// One-shot TTS concatenates chunks.
  func testTextToSpeechReturnsConcatenatedPCM() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let pcm = try await client.textToSpeech(
      modelId: "test-kokoro", text: "Hello, world.")
    XCTAssertEqual(
      pcm,
      Data([
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C,
      ]))
  }

  /// Streaming TTS yields chunks in order with byte fidelity.
  func testTextToSpeechStreamYieldsChunksInOrder() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var chunks: [Data] = []
    for try await chunk in client.textToSpeechStream(
      modelId: "test-kokoro", text: "hello")
    {
      chunks.append(chunk)
    }
    XCTAssertEqual(chunks.count, 3)
    XCTAssertEqual(chunks[0], Data([0x01, 0x02, 0x03, 0x04]))
    XCTAssertEqual(chunks[1], Data([0x05, 0x06, 0x07, 0x08]))
    XCTAssertEqual(chunks[2], Data([0x09, 0x0A, 0x0B, 0x0C]))
  }

  /// TTSOptions round-trip.
  func testTTSOptionsRoundTrip() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let opts = TTSOptions(voice: "af_bella", speed: 1.1, sampleRate: 22050)
    let pcm = try await client.textToSpeech(
      modelId: "test-kokoro", text: "hi", options: opts)
    XCTAssertFalse(pcm.isEmpty)
  }
}
