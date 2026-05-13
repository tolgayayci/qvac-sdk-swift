import { createRequire } from "node:module";
import * as path from "node:path";
import * as url from "node:url";

const require = createRequire(import.meta.url);

export interface CliOptions {
  sdkPath: string;
  outDir: string;
}

/**
 * Parse argv into a `CliOptions`. Accepts:
 *   --sdk-path <path>  (or first positional)
 *   --out-dir  <path>  (or second positional)
 * Falls back to require.resolve("@qvac/sdk/package.json") and
 * "<repo-root>/Sources/QVACClient/Generated" when omitted.
 *
 * Errors thrown here are surfaced verbatim — main() turns them into
 * non-zero exits with a clear message.
 */
export function parseCliOptions(argv: readonly string[]): CliOptions {
  let sdkPath: string | undefined;
  let outDir: string | undefined;
  const positional: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    switch (arg) {
      case "--sdk-path": {
        const next = argv[++i];
        if (next === undefined) {
          throw new Error("--sdk-path requires a path argument");
        }
        sdkPath = next;
        break;
      }
      case "--out-dir": {
        const next = argv[++i];
        if (next === undefined) {
          throw new Error("--out-dir requires a path argument");
        }
        outDir = next;
        break;
      }
      case "--help":
      case "-h":
        throw new Error(usage());
      default:
        if (arg.startsWith("--")) {
          throw new Error(`Unknown flag: ${arg}\n${usage()}`);
        }
        positional.push(arg);
        break;
    }
  }

  if (sdkPath === undefined && positional[0] !== undefined) {
    sdkPath = positional[0];
  }
  if (outDir === undefined && positional[1] !== undefined) {
    outDir = positional[1];
  }

  if (sdkPath === undefined) {
    // @qvac/sdk exports its package.json under the "./package" subpath
    // rather than the bare ".json" suffix.
    sdkPath = require.resolve("@qvac/sdk/package");
  }

  if (outDir === undefined) {
    const here = path.dirname(url.fileURLToPath(import.meta.url));
    // src/cli.ts is two levels below scripts/codegen, and scripts/codegen
    // is two levels below the repo root.
    outDir = path.resolve(here, "../../../Sources/QVACClient/Generated");
  }

  return { sdkPath: path.resolve(sdkPath), outDir: path.resolve(outDir) };
}

export function usage(): string {
  return [
    "Usage: tsx src/index.ts [--sdk-path <path>] [--out-dir <path>]",
    "       tsx src/index.ts <sdk-path> <out-dir>",
    "",
    "  --sdk-path  Path to @qvac/sdk's package.json. Defaults to the resolved npm package.",
    "  --out-dir   Where to write generated Swift sources. Defaults to",
    "              <repo-root>/Sources/QVACClient/Generated/.",
  ].join("\n");
}
