import Foundation

/// Encoder / decoder for the QVAC wire payload.
///
/// The QVAC SDK uses **JSON** for every request and response — confirmed by
/// reading every handler in `packages/sdk/server/rpc/handler-registry.ts`
/// and documented in `docs/qvac-sdk-internals.md` §8. This protocol exists
/// so the rest of the client (`RPCBridge`, `QVACClient`) doesn't depend on
/// `JSONEncoder` / `JSONDecoder` directly:
///
/// - Tests can swap in a `LoggingCodec` to inspect wire bytes without
///   asserting on internal encoder configuration.
/// - If upstream ever moves to `bare-structured-clone` or a binary format,
///   one type swaps; everything above is unchanged.
///
/// Streaming chunks (newline-delimited JSON) are split by `RPCBridge`
/// before being handed to `Codec.decode` — the codec only ever sees a
/// single JSON value per call.
public protocol Codec: Sendable {
  func encode<T: Encodable>(_ value: T) throws -> Data
  func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

/// Production `Codec` for QVAC's JSON wire format.
///
/// Configuration choices, with reasons:
///
/// - **`keyEncodingStrategy = .useDefaultKeys`** and **`keyDecodingStrategy
///   = .useDefaultKeys`**. The JS server emits camelCase keys (verified
///   per-handler in YK-175); generated Swift DTOs use camelCase property
///   names that match verbatim. Where the wire name is kebab- or
///   snake-case (e.g. `llamacpp-completion`), the generated DTO carries a
///   `CodingKey` override — that's handled at the type level, not here.
/// - **`dateEncodingStrategy` / `dateDecodingStrategy` left at default
///   (`.deferredToDate`)**. No SDK type in M1's allowlist carries a `Date`
///   field; date-heavy DTOs (e.g. RAG ingest timestamps) decide their own
///   strategy at the type level via `Codable`. If a global ISO-8601 rule
///   is ever needed, change here.
/// - **`outputFormatting = []`** (compact). The wire doesn't require
///   formatting and compact output is faster + smaller.
/// - **No `nonConformingFloatEncodingStrategy`**. NaN / Inf in JSON is
///   illegal; we let the encoder throw rather than silently coercing.
///
/// Forward-compat behavior worth knowing:
///
/// - **Unknown fields are silently ignored** on decode. `JSONDecoder`'s
///   default ignores extra keys, so a newer worker that adds a field
///   doesn't break an older Swift client. Covered by `CodecTest`.
/// - **Missing required fields throw** `DecodingError.keyNotFound`. Maps
///   to `QVACError.transport(.decodingFailed)` upstream in `RPCBridge`.
public struct JSONCodec: Codec {
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init() {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .useDefaultKeys
    encoder.outputFormatting = []
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .useDefaultKeys
    self.decoder = decoder
  }

  /// Encode any `Encodable` to wire bytes via the configured
  /// `JSONEncoder` (sorted keys, JSON output).
  public func encode<T: Encodable>(_ value: T) throws -> Data {
    return try encoder.encode(value)
  }

  /// Decode wire bytes into the requested `Decodable` type via
  /// the configured `JSONDecoder`. Throws standard `DecodingError`
  /// shapes; callers typically wrap into `QVACError.transport(.decodingFailed)`.
  public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    return try decoder.decode(type, from: data)
  }
}
