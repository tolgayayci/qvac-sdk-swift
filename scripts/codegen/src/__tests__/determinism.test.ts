import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import * as url from "node:url";

import { describe, expect, it } from "vitest";

/**
 * Run the full codegen pipeline twice into separate tmp directories and
 * assert that every emitted file is byte-identical between runs.
 *
 * Complements `test-idempotency.sh` (which runs the same check from the
 * shell so it can be wired into CI without a Node test harness). Vitest
 * coverage means the determinism guard runs in the same `pnpm test` job
 * as the rest of the codegen unit tests, so a regression is caught
 * before the slower drift check has to.
 */
describe("codegen determinism", () => {
  it("two consecutive runs into separate tmp dirs produce byte-identical output", () => {
    const cliEntry = path.resolve(
      path.dirname(url.fileURLToPath(import.meta.url)),
      "../index.ts",
    );

    const tmp1 = mkdtempSync(path.join(tmpdir(), "qvac-codegen-a-"));
    const tmp2 = mkdtempSync(path.join(tmpdir(), "qvac-codegen-b-"));

    try {
      runCodegen(cliEntry, tmp1);
      runCodegen(cliEntry, tmp2);

      const files1 = listRel(tmp1).sort();
      const files2 = listRel(tmp2).sort();
      expect(files2).toEqual(files1);
      expect(files1.length).toBeGreaterThan(0);

      for (const rel of files1) {
        const a = readFileSync(path.join(tmp1, rel));
        const b = readFileSync(path.join(tmp2, rel));
        expect(b.equals(a)).toBe(true);
      }
    } finally {
      rmSync(tmp1, { recursive: true, force: true });
      rmSync(tmp2, { recursive: true, force: true });
    }
  });
});

function runCodegen(cliEntry: string, outDir: string): void {
  const result = spawnSync(
    "pnpm",
    ["-s", "exec", "tsx", cliEntry, "--out-dir", outDir],
    {
      stdio: ["ignore", "pipe", "pipe"],
      encoding: "utf-8",
      cwd: path.resolve(path.dirname(cliEntry), ".."),
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `codegen exit ${result.status}: ${result.stderr || result.stdout}`,
    );
  }
}

function listRel(root: string): string[] {
  const out: string[] = [];
  const walk = (dir: string, prefix: string): void => {
    for (const entry of readdirSync(dir)) {
      const full = path.join(dir, entry);
      const rel = prefix === "" ? entry : `${prefix}/${entry}`;
      const stat = statSync(full);
      if (stat.isDirectory()) walk(full, rel);
      else out.push(rel);
    }
  };
  walk(root, "");
  return out;
}
