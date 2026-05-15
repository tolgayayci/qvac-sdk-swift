import Foundation

// MARK: - Types

/// Envelope for `invokePlugin` / `invokePluginStream` on the wire.
/// `handler` names the plugin method (registered with `definePlugin`
/// in the worker-side plugin manifest); `params` is whatever
/// `Encodable` payload the caller hands in. `modelId` scopes the
/// invocation to a loaded model, since plugins are registered per
/// model in `@qvac/sdk`'s plugin registry.
internal struct PluginInvocation<Params: Encodable>: Encodable {
  let modelId: String
  let handler: String
  let params: Params
}

// MARK: - Methods

extension QVACClient {

  /// Invoke a plugin handler and receive a single `Result` value.
  ///
  /// `Result` is decoded with `JSONDecoder` from the worker's
  /// `result` field. The caller supplies both the args type and
  /// the response type — the SDK is generic over them, so plugin
  /// authors can ship plain Swift `struct`s without going through
  /// codegen.
  ///
  /// **Errors.** Plugin-raised exceptions surface as
  /// `QVACError.transport(.framingError(...))` carrying the JS
  /// plugin's `error.message`. Unknown handlers / unknown model
  /// ids surface as `QVACError.server(...)` via the standard
  /// `Generated/ErrorCodes` path; no plugin-specific error code
  /// exists today.
  public func invokePlugin<Params: Encodable, Result: Decodable>(
    modelId: ModelId,
    handler: String,
    params: Params
  ) async throws -> Result {
    let invocation = PluginInvocation(
      modelId: modelId, handler: handler, params: params)
    let response: AnyCodable = try await send(command: .pluginInvoke, invocation)
    return try Self.decodePluginResult(response, handler: handler)
  }

  /// No-args overload — convenience when the plugin handler takes
  /// no parameters. Sends `params: {}` on the wire (matches what
  /// the JS SDK's `definePlugin` handler receives when its caller
  /// passes nothing).
  public func invokePlugin<Result: Decodable>(
    modelId: ModelId,
    handler: String
  ) async throws -> Result {
    try await invokePlugin(
      modelId: modelId, handler: handler, params: EmptyParams())
  }

  /// Streaming plugin invocation. The worker emits one or more
  /// `{result, done?: true}` frames; the Swift stream yields one
  /// `Chunk` per frame and finishes when the terminal frame with
  /// `done: true` (or end-of-stream) arrives.
  ///
  /// Caller-side `break` or `Task.cancel()` terminates the stream
  /// — the underlying RPC is torn down via the standard
  /// `streamResponse` machinery.
  public nonisolated func invokePluginStream<Params: Encodable, Chunk: Decodable>(
    modelId: ModelId,
    handler: String,
    params: Params,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
    let invocation = PluginInvocation(
      modelId: modelId, handler: handler, params: params)
    let raw: AsyncThrowingStream<AnyCodable, Error> =
      self.streamResponse(
        command: .pluginInvokeStream, invocation, bufferSize: bufferSize)
    return AsyncThrowingStream<Chunk, Error> { continuation in
      let task = Task {
        do {
          for try await rawChunk in raw {
            if let chunk: Chunk = try? Self.decodePluginResult(
              rawChunk, handler: handler)
            {
              continuation.yield(chunk)
            }
            if Self.pluginFrameIsTerminal(rawChunk) { break }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  /// No-args streaming overload — same shape as the blocking
  /// overload above but for streams.
  public nonisolated func invokePluginStream<Chunk: Decodable>(
    modelId: ModelId,
    handler: String,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
    invokePluginStream(
      modelId: modelId, handler: handler,
      params: EmptyParams(), bufferSize: bufferSize)
  }

  /// Fluent accessor that pins the `modelId` so plugin authors can
  /// hand it to consumers without repeating the model id on every
  /// call. Returns a value type, no actor hop.
  public nonisolated func plugin(modelId: ModelId) -> PluginClient {
    PluginClient(client: self, modelId: modelId)
  }

  // MARK: - private helpers

  /// `{type:"pluginInvoke", result: <anything>}` → decode `result` as
  /// `T`. `result` may itself be any JSON shape (object, array,
  /// string, number, bool, null); we re-encode to JSON and re-decode
  /// as `T` to leverage Swift's `JSONDecoder` for the user-provided
  /// type without manual `AnyCodableValue` → T translation.
  private static func decodePluginResult<T: Decodable>(
    _ response: AnyCodable,
    handler: String
  ) throws -> T {
    guard case .object(let dict) = response.value else {
      throw QVACError.transport(.decodingFailed(
        "plugin/\(handler) response is not an object: \(response.value)"))
    }
    guard let resultValue = dict["result"] else {
      throw QVACError.transport(.decodingFailed(
        "plugin/\(handler) response missing `result` field"))
    }
    // Round-trip the AnyCodable value through JSON to materialize
    // the caller's typed `T`. AnyCodable's encoder writes
    // canonical JSON for any value shape.
    let payload = AnyCodable(resultValue)
    let data = try JSONEncoder().encode(payload)
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw QVACError.transport(.decodingFailed(
        "plugin/\(handler) result decode failed: \(error)"))
    }
  }

  /// `done: true` marks the terminal frame on a plugin stream.
  /// Some plugins omit the flag and rely on end-of-stream instead;
  /// both work — `pluginFrameIsTerminal` just gives the stream a
  /// chance to bail out early when the worker did send it.
  private static func pluginFrameIsTerminal(_ value: AnyCodable) -> Bool {
    guard case .object(let dict) = value.value,
      case .bool(true) = dict["done"]
    else { return false }
    return true
  }
}

// MARK: - PluginClient

/// Fluent wrapper for plugin invocation. Pins the `modelId` so
/// callers can route a `client.plugin(modelId:)` through their
/// own code without threading the model id through every method.
public struct PluginClient: Sendable {
  private let client: QVACClient
  private let modelId: ModelId

  internal init(client: QVACClient, modelId: ModelId) {
    self.client = client
    self.modelId = modelId
  }

  /// Blocking call — see `QVACClient.invokePlugin(...)`.
  public func call<Params: Encodable, Result: Decodable>(
    _ handler: String,
    params: Params
  ) async throws -> Result {
    try await client.invokePlugin(
      modelId: modelId, handler: handler, params: params)
  }

  /// No-args blocking call.
  public func call<Result: Decodable>(
    _ handler: String
  ) async throws -> Result {
    try await client.invokePlugin(modelId: modelId, handler: handler)
  }

  /// Streaming call — see `QVACClient.invokePluginStream(...)`.
  public func stream<Params: Encodable, Chunk: Decodable>(
    _ handler: String,
    params: Params,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
    client.invokePluginStream(
      modelId: modelId, handler: handler,
      params: params, bufferSize: bufferSize)
  }

  /// No-args streaming call.
  public func stream<Chunk: Decodable>(
    _ handler: String,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
    client.invokePluginStream(
      modelId: modelId, handler: handler, bufferSize: bufferSize)
  }
}

// MARK: - EmptyParams

/// Placeholder `Encodable` for the no-args overloads. Encodes as
/// `{}` so the worker's `params: z.unknown()` matches.
private struct EmptyParams: Encodable {}
