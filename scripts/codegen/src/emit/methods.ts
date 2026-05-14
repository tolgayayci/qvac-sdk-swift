import { mkdirSync, writeFileSync } from "node:fs";
import * as path from "node:path";

export interface EmitMethodsResult {
  swiftPath: string;
  count: number;
}

/**
 * Static method list mirroring `tetherto/qvac/packages/sdk/index.ts:4-47`
 * (verified at commit 9db6f98 — see `docs/qvac-sdk-internals.md` §13).
 *
 * Each entry maps a public SDK function to:
 *  - the `QVACCommand` it dispatches on the wire
 *  - the Swift signature shape (`reply` → `async throws -> Response`,
 *    `stream` → `AsyncThrowingStream<Chunk, Error>`, `duplex` → bidirectional)
 *  - the request DTO type name (from YK-179's `Models/`) or
 *    `AnyCodable` for the deferred set
 *  - the response DTO type name (same)
 *
 * For M1, method bodies route through `QVACClient`'s internal `send` /
 * `streamResponse` helpers — currently stubs (`fatalError("YK-201 wires
 *  QVACClient → RPCBridge")`). The compile-time surface is complete; M2
 * fills in the runtime.
 */
const QVAC_METHODS: ReadonlyArray<MethodSpec> = [
  // Lifecycle
  // QVAC's worker dispatches on the JSON envelope's `type` field, but
  // since YK-198 the `QVACClient.send` helper auto-injects `type` from
  // the `QVACCommand` argument; the payload can be empty. Typed-DTO
  // methods (e.g. UnloadModelRequest) still carry a `type: String`
  // field at the type level — that's the source-of-truth for their
  // schema, but the envelope helper overrides it anyway with the
  // command's rawValue.
  { name: "heartbeat", command: "heartbeat", mode: "reply",
    request: { kind: "literal", swift: "[String: AnyCodable]",
      value: "([:] as [String: AnyCodable])" },
    response: { kind: "type", swift: "HeartbeatResponse" } },
  { name: "loadModel", command: "loadModel", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "unloadModel", command: "unloadModel", mode: "reply",
    request: { kind: "type", swift: "UnloadModelRequest" },
    response: { kind: "type", swift: "UnloadModelResponse" } },
  { name: "downloadAsset", command: "downloadAsset", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "suspend", command: "suspend", mode: "reply",
    request: { kind: "type", swift: "SuspendRequest" },
    response: { kind: "type", swift: "SuspendResponse" } },
  { name: "resume", command: "resume", mode: "reply",
    request: { kind: "type", swift: "ResumeRequest" },
    response: { kind: "type", swift: "ResumeResponse" } },
  { name: "state", command: "state", mode: "reply",
    request: { kind: "type", swift: "StateRequest" },
    response: { kind: "type", swift: "StateResponse" } },

  // `close()` is hand-written on the QVACClient actor itself (it tears
  // the transport + RPCBridge down — client-side lifecycle, not a wire
  // request). The bounty-method table in CommandsAndMethodsTest.swift
  // still tracks it with `wireCommand: nil` so the surface contract
  // remains explicit.

  // Embed / Completion
  { name: "embed", command: "embed", mode: "reply",
    request: { kind: "type", swift: "EmbedRequest" },
    response: { kind: "type", swift: "EmbedResponse" } },
  { name: "completion", command: "completionStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Transcription
  { name: "transcribe", command: "transcribe", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "transcribeStream", command: "transcribeStream", mode: "duplex",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Text-to-speech
  { name: "textToSpeech", command: "textToSpeech", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "textToSpeechStream", command: "textToSpeechStream", mode: "duplex",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Translation
  { name: "translate", command: "translate", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // OCR
  { name: "ocr", command: "ocrStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Diffusion / Upscale
  { name: "diffusion", command: "diffusionStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "upscale", command: "upscaleStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Cancel / DeleteCache
  { name: "cancel", command: "cancel", mode: "reply",
    request: { kind: "anyCodable" },
    response: { kind: "type", swift: "CancelResponse" } },
  { name: "deleteCache", command: "deleteCache", mode: "reply",
    request: { kind: "anyCodable" },
    response: { kind: "type", swift: "DeleteCacheResponse" } },

  // Get model info
  { name: "getModelInfo", command: "getModelInfo", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "getLoadedModelInfo", command: "getLoadedModelInfo", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Logging
  { name: "loggingStream", command: "loggingStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Plugins
  { name: "invokePlugin", command: "pluginInvoke", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "invokePluginStream", command: "pluginInvokeStream", mode: "stream",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Model registry
  { name: "modelRegistryList", command: "modelRegistryList", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "modelRegistrySearch", command: "modelRegistrySearch", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "modelRegistryGetModel", command: "modelRegistryGetModel", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Finetune
  { name: "finetune", command: "finetune", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },

  // Provider lifecycle (renamed in SDK: startQVACProvider → wire `provide`)
  { name: "startQVACProvider", command: "provide", mode: "reply",
    request: { kind: "type", swift: "ProvideRequest" },
    response: { kind: "type", swift: "ProvideResponse" } },
  { name: "stopQVACProvider", command: "stopProvide", mode: "reply",
    request: { kind: "type", swift: "StopProvideRequest" },
    response: { kind: "type", swift: "StopProvideResponse" } },

  // RAG (9 operations)
  { name: "ragChunk", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragIngest", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragSaveEmbeddings", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragSearch", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragDeleteEmbeddings", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragReindex", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragListWorkspaces", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragCloseWorkspace", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
  { name: "ragDeleteWorkspace", command: "rag", mode: "reply",
    request: { kind: "anyCodable" }, response: { kind: "anyCodable" } },
];

interface MethodSpec {
  /** Swift method name as it'll appear on QVACClient (camelCase). */
  name: string;
  /** QVACCommand case the method dispatches on, or null for client-only methods like `close`. */
  command: string | null;
  /** Wire-level dispatch mode. `void` is the special case for `close()`. */
  mode: "reply" | "stream" | "duplex" | "void";
  /** Request payload shape. null for nullary methods (close). */
  request: TypeRef | null;
  /** Response shape. null for void-returning methods. */
  response: TypeRef | null;
}

type TypeRef =
  | { kind: "type"; swift: string }
  | { kind: "anyCodable" }
  | { kind: "literal"; swift: string; value: string };

export function emitMethods(input: { source: string }, outDir: string): EmitMethodsResult {
  mkdirSync(outDir, { recursive: true });
  const swiftPath = path.join(outDir, "Client+Methods.swift");
  const sorted = [...QVAC_METHODS].sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
  );

  const out: string[] = [];
  out.push("// Auto-generated by scripts/codegen — DO NOT EDIT BY HAND.");
  out.push(`// Source: ${input.source}`);
  out.push("// Curated from packages/sdk/index.ts:4-47 (YK-175 §13).");
  out.push("// Re-generate with: pnpm --filter @qvac-swift/codegen run run");
  out.push("");
  out.push("import Foundation");
  out.push("");
  out.push("/// Public method surface. Every entry from `@qvac/sdk`'s exported");
  out.push("/// function list (`packages/sdk/index.ts:4-47`) gets a Swift-side");
  out.push("/// counterpart on `QVACClient`. Bodies route through the actor's");
  out.push("/// internal `send` / `streamResponse` helpers (see");
  out.push("/// `Sources/QVACClient/Support/QVACClient+SendStream.swift`), which");
  out.push("/// in turn delegate to the `RPCBridge` set up by `connect()`.");
  out.push("///");
  out.push("/// Per-method richer types (replacing the `AnyCodable` placeholders");
  out.push("/// where the YK-179 allowlist doesn't cover the request/response");
  out.push("/// yet) land in YK-201..YK-205. The surface itself is wired and");
  out.push("/// callable from M2/YK-197.");
  out.push("extension QVACClient {");
  for (const m of sorted) {
    out.push("");
    emitMethodSignature(out, m);
  }
  out.push("}");
  out.push("");

  writeFileSync(swiftPath, out.join("\n") + "\n", "utf-8");
  return { swiftPath, count: sorted.length };
}

function emitMethodSignature(out: string[], method: MethodSpec): void {
  if (method.mode === "void") {
    // Unused since YK-197 — `close()` is hand-written on the actor.
    // Kept as a fallthrough in case a future bounty method is genuinely
    // client-only.
    throw new Error(
      `void-mode method "${method.name}" should be hand-written on QVACClient, not generated`,
    );
  }

  const requestParam = formatRequestParam(method);
  const requestValue = formatRequestValue(method);
  const command = method.command;
  if (command === null) throw new Error(`method ${method.name} has no command`);

  switch (method.mode) {
    case "reply": {
      const responseSwift = formatResponseType(method);
      out.push(`  /// Routes wire command \`${command}\` (reply).`);
      if (method.response?.kind === "anyCodable" || method.request?.kind === "anyCodable") {
        out.push("  /// Request/response shape is `AnyCodable` until codegen drains");
        out.push("  /// the deferred set (see `docs/codegen-deferred.md`).");
      }
      out.push(`  public func ${method.name}(${requestParam}) async throws -> ${responseSwift} {`);
      out.push(`    return try await self.send(`);
      out.push(`      command: .${camelFromWire(command)}, ${requestValue})`);
      out.push("  }");
      break;
    }
    case "stream": {
      const chunkSwift = formatResponseType(method);
      out.push(`  /// Routes wire command \`${command}\` (server-streamed response).`);
      out.push(
        `  public nonisolated func ${method.name}(${requestParam}) -> AsyncThrowingStream<${chunkSwift}, Error> {`,
      );
      out.push(`    return self.streamResponse(`);
      out.push(`      command: .${camelFromWire(command)}, ${requestValue})`);
      out.push("  }");
      break;
    }
    case "duplex": {
      out.push(`  /// Routes wire command \`${command}\` (duplex — request and`);
      out.push("  /// response streams both run). Full duplex API design lands in");
      out.push("  /// M2 (YK-202 / YK-204); M1 surfaces a single-stream stub.");
      out.push(`  public nonisolated func ${method.name}(${requestParam}) -> AsyncThrowingStream<AnyCodable, Error> {`);
      out.push(`    return self.streamResponse(`);
      out.push(`      command: .${camelFromWire(command)}, ${requestValue})`);
      out.push("  }");
      break;
    }
  }
}

function formatRequestParam(method: MethodSpec): string {
  const req = method.request;
  if (req === null) return "";
  if (req.kind === "literal") return ""; // hardcoded default
  if (req.kind === "anyCodable") return "_ request: AnyCodable = AnyCodable(.null)";
  return `_ request: ${req.swift}`;
}

function formatRequestValue(method: MethodSpec): string {
  const req = method.request;
  if (req === null) return "";
  if (req.kind === "literal") return req.value;
  return "request";
}

function formatResponseType(method: MethodSpec): string {
  const resp = method.response;
  if (resp === null) return "Void";
  if (resp.kind === "anyCodable") return "AnyCodable";
  return resp.swift;
}

function camelFromWire(wire: string): string {
  // Wire-side names are already camelCase (heartbeat, loadModel, etc.).
  return wire;
}
