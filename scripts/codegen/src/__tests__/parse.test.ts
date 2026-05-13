import { createRequire } from "node:module";

import { describe, expect, it } from "vitest";

import { listEntryExports, parseSdk } from "../parse.js";

const require = createRequire(import.meta.url);

describe("parseSdk against the real @qvac/sdk package", () => {
  const pkgJson = require.resolve("@qvac/sdk/package");

  it("loads @qvac/sdk and returns a populated Program", () => {
    const parsed = parseSdk(pkgJson);
    expect(parsed.packageName).toBe("@qvac/sdk");
    expect(parsed.packageVersion.split(".")[0]).toBe("0");
    expect(parsed.program.getSourceFiles().length).toBeGreaterThan(0);
    expect(parsed.checker).toBeDefined();
  });

  it("entry .d.ts exists and is the package's types entry", () => {
    const parsed = parseSdk(pkgJson);
    expect(parsed.entryDts.endsWith(".d.ts")).toBe(true);
    // The compiler program loaded that exact file
    const sf = parsed.program.getSourceFile(parsed.entryDts);
    expect(sf).toBeDefined();
  });

  it("enumerates exports of the SDK entry — at least one method we expect", () => {
    const parsed = parseSdk(pkgJson);
    const exports = listEntryExports(parsed);
    const names = exports.map((e) => e.name);
    // These names are pinned by YK-175 §13 (public API surface).
    for (const expected of [
      "loadModel",
      "unloadModel",
      "embed",
      "heartbeat",
      "cancel",
      "close",
      "SDK_CLIENT_ERROR_CODES",
      "SDK_SERVER_ERROR_CODES",
    ]) {
      expect(names, `expected SDK to export ${expected}`).toContain(expected);
    }
  });

  it("export enumeration is stable across calls (deterministic ordering)", () => {
    const parsed1 = parseSdk(pkgJson);
    const parsed2 = parseSdk(pkgJson);
    const a = listEntryExports(parsed1).map((e) => e.name);
    const b = listEntryExports(parsed2).map((e) => e.name);
    expect(a).toEqual(b);
  });
});

describe("parseSdk failure modes", () => {
  it("throws with a clear message when package.json is missing", () => {
    expect(() => parseSdk("/tmp/does-not-exist/package.json")).toThrow(
      /not found/,
    );
  });
});
