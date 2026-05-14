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
  { name: "heartbeat", command: "heartbeat", mode: "reply",
    request: { kind: "literal", swift: "[String: AnyCodable]", value: "([:] as [String: AnyCodable])" },
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
  { name: "close", command: null, mode: "void", request: null, response: null },

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
  out.push("/// counterpart on `QVACClient`. M1 only declares the surface — the");
  out.push("/// runtime wiring (Transport setup, RPCBridge composition, JSON");
  out.push("/// envelope construction with the correct `type` discriminator)");
  out.push("/// lands in M2 (YK-197 QVACClient actor, YK-198 init handshake,");
  out.push("/// YK-201..YK-205 per-method work).");
  out.push("///");
  out.push("/// Until then, every body is a `fatalError(\"YK-201\")` placeholder —");
  out.push("/// the surface compiles, downstream consumers can wire against it,");
  out.push("/// and runtime callers are guaranteed to crash loudly so we never");
  out.push("/// ship a silently-broken method.");
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
    // close() — no command on the wire, no request/response.
    out.push("  /// Tears down the client. Sends `__shutdown__` to the worker");
    out.push("  /// (M2 — see docs/qvac-sdk-internals.md §5) and closes the transport.");
    out.push(`  public func ${method.name}() async throws {`);
    out.push(`    fatalError("YK-201 wires QVACClient.${method.name} to RPCBridge")`);
    out.push("  }");
    return;
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
      out.push(`    let _: ${responseSwift} = try await self.send(`);
      out.push(`      command: .${camelFromWire(command)}, ${requestValue})`);
      out.push(`    fatalError("YK-201 wires QVACClient.send to RPCBridge")`);
      out.push("  }");
      break;
    }
    case "stream": {
      const chunkSwift = formatResponseType(method);
      out.push(`  /// Routes wire command \`${command}\` (server-streamed response).`);
      out.push(
        `  public func ${method.name}(${requestParam}) -> AsyncThrowingStream<${chunkSwift}, Error> {`,
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
      out.push(`  public func ${method.name}(${requestParam}) -> AsyncThrowingStream<AnyCodable, Error> {`);
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
