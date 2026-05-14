import { spawnSync } from "node:child_process";
import * as path from "node:path";
import * as url from "node:url";

/**
 * Optional swift-format post-pass. The generator's hand-written output is
 * already canonical (sorted, `\n`-only line endings, no timestamps), so
 * formatting only catches drift if someone hand-edits a generated file —
 * which the `pnpm run run` drift check would also catch.
 *
 * We run swift-format if-and-only-if the binary is on PATH. Most CI
 * runners (Ubuntu, the codegen-ts and codegen-drift jobs in our pipeline)
 * don't ship swift-format, and we don't want to gate codegen on a
 * platform-specific binary. The macOS runner that has Xcode 16 does
 * have it via `xcrun swift-format`, and that's where the format pass
 * actually matters.
 *
 * Required version: swift-format from the Swift 6.0 toolchain (ships
 * with Xcode 16). Pinned via the toolchain itself rather than a
 * standalone binary — see `docs/dependencies.md`.
 *
 * Returns `{ ran: false, reason }` when skipped (no binary, no config),
 * and `{ ran: true, files }` when applied.
 */
export interface FormatResult {
  ran: boolean;
  reason?: string;
  files?: number;
}

export function formatGenerated(outDir: string): FormatResult {
  const swiftFormat = locateSwiftFormat();
  if (swiftFormat === null) {
    return {
      ran: false,
      reason: "swift-format not on PATH; skipping (output is already canonical)",
    };
  }

  const configPath = locateSwiftFormatConfig();
  if (configPath === null) {
    return { ran: false, reason: ".swift-format config not found at repo root" };
  }

  const result = spawnSync(
    swiftFormat,
    [
      "format",
      "--in-place",
      "--recursive",
      "--configuration",
      configPath,
      path.resolve(outDir),
    ],
    { stdio: ["ignore", "pipe", "pipe"], encoding: "utf-8" },
  );

  if (result.status !== 0) {
    const stderr = result.stderr?.trim() ?? "";
    throw new Error(
      `swift-format exited with code ${result.status}${stderr ? `: ${stderr}` : ""}`,
    );
  }

  return { ran: true, files: countSwiftFiles(outDir) };
}

function locateSwiftFormat(): string | null {
  // `which` is on every Unix; the spawn returns 0 + the resolved path on
  // stdout if found. On Windows we'd use `where`, but the codegen is only
  // expected to run on macOS/Linux dev hosts.
  const which = spawnSync("which", ["swift-format"], { encoding: "utf-8" });
  if (which.status === 0) {
    const path = which.stdout.trim();
    if (path.length > 0) return path;
  }

  // Fall back to `xcrun -f swift-format` on macOS — handles the case
  // where Xcode ships the binary but it isn't on the user's PATH.
  const xcrun = spawnSync("xcrun", ["-f", "swift-format"], { encoding: "utf-8" });
  if (xcrun.status === 0) {
    const path = xcrun.stdout.trim();
    if (path.length > 0) return path;
  }

  return null;
}

function locateSwiftFormatConfig(): string | null {
  // The config lives at the repo root. cli.ts already knows we sit at
  // scripts/codegen/src — apply the same relative offset.
  const here = path.dirname(url.fileURLToPath(import.meta.url));
  const candidate = path.resolve(here, "../../..", ".swift-format");
  return candidate;
}

function countSwiftFiles(dir: string): number {
  const result = spawnSync(
    "find",
    [dir, "-type", "f", "-name", "*.swift"],
    { encoding: "utf-8" },
  );
  if (result.status !== 0) return 0;
  return result.stdout.split("\n").filter((l) => l.length > 0).length;
}
