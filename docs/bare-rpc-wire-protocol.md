# bare-rpc Wire Protocol — Reference for `QVACClient` Swift Port

> **Status:** YK-176 deliverable. Documents the exact bytes that travel over the IPC duplex between the Swift client and the Bare worker, plus how `bare-rpc-swift`'s public API maps to those frames. Every claim cites `file:line` in `holepunchto/bare-rpc` (JS reference) and `holepunchto/bare-rpc-swift` (Swift port).

## 1. Version Table

| Package | Version | Branch / Commit examined |
| --- | --- | --- |
| `bare-rpc` (npm, JS) | **1.3.1** | `main`, depth-1 HEAD |
| `bare-rpc-swift` (SPM, Swift) | unversioned | `main` @ `3983622` (`feat: bidirectional streams (#16)`) |
| `compact-encoding` (npm) | `^3.0.0` (dep of `bare-rpc`) | — |
| `compact-encoding-swift` (SPM) | `branch: main` @ `ab53958` | — |
| License | Apache-2.0 (both) | — |

**Important correction**: the kickoff note pointed at PR #13 commit `4e67f03` for the backpressure feature in `bare-rpc-swift`. That SHA is not present in `bare-rpc-swift`'s history. PR #13 (`feat: backpressure`) was merged at `8405c6f`. Backpressure is now in `main` along with bidirectional streams (PR #16) and max-frame-size guards (PR #14). No branch checkout is needed.

Reference list of merged PRs (chronological):
1. `8486c32` Initial implementation (#1)
2. `7a88cca` Move callback properties to delegate methods (#9)
3. `24bbf8e` CommandRouter (#10)
4. `02bb2c0` JS interop tests (#11)
5. `b07e09a` Response stream force-destroy + IncomingStream wire destroy (#12)
6. **`8405c6f` Backpressure (#13)** ← cork/uncork PAUSE/RESUME flow
7. `23f9e86` Max frame size (#14)
8. `59da153` Prettier (#15)
9. **`3983622` Bidirectional streams (#16)** ← current main HEAD

## 2. Frame Structure

Every frame on the wire is **`[ 4-byte body_length (uint32 LE) ][ body ]`**. The body length excludes the prefix itself.

```
+--------+--------+--------+--------+============================+
| u32 LE body length            ... | body (length bytes)         |
+--------+--------+--------+--------+============================+
```

Body layout, decoded as a chain of `compact-encoding` primitives:

```
type   : c.uint           // 1=REQUEST, 2=RESPONSE, 3=STREAM
id     : c.uint           // 0 for broadcast event, >=1 for request id

(type-specific, see §3)
```

Source-of-truth:
- `bare-rpc/lib/messages.js:24-102` (`header.encode`)
- `bare-rpc/lib/messages.js:104-155` (`message.decode`)
- `bare-rpc/index.js:142-178` (`_ondata`, `_onbeforeframe`, `_onafterframe`) — confirms the 4-byte prefix is read first, then the framed body
- Swift mirror: `bare-rpc-swift/Sources/BareRPC/Messages.swift:216-241` (`FrameCodec`)
- Swift mirror: `bare-rpc-swift/Sources/BareRPC/RPC.swift:96-119` (`receive(_:)` runs the same prefix-then-body loop, with a configurable `maxFrameSize` guard — default `16 * 1024 * 1024` bytes)

### 2.1 `compact-encoding` primitive cheatsheet

| Primitive | Wire shape | Notes |
| --- | --- | --- |
| `c.uint` (varint) | 1, 3, 5, or 9 bytes | `<0xFD` → 1 byte; `0xFD,u16 LE` → 3 bytes; `0xFE,u32 LE` → 5 bytes; `0xFF,u64 LE` → 9 bytes |
| `c.int` | zigzag-encoded varint | `n>=0` → `2n`; `n<0` → `-2n - 1`. Example: `-1` → `0x01`, `42` → `0x54`, `-2147483648` → `0xFEFFFFFFFF` |
| `c.bool` | 1 byte | `0x00` = false, `0x01` = true |
| `c.utf8` | `c.uint length + utf8 bytes` | length is byte length, not codepoint count |
| `c.optionalBuffer` | `c.uint length + bytes` | length=0 encodes an empty buffer; decoders may treat `0` as `nil` |
| `c.uint32` | 4 bytes LE | fixed-width, only used for the frame length prefix |

Empirically confirmed against the `InteropFixturesTests.swift` byte-exact fixtures (see §9).

## 3. Message Types

### 3.1 `REQUEST` (type = 1)

Used for one-shot requests, fire-and-forget events, and (in QVAC) the `__init_config` and `__shutdown__` handshakes.

```
type    : c.uint = 1
id      : c.uint              // 0 for event, >=1 for awaited request
command : c.uint              // application-level command id (in QVAC SDK: per-call counter)
stream  : c.uint              // 0 if inline data; non-zero (typically OPEN) if this is a stream init
data    : c.optionalBuffer    // PRESENT iff stream == 0
```

Source: `bare-rpc/lib/messages.js:32-37` (encode), `:114-120` (decode).

### 3.2 `RESPONSE` (type = 2)

Reply to a request with matching `id`. Either a success (with optional inline data) or a remote error (message + code + errno triple).

```
type    : c.uint = 2
id      : c.uint              // matches the originating request id
error   : c.bool              // true => error frame; false => success
stream  : c.uint              // 0 if inline data; non-zero (OPEN) if this is a stream init
if error:
  message : c.utf8
  code    : c.utf8
  errno   : c.int             // zigzag varint
else if stream == 0:
  data    : c.optionalBuffer
```

Source: `bare-rpc/lib/messages.js:39-45` (encode), `:122-135` (decode).

### 3.3 `STREAM` (type = 3)

Carries DATA chunks and control signals for any open stream (request-stream or response-stream).

```
type    : c.uint = 3
id      : c.uint              // matches the request id this stream belongs to
stream  : c.uint              // bitmask (see §3.4)
if stream & ERROR:
  message : c.utf8
  code    : c.utf8
  errno   : c.int
else if stream & DATA:
  data    : c.optionalBuffer
```

Source: `bare-rpc/lib/messages.js:47-53` (encode), `:137-149` (decode).

### 3.4 Stream flag bitmask

```
OPEN     = 0x01    // initial handshake / ack
CLOSE    = 0x02    // sender (OutgoingStream) finishing
PAUSE    = 0x04    // receiver telling sender to stop
RESUME   = 0x08    // receiver telling sender to resume
DATA     = 0x10    // chunk payload follows
END      = 0x20    // graceful end-of-stream, no more DATA
DESTROY  = 0x40    // receiver (IncomingStream) cancelling
ERROR    = 0x80    // ERROR payload follows (combine with CLOSE or DESTROY)
REQUEST  = 0x100   // direction marker: this stream is the REQUEST stream (uploads)
RESPONSE = 0x200   // direction marker: this stream is the RESPONSE stream (downloads)
```

Source: `bare-rpc/lib/constants.js:1-19` (verified byte-for-byte against `bare-rpc-swift/Sources/BareRPC/StreamConstants.swift:1-12`).

The direction marker is critical: a `STREAM` frame with `REQUEST|DATA` carries a chunk **on the upload stream** (client → server), while `RESPONSE|DATA` carries one on the download stream (server → client). Both can exist concurrently for the same `id` in a duplex session.

## 4. Request Multiplexing

The initiator owns id allocation:

- `bare-rpc/index.js:49-51`: `request(command) { return new OutgoingRequest(this, ++this._id, command) }`
- Counter is monotonically incrementing; **JS does not wrap on overflow** — the field is `Number`, so it'll silently grow past `2^53` and lose precision.
- Swift mirror wraps at `0xFFFF_FFFE` (`bare-rpc-swift/Sources/BareRPC/RPC.swift:43`): `nextId = (nextId % 0xFFFF_FFFE) + 1`. This means **Swift cannot interoperate with a JS peer once the JS side has issued more than ~4.29 billion requests in a session** — not a practical concern for QVAC but worth noting.
- `id = 0` is reserved for **events** (broadcast, no response expected).
- The receiver does no id allocation — it echoes the initiator's id back on RESPONSE and STREAM frames.

QVAC-specific note: the SDK's `getNextCommandId()` (`packages/sdk/client/rpc/rpc-client.ts:39-45`) is the application-layer counter that QVAC passes as `bare-rpc`'s `command` argument. **It is not a method discriminator** — see `docs/qvac-sdk-internals.md` §6. QVAC uses `rpc.request(getNextCommandId())` purely for bare-rpc framing; the actual SDK method is encoded in the JSON `data` payload's `type` field.

## 5. Streaming OPEN Handshake

Streams require a 2-step OPEN handshake before DATA can flow. The direction marker (REQUEST vs RESPONSE) in the stream flag distinguishes upload vs download.

### 5.1 Upload stream (client writes, server reads)

```
Client                                                       Server
  | (1) REQUEST { id, command, stream=OPEN, data=nil } ---->  |
  |                                                           | creates IncomingStream
  | <----  (2) STREAM   { id, stream=REQUEST|OPEN } --------- |
  | (continueOpen on OutgoingStream._open's pending list)     |
  | (3) STREAM { id, stream=REQUEST|DATA, data=... }   ---->  |  push
  | (3) STREAM { id, stream=REQUEST|DATA, data=... }   ---->  |  push
  | (4) STREAM { id, stream=REQUEST|END }              ---->  |  end()
  | (5) STREAM { id, stream=REQUEST|CLOSE }            ---->  |  full teardown
```

Source:
- (1) sent by `bare-rpc/lib/outgoing-stream.js:29-43` (REQUEST type, OPEN flag, no data)
- (2) sent by `bare-rpc/lib/incoming-stream.js:14-25` (STREAM type, mask|OPEN), received as `_onstreamopen` by initiator which clears `_pendingRequests` and lets `OutgoingStream._open`'s flushed callback run
- (3) `outgoing-stream.js:69-80`
- (4) `outgoing-stream.js:82-93`
- (5) `outgoing-stream.js:95-119` — emitted on Writable `_destroy`. Note the asymmetry: OutgoingStream sends `CLOSE`, IncomingStream sends `DESTROY` (see §7).

Swift mirror: `bare-rpc-swift/Sources/BareRPC/RPC.swift:57-66` (`createRequestStream`) sends frame (1); `:155-169` (`handleRequestStreamOpen`) creates the IncomingStream and sends frame (2). OutgoingStream `write()`, `end()`, `destroy()` send frames (3)/(4)/(5) (`OutgoingStream.swift:18-49`).

### 5.2 Download stream (server writes, client reads)

```
Client                                                       Server
  | (0) REQUEST { id, command, stream=0, data=<JSON> }  ---->  |
  |                                                           | dispatches handler
  | <----  (1) RESPONSE { id, error=false, stream=OPEN } ---  |
  | creates IncomingStream                                    |
  | (2) STREAM { id, stream=RESPONSE|OPEN }            ---->  | continueOpen
  | <----  (3) STREAM { id, stream=RESPONSE|DATA, data=... } -|
  | <----  (3) STREAM { id, stream=RESPONSE|DATA, data=... } -|
  | <----  (4) STREAM { id, stream=RESPONSE|END }   --------  |
  | <----  (5) STREAM { id, stream=RESPONSE|CLOSE } --------  |
```

Source: same as §5.1 but with mask=RESPONSE. The QVAC SDK uses this pattern for every method registered as `stream` in `handler-registry.ts` (transcribe, completionStream, etc. — see `docs/qvac-sdk-internals.md` §6).

Note on JSON streams: the JS SDK does **not** rely on individual STREAM-DATA frames being one JSON document. It assembles the receive buffer and splits on `'\n'`, parsing each line as a JSON object (see `packages/sdk/client/rpc/rpc-client.ts:255-272`). So the Swift port must:
1. Concatenate all `DATA` chunks for the response stream.
2. Split on `\n`.
3. Parse each non-empty line as a separate JSON response.
4. Treat END/CLOSE as end-of-stream (whichever arrives first).

### 5.3 Bidirectional streams

Used by QVAC's `transcribeStream` and `textToSpeechStream` (`handler-registry.ts:114, 118` — declared `type: "duplex"`).

The bidirectional handshake combines §5.1 and §5.2: client opens an upload stream (sending REQUEST with `stream=OPEN`), server creates **both** an IncomingStream (for client→server chunks) and an OutgoingStream (for server→client chunks). The first chunk sent by the client on the upload stream is the JSON metadata for the original request — `server/rpc/handle-request.ts:142-204` (`handleDuplexRequest`) reads it via `inputStream.once("data")` before invoking the handler.

Swift `RPC.createBidirectionalStream(command:)` (`RPC.swift:68-81`) is the matching primitive on the initiator side.

## 6. Backpressure: PAUSE / RESUME

Each `IncomingStream` (the consumer side) tracks how many DATA chunks are buffered. When the buffer hits its high watermark, it tells the sender to stop. When it drains below the low watermark, it tells the sender to resume.

### JS

`bare-rpc/index.js:344-369` (`_onstreamdata`):
```js
if (stream.push(message.data) === false) {
  this._sendMessage({
    type: t.STREAM,
    id: stream._request.id,
    stream: stream._mask | s.PAUSE,
    ...
  })
}
```

`bare-rpc/lib/incoming-stream.js:27-35` (`_read()`) — sends RESUME each time the Readable's `_read` is called (i.e. the consumer wants more):
```js
this._rpc._sendMessage({
  type: t.STREAM, id: ..., stream: this._mask | s.RESUME, ...
})
```

Sender-side (`bare-rpc/index.js:304-322`, `_onstreampause`/`_onstreamresume`): `stream.cork()` / `stream.uncork()` — the Writable's standard cork mechanism queues writes until uncorked.

### Swift

The Swift port is more explicit about the watermarks:

`IncomingStream.swift:18-25`:
```swift
init(requestId: UInt, mask: UInt, rpc: RPC, highWaterMark: Int = 16, lowWaterMark: Int = 4)
```

`IncomingStream.push(_:)` sends PAUSE when `buffer.count >= highWaterMark`. `IncomingStream.nextChunk()` (the AsyncIterator entry point) sends RESUME when `buffer.count <= lowWaterMark`.

`OutgoingStream.swift:18-26` — `write()` suspends on a continuation while `corked == true`. The RPC dispatcher's `handleStreamMessage` translates PAUSE → `cork()`, RESUME → `uncork()`.

Wire frames (verified hex):
- PAUSE on upload: `STREAM { id, stream = REQUEST|PAUSE }` — flag `0x100 | 0x4 = 0x104`
- RESUME on upload: `STREAM { id, stream = REQUEST|RESUME }` — flag `0x108`
- PAUSE on download: `RESPONSE|PAUSE` = `0x204`
- RESUME on download: `0x208`

Swift watermark defaults (highWaterMark=16 chunks, lowWaterMark=4) are conservative for QVAC's streaming use cases (e.g. completion token-by-token). The Swift port exposes them in the initializer so QVACClient can tune per-method.

## 7. End-of-stream vs Destroy

Two paths, asymmetric:

| Initiating side | Frame sent | Receiver sees | Semantics |
| --- | --- | --- | --- |
| OutgoingStream finishes normally | `STREAM mask|END` then `STREAM mask|CLOSE` | end-of-iteration | sender said "done sending" |
| OutgoingStream errored | `STREAM mask|CLOSE|ERROR + error payload` | iterator throws | sender failed mid-stream |
| IncomingStream destroyed (cancel) | `STREAM mask|DESTROY` | sender's OutgoingStream destroyed | receiver said "stop sending" |
| IncomingStream destroyed (error) | `STREAM mask|DESTROY|ERROR + error payload` | sender's OutgoingStream destroyed | receiver failed |

Source-of-truth:
- OutgoingStream graceful end: `bare-rpc/lib/outgoing-stream.js:82-119` sends END then (on `_destroy`) CLOSE
- IncomingStream destroy: `bare-rpc/lib/incoming-stream.js:37-61` sends DESTROY (or DESTROY|ERROR)
- Dispatcher: `bare-rpc/index.js:235-410` — `_onstreamend`, `_onstreamclose`, `_onstreamdestroy`

Swift mirror:
- `OutgoingStream.swift:28-49`: `end()` sends END+CLOSE; `destroy(error:)` sends CLOSE+ERROR or CLOSE
- `IncomingStream.swift:52-73`: `destroy(error:)` sends DESTROY or DESTROY+ERROR

This asymmetry matters: **a Swift cancellation of a server-streamed download must send `DESTROY` (on the response direction), not `CLOSE`** — sending CLOSE here would be invalid (it's the sender-side teardown signal).

## 8. Payload Encoding — JSON only for QVAC

Inside the `data` field (an `optionalBuffer` = raw bytes from bare-rpc's perspective), QVAC always lays a **UTF-8 JSON string**. There is **no** `bare-structured-clone`, msgpack, or proprietary envelope.

Evidence (cross-referenced from YK-175):
- `packages/sdk/client/rpc/rpc-client.ts:127`: `req.send(JSON.stringify(payloadObj), "utf-8")` (reply mode)
- `:170, 240, 305, 412`: same pattern for stream and duplex modes
- `packages/sdk/server/rpc/handler-utils.ts:70`: `req.reply(profiler.serialize(response, true), "utf-8")` (reply on server)
- `:104, 107, 116`: `stream.write(profiler.serialize(response, isTerminal) + "\n", "utf-8")` (stream/duplex on server — note the trailing `\n`)
- `compact-encoding` is a transitive dep of `corestore`/`hyperdb`, not used by `@qvac/sdk` for RPC payloads

This answers the **single most important question** from the YK-176 brief: payloads are JSON. The Swift port uses `JSONEncoder` / `JSONDecoder` directly on `Data` produced by/passed to `bare-rpc-swift`.

The streaming subprotocol is **newline-delimited JSON**: each `STREAM|DATA` chunk may contain one or more JSON objects, each followed by `\n`. The client buffers across chunks and splits on `\n`. Empty lines are skipped. This is QVAC SDK convention, layered on top of bare-rpc — bare-rpc itself does not require a delimiter.

## 9. Hex Frame Fixtures (verified)

These are byte-exact frame captures verified by `swift test --filter InteropFixturesTests` (29/29 passing on macOS 26.4 / Swift 6.2 — see §11). Each row decodes to the described frame and re-encodes to the same bytes.

| Frame | Hex (body-length-prefixed) | Decoded |
| --- | --- | --- |
| REQUEST id=1 cmd=42 data="hello" | `0a000000 01 01 2a 00 0568656c6c6f` | REQUEST { id:1, cmd:42, stream:0, data:hello } |
| REQUEST id=2 cmd=7 data=empty | `05000000 01 02 07 00 00` | REQUEST { id:2, cmd:7, stream:0, data:nil } |
| REQUEST id=0 cmd=99 data=0xdeadbeef | `09000000 01 00 63 00 04deadbeef` | EVENT { cmd:99, data:0xdeadbeef } |
| REQUEST id=3 cmd=5 stream=OPEN | `04000000 01 03 05 01` | REQUEST stream-open id=3 |
| REQUEST id=1 cmd=300 (3-byte varint) | `09000000 01 01 fd2c01 00 026869` | REQUEST { id:1, cmd:300, data:"hi" } |
| REQUEST id=1000 (3-byte varint) cmd=1 data=empty | `07000000 01 fde803 01 00 00` | REQUEST { id:1000, cmd:1, stream:0, data:nil } |
| REQUEST id=0xFFFFFFFE (5-byte varint) | `0c000000 01 fefeffffff 02 00 03010203` | REQUEST max32 id |
| REQUEST id=2^32 (9-byte varint) | `10000000 01 ff0000000001000000 02 00 03010203` | REQUEST id=2^32 |
| RESPONSE id=1 data="world" | `0a000000 02 01 00 00 05776f726c64` | RESPONSE success { id:1, data:"world" } |
| RESPONSE id=2 data=empty | `05000000 02 02 00 00 00` | RESPONSE success { id:2, data:nil } |
| RESPONSE id=1 error message="boom" code="EBOOM" errno=-2 | `10000000 02 01 01 00 04626f6f6d 0545424f4f4d 03` | RESPONSE remoteError |
| RESPONSE id=4 stream=OPEN | `04000000 02 04 00 01` | RESPONSE stream-open id=4 |
| STREAM id=3 REQUEST\|OPEN | `05000000 03 03 fd0101` | STREAM upload-open ack id=3 |
| STREAM id=4 RESPONSE\|OPEN | `05000000 03 04 fd0102` | STREAM download-open ack id=4 |
| STREAM id=3 REQUEST\|DATA "abc" | `09000000 03 03 fd1001 03616263` | STREAM upload data |
| STREAM id=3 REQUEST\|END | `05000000 03 03 fd2001` | STREAM upload end |
| STREAM id=3 REQUEST\|CLOSE | `05000000 03 03 fd0201` | STREAM upload close |
| STREAM id=4 RESPONSE\|DATA "xyz" | `09000000 03 04 fd1002 0378797a` | STREAM download data |
| STREAM id=4 RESPONSE\|END | `05000000 03 04 fd2002` | STREAM download end |
| STREAM id=4 RESPONSE\|CLOSE | `05000000 03 04 fd0202` | STREAM download close |
| STREAM id=3 REQUEST\|DESTROY | `05000000 03 03 fd4001` | STREAM upload destroy |
| STREAM id=4 RESPONSE\|DESTROY | `05000000 03 04 fd4002` | STREAM download destroy |
| STREAM id=3 REQUEST\|ERROR message="nope" code="ENOPE" errno=-1 | `11000000 03 03 fd8001 046e6f7065 05454e4f5045 01` | STREAM upload error |
| STREAM id=4 RESPONSE\|ERROR message="boom" code="EBOOM" errno=-1 | `11000000 03 04 fd8002 04626f6f6d 0545424f4f4d 01` | STREAM download error |

Notes on encoding:

- The 4-byte `uint32 LE` prefix in front of every frame: `0a000000` = 10 (decimal) = body length.
- `c.uint` varint: values `<0xFD` are 1 byte. Stream-direction-or-flag values like `0x101`, `0x102`, `0x104`, etc. all exceed 0xFC, so they use the 3-byte varint form `fd <u16 LE>`. That's why every stream-direction frame above has `fd...` in the stream-flag position.
- `c.int` zigzag: `-1` → `0x01`, `-2` → `0x03`, `42` → `0x54`, `-2147483648` → `0xFEFFFFFFFF`.
- `c.optionalBuffer`: `length-varint + bytes`. Empty buffer encodes as a single byte `0x00` (length=0).
- An empty buffer round-trips to `nil` in the Swift decoder (`Messages.swift:62`) — this is a documented divergence from JS where the field stays `Buffer.alloc(0)`. QVAC code paths never depend on the distinction.

Fixtures regenerator (Bare/Node): `bare-rpc-swift/Tests/BareRPCTests/Fixtures/gen_fixtures.js`. To re-verify after any wire bump:
```bash
cd ~/qvac/bare-rpc-swift/Tests/BareRPCTests/Fixtures
bun install   # or: npm install
bare gen_fixtures.js   # prints JSON of {name → hex}
```

## 10. `bare-rpc-swift` Public API Surface

Everything Swift code calls on `bare-rpc-swift` to produce or consume the frames above. **All cited from `main` @ `3983622`.**

### 10.1 The `RPC` actor — `Sources/BareRPC/RPC.swift`

```swift
public actor RPC {
  public static let defaultMaxFrameSize: Int = 16 * 1024 * 1024  // 16 MiB
  public let maxFrameSize: Int
  public weak var delegate: RPCDelegate?

  public init(delegate: RPCDelegate? = nil, maxFrameSize: Int = .defaultMaxFrameSize)

  // Initiator
  public func request(_ command: UInt, data: Data? = nil) async throws -> Data?
  public func requestWithResponseStream(command: UInt, data: Data? = nil) async throws -> IncomingStream
  public func createRequestStream(command: UInt) throws -> OutgoingStream
  public func createBidirectionalStream(command: UInt) async throws
    -> (outgoing: OutgoingStream, incoming: IncomingStream)
  public func event(_ command: UInt, data: Data? = nil)

  // Transport plumbing
  public func receive(_ data: Data) async   // call from your Transport on bytes-in
}
```

### 10.2 The `RPCDelegate` protocol — same file

```swift
public protocol RPCDelegate: AnyObject {
  func rpc(_ rpc: RPC, send data: Data)
  func rpc(_ rpc: RPC, didReceiveRequest request: IncomingRequest) async throws
  func rpc(_ rpc: RPC, didReceiveEvent event: IncomingEvent) async
  func rpc(_ rpc: RPC, didFailWith error: Error)
}
```

This is the seam where the QVAC Swift port wires the IPC `Transport` (YK-183). The Swift port owns:

- a `Transport` (UDS / Bare-kit / Mock) that produces bytes-in and accepts bytes-out
- an `RPC` actor that turns bytes ↔ frames
- the QVAC client code that turns frames ↔ method calls

The `RPCDelegate.send` callback writes outbound bytes to the Transport; the Transport's read loop calls `await rpc.receive(data)` for inbound bytes.

### 10.3 `IncomingRequest` — `IncomingRequest.swift`

```swift
public class IncomingRequest {
  public let command: UInt
  public let id: UInt
  public let data: Data?
  public let requestStream: IncomingStream?

  public func reply(_ data: Data? = nil) async
  public func reject(_ message: String, code: String = "ERROR", errno: Int = 0) async
  public func createResponseStream() async -> OutgoingStream?
}
```

`requestStream` is non-nil when the original REQUEST opened an upload stream (i.e. duplex / request-stream methods).

### 10.4 `IncomingStream` — `IncomingStream.swift`

```swift
public actor IncomingStream: AsyncSequence {
  public typealias Element = Data
  public nonisolated let requestId: UInt
  public nonisolated let mask: UInt           // StreamFlag.request or .response
  public nonisolated let highWaterMark: Int   // default 16
  public nonisolated let lowWaterMark: Int    // default 4
  public private(set) var finished: Bool

  public func destroy(error: RPCRemoteError? = nil) async
  public nonisolated func makeAsyncIterator() -> AsyncIterator
}
```

Use `for try await chunk in incomingStream { ... }`. Watermarks dictate when `PAUSE`/`RESUME` go out (§6). Cancel mid-iteration by calling `await stream.destroy()`.

### 10.5 `OutgoingStream` — `OutgoingStream.swift`

```swift
public actor OutgoingStream {
  public nonisolated let requestId: UInt
  public nonisolated let mask: UInt
  public private(set) var ended: Bool
  public private(set) var corked: Bool

  public func write(_ data: Data) async      // suspends if corked
  public func end() async                    // sends END+CLOSE
  public func destroy(error: RPCRemoteError? = nil) async   // sends CLOSE (+ERROR)
}
```

`cork()`/`uncork()` are internal-only; they're driven by inbound PAUSE/RESUME frames from the dispatcher.

### 10.6 `IncomingEvent`, `RPCError`, `CommandRouter`

- `IncomingEvent { command: UInt, data: Data? }` — for `id == 0` frames.
- `RPCError.frameTooLarge(size:limit:)` — surfaced when an inbound frame exceeds `maxFrameSize`.
- `RPCRemoteError { message, code, errno }` — what a `RESPONSE` error or `STREAM|ERROR` frame deserializes to.
- `CommandRouter` — convenience dispatcher for server-side request/event handlers (per-command closures). Useful for the test fixture worker (YK-191).

### 10.7 Gap vs JS reference

The Swift port consolidates a few JS classes:

| JS | Swift |
| --- | --- |
| `OutgoingRequest` (per-call object with `send` / `reply` / `createRequestStream` / `createResponseStream`) | folded into `RPC.request(_:data:)` / `RPC.requestWithResponseStream(...)` / `RPC.createRequestStream(...)` / `RPC.createBidirectionalStream(...)` |
| `OutgoingEvent` | folded into `RPC.event(_:data:)` |
| `IncomingRequest.createRequestStream()` (for duplex) | populated automatically as `IncomingRequest.requestStream` when the server-side handler receives a REQUEST with `stream=OPEN` |

No functionality is missing for QVAC's needs. The Swift API just trades JS's object-per-call style for async/await + actors.

## 11. Validation Tests

### 11.1 Manual verification

Toolchain on this machine: macOS 26.4.1, Swift 6.2 (`swift-driver 1.127.14.1`, target `arm64-apple-macosx26.0`).

```bash
$ cd ~/qvac/bare-rpc-swift
$ swift build
Build complete! (5.31s)

$ swift test --filter InteropFixturesTests
✔ Suite InteropFixturesTests passed after 0.001 seconds.
✔ Test run with 29 tests in 1 suite passed after 0.001 seconds.
```

Tests cover request/event/response/error/stream framings with explicit hex byte expectations — including multi-byte varint encodings for ids/commands up to `2^32`, zigzag for negative errno, multi-byte UTF-8 lengths, and stream OPEN/DATA/END/DESTROY/CLOSE/ERROR for both REQUEST and RESPONSE directions. **29/29 pass.**

### 11.2 To-be-added: `Tests/QVACClientTests/WireProtocolFixturesTest.swift`

The YK-176 acceptance criteria includes "At least 3 wire-frame fixture tests in Swift pass" in the **QVAC client repo** (not `bare-rpc-swift`). Once `Package.swift` is set up (YK-174), add the following minimal port. They re-use the verified hex strings above and only require `BareRPC` as a SPM dep (added by YK-177).

```swift
import XCTest
@testable import QVACClient
import BareRPC

final class WireProtocolFixturesTest: XCTestCase {
  // Re-uses fixtures verified in bare-rpc-swift's InteropFixturesTests.swift.
  // These guarantee QVACClient pins the same wire format observed in M1.

  func testDecodePingFrame() throws {
    let hex = "0a00000001012a000568656c6c6f"
    let bytes = Data(hex: hex)
    let frame = try Messages.decodeFrame(bytes)
    guard case .request(let req) = frame else {
      return XCTFail("expected REQUEST")
    }
    XCTAssertEqual(req.id, 1)
    XCTAssertEqual(req.command, 42)
    XCTAssertEqual(req.stream, 0)
    XCTAssertEqual(req.data, Data("hello".utf8))
  }

  func testDecodeStreamDataFrame() throws {
    let hex = "090000000303fd100103616263"
    let bytes = Data(hex: hex)
    let frame = try Messages.decodeFrame(bytes)
    guard case .stream(let s) = frame else {
      return XCTFail("expected STREAM")
    }
    XCTAssertEqual(s.flags, StreamFlag.request | StreamFlag.data)
    XCTAssertEqual(s.data, Data("abc".utf8))
  }

  func testDecodeErrorResponseFrame() throws {
    let hex = "100000000201010004626f6f6d0545424f4f4d03"
    let bytes = Data(hex: hex)
    let frame = try Messages.decodeFrame(bytes)
    guard case .response(let resp) = frame,
          case .remoteError(let m, let c, let e) = resp.result else {
      return XCTFail("expected RESPONSE error")
    }
    XCTAssertEqual(m, "boom")
    XCTAssertEqual(c, "EBOOM")
    XCTAssertEqual(e, -2)
  }
}
```

**Status of this test**: file deferred until `Package.swift` exists (YK-174) and `BareRPC` is a SPM dep (YK-177). The fixture bytes are pre-validated and committed in this doc as ground truth.

### 11.3 Bare interop test (optional, requires `bare` runtime)

`bare-rpc-swift/Tests/BareRPCTests/BareInteropTests.swift` spawns a real Bare worker via `bare-rpc/Tests/Fixtures/rpc_peer.js` and round-trips actual frames. Not run here (requires `bare` runtime + npm install in the fixtures dir); will be exercised at YK-191/YK-192 against the QVAC ping fixture.

## 12. Frame Decoder State Machine (informative)

Pseudo-code for the dispatch loop, matching both JS (`bare-rpc/index.js:142-220`) and Swift (`bare-rpc-swift/Sources/BareRPC/RPC.swift:96-119, 242-293`):

```
loop:
  read 4 bytes → body_length: uint32 LE
  if body_length > maxFrameSize: fail(frameTooLarge)
  read body_length bytes → body

  parse body:
    type = c.uint
    id   = c.uint
    switch type:
      REQUEST (1):
        command = c.uint
        stream  = c.uint
        if stream == 0:  data = c.optionalBuffer
        if id == 0:
          deliver as IncomingEvent
        else if stream == OPEN:
          create IncomingStream (upload), ack with STREAM|REQUEST|OPEN
          deliver as IncomingRequest with requestStream attached
        else:
          deliver as IncomingRequest
      RESPONSE (2):
        error  = c.bool
        stream = c.uint
        if error: parse {utf8, utf8, c.int} → resolve pending continuation with throw
        else if stream == OPEN: create IncomingStream (download), ack, resolve with stream
        else if stream == 0:
          data = c.optionalBuffer
          resolve pending continuation with data
      STREAM (3):
        stream = c.uint
        if stream & OPEN:  no-op (it's an ack we issued already)
        if stream & CLOSE: end the matching IncomingStream
        if stream & END:   end the matching IncomingStream
        if stream & DESTROY: destroy the matching OutgoingStream
        if stream & PAUSE: cork the matching OutgoingStream
        if stream & RESUME: uncork the matching OutgoingStream
        if stream & DATA:  push data into the matching IncomingStream
        if stream & ERROR: deliver remote error to the matching stream
```

## 13. Open Questions for Tether

1. **Wire stability across `@qvac/sdk` versions**. `bare-rpc` is at 1.3.x; QVAC pins `^1.0.0`. Is there a published commitment that the wire layout (the parts in §3) will not break in a minor bump? If yes, we'd like to add a `bare-rpc` version assertion at SDK init. If no, we'll pin both `bare-rpc` (JS) and `bare-rpc-swift` versions and rebuild on every QVAC bump.

2. **`maxFrameSize` policy**. `bare-rpc-swift` defaults to 16 MiB. QVAC payloads for image generation (`diffusionStream`) can carry base64-encoded PNGs that approach or exceed that; we'll likely need to raise the limit on a per-connection basis. **Is there a documented maximum frame size the worker will emit, or should the Swift client size to "unlimited"?**

3. **JS Number id overflow**. JS `bare-rpc` uses `++this._id` without wrap. Swift wraps at `0xFFFF_FFFE`. The mismatch is impractical to hit but worth knowing whether Tether expects a server side cap. We'll cap at `0xFFFF_FFFE` to match Swift.

4. **Per-call profiling metadata**. QVAC's RPC layer injects optional profiling metadata into the JSON envelope (`packages/sdk/client/rpc/rpc-client.ts:160-208`), not the bare-rpc framing. The Swift port just round-trips it. Confirm: profiling metadata is purely advisory and the wire format does not depend on it.

5. **Newline-delimited JSON convention**. The SDK appends `\n` after every stream chunk on the server side (`packages/sdk/server/rpc/handler-utils.ts:104`) and splits on `\n` on the client side. **Is this a stable convention or a QVAC implementation detail?** If stable, we can rely on it; if implementation detail, we should treat any non-JSON byte run as opaque and skip the line splitting.

## 14. Source-of-Truth File Index

| Concern | File |
| --- | --- |
| JS RPC core | `bare-rpc/index.js:1-423` |
| JS frame encoding | `bare-rpc/lib/messages.js:1-156` |
| JS constants (types + stream flags) | `bare-rpc/lib/constants.js:1-19` |
| JS outgoing request | `bare-rpc/lib/outgoing-request.js:1-74` |
| JS incoming request | `bare-rpc/lib/incoming-request.js:1-57` |
| JS outgoing event | `bare-rpc/lib/outgoing-event.js:1-27` |
| JS incoming event | `bare-rpc/lib/incoming-event.js:1` |
| JS outgoing stream | `bare-rpc/lib/outgoing-stream.js:1-121` |
| JS incoming stream | `bare-rpc/lib/incoming-stream.js:1-63` |
| JS command router | `bare-rpc/lib/command-router.js:1-` |
| JS errors | `bare-rpc/lib/errors.js:1-27` |
| Swift RPC actor | `bare-rpc-swift/Sources/BareRPC/RPC.swift:1-295` |
| Swift Messages codec | `bare-rpc-swift/Sources/BareRPC/Messages.swift:1-290` |
| Swift constants | `bare-rpc-swift/Sources/BareRPC/StreamConstants.swift:1-12` |
| Swift IncomingRequest | `bare-rpc-swift/Sources/BareRPC/IncomingRequest.swift:1-39` |
| Swift IncomingStream | `bare-rpc-swift/Sources/BareRPC/IncomingStream.swift:1-115` |
| Swift OutgoingStream | `bare-rpc-swift/Sources/BareRPC/OutgoingStream.swift:1-79` |
| Swift IncomingEvent | `bare-rpc-swift/Sources/BareRPC/IncomingEvent.swift:1-7` |
| Swift CommandRouter | `bare-rpc-swift/Sources/BareRPC/CommandRouter.swift:1-85` |
| Swift RPCError | `bare-rpc-swift/Sources/BareRPC/RPCError.swift:1-18` |
| Swift fixture tests | `bare-rpc-swift/Tests/BareRPCTests/InteropFixturesTests.swift:1-494` |
| Swift messages tests | `bare-rpc-swift/Tests/BareRPCTests/MessagesTests.swift:1-174` |
| Fixture generator (JS) | `bare-rpc-swift/Tests/BareRPCTests/Fixtures/gen_fixtures.js:1-130` |
| QVAC SDK RPC client (consumer) | `qvac/packages/sdk/client/rpc/rpc-client.ts:1-558` |
| QVAC SDK Node transport | `qvac/packages/sdk/client/rpc/node-rpc-client.ts:1-352` |
| QVAC SDK init handshake | `qvac/packages/sdk/client/init-hooks.ts:29-93` |

Reproduce locally:

```bash
git clone --depth=1 https://github.com/holepunchto/bare-rpc.git       ~/qvac/bare-rpc
git clone https://github.com/holepunchto/bare-rpc-swift.git           ~/qvac/bare-rpc-swift
cd ~/qvac/bare-rpc-swift
git rev-parse HEAD     # expect: 3983622... feat: bidirectional streams (#16)
swift build            # expect: Build complete! (~5s)
swift test --filter InteropFixturesTests   # expect: 29/29 pass
```

---

_End of document. Re-run §11 validations after every `bare-rpc-swift` update; refresh §9 hex table if the fixture generator changes._
