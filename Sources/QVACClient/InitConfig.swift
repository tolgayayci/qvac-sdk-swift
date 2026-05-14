import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Runtime configuration sent during the `__init_config` handshake at
/// the start of every QVAC connection. Mirrors the JS SDK's `QvacConfig`
/// (see `packages/sdk/schemas/sdk-config.ts:99-179` and
/// `docs/qvac-sdk-internals.md` §4 for the full field table).
///
/// Every field is optional; an entirely-defaulted `QVACInitConfig()`
/// makes the worker use its built-in defaults. Most apps pass `nil`
/// for `config` entirely and rely on the runtime-context auto-detection.
public struct QVACInitConfig: Codable, Sendable, Equatable {
  /// Where downloaded models / asset caches live. JS SDK default is
  /// `~/.qvac/models`.
  public var cacheDirectory: String?

  /// DHT relay nodes for swarm-distributed assets. Optional.
  public var swarmRelays: [String]?

  /// `"error" | "warn" | "info" | "debug"`. JS default: `"info"`.
  public var loggerLevel: QVACLogLevel?

  /// Whether the worker echoes logs to its console. JS default: `true`.
  public var loggerConsoleOutput: Bool?

  /// Maximum concurrent HTTP downloads. JS default: `3`. Must be > 0.
  public var httpDownloadConcurrency: Int?

  /// HTTP connection timeout in milliseconds. JS default: `10000`.
  public var httpConnectionTimeoutMs: Int?

  /// Max retries on registry downloads. JS default: `3`. Non-negative.
  public var registryDownloadMaxRetries: Int?

  /// Registry stream timeout in milliseconds. JS default: `60000`.
  public var registryStreamTimeoutMs: Int?

  public init(
    cacheDirectory: String? = nil,
    swarmRelays: [String]? = nil,
    loggerLevel: QVACLogLevel? = nil,
    loggerConsoleOutput: Bool? = nil,
    httpDownloadConcurrency: Int? = nil,
    httpConnectionTimeoutMs: Int? = nil,
    registryDownloadMaxRetries: Int? = nil,
    registryStreamTimeoutMs: Int? = nil
  ) {
    self.cacheDirectory = cacheDirectory
    self.swarmRelays = swarmRelays
    self.loggerLevel = loggerLevel
    self.loggerConsoleOutput = loggerConsoleOutput
    self.httpDownloadConcurrency = httpDownloadConcurrency
    self.httpConnectionTimeoutMs = httpConnectionTimeoutMs
    self.registryDownloadMaxRetries = registryDownloadMaxRetries
    self.registryStreamTimeoutMs = registryStreamTimeoutMs
  }
}

/// JS SDK log levels — `packages/sdk/schemas/sdk-config.ts`.
public enum QVACLogLevel: String, Codable, Sendable, Equatable, CaseIterable {
  case error
  case warn
  case info
  case debug
}

/// Per-runtime context sent alongside `QVACInitConfig`. Tells the
/// worker which runtime/platform it's serving so device-pattern
/// defaults match. Mirrors `packages/sdk/schemas/runtime-context.ts:1-10`.
///
/// `QVACClient` defaults to `runtime: "bare"` (the worker IS bare)
/// and `platform` auto-detected from the host OS. Callers can
/// override either if they're bridging a non-default runtime.
public struct QVACRuntimeContext: Codable, Sendable, Equatable {
  /// `"node" | "bare" | "react-native"`. Swift sends `"bare"` —
  /// the QVAC worker we talk to IS a bare runtime.
  public var runtime: String

  /// `"android" | "ios" | "darwin" | "linux" | "win32"`.
  public var platform: String?

  /// Optional device model string for device-defaults matching.
  public var deviceModel: String?

  /// Optional device brand.
  public var deviceBrand: String?

  public init(
    runtime: String = "bare",
    platform: String? = QVACRuntimeContext.detectPlatform(),
    deviceModel: String? = nil,
    deviceBrand: String? = nil
  ) {
    self.runtime = runtime
    self.platform = platform
    self.deviceModel = deviceModel
    self.deviceBrand = deviceBrand
  }

  /// Best-effort host platform name matching the JS SDK's allowed
  /// values. `Process.info` doesn't give the JS-flavored names, so we
  /// map manually.
  public static func detectPlatform() -> String? {
    #if os(macOS)
      return "darwin"
    #elseif os(iOS)
      return "ios"
    #elseif os(tvOS) || os(watchOS) || os(visionOS)
      // Map to ios — closest JS-compat label.
      return "ios"
    #elseif os(Linux)
      return "linux"
    #elseif os(Windows)
      return "win32"
    #else
      return nil
    #endif
  }
}

/// Internal — the wire shape of the `__init_config` request frame.
/// `type` is the discriminator that bypasses the worker's normal
/// schema validation (see `packages/sdk/server/rpc/handler-utils.ts:264-277`).
///
/// `config` and `runtimeContext` are optional per the JS schema; both
/// are encoded as JSON `null` when nil rather than omitted — matches
/// the JS SDK's `JSON.stringify(initMessage)` behavior which preserves
/// keys with explicit `undefined` → drops them. Swift's default
/// encoder drops nil keys, which is what we want here.
struct InitConfigRequest: Encodable {
  let type: String
  let config: QVACInitConfig?
  let runtimeContext: QVACRuntimeContext?

  init(config: QVACInitConfig?, runtimeContext: QVACRuntimeContext?) {
    self.type = "__init_config"
    self.config = config
    self.runtimeContext = runtimeContext
  }
}

/// Worker reply per `handler-utils.ts:279-300`. On `success: false`,
/// `error` carries the human-readable reason.
struct InitConfigResponse: Decodable {
  let success: Bool
  let error: String?
}
