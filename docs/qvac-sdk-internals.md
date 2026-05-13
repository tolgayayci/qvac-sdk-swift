# QVAC SDK Internals — Reference for `QVACClient` Swift Port

> **Status:** YK-175 deliverable. Captures the exact wire protocol, request type registry, error codes, init handshake, and per-method request/response shapes that the Swift client must reproduce. Every claim is cited with a file path + line number from a local clone of `tetherto/qvac`.

## 1. Version Table

| Field | Value |
| --- | --- |
| Package | `@qvac/sdk` |
| Version examined | **0.10.2** |
| Repo | `https://github.com/tetherto/qvac` |
| Branch | `main` |
| Commit SHA examined | `9db6f98` (`QVAC-18827 feat[bc|api]: add unloadModel autoClose option, default-off on Bare`) |
| License | Apache-2.0 |
| `@qvac/error` peer | `^0.1.1` (examined: `0.1.2`) |
| `bare-rpc` peer | `^1.0.0` |
| Module type | ESM (`"type": "module"`) |
| Main entry | `./dist/index.js` (built from `index.ts`) |
| Public types entry | `./dist/index.d.ts` |
| Runtime targets | Bare, Node, React Native (Expo) — distinct RPC clients each |

Source-of-truth files:
- `packages/sdk/package.json:1-30`
- `packages/sdk/index.ts:1-159` (full public surface)
- `packages/error/package.json:1-30`

## 2. Critical Correction to YK-175 Premise

The Linear issue body assumes a **numeric command ID table** in `lib/rpc/commands.js`. **No such table exists in the repository.** Method dispatch is by **string-typed `request.type` discriminator** parsed by a Zod discriminated union (`packages/sdk/schemas/common.ts:93-125`). The only numeric request identifier in the wire is the per-call counter `bare-rpc` uses to correlate request/response framing — generated client-side via a monotonic `commandCounter` (`packages/sdk/client/rpc/rpc-client.ts:39-45`):

```ts
let commandCounter = 0;
function getNextCommandId() {
  commandCounter = (commandCounter + 1) % Number.MAX_SAFE_INTEGER;
  return commandCounter;
}
```

That counter is opaque to the SDK protocol layer. The Swift code-gen target is therefore:

1. An enum of **string** `RequestType` discriminants (34 entries — see §6).
2. Generated `Codable` request/response structs keyed by the discriminant.

Implication for `YK-181` (M1-CODEGEN-ERRORS): no `commands.js` to read; the codegen pipeline must walk `packages/sdk/schemas/*.ts` Zod schemas to enumerate types.

## 3. Architecture Overview

```
+--------------------+              UDS / named pipe                 +-----------------------+
|  Swift QVACClient  | <----------------------------------------->   |  Bare worker process  |
|  (host process)    |   bare-rpc frames over a Duplex byte stream   |  (qvac/worker.js)     |
+--------------------+                                                +-----------------------+
        |                                                                       |
        | initializeConfig (commandId=1, type="__init_config")  -->  setSDKConfig / setRuntimeContext
        | <----------- {success: true}
        |
        | rpc.request(N).send(JSON.stringify(request), "utf-8")
        | <----------- rpc reply (reply/stream/duplex)
```

Three transports exist in JS today:

| Runtime | Client file | Transport |
| --- | --- | --- |
| Node | `client/rpc/node-rpc-client.ts` | spawns `bare` subprocess, connects via Unix socket (or Windows named pipe) at `tmpdir()/qvac-worker-<pid>-<ts>-<rand>.sock` |
| Bare (in-process) | `client/rpc/bare-client.ts` | in-process — wraps the handler registry directly, no real socket |
| React Native / Expo | `client/rpc/expo-rpc-client.ts` | Bare worklet via `react-native-bare-kit` |

The Swift target reproduces the **Node pattern** (spawn `bare`, connect over UDS) for the macOS/iOS desktop transport, and a **Bare-kit** pattern (`bare-kit-swift`) for in-process iOS/macOS app worklets — matching M2-TRANSPORT-BAREKIT (YK-206).

Source-of-truth:
- `packages/sdk/client/rpc/node-rpc-client.ts:91-282` (worker spawn + socket + RPC init)
- `packages/sdk/package.json:"#rpc"` imports map (per-runtime client selection)

## 4. The `__init_config` Handshake

After the bare-rpc transport is up but before any application call, the client sends a single fixed-shape message. **Send it on `bare-rpc` command id `1`** — that constant is hardcoded in the JS init hook and the server detects the handshake by the message's `type` field, not by command id (the dispatcher bypasses Zod schema validation for this message).

### Wire shape

```ts
{
  "type": "__init_config",
  "config": QvacConfig | undefined,
  "runtimeContext": RuntimeContext | undefined
}
```

`QvacConfig` and `RuntimeContext` Zod schemas (full field tables in §10 below):
- `packages/sdk/schemas/sdk-config.ts:99-179` (QvacConfig)
- `packages/sdk/schemas/runtime-context.ts:1-10` (RuntimeContext)

### Server detection (bypasses normal request schema)

```ts
// packages/sdk/server/rpc/handler-utils.ts:264-277
type InitConfigMessage = {
  type: "__init_config";
  config: QvacConfig;
  runtimeContext?: RuntimeContext;
};

export function isInitConfigMessage(data: unknown): data is InitConfigMessage {
  return typeof data === "object" && data !== null && "type" in data && data.type === "__init_config";
}
```

### Reply

```json
{ "success": true }
```
or, on failure:
```json
{ "success": false, "error": "..." }
```

If `parsed.success === false`, the JS client throws `SetConfigFailedError` (a `QvacErrorBase` with code `53350` = `SET_CONFIG_FAILED`).

Source-of-truth:
- `packages/sdk/client/init-hooks.ts:29-55` (`sendInitMessage` — uses literal `rpc.request(1)` and `JSON.stringify(initMessage)`)
- `packages/sdk/server/rpc/handler-utils.ts:279-300` (`handleInitConfig`)
- `packages/sdk/server/rpc/handle-request.ts:57-60` (dispatch branch)

### `RuntimeContext` field table

| Field | Type | Notes |
| --- | --- | --- |
| `runtime` | `"node" \| "bare" \| "react-native"` | Sent by the runtime adapter. Swift sends `"bare"` (the worker is bare). |
| `platform` | `"android" \| "ios" \| "darwin" \| "linux" \| "win32"` | Drives device-pattern config matching. |
| `deviceModel` | string | Optional. Used for device-specific defaults. |
| `deviceBrand` | string | Optional. |

### `QvacConfig` field table

All optional. See §10 for full schema.

| Field | Type | Default |
| --- | --- | --- |
| `cacheDirectory` | absolute path string | `~/.qvac/models` |
| `swarmRelays` | `string[]` | — |
| `loggerLevel` | `"error"\|"warn"\|"info"\|"debug"` | `"info"` |
| `loggerConsoleOutput` | bool | `true` |
| `httpDownloadConcurrency` | positive int | `3` |
| `httpConnectionTimeoutMs` | positive int | `10000` |
| `registryDownloadMaxRetries` | non-negative int | `3` |
| `registryStreamTimeoutMs` | positive int | `60000` |
| `deviceDefaults` | `DevicePattern[]` | — |

## 5. The `__shutdown__` Pre-Terminate Signal

Mirrors `__init_config`: bypasses normal request schema, uses the dispatcher's early branch.

```ts
// packages/sdk/server/rpc/handler-utils.ts:306-317
type ShutdownMessage = { type: "__shutdown__" };
```

Reply: `{ "success": true }` (or `{ success: false, error }`).

Purpose: tells the Bare worker to release env-bound state in native addons before the host tears down the runtime (e.g. on `Worklet.terminate()` for mobile, or before `process.kill()` from the parent on desktop).

Swift implication: `QVACClient.close()` should send `__shutdown__` and wait for the success reply **before** killing the worker subprocess.

## 6. Request Type Registry (34 Handlers)

Authoritative source: `packages/sdk/server/rpc/handler-registry.ts:75-158`. Each handler has a `type` discriminating its response style:

- `reply` — single response from `req.reply(...)`.
- `stream` — newline-delimited JSON chunks via `req.createResponseStream()`; server calls `stream.end()` to signal end-of-stream. Each chunk passes through `responseSchema.parse(JSON.parse(line))` on the client.
- `duplex` — bidirectional; client provides request stream and reads response stream.
- `(progress)` — overlay on `reply`: when `request.withProgress === true` and the handler `supportsProgress`, the dispatcher upgrades it to streaming behavior (progress chunks + a single final response). See `handler-utils.ts:127-170` (`executeProgressHandler`).

| `request.type` | Mode | Delegation | Progress |
| --- | --- | --- | --- |
| `heartbeat` | reply | yes (delegate) | — |
| `loadModel` | reply | yes | yes |
| `unloadModel` | reply | yes | — |
| `embed` | reply | — | — |
| `cancel` | reply | yes (downloadAsset, inference) | — |
| `provide` | reply | — | — |
| `stopProvide` | reply | — | — |
| `deleteCache` | reply | — | — |
| `getModelInfo` | reply | — | — |
| `getLoadedModelInfo` | reply | — | — |
| `pluginInvoke` | reply | — | — |
| `modelRegistryList` | reply | — | — |
| `modelRegistrySearch` | reply | — | — |
| `modelRegistryGetModel` | reply | — | — |
| `suspend` | reply | — | — |
| `resume` | reply | — | — |
| `state` | reply | — | — |
| `downloadAsset` | reply | — | yes |
| `rag` | reply | — | yes (when `operation ∈ {ingest, saveEmbeddings, reindex}`) |
| `finetune` | reply | — | yes (when `operation ∈ {start, resume, undefined}`) |
| `transcribe` | stream | — | — |
| `loggingStream` | stream | — | — |
| `translate` | stream | — | — |
| `textToSpeech` | stream | — | — |
| `ocrStream` | stream | — | — |
| `diffusionStream` | stream | — | — |
| `upscaleStream` | stream | — | — |
| `pluginInvokeStream` | stream | — | — |
| `completionStream` | stream | yes (`isModelDelegated`) | — |
| `transcribeStream` | duplex | — | — |
| `textToSpeechStream` | duplex | — | — |

The discriminated union of valid request types: `packages/sdk/schemas/common.ts:93-125` (`requestSchema`). The discriminated union of valid responses: `common.ts:127-163` (`responseSchema`).

## 7. Wire Format

### 7.1 Frame layer

The SDK relies on `bare-rpc` (peer dep `^1.0.0`) for request/response framing. From the perspective of the client SDK code, `bare-rpc` exposes:

```ts
// observed usage in packages/sdk/client/rpc/rpc-client.ts
const rpc: RPC = ... // constructed from a Duplex byte stream
const req = rpc.request(commandId)          // IncomingRequest on server side
req.send(payload, "utf-8")                  // single-shot
const reply = await req.reply("utf-8")      // Buffer

// streaming
const stream = req.createResponseStream({ encoding: "utf-8" })
for await (const chunk of stream) { ... }

// duplex (client side)
const inputStream  = req.createRequestStream()
const outputStream = req.createResponseStream({ encoding: "utf-8" })
inputStream.write(initialJsonMetadata, "utf-8")
inputStream.write(chunk, "utf-8")  // ... more chunks ...
inputStream.end()
```

The Swift port wires `bare-rpc-swift` against a `Transport` protocol (UDS / Bare-kit IPC). Frame layout itself is **bare-rpc internal** — its specifics belong in `docs/bare-rpc-wire.md` (YK-176). For this doc, the contract that matters is:

- The SDK passes UTF-8 JSON strings to `req.send` and `stream.write`.
- Replies are returned as `Buffer`, decoded as UTF-8, parsed as JSON.
- Stream chunks are appended together into a buffer; the client splits on `'\n'` and parses each non-empty line as a separate JSON response.

### 7.2 Payload encoding — **JSON, not bare-structured-clone**

Every observed call uses `JSON.stringify` / `JSON.parse`:

```ts
// rpc-client.ts:127  send (reply mode)
req.send(JSON.stringify(payloadObj), "utf-8")

// rpc-client.ts:240  send (stream mode)
req.send(JSON.stringify(payloadObj), "utf-8")

// rpc-client.ts:412  duplex first chunk
inputStream.write(JSON.stringify(payloadObj), "utf-8")
```

Server-side mirror:

```ts
// handler-utils.ts:70  reply
req.reply(profiler.serialize(response, true), "utf-8")  // serialize() returns JSON

// handler-utils.ts:104,107,116 stream chunks
stream.write(profiler.serialize(response, isTerminal) + "\n", "utf-8")

// handle-request.ts:53  parse incoming
const jsonData: unknown = JSON.parse(rawData)
```

**No `bare-structured-clone`, `compact-encoding`, or msgpack appears in any RPC code path.** `compact-encoding` is listed in peer deps, but its only role in the SDK is as a transitive dep of `corestore`/`hyperdb` (used by the registry-client and RAG storage), not as a wire codec for the SDK's RPC layer.

This is decisively different from the YK-176 hypothesis that bare-rpc frames might carry structured-clone payloads. Swift can use `JSONEncoder` / `JSONDecoder` end-to-end.

### 7.3 Stream end-of-stream signal

Two cooperating mechanisms:

1. **Logical**: each stream response schema includes a `done?: boolean` flag (see `transcribe`, `translate`, `textToSpeech`, `completionStream`, `diffusionStream`, `upscaleStream`, `ocrStream`). When the server emits a chunk with `done: true`, the consumer treats it as terminal.
2. **Transport**: the server calls `stream.end()` after writing the last chunk. `bare-rpc` closes the response stream; the client `for await` exits naturally.

The dispatcher uses `isTerminalChunk(response)` (`packages/sdk/server/rpc/rpc-utils.ts`) to decide whether to call `stream.end()` after a chunk. In Swift's `AsyncThrowingStream`, both signals are observable: the iterator finishes either when the response with `done == true` is yielded, or when the underlying socket reports EOS.

### 7.4 Cancellation

Three layers:

1. **Per-call timeout**: `RPCOptions.timeout` (ms) — client wraps `req.reply` or the response stream in `withTimeout` (`packages/sdk/utils/withTimeout.ts`).
2. **In-flight cancel by `requestId`** (canonical since 0.11.0): send a new `cancel` request with `{ operation: "request", requestId: "..." }` (`schemas/cancel.ts:45-53`). The `completion(...)` and similar long-running calls return their `requestId` on the result object so the client can use it.
3. **Broad cancel by `modelId`**: `cancel({ operation: "inference", modelId })` aborts all in-flight requests on that model.

Special cases:
- `downloadAsset`: `cancel({ operation: "downloadAsset", downloadKey, clearCache? })`.
- `rag`: `cancel({ operation: "rag", workspace? })`.
- `embeddings`: `cancel({ operation: "embeddings", modelId })`.

Wire shape of `cancel` request: see §10.7.

## 8. Error Model

### 8.1 Error response wire shape

```ts
// packages/sdk/schemas/error.ts:4-12
{
  type: "error",
  message: string,
  code?: number,
  name?: string,
  stack?: string,
  timestamp?: string,
  cause?: unknown
}
```

The error response goes through the normal `responseSchema` discriminated union (`common.ts:144` `errorResponseSchema`). The client checks `response.type === "error"` and throws an `RPCError(response)` (`packages/sdk/client/rpc/rpc-error.ts`).

Server-side serialization: `createErrorResponse(error)` (`schemas/error.ts:20-42`) — if the error is a `QvacErrorBase`, it copies `name/code/message/stack`; otherwise it wraps a generic `Error`.

Swift `QVACError` therefore needs:
```swift
public struct QVACError: Error, Decodable {
  public let code: Int?       // numeric SDK error code, optional
  public let name: String?    // e.g. "MODEL_NOT_FOUND"
  public let message: String
  public let timestamp: Date?
  public let stack: String?
  // mapped from server-side wire frame
}
```

### 8.2 Error code tables (4 ranges, ~114 codes)

Codes are owned by 4 packages, each owning a numeric range:

| Range | Owner | Source file | Count |
| --- | --- | --- | --- |
| 0–999 | `@qvac/error` internal | `packages/error/index.js:39-47` | 6 |
| 19,001–20,000 | `@qvac/registry-client` (re-exported subset) | `packages/sdk/schemas/sdk-errors-registry.ts:4-8` | 3 |
| 50,001–52,000 | SDK Client | `packages/sdk/schemas/sdk-errors-client.ts:4-43` | 30 |
| 52,001–54,000 | SDK Server | `packages/sdk/schemas/sdk-errors-server.ts:4-122` | 75 |

#### 8.2.1 `INTERNAL_ERROR_CODES` (`@qvac/error`)

| Code | Name | Message |
| --- | --- | --- |
| 0 | `UNKNOWN_ERROR_CODE` | `Unknown QVAC error code: ${code}` |
| 1 | `INVALID_CODE_DEFINITION` | `Invalid definition for error code: ${code}` |
| 2 | `ERROR_CODE_ALREADY_EXISTS` | `Error code already exists: ${code}` |
| 3 | `MISSING_ERROR_DEFINITION` | `Missing name or message for error code: ${code}` |
| 4 | `PACKAGE_VERSION_CONFLICT` | `Package ${pkg} version conflict: existing ${existingVer}, attempted ${newVer}` |
| 5 | `INVALID_PACKAGE_INFO` | `Package name and version are required for registration` |

#### 8.2.2 `REGISTRY_ERROR_CODES`

| Code | Name |
| --- | --- |
| 19001 | `FAILED_TO_CONNECT` |
| 19002 | `FAILED_TO_CLOSE` |
| 19003 | `MODEL_NOT_FOUND` |

(Re-exported subset; full registry-client error definitions live in `packages/registry-client` outside the SDK package and are not enumerated here. They're re-thrown verbatim by SDK server handlers — see `sdk-errors-server.ts:120-121`.)

#### 8.2.3 `SDK_CLIENT_ERROR_CODES` (50,001–52,000)

**Response Validation (50,001–50,199)**

| Code | Name | Message |
| --- | --- | --- |
| 50001 | `INVALID_RESPONSE_TYPE` | `Invalid response type received, expected: ${expected}` |
| 50002 | `INVALID_OPERATION_IN_RESPONSE` | `Invalid operation type in response` |
| 50003 | `STREAM_ENDED_WITHOUT_RESPONSE` | `Stream ended without receiving final response` |
| 50004 | `INVALID_AUDIO_CHUNK_TYPE` | `Invalid audio chunk type received` |
| 50005 | `INVALID_TOOLS_ARRAY` | `Invalid tools array provided` |
| 50006 | `INVALID_TOOL_SCHEMA` | `Invalid tool schema: ${details}` |
| 50007 | `OCR_FAILED` | `OCR operation failed[: ${details}]` |
| 50008 | `MODEL_TYPE_REQUIRED` | `modelType is required: ...` (long-form, see source) |
| 50009 | `MODEL_SRC_TYPE_MISMATCH` | `modelSrc describes "${inferred}", but modelType resolves to "${resolved}". ...` |

**RPC Communication (50,200–50,399)**

| Code | Name | Message |
| --- | --- | --- |
| 50200 | `RPC_NO_HANDLER` | `No handler function registered for request type: ${requestType}` |
| 50201 | `RPC_REQUEST_NOT_SENT` | `Cannot perform operation - request has not been sent yet` |
| 50202 | `RPC_RESPONSE_STREAM_NOT_CREATED` | `Cannot perform operation - response stream not created` |
| 50203 | `RPC_CONNECTION_FAILED` | `RPC connection failed: ${details}` |
| 50204 | `RPC_INIT_TIMEOUT` | `RPC initialization timed out after ${timeoutMs}ms — ...` |

**Provider / Delegation (50,400–50,599)**

| Code | Name |
| --- | --- |
| 50400 | `PROVIDER_START_FAILED` |
| 50401 | `PROVIDER_STOP_FAILED` |
| 50402 | `DELEGATE_NO_FINAL_RESPONSE` |
| 50403 | `DELEGATE_PROVIDER_ERROR` |
| 50404 | `DELEGATE_CONNECTION_FAILED` |

**Build / Bundle (50,600–50,799)**

| Code | Name |
| --- | --- |
| 50600 | `SDK_NOT_FOUND_IN_NODE_MODULES` |
| 50601 | `WORKER_FILE_NOT_FOUND` |
| 50602 | `CONFIG_FILE_NOT_FOUND` |
| 50603 | `CONFIG_FILE_INVALID` |
| 50604 | `CONFIG_FILE_PARSE_FAILED` |
| 50605 | `CONFIG_VALIDATION_FAILED` |
| 50606 | `PEAR_WORKER_ENTRY_REQUIRED` |
| 50607 | `MULTIPLE_SDK_INSTALLATIONS` |

**Profiler (50,800–50,899)**

| Code | Name |
| --- | --- |
| 50800 | `PROFILER_INVALID_CAPACITY` |

#### 8.2.4 `SDK_SERVER_ERROR_CODES` (52,001–54,000)

**Model Registry (52,001–52,199)**

| Code | Name |
| --- | --- |
| 52001 | `MODEL_ALREADY_REGISTERED` |
| 52002 | `MODEL_NOT_FOUND` |
| 52003 | `MODEL_NOT_LOADED` |
| 52004 | `MODEL_IS_DELEGATED` |
| 52005 | `UNKNOWN_MODEL_TYPE` |

**Model Loading (52,200–52,399)**

| Code | Name |
| --- | --- |
| 52200 | `MODEL_LOAD_FAILED` |
| 52201 | `MODEL_FILE_NOT_FOUND` |
| 52202 | `MODEL_FILE_NOT_FOUND_IN_DIR` |
| 52203 | `MODEL_FILE_LOCATE_FAILED` |
| 52204 | `PROJECTION_MODEL_REQUIRED` |
| 52205 | `VAD_MODEL_REQUIRED` |
| 52208 | `TTS_ARTIFACTS_REQUIRED` |
| 52209 | `TTS_REFERENCE_AUDIO_REQUIRED` |
| 52210 | `PARAKEET_ARTIFACTS_REQUIRED` |

**Model Operations (52,400–52,799)**

| Code | Name |
| --- | --- |
| 52400 | `MODEL_UNLOAD_FAILED` |
| 52401 | `EMBED_FAILED` |
| 52402 | `EMBED_NO_EMBEDDINGS` |
| 52403 | `TRANSCRIPTION_FAILED` |
| 52404 | `AUDIO_FILE_NOT_FOUND` |
| 52405 | `TRANSLATION_FAILED` |
| 52406 | `COMPLETION_FAILED` |
| 52407 | `ATTACHMENT_NOT_FOUND` |
| 52408 | `CANCEL_FAILED` |
| 52409 | `TEXT_TO_SPEECH_FAILED` |
| 52410 | `CONFIG_RELOAD_NOT_SUPPORTED` |
| 52411 | `MODEL_TYPE_MISMATCH` |
| 52412 | `OCR_FAILED` |
| 52413 | `IMAGE_FILE_NOT_FOUND` |
| 52414 | `INVALID_IMAGE_INPUT` |
| 52415 | `TEXT_TO_SPEECH_STREAM_FAILED` |
| 52416 | `MODEL_OPERATION_NOT_SUPPORTED` |
| 52417 | `REQUEST_ID_CONFLICT` |
| 52418 | `REQUEST_NOT_FOUND` |

**RAG (52,800–52,999)**

| Code | Name |
| --- | --- |
| 52800 | `RAG_SAVE_FAILED` |
| 52801 | `RAG_SEARCH_FAILED` |
| 52802 | `RAG_DELETE_FAILED` |
| 52803 | `RAG_UNKNOWN_OPERATION` |
| 52804 | `RAG_HYPERDB_FAILED` |
| 52805 | `RAG_WORKSPACE_MODEL_MISMATCH` |
| 52806 | `RAG_WORKSPACE_NOT_FOUND` |
| 52807 | `RAG_WORKSPACE_IN_USE` |
| 52808 | `RAG_WORKSPACE_CLOSE_FAILED` |
| 52809 | `RAG_LIST_WORKSPACES_FAILED` |
| 52810 | `RAG_CHUNK_FAILED` |
| 52811 | `RAG_WORKSPACE_NOT_OPEN` |

**Download / Resource (53,000–53,199)**

| Code | Name |
| --- | --- |
| 53000 | `FILE_NOT_FOUND` |
| 53001 | `DOWNLOAD_CANCELLED` |
| 53002 | `CHECKSUM_VALIDATION_FAILED` |
| 53003 | `HTTP_ERROR` |
| 53004 | `NO_RESPONSE_BODY` |
| 53005 | `RESPONSE_BODY_NOT_READABLE` |
| 53006 | `NO_BLOB_FOUND` |
| 53007 | `DOWNLOAD_ASSET_FAILED` |
| 53008 | `SEEDING_NOT_SUPPORTED` |
| 53009 | `HYPERDRIVE_DOWNLOAD_FAILED` |
| 53010 | `INVALID_SHARD_URL_PATTERN` |
| 53011 | `ARCHIVE_EXTRACTION_FAILED` |
| 53012 | `ARCHIVE_UNSUPPORTED_TYPE` |
| 53013 | `ARCHIVE_MISSING_SHARDS` |
| 53014 | `PARTIAL_DOWNLOAD_OFFLINE` |
| 53015 | `REGISTRY_DOWNLOAD_FAILED` |

**Cache (53,200–53,349)**

| Code | Name |
| --- | --- |
| 53200 | `DELETE_CACHE_FAILED` |
| 53201 | `INVALID_DELETE_CACHE_PARAMS` |
| 53202 | `CACHE_DIR_NOT_ABSOLUTE` |
| 53203 | `CACHE_DIR_NOT_WRITABLE` |

**Config (53,350–53,499)**

| Code | Name |
| --- | --- |
| 53350 | `SET_CONFIG_FAILED` |
| 53351 | `CONFIG_ALREADY_SET` |

**System / Runtime (53,500–53,699)**

| Code | Name |
| --- | --- |
| 53500 | `FFMPEG_NOT_AVAILABLE` |
| 53501 | `AUDIO_PLAYER_FAILED` |
| 53502 | `INVALID_AUDIO_CHUNK_TYPE` |
| 53503 | `ASYNC_DISPOSE_UNAVAILABLE` |
| 53600 | `LIFECYCLE_SUSPEND_FAILED` |
| 53601 | `LIFECYCLE_RESUME_FAILED` |
| 53602 | `LIFECYCLE_OPERATION_BLOCKED` |

**RPC / Delegation (server-side) (53,700–53,849)**

| Code | Name |
| --- | --- |
| 53700 | `DELEGATE_NO_FINAL_RESPONSE` |
| 53701 | `DELEGATE_CONNECTION_FAILED` |
| 53702 | `DELEGATE_PROVIDER_ERROR` |
| 53703 | `RPC_NO_DATA_RECEIVED` |
| 53704 | `RPC_UNKNOWN_REQUEST_TYPE` |

**Plugins (53,850–53,899)**

| Code | Name |
| --- | --- |
| 53850 | `PLUGIN_NOT_FOUND` |
| 53851 | `PLUGIN_HANDLER_NOT_FOUND` |
| 53852 | `PLUGIN_REQUEST_VALIDATION_FAILED` |
| 53853 | `PLUGIN_RESPONSE_VALIDATION_FAILED` |
| 53854 | `PLUGIN_ALREADY_REGISTERED` |
| 53855 | `PLUGIN_HANDLER_TYPE_MISMATCH` |
| 53856 | `PLUGIN_LOGGING_INVALID` |
| 53857 | `PLUGIN_DEFINITION_INVALID` |
| 53858 | `PLUGIN_MODEL_TYPE_RESERVED` |
| 53859 | `PLUGIN_LOAD_CONFIG_VALIDATION_FAILED` |

**Security (53,900–53,949)**

| Code | Name |
| --- | --- |
| 53900 | `PATH_TRAVERSAL` |

**QVAC Model Registry (53,950–54,000)**

| Code | Name |
| --- | --- |
| 53950 | `QVAC_MODEL_REGISTRY_QUERY_FAILED` |

Full message factories (for the codes that interpolate user-supplied detail) are in `sdk-errors-server.ts:124-594`. The Swift codegen target (YK-181) maps each code → a Swift enum case with localized message via the same factories — but server messages flow over the wire pre-formatted, so the Swift mapping only needs the `code → name` direction.

## 9. Plugin Extensibility — Built-ins & Custom Plugins

The SDK ships 8 built-in plugins (each backed by a native addon):

| `modelType` (canonical) | Alias | Plugin entrypoint | Addon |
| --- | --- | --- | --- |
| `llamacpp-completion` | `llm` | `@qvac/sdk/llamacpp-completion/plugin` | `@qvac/llm-llamacpp` |
| `llamacpp-embedding` | `embeddings` | `@qvac/sdk/llamacpp-embedding/plugin` | `@qvac/embed-llamacpp` |
| `whispercpp-transcription` | `whisper` | `@qvac/sdk/whispercpp-transcription/plugin` | `@qvac/transcription-whispercpp` |
| `parakeet-transcription` | `parakeet` | `@qvac/sdk/parakeet-transcription/plugin` | `@qvac/transcription-parakeet` |
| `nmtcpp-translation` | `nmt` | `@qvac/sdk/nmtcpp-translation/plugin` | `@qvac/translation-nmtcpp` |
| `onnx-tts` | `tts` | `@qvac/sdk/onnx-tts/plugin` | `@qvac/tts-onnx` |
| `onnx-ocr` | `ocr` | `@qvac/sdk/onnx-ocr/plugin` | `@qvac/ocr-onnx` |
| `sdcpp-generation` | `diffusion` | `@qvac/sdk/sdcpp-generation/plugin` | `@qvac/diffusion-cpp` |

Source: `packages/sdk/schemas/plugin.ts:301-366` (constants), `schemas/model-types.ts:9-46` (canonical + alias table).

Custom plugins register additional `modelType` strings → handler maps (each handler has its own Zod request/response schema and is invoked via `pluginInvoke` or `pluginInvokeStream`). Swift surfaces this as generic-typed helpers:

```swift
func invokePlugin<Req: Encodable, Resp: Decodable>(
  modelId: String, handler: String, params: Req
) async throws -> Resp
```

## 10. Per-Method Request/Response Shapes

All schemas are Zod. Field-by-field tables below quote the schema file directly. For each method: **R** = `request.type` discriminant, **mode** from the registry, **C** = canonical schema file.

### 10.1 `heartbeat` (R = `"heartbeat"`, mode = reply)

C: `schemas/heartbeat.ts:1-15`

```ts
HeartbeatRequest:  { type: "heartbeat", delegate?: DelegateBase }
HeartbeatResponse: { type: "heartbeat", number: number }
```

### 10.2 `loadModel` (R = `"loadModel"`, mode = reply, progress = yes)

C: `schemas/load-model.ts:46-409`

The request is one of 9 discriminated cases (one per built-in modelType + a custom-plugin catch-all). Common fields across all variants:

```ts
{
  type: "loadModel",
  modelSrc: string,          // resolved to a URL string
  modelName?: string,
  modelType: CanonicalModelType | string,  // string for custom plugins
  modelConfig?: <per-modelType config object>,
  seed: boolean,             // default false
  withProgress?: boolean,
  delegate?: Delegate
}
```

Response:
```ts
LoadModelResponse: { type: "loadModel", success: boolean, modelId?: string, error?: string }
```

Progress stream chunk (sent when `withProgress: true`):
```ts
ModelProgressUpdate: {
  type: "modelProgress",
  downloaded: number, total: number, percentage: number, downloadKey: string,
  shardInfo?: { currentShard, totalShards, shardName, overallDownloaded, overallTotal, overallPercentage },
  fileSetInfo?: { setKey, currentFile, fileIndex, totalFiles, overallDownloaded, overallTotal, overallPercentage }
}
```

Per-modelType `modelConfig` schemas (all in `schemas/`):
- `llmConfigBaseSchema` / `embedConfigBaseSchema` → `llamacpp-config.ts`
- `whisperConfigSchema` / `parakeetConfigSchema` → `transcription-config.ts`
- `nmtConfigSchema` → `translation-config.ts`
- `ttsConfigSchema` (union of Chatterbox + Supertonic) → `text-to-speech.ts`
- `ocrConfigSchema` → `ocr.ts:5-18`
- `sdcppConfigSchema` → `sdcpp-config.ts:9-106`
- custom plugin: `Record<string, unknown>`

Server-side parameter normalization (paths, model resolution): `schemas/load-model.ts:477-490` (`loadModelServerParamsSchema`).

### 10.3 `unloadModel` (R = `"unloadModel"`, mode = reply)

C: `schemas/unload-model.ts:1-26`

```ts
UnloadModelRequest:  { type: "unloadModel", modelId: string, clearStorage?: boolean }
UnloadModelResponse: {
  type: "unloadModel", success: boolean, error?: string,
  hasActiveModels?: boolean, hasActiveProviders?: boolean
}

// Client-facing params (additional `autoClose?` for the SDK-level wrapper)
UnloadModelParams: { modelId, clearStorage = false, autoClose? }
```

### 10.4 `embed` (R = `"embed"`, mode = reply)

C: `schemas/embed.ts:1-54`

```ts
EmbedRequest:  {
  type: "embed",
  modelId: string,
  text: string | string[]    // single text or batch
}
EmbedResponse: {
  type: "embed",
  success: boolean,
  embedding: number[] | number[][]  // single vec for string input, matrix for array input
  stats?: { totalTime?, tokensPerSecond?, totalTokens?, backendDevice?: "cpu"|"gpu" }
  error?: string
}
```

### 10.5 `completionStream` (R = `"completionStream"`, mode = stream)

C: `schemas/completion-stream.ts:1-249`

```ts
CompletionStreamRequest: {
  type: "completionStream",
  modelId: string,
  history: { role: string, content: string, attachments?: Attachment[] }[],
  kvCache?: boolean | string,                  // string = explicit cache key
  tools?: Tool[],
  stream: boolean,
  generationParams?: {
    temp?, top_p?, top_k?, predict?, seed?,
    frequency_penalty?, presence_penalty?, repeat_penalty?,
    reasoning_budget?: -1 | 0
  },
  captureThinking?: boolean,
  emitRawDeltas?: boolean,
  toolDialect?: "hermes" | "pythonic" | "json" | "harmony" | "qwen35" | "gemma4",
  responseFormat?:
    | { type: "text" }
    | { type: "json_object" }
    | { type: "json_schema", json_schema: { name, description?, schema: JSONSchema, strict? } },
  requestId?: string             // client-generated UUID for targeted cancel
}

// strict invariant: tools must be empty when responseFormat is non-"text"

CompletionStreamResponse (per chunk): {
  type: "completionStream",
  done?: boolean,
  events: CompletionEvent[]      // see completion-event.ts (deltas, thinking, tool calls, stats)
}
```

`CompletionEvent` union is large — defined in `schemas/completion-event.ts`. Codegen for the Swift port will need to surface every variant; document explicitly in `YK-180`/`YK-179` work.

### 10.6 `transcribe` / `transcribeStream` / `textToSpeech` / `textToSpeechStream`

C: `schemas/transcription.ts:1-155`, `schemas/text-to-speech.ts:1-157`.

```ts
TranscribeRequest: {
  type: "transcribe",
  modelId, audioChunk: { type: "base64"|"filePath", value: string },
  prompt?, metadata?
}
TranscribeResponse: {
  type: "transcribe",
  text?: string, done?: boolean,
  stats?: TranscribeStats,
  segment?: TranscribeSegment, vad?: VadStateEvent, endOfTurn?: EndOfTurnEvent,
  error?: string
}

TranscribeStreamRequest: {
  type: "transcribeStream",
  modelId, prompt?, metadata?,
  emitVadEvents?: bool, endOfTurnSilenceMs?: int (>=0), vadRunIntervalMs?: int (>0)
}
TranscribeStreamResponse: { type: "transcribeStream", ...same as TranscribeResponse }
```

`transcribeStream` is duplex: client streams audio buffers in (write `Uint8Array` chunks to request stream), receives interleaved segment/vad/endOfTurn events out.

```ts
TtsRequest: {
  type: "textToSpeech",
  modelId, text: non-empty string, inputType: string (default "text"),
  stream: bool (default true), sentenceStream?: bool,
  sentenceStreamLocale?, sentenceStreamMaxChunkScalars?
}
TtsResponse: { type: "textToSpeech", buffer: number[], done: bool, stats?, chunkIndex?, sentenceChunk? }

TextToSpeechStreamRequest: {
  type: "textToSpeechStream",
  modelId, inputType: string, accumulateSentences?,
  sentenceDelimiterPreset?: "latin"|"cjk"|"multilingual",
  maxBufferScalars?, flushAfterMs?
}
TextToSpeechStreamResponse: same buffer-style payload as TtsResponse, type: "textToSpeechStream"
```

### 10.7 `cancel` (R = `"cancel"`, mode = reply)

C: `schemas/cancel.ts:1-99`

Discriminated by `operation`:

| `operation` | Extra fields | Purpose |
| --- | --- | --- |
| `"request"` | `requestId: string` | targeted cancel of one in-flight request (new in 0.11.0) |
| `"inference"` | `modelId: string` | broad cancel of all in-flight requests on a model |
| `"embeddings"` | `modelId: string` | embeddings-specific broad cancel |
| `"downloadAsset"` | `downloadKey: string`, `clearCache?: bool`, `delegate?` | abort a download |
| `"rag"` | `workspace?: string` | abort RAG ops in a workspace |

Response: `{ type: "cancel", success: bool, error?: string }`.

### 10.8 `downloadAsset` (R = `"downloadAsset"`, mode = reply, progress = yes)

C: `schemas/download-asset.ts:1-99`

```ts
DownloadAssetRequest: { type: "downloadAsset", assetSrc: string, withProgress?: bool, seed: bool /* default false */ }
DownloadAssetResponse: { type: "downloadAsset", success: bool, assetId?: string, error?: string }
// progress chunks: ModelProgressUpdate (see 10.2)
```

### 10.9 `rag` (R = `"rag"`, mode = reply, progress = yes for ingest/saveEmbeddings/reindex)

C: `schemas/rag.ts:1-330`

Discriminated by `operation` — 9 cases:

| `operation` | Extra fields |
| --- | --- |
| `"chunk"` | `documents: string \| string[]`, `chunkOpts?` |
| `"ingest"` | `modelId`, `workspace?`, `documents`, `chunk = true`, `chunkOpts?`, `progressInterval?`, `withProgress?` |
| `"saveEmbeddings"` | `modelId?`, `workspace?`, `documents: EmbeddedDoc[]`, `progressInterval?`, `withProgress?` |
| `"search"` | `modelId`, `workspace?`, `query: non-empty`, `topK = 5`, `n = 3` |
| `"deleteEmbeddings"` | `modelId?`, `workspace?`, `ids: non-empty string[]` |
| `"reindex"` | `modelId?`, `workspace?`, `withProgress?` |
| `"listWorkspaces"` | (none) |
| `"closeWorkspace"` | `workspace?`, `deleteOnClose?` |
| `"deleteWorkspace"` | `workspace: non-empty (safePathComponent)` |

Response: discriminated by the same `operation` (each carries op-specific result fields, all extend `{ type: "rag", success, error?, operation }`).

Progress chunk:
```ts
{ type: "rag:progress", operation: "ingest"|"saveEmbeddings"|"reindex",
  workspace: string, stage: string, current: number, total: number, timestamp: number }
```

### 10.10 `translate` (R = `"translate"`, mode = stream)

C: `schemas/translate.ts:1-178`

```ts
TranslateRequest: union of two variants:
  NMT:  { type: "translate", modelId, text: string|string[], stream: bool, modelType: "nmt"|"nmtcpp-translation" }
  LLM:  { type: "translate", modelId, text: string, stream: bool, modelType: "llm"|"llamacpp-completion",
          from?: string, to: string, context?: string }
TranslateResponse (per stream chunk): { type: "translate", token: string, done?: bool, stats?, error? }
```

For LLM translation, both `from` and `to` are required (server enforces).

### 10.11 `ocrStream` (R = `"ocrStream"`, mode = stream)

C: `schemas/ocr.ts:1-81`

```ts
OCRStreamRequest: {
  type: "ocrStream", modelId,
  image: { type: "base64"|"filePath", value: string },
  options?: { paragraph?: bool }
}
OCRStreamResponse (per chunk): {
  type: "ocrStream",
  blocks?: Array<{ text: string, bbox?: [num, num, num, num], confidence?: number }>,
  done?: bool, error?, stats?
}
```

### 10.12 `diffusionStream` / `upscaleStream`

C: `schemas/sdcpp-config.ts:165-462`

```ts
DiffusionStreamRequest: {
  type: "diffusionStream",
  modelId, prompt, negative_prompt?,
  width? (multipleOf 8), height? (multipleOf 8),
  steps?, cfg_scale?, img_cfg_scale (= -1), guidance?,
  sampling_method?, scheduler?, seed?, batch_count?,
  vae_tiling?, cache_preset?,
  init_image?: base64,             // mutually exclusive with init_images
  init_images?: base64[],          // FLUX.2 fusion only
  increase_ref_index?, auto_resize_ref_image?,
  lora?: absolute filesystem path, strength?,
  upscale?: bool | { repeats?: int }
}
DiffusionStreamResponse: {
  type: "diffusionStream",
  step?, totalSteps?, elapsedMs?,
  data?: string (base64 PNG), outputIndex?, done?, stats?
}

UpscaleStreamRequest:  { type: "upscaleStream", modelId, image: base64, repeats?: int }
UpscaleStreamResponse: { type: "upscaleStream", data?, outputIndex?, done?, stats? }
```

### 10.13 `finetune` (R = `"finetune"`, mode = reply, progress = yes for start/resume)

C: `schemas/finetune.ts:1-199`

Discriminated by `operation`:

| `operation` | Fields |
| --- | --- |
| `"start"` / `"resume"` / *(omitted)* | `modelId`, `options: FinetuneOptionsPayload`, `withProgress?` |
| `"getState"` | `modelId`, `options: FinetuneOptionsPayload` |
| `"pause"` / `"cancel"` | `modelId` |

Response: `{ type: "finetune", status: "IDLE"|"RUNNING"|"PAUSED"|"CANCELLED"|"COMPLETED", stats?: FinetuneStats }`.

Progress chunks: `{ type: "finetune:progress", modelId, is_train, loss, accuracy, global_steps, current_epoch, current_batch, total_batches, elapsed_ms, eta_ms, ... }` (NaN-bearing fields preserved).

### 10.14 `getModelInfo` / `getLoadedModelInfo`

C: `schemas/get-model-info.ts:1-149`, `schemas/get-loaded-model-info.ts:1-64`

```ts
GetModelInfoRequest: { type: "getModelInfo", name: string }
GetModelInfoResponse: { type: "getModelInfo", modelInfo: ModelInfo }
// ModelInfo: name, modelId, registryPath?, registrySource?, blob*, engine?, quantization?, params?,
//            expectedSize, sha256Checksum, addon (enum), isCached, isLoaded, cacheFiles[], loadedInstances?[]

GetLoadedModelInfoRequest: { type: "getLoadedModelInfo", modelId: string }
GetLoadedModelInfoResponse: {
  type: "getLoadedModelInfo",
  info: LocalLoadedModelInfo | DelegatedLoadedModelInfo  // discriminated on `isDelegated`
}
```

### 10.15 `pluginInvoke` / `pluginInvokeStream`

C: `schemas/plugin.ts:147-180`

```ts
PluginInvokeRequest:  { type: "pluginInvoke", modelId, handler: string, params: unknown }
PluginInvokeResponse: { type: "pluginInvoke", result: unknown }

PluginInvokeStreamRequest:  { type: "pluginInvokeStream", modelId, handler, params }
PluginInvokeStreamResponse: { type: "pluginInvokeStream", result: unknown, done?: bool }
```

The `params`/`result` shapes are plugin-specific — the SDK does not enforce a Zod schema at the wire layer; per-plugin validation happens inside each plugin handler.

### 10.16 `modelRegistryList` / `modelRegistrySearch` / `modelRegistryGetModel`

C: `schemas/registry.ts:1-163`

```ts
ModelRegistryListRequest:  { type: "modelRegistryList" }
ModelRegistryListResponse: { type: "modelRegistryList", success, models?: ModelRegistryEntry[], error? }

ModelRegistrySearchRequest:  {
  type: "modelRegistrySearch",
  filter?: string, engine?: string, quantization?: string,
  addon?: "llm"|"whisper"|"embeddings"|"nmt"|"vad"|"tts"|"ocr"|"parakeet"|"diffusion"|"other"
}
ModelRegistrySearchResponse: { type: "modelRegistrySearch", success, models?, error? }

ModelRegistryGetModelRequest:  { type: "modelRegistryGetModel", registryPath, registrySource }
ModelRegistryGetModelResponse: { type: "modelRegistryGetModel", success, model?, error? }
```

`ModelRegistryEntry` carries the full Hyperdrive blob coordinates required to fetch the model file (`blobCoreKey`, `blobBlockOffset`, `blobBlockLength`, `blobByteOffset`, `sha256Checksum`).

### 10.17 `provide` / `stopProvide`

C: `schemas/provide.ts:1-33`, `schemas/stop-provide.ts:1-17`

```ts
ProvideRequest: {
  type: "provide",
  firewall?: { mode: "allow"|"deny" (default "allow"), publicKeys: string[] (default []) }
}
ProvideResponse: { type: "provide", success, error?, publicKey? }   // returned Hyperswarm topic key

StopProvideRequest:  { type: "stopProvide" }
StopProvideResponse: { type: "stopProvide", success, error? }
```

Env required for `provide`: `QVAC_HYPERSWARM_SEED` (32-byte seed for ed25519). Source: `schemas/provide.ts:25-27`.

### 10.18 `suspend` / `resume` / `state`

C: `schemas/suspend.ts`, `schemas/resume.ts`, `schemas/state.ts`

```ts
SuspendRequest: { type: "suspend" }              SuspendResponse: { type: "suspend" }
ResumeRequest:  { type: "resume" }               ResumeResponse:  { type: "resume" }
StateRequest:   { type: "state" }                StateResponse:   { type: "state", state: "active"|"suspending"|"suspended"|"resuming" }
```

Operations issued while the runtime is non-active are rejected with `LIFECYCLE_OPERATION_BLOCKED` (53602) — see `schemas/sdk-errors-server.ts:574-578` and `server/bare/runtime-lifecycle.ts`.

### 10.19 `deleteCache`

C: `schemas/delete-cache.ts:1-22`

Two-variant union:
```ts
{ type: "deleteCache", all: true }
{ type: "deleteCache", kvCacheKey: string, modelId?: string }
```
Response: `{ type: "deleteCache", success: bool, error? }`.

### 10.20 `loggingStream` (R = `"loggingStream"`, mode = stream)

C: `schemas/logging-stream.ts:1-26`

```ts
LoggingStreamRequest:  { type: "loggingStream", id: string }
LoggingStreamResponse: {
  type: "loggingStream", id: string,
  level: "error"|"warn"|"info"|"debug",
  namespace: string, message: string, timestamp: number
}
```

## 11. Delegate Schema

C: `schemas/delegate.ts:5-44`

```ts
DelegateBase: {
  providerPublicKey: 64-char-hex,         // ed25519 public key
  timeout?: number (>=100),
  healthCheckTimeout?: number (>=100)
}
Delegate (extends): {
  ...DelegateBase,
  fallbackToLocal?: bool (default false),
  forceNewConnection?: bool (default false)
}
```

`delegate` is an optional field on `heartbeat`, `loadModel`, `unloadModel`, `completionStream`, `cancel.downloadAsset`. Adding delegate routing to the Swift client is an M3 concern (RAG/plugin work).

## 12. Model Types — Canonical & Aliases

C: `schemas/model-types.ts:9-46`

```
"llamacpp-completion"      <-->  "llm"
"llamacpp-embedding"       <-->  "embeddings"
"whispercpp-transcription" <-->  "whisper"
"parakeet-transcription"   <-->  "parakeet"
"nmtcpp-translation"       <-->  "nmt"
"onnx-tts"                 <-->  "tts"
"onnx-ocr"                 <-->  "ocr"
"sdcpp-generation"         <-->  "diffusion"
```

Swift codegen normalizes input to the canonical form (matching `normalizeModelType` in `schemas/model-types.ts:104-115`). Custom plugin types (non-built-in strings) pass through unchanged.

## 13. Public API Surface — Method Inventory

From `packages/sdk/index.ts:4-47`, every exported client function (Swift port must surface each):

```
completion, deleteCache, loadModel, downloadAsset, heartbeat,
startQVACProvider, stopQVACProvider, unloadModel,
transcribe, transcribeStream,
embed, finetune,
translate, cancel,
ragChunk, ragIngest, ragSaveEmbeddings, ragSearch,
ragDeleteEmbeddings, ragReindex, ragListWorkspaces,
ragCloseWorkspace, ragDeleteWorkspace,
textToSpeech, textToSpeechStream,
getModelInfo, getLoadedModelInfo, loggingStream,
ocr, invokePlugin, invokePluginStream,
diffusion, upscale,
modelRegistryList, modelRegistrySearch, modelRegistryGetModel,
suspend, resume, state, close
```

This is the **authoritative method list** for codegen (`YK-180`). Note:
- `completion(...)` wraps `completionStream` on the wire — the public API exposes both streaming and blocking modes through the same function.
- `diffusion(...)` and `upscale(...)` wrap `diffusionStream` / `upscaleStream`.
- `ocr(...)` wraps `ocrStream`.
- `transcribe(...)` is the one-shot path; `transcribeStream(...)` is duplex.
- `startQVACProvider` / `stopQVACProvider` map to `provide` / `stopProvide`.
- `close()` is the SDK-level shutdown — sends `__shutdown__`, then tears down the worker.

Public API cross-reference per modality:
- LLM: `completion`, `embed`
- ASR: `transcribe`, `transcribeStream`
- TTS: `textToSpeech`, `textToSpeechStream`
- NMT: `translate`
- OCR: `ocr`
- Diffusion: `diffusion`, `upscale`
- RAG: `ragIngest`, `ragSearch`, `ragChunk`, `ragSaveEmbeddings`, `ragDeleteEmbeddings`, `ragReindex`, `ragListWorkspaces`, `ragCloseWorkspace`, `ragDeleteWorkspace`
- Lifecycle: `loadModel`, `unloadModel`, `heartbeat`, `getModelInfo`, `getLoadedModelInfo`, `deleteCache`, `cancel`, `loggingStream`, `suspend`, `resume`, `state`, `close`
- Registry: `modelRegistryList`, `modelRegistrySearch`, `modelRegistryGetModel`
- Provider: `startQVACProvider`, `stopQVACProvider`
- Finetune: `finetune`
- Plugins: `invokePlugin`, `invokePluginStream`

## 14. Cross-References to docs.qvac.tether.io

Public docs index: https://docs.qvac.tether.io/sdk/api/. Per-method canonical doc URLs (form `https://docs.qvac.tether.io/sdk/api/<method>` — verify before linking from the README):

- `loadModel`, `unloadModel`, `heartbeat`, `getModelInfo`, `getLoadedModelInfo`
- `completion`, `embed`, `cancel`
- `transcribe`, `transcribeStream`
- `textToSpeech`, `textToSpeechStream`
- `translate`, `ocr`
- `diffusion`, `upscale`
- `ragIngest`, `ragSearch`, `ragChunk`, `ragSaveEmbeddings`, `ragDeleteEmbeddings`, `ragReindex`, `ragListWorkspaces`, `ragCloseWorkspace`, `ragDeleteWorkspace`
- `startQVACProvider`, `stopQVACProvider`
- `modelRegistryList`, `modelRegistrySearch`, `modelRegistryGetModel`
- `suspend`, `resume`, `state`
- `invokePlugin`, `invokePluginStream`
- `finetune`, `downloadAsset`, `deleteCache`, `loggingStream`, `close`

Per the bounty AC, every method above is cross-referenced in the Swift `DocC` catalog (`YK-215`) with at least one upstream doc link.

## 15. Open Questions for Tether

1. **No `commands.js` exists.** The bounty PDF and YK-175 description both reference a numeric command-ID table in `lib/rpc/commands.js`. The current shipping SDK (0.10.2) dispatches by string `request.type`. **Confirm whether this is the intended public contract going forward, or whether numeric IDs are planned for a future version.** Our Swift codegen assumes string-typed dispatch; switching to numeric IDs would require a re-run.

2. **Error codes — public API or implementation detail?** `SDK_CLIENT_ERROR_CODES` and `SDK_SERVER_ERROR_CODES` are exported from `@qvac/sdk` and are visible in the error frame on the wire. **Confirm they are part of the stable public API.** If yes, we'll pin them in `ErrorCodes.swift` and add CI drift checks against `package.json` version bumps. If they're internal, we'll inline them and document the manual refresh procedure.

3. **`__init_config` reply schema is `{success, error?}` only.** No version negotiation field. **Should the SDK client send its version in the init payload?** A future server version may want to refuse incompatible clients.

4. **`bare-rpc` command-id 1 is hardcoded for the init handshake** in `init-hooks.ts:41`. **Is this a contract** the Swift implementation should rely on, or can the JS implementation move it? If contract: document it in the SDK README. If not: have the server detect by `type === "__init_config"` (it already does, the command id is incidental).

5. **`bare-structured-clone` vs JSON.** Every observed payload uses `JSON.stringify`. Are there codepaths (e.g. RN, Expo) that swap to structured-clone framing? If yes, the Swift port needs to support both; if no, the SDK guarantees JSON-only is helpful.

6. **`registryStreamTimeoutMs` and concurrency knobs in `QvacConfig`.** Several config fields are P2P-tuning specific (`swarmRelays`, `registryDownloadMaxRetries`, etc.). For the M1 Swift client we'll accept these but not enforce; should non-P2P clients refuse to set them, or silently accept?

7. **`unloadModel.autoClose`** appeared in the most recent commit (`9db6f98`). The wire request schema does not yet carry `autoClose` (only `clearStorage`); the param exists only on the client wrapper (`UnloadModelParams.autoClose`). **Confirm whether `autoClose` will be promoted to the wire** or remain a client-side hint.

8. **`Tools` and `CompletionEvent` schemas** are large unions referenced by `completionStream`. They aren't expanded here — Swift codegen for YK-179 should walk `schemas/tools.ts` and `schemas/completion-event.ts` and document them in a follow-up internals note.

9. **`pluginInvoke.params` is `unknown`.** Custom plugin handlers carry their own Zod schemas, but those are not advertised in the SDK's discriminated union. **What's the contract for clients (including Swift) to learn a plugin's request/response schema?** Best path forward: each plugin exports its schema as a side-by-side `.d.ts` artifact that the Swift codegen can read.

10. **Delegation timeouts** (`Delegate.timeout`, `healthCheckTimeout`) have a minimum of 100 ms. Should the Swift client expose this as a strongly-typed `Duration` with the same lower bound, or pass through raw `Int`?

## 16. Source-of-Truth File Index

A grep-equivalent listing of every file cited above for quick re-verification:

| Concern | File |
| --- | --- |
| Public exports | `packages/sdk/index.ts:1-159` |
| Request union | `packages/sdk/schemas/common.ts:93-125` |
| Response union | `packages/sdk/schemas/common.ts:127-163` |
| RPC client core | `packages/sdk/client/rpc/rpc-client.ts:1-558` |
| Node RPC transport | `packages/sdk/client/rpc/node-rpc-client.ts:1-352` |
| Bare in-process RPC | `packages/sdk/client/rpc/bare-client.ts:1-340` |
| Server dispatcher | `packages/sdk/server/rpc/handle-request.ts:34-246` |
| Handler registry | `packages/sdk/server/rpc/handler-registry.ts:75-158` |
| Handler executors | `packages/sdk/server/rpc/handler-utils.ts:50-260` |
| `__init_config` server | `packages/sdk/server/rpc/handler-utils.ts:264-300` |
| `__init_config` client | `packages/sdk/client/init-hooks.ts:29-93` |
| Shutdown signal | `packages/sdk/server/rpc/handler-utils.ts:306-336` |
| Error base class | `packages/error/index.js:39-296` |
| Client errors | `packages/sdk/schemas/sdk-errors-client.ts:4-188` |
| Server errors | `packages/sdk/schemas/sdk-errors-server.ts:4-598` |
| Registry errors | `packages/sdk/schemas/sdk-errors-registry.ts:4-8` |
| Error response shape | `packages/sdk/schemas/error.ts:1-43` |
| Model types | `packages/sdk/schemas/model-types.ts:9-233` |
| Plugin extension | `packages/sdk/schemas/plugin.ts:1-396` |
| SDK config | `packages/sdk/schemas/sdk-config.ts:1-182` |
| Runtime context | `packages/sdk/schemas/runtime-context.ts:1-11` |
| Delegate | `packages/sdk/schemas/delegate.ts:1-48` |
| Heartbeat | `packages/sdk/schemas/heartbeat.ts:1-15` |
| Load model | `packages/sdk/schemas/load-model.ts:46-579` |
| Unload model | `packages/sdk/schemas/unload-model.ts:1-26` |
| Embed | `packages/sdk/schemas/embed.ts:1-54` |
| Completion stream | `packages/sdk/schemas/completion-stream.ts:1-252` |
| Cancel | `packages/sdk/schemas/cancel.ts:1-99` |
| Download asset | `packages/sdk/schemas/download-asset.ts:1-99` |
| RAG | `packages/sdk/schemas/rag.ts:1-330` |
| Translate | `packages/sdk/schemas/translate.ts:1-178` |
| Transcription | `packages/sdk/schemas/transcription.ts:1-155` |
| Text to speech | `packages/sdk/schemas/text-to-speech.ts:1-157` |
| OCR | `packages/sdk/schemas/ocr.ts:1-81` |
| Diffusion / Upscale | `packages/sdk/schemas/sdcpp-config.ts:1-462` |
| Finetune | `packages/sdk/schemas/finetune.ts:1-199` |
| Registry methods | `packages/sdk/schemas/registry.ts:1-163` |
| Get model info | `packages/sdk/schemas/get-model-info.ts:1-149` |
| Get loaded model info | `packages/sdk/schemas/get-loaded-model-info.ts:1-64` |
| Provide / StopProvide | `packages/sdk/schemas/provide.ts`, `stop-provide.ts` |
| Suspend / Resume / State | `packages/sdk/schemas/suspend.ts`, `resume.ts`, `state.ts` |
| Delete cache | `packages/sdk/schemas/delete-cache.ts:1-22` |
| Logging stream | `packages/sdk/schemas/logging-stream.ts:1-26` |

Reproduce locally:

```bash
git clone --depth=1 https://github.com/tetherto/qvac.git ~/qvac/qvac
cd ~/qvac/qvac && git rev-parse HEAD        # expect: 9db6f98 ...
cat packages/sdk/package.json | grep '"version"'  # expect: "version": "0.10.2"
```

---

_End of document. Update on every `@qvac/sdk` minor bump (codegen drift check in CI: YK-194)._
