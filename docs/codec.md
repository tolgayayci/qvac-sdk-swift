# Codec

The `Codec` protocol is the seam between the typed Swift surface
(`QVACClient`, generated `Codable` DTOs) and the bare-rpc `Data` payload
that travels over the wire.

```swift
public protocol Codec: Sendable {
  func encode<T: Encodable>(_ value: T) throws -> Data
  func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}
```

## Why a protocol

Lifting `JSONEncoder` / `JSONDecoder` out of `RPCBridge` and behind a
protocol buys three things:

1. **Injection seam for tests.** A `LoggingCodec` or `TraceCodec` can
   wrap the production codec, count calls, snapshot raw payloads, or
   replay fixtures — without touching `RPCBridge` or `QVACClient`.
   `CodecTest.testCustomCodecCanBeInjected` proves the seam works.
2. **Single-line format swap.** If upstream ever moves from JSON to
   `bare-structured-clone` or a length-prefixed binary format, one
   conformer changes. Every layer above is unaware.
3. **Wire-error frame isolation.** `RPCBridge.decodeResponseOrThrow`
   tries to decode the response as a `WireErrorFrame` first (the SDK's
   `{ type: "error", code, name, message }` shape). Routing both
   the error-frame probe and the typed-response decode through the
   same `Codec` keeps configuration consistent — no risk of one path
   using snake_case keys while the other uses camelCase.

## Production format: JSON

QVAC's wire payloads are **JSON**, confirmed by reading every handler
in `packages/sdk/server/rpc/handler-registry.ts` and documented in
[`qvac-sdk-internals.md`](./qvac-sdk-internals.md) §8. The production
`JSONCodec` is what `RPCBridge.init(transport:codec:)` defaults to.

### Configuration choices

| Setting | Value | Reason |
| --- | --- | --- |
| `keyEncodingStrategy` | `.useDefaultKeys` | The JS server emits camelCase keys; generated Swift DTOs use camelCase property names that match verbatim. Where the wire name differs (kebab-case, snake-case), the DTO carries its own `CodingKey` override — handled at the type level, not the codec. |
| `keyDecodingStrategy` | `.useDefaultKeys` | Symmetry with the encoder. |
| `outputFormatting` | `[]` (compact) | Wire doesn't need formatting; compact is faster and smaller. |
| `dateEncodingStrategy` | `.deferredToDate` (default) | No M1-allowlist DTO carries a `Date` field. Date-heavy DTOs added later decide their own encoding via `Codable`. Global override added here if a common rule is needed. |
| `dateDecodingStrategy` | `.deferredToDate` (default) | Symmetry with the encoder. |
| `nonConformingFloatEncodingStrategy` | not set | NaN / Inf in JSON is illegal; the encoder throws rather than silently coercing. |

## Forward-compat guarantees

- **Unknown fields are silently ignored on decode.** `JSONDecoder`'s
  default ignores extra keys, so a newer worker that adds a field
  doesn't break an older Swift client. Covered by
  `CodecTest.testUnknownFieldsAreSilentlyIgnored`.
- **Missing required fields throw** `DecodingError.keyNotFound`. The
  error surfaces upstream as `QVACError.transport(.decodingFailed)` via
  `RPCBridge.decodeResponseOrThrow`. Covered by
  `CodecTest.testMissingRequiredFieldThrows` and `testEmptyJSONObjectThrowsOnRequiredFields`.
- **Type-mismatched fields throw** `DecodingError.typeMismatch`. Same
  upstream mapping. Covered by `CodecTest.testTypeMismatchThrows`.

## Streaming

Streaming responses (`completion`, `transcribe`, `loggingStream`, etc.)
arrive as **newline-delimited JSON** — each chunk is a self-contained
JSON object terminated by `\n`. The newline split happens inside
`RPCBridge.consumeStreamResponse`; the codec only ever sees one
JSON value per `decode` call.

## Deferred to YK-208 (real worker integration)

- **JS↔Swift byte-identical capture for representative requests.**
  Needs a live Bare worker emitting QVAC payloads; M1 ships only a
  PING fixture.
- **Legacy payload snapshots** in `Tests/Fixtures/legacy-payloads/`
  as a backwards-compat guard.
- **Binary payload pass-through** for large `embed` / `diffusion`
  responses (≥10 MB), checking we don't OOM on decode.

All three are recorded in the YK-211 M2-GATE checklist so the real
worker integration picks them up.

## How to swap in a non-default codec

```swift
struct CountingCodec: Codec {
  let inner: Codec
  let counter: Counter  // your test fixture

  func encode<T: Encodable>(_ v: T) throws -> Data {
    counter.encodes += 1
    return try inner.encode(v)
  }
  func decode<T: Decodable>(_ t: T.Type, from d: Data) throws -> T {
    counter.decodes += 1
    return try inner.decode(t, from: d)
  }
}

let bridge = RPCBridge(transport: myTransport, codec: CountingCodec(inner: JSONCodec(), counter: c))
```

For production callers there's nothing to pass — `RPCBridge(transport:)`
uses `JSONCodec()` automatically.
