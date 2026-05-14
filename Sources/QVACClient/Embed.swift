import Foundation

extension QVACClient {
  /// Embed one or more input strings into vector form.
  ///
  /// Returns `[[Double]]` where the outer array preserves input
  /// order and the inner length is the model's embedding dimension
  /// (model-dependent — e.g. 1024 for Nomic-Embed, 768 for many
  /// sentence-transformer variants).
  ///
  /// **Double vs Float.** The JS SDK transports embeddings as 32-bit
  /// floats; Swift's `JSONDecoder` decodes JSON numbers as `Double`
  /// by default. Returning `[[Double]]` keeps the API simple
  /// (matches what the decoder naturally produces) and avoids a
  /// lossy `Double→Float` step. Callers who want `Float` for memory
  /// can convert: `vec.map(Float.init)`.
  ///
  /// **Error mapping.** An empty `input` array fails client-side
  /// with `QVACError.transport(.framingError(...))`. Worker-side
  /// errors (model not embedding-capable, out-of-tokens, etc.)
  /// surface as `QVACError.server(...)` via the regular wire path.
  public func embed(modelId: ModelId, input: [String]) async throws -> [[Double]] {
    guard !input.isEmpty else {
      throw QVACError.transport(
        .framingError("embed requires non-empty input"))
    }

    let body: [String: AnyCodable] = [
      "modelId": AnyCodable(.string(modelId)),
      "text": AnyCodable(.array(input.map { .string($0) })),
    ]
    let response: AnyCodable = try await send(command: .embed, body)
    return try Self.decodeEmbeddings(response, expectedCount: input.count)
  }

  /// Single-input convenience overload. Returns the embedding for
  /// the one input as a flat `[Double]`.
  public func embed(modelId: ModelId, input: String) async throws -> [Double] {
    let batch = try await embed(modelId: modelId, input: [input])
    guard let first = batch.first else {
      throw QVACError.transport(
        .decodingFailed("embed returned no embedding for a single input"))
    }
    return first
  }

  // MARK: - private

  /// Decodes the `embedding` payload. JS workers emit either:
  /// - `{"embedding": [[..numbers..], [..]]}` for a batch
  /// - `{"embedding": [..numbers..]}` for a single input (some models)
  /// Both shapes normalize to `[[Double]]` here. `expectedCount`
  /// must match the input array length when the worker returns the
  /// batch shape; the single shape is wrapped to length-1.
  private static func decodeEmbeddings(
    _ response: AnyCodable,
    expectedCount: Int
  ) throws -> [[Double]] {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(
        .decodingFailed("embed response is not an object: \(response.value)"))
    }
    guard let embedding = dict["embedding"] else {
      throw QVACError.transport(
        .decodingFailed("embed response missing `embedding` field"))
    }

    if case .array(let outer) = embedding {
      if let first = outer.first, case .array = first {
        // Batch shape: [[Double]]
        let vectors = try outer.map(Self.numberArrayFromAnyCodable)
        return vectors
      }
      // Single-vector shape: [Double] — wrap to one-element batch.
      let single = try Self.numberArrayFromAnyCodable(embedding)
      return [single]
    }

    throw QVACError.transport(
      .decodingFailed("embed response `embedding` field is not an array: \(embedding)"))
  }

  private static func numberArrayFromAnyCodable(
    _ value: AnyCodableValue
  ) throws -> [Double] {
    guard case .array(let arr) = value else {
      throw QVACError.transport(
        .decodingFailed("expected an array of numbers, got \(value)"))
    }
    var result: [Double] = []
    result.reserveCapacity(arr.count)
    for v in arr {
      switch v {
      case .double(let d): result.append(d)
      case .int(let i): result.append(Double(i))
      default:
        throw QVACError.transport(
          .decodingFailed("embedding contained non-numeric value: \(v)"))
      }
    }
    return result
  }
}
