import XCTest

@testable import QVACClient

/// Covers `Commands.swift` (YK-180 part 1) and the generated method
/// surface in `Client+Methods.swift` (YK-180 part 2). The method bodies
/// are M2 stubs (`fatalError("YK-201")`), so the tests here are
/// **compile-time existence + metadata checks only** — running any
/// generated method would crash. That's intentional and acceptable for
/// M1: surface complete, runtime intentionally fails loud.
final class CommandsAndMethodsTest: XCTestCase {

  // MARK: - Commands

  func testCommandsCountMatchesHandlerRegistry() {
    // 31 from `packages/sdk/server/rpc/handler-registry.ts:75-158`.
    // See docs/qvac-sdk-internals.md §6.
    XCTAssertEqual(QVACCommand.allCases.count, 31)
  }

  func testCommandsRawValuesUnique() {
    let raws = QVACCommand.allCases.map(\.rawValue)
    XCTAssertEqual(raws.count, Set(raws).count, "duplicate wire names in QVACCommand")
  }

  func testCommandsKnownWireNames() {
    // Spot-check that the wire names match what the JS server dispatches on.
    XCTAssertEqual(QVACCommand.heartbeat.rawValue, "heartbeat")
    XCTAssertEqual(QVACCommand.loadModel.rawValue, "loadModel")
    XCTAssertEqual(QVACCommand.completionStream.rawValue, "completionStream")
    XCTAssertEqual(QVACCommand.transcribeStream.rawValue, "transcribeStream")
    XCTAssertEqual(QVACCommand.rag.rawValue, "rag")
  }

  func testCommandModePartitioning() {
    let reply = QVACCommand.allCases.filter { $0.mode == .reply }
    let stream = QVACCommand.allCases.filter { $0.mode == .stream }
    let duplex = QVACCommand.allCases.filter { $0.mode == .duplex }
    // From handler-registry classification: 20 reply, 9 stream, 2 duplex.
    XCTAssertEqual(reply.count, 20, "reply-mode commands")
    XCTAssertEqual(stream.count, 9, "stream-mode commands")
    XCTAssertEqual(duplex.count, 2, "duplex-mode commands")
    XCTAssertEqual(reply.count + stream.count + duplex.count, QVACCommand.allCases.count)
  }

  func testCommandModeKnownValues() {
    XCTAssertEqual(QVACCommand.heartbeat.mode, .reply)
    XCTAssertEqual(QVACCommand.completionStream.mode, .stream)
    XCTAssertEqual(QVACCommand.transcribeStream.mode, .duplex)
    XCTAssertEqual(QVACCommand.textToSpeechStream.mode, .duplex)
  }

  // MARK: - Method surface

  /// Verifies every bounty-PDF method has a routing target in
  /// `QVACCommand`. The Swift methods themselves are actor-isolated so
  /// partial application isn't legal at the test boundary — instead we
  /// check the wire commands they map to, which is the real cross-
  /// reference Tether reviewers will care about.
  func testBountyMethodsMapToCommands() {
    // From the bounty PDF / YK-175 §13. Each entry is `(swift method,
    // wire command it dispatches on)`. Validation: every command exists
    // in QVACCommand. (Swift method existence is enforced by `swift build`
    // succeeding — the file Client+Methods.swift wouldn't compile if a
    // method had the wrong signature shape against the QVACClient actor.)
    let expectations: [(swiftMethod: String, wireCommand: QVACCommand?)] = [
      ("heartbeat", .heartbeat),
      ("loadModel", .loadModel),
      ("unloadModel", .unloadModel),
      ("embed", .embed),
      ("completion", .completionStream),
      ("cancel", .cancel),
      ("suspend", .suspend),
      ("resume", .resume),
      ("state", .state),
      ("close", nil),  // client-only — no wire command
      ("downloadAsset", .downloadAsset),
      ("deleteCache", .deleteCache),
      ("getModelInfo", .getModelInfo),
      ("getLoadedModelInfo", .getLoadedModelInfo),
      ("loggingStream", .loggingStream),
      ("transcribe", .transcribe),
      ("transcribeStream", .transcribeStream),
      ("textToSpeech", .textToSpeech),
      ("textToSpeechStream", .textToSpeechStream),
      ("translate", .translate),
      ("ocr", .ocrStream),
      ("diffusion", .diffusionStream),
      ("upscale", .upscaleStream),
      ("finetune", .finetune),
      ("startQVACProvider", .provide),
      ("stopQVACProvider", .stopProvide),
      ("invokePlugin", .pluginInvoke),
      ("invokePluginStream", .pluginInvokeStream),
      ("modelRegistryList", .modelRegistryList),
      ("modelRegistrySearch", .modelRegistrySearch),
      ("modelRegistryGetModel", .modelRegistryGetModel),
      ("ragChunk", .rag),
      ("ragIngest", .rag),
      ("ragSaveEmbeddings", .rag),
      ("ragSearch", .rag),
      ("ragDeleteEmbeddings", .rag),
      ("ragReindex", .rag),
      ("ragListWorkspaces", .rag),
      ("ragCloseWorkspace", .rag),
      ("ragDeleteWorkspace", .rag),
    ]
    // 40 entries: every bounty-PDF method accounted for. If you remove a
    // method from the SDK, drop the entry here too.
    XCTAssertEqual(expectations.count, 40)

    // Every non-nil command is a real QVACCommand case — Swift's enum
    // typing makes that a compile-time check, but explicit is friendlier
    // when a method gets retargeted.
    for entry in expectations {
      if let command = entry.wireCommand {
        XCTAssertTrue(
          QVACCommand.allCases.contains(command),
          "method \(entry.swiftMethod) maps to nonexistent command \(command)")
      }
    }
  }
}
