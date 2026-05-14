import Foundation
import XCTest

@testable import QVACClient

/// YK-205 — typed wrappers for `translate`, `diffusion`, `ocr`,
/// `downloadAsset`. Tests verify the chunk-parsing + request-shape
/// against fakes; real-model / real-network validation → YK-209.
final class VisionTest: XCTestCase {

  private func makePair() async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - translate

  func testTranslateReturnsFinalText() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let result = try await client.translate(
      modelId: "bergamot-en-fr", text: "Hello", from: "en", to: "fr")
    XCTAssertEqual(result, "Bonjour")
  }

  // MARK: - diffusion

  func testDiffusionEmitsProgressThenCompleted() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var progress: [(Int, Int)] = []
    var completedImage: Data?

    for try await step in client.diffusion(
      modelId: "stable-diffusion-1.5", prompt: "a red apple",
      options: DiffusionOptions(width: 256, height: 256, steps: 3, seed: 42))
    {
      switch step {
      case .progress(let s, let total):
        progress.append((s, total))
      case .preview:
        break
      case .completed(let img):
        completedImage = img
      }
    }

    XCTAssertEqual(progress.count, 3)
    XCTAssertEqual(progress.first?.0, 1)
    XCTAssertEqual(progress.first?.1, 3)
    XCTAssertEqual(progress.last?.0, 3)

    // PNG magic bytes — proves base64 decode worked.
    XCTAssertEqual(
      completedImage?.prefix(4),
      Data([0x89, 0x50, 0x4E, 0x47]))
  }

  // MARK: - ocr

  func testOCRReturnsTextAndRegions() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let result = try await client.ocr(modelId: "tesseract", image: pngBytes)

    XCTAssertEqual(result.text, "QVAC ROCKS")
    XCTAssertEqual(result.regions.count, 2)
    XCTAssertEqual(result.regions[0].text, "QVAC")
    XCTAssertEqual(result.regions[0].bbox, [10.0, 20.0, 80.0, 30.0])
    XCTAssertEqual(result.regions[0].confidence, 0.98)
  }

  // MARK: - downloadAsset

  func testDownloadAssetEmitsProgressThenCompleted() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var progress: [(Int64, Int64?)] = []
    var finalPath: String?

    for try await update in client.downloadAsset(
      src: "https://example.com/test-asset.bin")
    {
      switch update {
      case .progress(let done, let total):
        progress.append((done, total))
      case .completed(let path):
        finalPath = path
      }
    }

    XCTAssertEqual(progress.count, 3)
    XCTAssertEqual(progress.map { $0.0 }, [256, 512, 1024])
    XCTAssertEqual(progress.last?.1, 1024)
    XCTAssertEqual(finalPath, "/tmp/qvac-test-asset.bin")
  }
}
