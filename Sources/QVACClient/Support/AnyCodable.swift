import Foundation

/// Type-erased `Codable` value. Used by code-generated DTOs as the fallback
/// for TypeScript `unknown` / `any`, multi-variant unions that don't fit a
/// Swift enum, and anonymous nested object types the IR couldn't hoist into
/// a named struct.
///
/// Round-trips JSON via `Codable`. Supports the seven JSON value kinds:
/// null, bool, integer, double, string, array, object.
public struct AnyCodable: Codable, Sendable, Equatable {
  public let value: AnyCodableValue

  public init(_ value: AnyCodableValue) {
    self.value = value
  }

  public init(_ raw: Any?) {
    self.value = AnyCodableValue.from(raw)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.value = try AnyCodableValue.decode(from: container)
  }

  /// `Encodable` conformance — delegates to `AnyCodableValue`'s
  /// recursive encoder so any JSON-representable shape round-trips.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try value.encode(into: &container)
  }
}

/// Discriminated representation of any JSON value AnyCodable can carry.
public enum AnyCodableValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  indirect case array([AnyCodableValue])
  indirect case object([String: AnyCodableValue])

  fileprivate static func decode(from container: SingleValueDecodingContainer) throws -> AnyCodableValue {
    if container.decodeNil() { return .null }
    if let v = try? container.decode(Bool.self) { return .bool(v) }
    if let v = try? container.decode(Int.self) { return .int(v) }
    if let v = try? container.decode(Double.self) { return .double(v) }
    if let v = try? container.decode(String.self) { return .string(v) }
    if let v = try? container.decode([AnyCodable].self) {
      return .array(v.map { $0.value })
    }
    if let v = try? container.decode([String: AnyCodable].self) {
      var out: [String: AnyCodableValue] = [:]
      for (key, val) in v { out[key] = val.value }
      return .object(out)
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "AnyCodable: value is not a JSON scalar, array, or object")
  }

  fileprivate func encode(into container: inout SingleValueEncodingContainer) throws {
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let v):
      try container.encode(v)
    case .int(let v):
      try container.encode(v)
    case .double(let v):
      try container.encode(v)
    case .string(let v):
      try container.encode(v)
    case .array(let arr):
      try container.encode(arr.map { AnyCodable($0) })
    case .object(let dict):
      var out: [String: AnyCodable] = [:]
      for (k, v) in dict { out[k] = AnyCodable(v) }
      try container.encode(out)
    }
  }

  fileprivate static func from(_ raw: Any?) -> AnyCodableValue {
    guard let raw else { return .null }
    if let v = raw as? Bool { return .bool(v) }
    if let v = raw as? Int { return .int(v) }
    if let v = raw as? Double { return .double(v) }
    if let v = raw as? String { return .string(v) }
    if let v = raw as? [Any?] { return .array(v.map { AnyCodableValue.from($0) }) }
    if let v = raw as? [String: Any?] {
      var out: [String: AnyCodableValue] = [:]
      for (key, val) in v { out[key] = AnyCodableValue.from(val) }
      return .object(out)
    }
    return .null
  }
}
