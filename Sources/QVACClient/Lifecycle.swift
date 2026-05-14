import Foundation

/// Opaque, worker-issued model identifier. The QVAC worker assigns this
/// at `loadModel` time; pass it back to `unloadModel`, `embed`,
/// `completion`, etc. Just a `String` under the hood so callers can
/// log / persist / round-trip it without ceremony.
public typealias ModelId = String

extension QVACClient {

  // MARK: - ping

  /// Round-trips a `heartbeat` and returns wall-clock RTT in seconds.
  /// Useful as a liveness check + connection-quality probe (separate
  /// from `state`, which only reflects local lifecycle).
  ///
  /// Today RTT on `LoopbackTransport` is sub-millisecond; on a real
  /// `UDSTransport` against a local Bare worker, expect 1-5ms.
  public func ping() async throws -> TimeInterval {
    let start = Date()
    _ = try await heartbeat()
    return Date().timeIntervalSince(start)
  }

  // MARK: - unloadModel

  /// Ergonomic wrapper around the generated
  /// `unloadModel(UnloadModelRequest)`. Defaults `clearStorage` to
  /// `false` (the JS SDK's default: just drop from RAM, leave the
  /// downloaded weights on disk). Pass `true` to evict the
  /// on-disk cache too.
  ///
  /// The `type` field on the request struct is whatever — the
  /// `QVACClient.send` envelope helper overrides it to the
  /// `QVACCommand`'s rawValue anyway.
  public func unloadModel(_ id: ModelId, clearStorage: Bool = false) async throws {
    let _: UnloadModelResponse = try await unloadModel(
      UnloadModelRequest(
        modelId: id,
        clearStorage: clearStorage,
        type: "unloadModel"))
  }

  // MARK: - loadModel

  /// Pragmatic typed wrapper for `loadModel`. Constructs the request
  /// body as `[String: AnyCodable]` and decodes the `modelId` field
  /// out of the worker's response.
  ///
  /// Why not a fully-typed `LoadModelRequest` DTO yet: the JS Zod
  /// schema for the request includes a discriminated union over
  /// `modelSrc` (path / URL / registry-id) and per-model-type
  /// configuration sub-objects (llama.cpp GPU layers, diffusion VAE
  /// override, …). These are deeply optional and dropped from the
  /// YK-179 codegen allowlist. Hand-rolling them today risks
  /// wire-shape divergence — better to verify field-by-field against
  /// the YK-208 real worker fixture before generating.
  ///
  /// Until then this wrapper:
  /// - takes the two universal fields (`modelSrc`, `modelType`)
  /// - allows extra parameters via `extras: [String: AnyCodable]` for
  ///   per-model-type configuration (e.g. `["nGpuLayers": .int(33)]`
  ///   for llama.cpp)
  /// - decodes the `modelId` field from the response object
  ///
  /// Progress streaming (the `withProgress: true` overlay per
  /// `docs/qvac-sdk-internals.md` §6) is **not** yet wired — it
  /// becomes available once the real worker confirms the chunk shape.
  /// Use `loadModelProgress(...)` once that lands.
  public func loadModel(
    modelSrc: String,
    modelType: String,
    extras: [String: AnyCodable] = [:]
  ) async throws -> ModelId {
    var body: [String: AnyCodable] = [
      "modelSrc": AnyCodable(.string(modelSrc)),
      "modelType": AnyCodable(.string(modelType)),
    ]
    for (key, value) in extras { body[key] = value }

    let response: AnyCodable = try await send(command: .loadModel, body)

    guard case .object(let dict) = response.value,
      case .string(let id) = dict["modelId"]
    else {
      throw QVACError.transport(
        .decodingFailed("loadModel response missing `modelId` field: \(response.value)"))
    }
    return id
  }
}
