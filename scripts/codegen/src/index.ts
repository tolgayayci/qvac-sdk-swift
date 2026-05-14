#!/usr/bin/env tsx
import ts from "typescript";

import { parseCliOptions, usage } from "./cli.js";
import { emitCommands } from "./emit/commands.js";
import { emitErrorCodes, loadErrorCodesFromPackage } from "./emit/errors.js";
import { emitMethods } from "./emit/methods.js";
import { emitTypes } from "./emit/types.js";
import { listEntryExports, parseSdk, type ParsedSdk } from "./parse.js";

/**
 * Curated set of `@qvac/sdk` type names that the M1 codegen knows how to
 * translate cleanly into Swift `Codable`. Anything outside this list
 * needs deeper TypeChecker resolution (cross-type references, generics,
 * intersections, ambiguous discriminated unions) and is deferred to
 * M2/M3 codegen passes. Tracked in `docs/codegen-deferred.md`.
 */
const CODEGEN_TYPES_ALLOWLIST = [
  // Lifecycle
  "LifecycleState",
  "StateRequest",
  "StateResponse",
  "SuspendRequest",
  "SuspendResponse",
  "ResumeRequest",
  "ResumeResponse",
  // Connectivity
  "HeartbeatRequest",
  "HeartbeatResponse",
  "DelegateBase",
  // Embed
  "EmbedParams",
  "EmbedRequest",
  "EmbedResponse",
  "EmbedStats",
  // Unload
  "UnloadModelRequest",
  "UnloadModelResponse",
  // Provider lifecycle
  "ProvideRequest",
  "ProvideResponse",
  "FirewallConfig",
  "StopProvideRequest",
  "StopProvideResponse",
  // Cache
  "DeleteCacheResponse",
  // Cancellation
  "CancelResponse",
  // Common enums
  "TtsLanguage",
  "BergamotLanguage",
  "ProfilerMode",
  "ModelType",
] as const;

/**
 * Print a deterministic, human-readable summary of what the harness sees.
 * Emit format intentionally stable: each subsequent codegen issue (YK-179,
 * YK-180, YK-181) will fill in real outputs and append/replace lines here.
 */
export function reportHarnessFindings(parsed: ParsedSdk): string {
  // Count declaration files that live inside the SDK package directory —
  // i.e. all the .d.ts the entry's exports transitively touch, minus the
  // TypeScript stdlib (lib.*.d.ts) and unrelated node_modules.
  const pkgDir = parsed.entryDts.split("/dist/")[0] ?? "";
  const sourceFiles = parsed.program
    .getSourceFiles()
    .filter((sf) => sf.fileName.startsWith(pkgDir));
  const exports = listEntryExports(parsed);

  // Aliases: the entry .d.ts re-exports nearly everything from `./schemas/*`.
  // YK-179 will widen the parse to follow those imports (load schemas/*.d.ts
  // directly) so kind classification becomes accurate. For YK-178 we just
  // surface how many of the entry exports are pure re-exports.
  let aliasCount = 0;
  for (const ex of exports) {
    if (ex.flags & ts.SymbolFlags.Alias) aliasCount++;
  }

  return [
    "QVAC Swift codegen harness",
    "",
    `  package        ${parsed.packageName}@${parsed.packageVersion}`,
    `  package.json   ${parsed.packageJsonPath}`,
    `  entry .d.ts    ${parsed.entryDts}`,
    `  sources read   ${sourceFiles.length}`,
    `  exports found  ${exports.length}`,
    `    (of which re-exports / aliases: ${aliasCount})`,
    "",
    "  YK-179 will widen the parse to follow `export ... from \"./schemas\"`",
    "  re-exports and classify each symbol by its concrete declaration kind.",
  ].join("\n");
}

export async function main(argv: readonly string[]): Promise<number> {
  let options;
  try {
    options = parseCliOptions(argv);
  } catch (err) {
    if (err instanceof Error && err.message.startsWith("Usage:")) {
      process.stdout.write(`${err.message}\n`);
      return 0;
    }
    process.stderr.write(
      `error: ${err instanceof Error ? err.message : String(err)}\n${usage()}\n`,
    );
    return 2;
  }

  let parsed;
  try {
    parsed = parseSdk(options.sdkPath);
  } catch (err) {
    process.stderr.write(
      `error: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 1;
  }

  process.stdout.write(`${reportHarnessFindings(parsed)}\n`);

  // YK-181 — emit ErrorCodes.swift.
  try {
    const { clientCodes, serverCodes } = await loadErrorCodesFromPackage();
    const result = emitErrorCodes(
      {
        clientCodes,
        serverCodes,
        packageName: parsed.packageName,
        packageVersion: parsed.packageVersion,
      },
      options.outDir,
    );
    process.stdout.write(
      `  ErrorCodes.swift  ${result.clientCount} client + ${result.serverCount} server codes\n`,
    );
  } catch (err) {
    process.stderr.write(
      `error: emitErrorCodes failed: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 1;
  }

  // YK-179 — emit Models/*.swift for a curated, build-verified allowlist.
  // The full SDK has 138 exported types but many resolve to deeply nested
  // Zod-inferred shapes with cross-type references that don't translate
  // cleanly into Swift Codable without extensive special-casing (generics,
  // intersections, discriminated unions with shared discriminant values).
  // The allowlist is what M1 ships with a clean compile; the deferred set
  // is documented at `docs/codegen-deferred.md` and gets built out in
  // M2/M3 as those methods need them.
  try {
    const result = emitTypes(
      {
        program: parsed.program,
        checker: parsed.checker,
        source: `${parsed.packageName}@${parsed.packageVersion}`,
        include: CODEGEN_TYPES_ALLOWLIST,
      },
      options.outDir,
    );
    process.stdout.write(
      `  Models/           ${result.written.length} written, ${result.skipped.length} skipped\n`,
    );
    if (result.skipped.length > 0 && process.env["QVAC_CODEGEN_VERBOSE"]) {
      for (const skip of result.skipped.slice(0, 20)) {
        process.stdout.write(`    skipped: ${skip.name} — ${skip.reason}\n`);
      }
      if (result.skipped.length > 20) {
        process.stdout.write(`    ... ${result.skipped.length - 20} more skipped\n`);
      }
    }
  } catch (err) {
    process.stderr.write(
      `error: emitTypes failed: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 1;
  }

  // YK-180 — emit Commands.swift + Client+Methods.swift.
  try {
    const source = `${parsed.packageName}@${parsed.packageVersion}`;
    const commands = emitCommands({ source }, options.outDir);
    const methods = emitMethods({ source }, options.outDir);
    process.stdout.write(`  Commands.swift    ${commands.count} request types\n`);
    process.stdout.write(`  Client+Methods    ${methods.count} method stubs\n`);
  } catch (err) {
    process.stderr.write(
      `error: emitCommands/emitMethods failed: ${err instanceof Error ? err.message : String(err)}\n`,
    );
    return 1;
  }

  process.stdout.write(`✓ Codegen complete → ${options.outDir}\n`);
  return 0;
}

const isDirectInvocation =
  import.meta.url === `file://${process.argv[1] ?? ""}` ||
  process.argv[1]?.endsWith("/index.ts") === true ||
  process.argv[1]?.endsWith("/index.js") === true;

if (isDirectInvocation) {
  const code = await main(process.argv.slice(2));
  process.exit(code);
}
