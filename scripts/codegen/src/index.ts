#!/usr/bin/env tsx
import ts from "typescript";

import { parseCliOptions, usage } from "./cli.js";
import { emitErrorCodes, loadErrorCodesFromPackage } from "./emit/errors.js";
import { listEntryExports, parseSdk, type ParsedSdk } from "./parse.js";

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

  process.stdout.write(`✓ Codegen complete → ${options.outDir}\n`);

  // YK-179, YK-180 plug their emit passes in here.
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
