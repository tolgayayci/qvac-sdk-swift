import { existsSync, readFileSync, rmSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { emitErrorCodes, loadErrorCodesFromPackage } from "../emit/errors.js";

describe("emitErrorCodes against the real @qvac/sdk", () => {
  let outDir: string;
  beforeEach(() => {
    outDir = mkdtempSync(path.join(tmpdir(), "qvac-codegen-errors-"));
  });
  afterEach(() => {
    rmSync(outDir, { recursive: true, force: true });
  });

  it("loads codes from @qvac/sdk and writes ErrorCodes.swift", async () => {
    const codes = await loadErrorCodesFromPackage();
    expect(Object.keys(codes.clientCodes).length).toBeGreaterThan(0);
    expect(Object.keys(codes.serverCodes).length).toBeGreaterThan(0);

    const result = emitErrorCodes(
      {
        clientCodes: codes.clientCodes,
        serverCodes: codes.serverCodes,
        packageName: "@qvac/sdk",
        packageVersion: "0.10.2",
      },
      outDir,
    );

    expect(existsSync(result.swiftPath)).toBe(true);
    expect(existsSync(result.metaPath)).toBe(true);

    const swift = readFileSync(result.swiftPath, "utf-8");
    expect(swift).toContain("public enum QVACError");
    expect(swift).toContain("public enum QVACClientErrorCode");
    expect(swift).toContain("public enum QVACServerErrorCode");
    expect(swift).toContain("public enum QVACTransportError");

    // Known codes from YK-175 §8.2 must be present.
    expect(swift).toContain("invalidResponseType = 50001");
    expect(swift).toContain("modelNotFound = 52002");
  });

  it("is deterministic — two emissions produce byte-identical output", async () => {
    const codes = await loadErrorCodesFromPackage();
    const baseInput = {
      clientCodes: codes.clientCodes,
      serverCodes: codes.serverCodes,
      packageName: "@qvac/sdk",
      packageVersion: "0.10.2",
    };

    const dirA = mkdtempSync(path.join(tmpdir(), "qvac-codegen-det-a-"));
    const dirB = mkdtempSync(path.join(tmpdir(), "qvac-codegen-det-b-"));
    try {
      const a = emitErrorCodes(baseInput, dirA);
      const b = emitErrorCodes(baseInput, dirB);
      expect(readFileSync(a.swiftPath, "utf-8")).toBe(
        readFileSync(b.swiftPath, "utf-8"),
      );
      expect(readFileSync(a.metaPath, "utf-8")).toBe(
        readFileSync(b.metaPath, "utf-8"),
      );
    } finally {
      rmSync(dirA, { recursive: true, force: true });
      rmSync(dirB, { recursive: true, force: true });
    }
  });

  it("sidecar JSON pins the exact code list", async () => {
    const codes = await loadErrorCodesFromPackage();
    const result = emitErrorCodes(
      {
        clientCodes: codes.clientCodes,
        serverCodes: codes.serverCodes,
        packageName: "@qvac/sdk",
        packageVersion: "0.10.2",
      },
      outDir,
    );
    const meta = JSON.parse(readFileSync(result.metaPath, "utf-8"));
    expect(meta.source).toBe("@qvac/sdk@0.10.2");
    expect(meta.clientCount).toBe(Object.keys(codes.clientCodes).length);
    expect(meta.serverCount).toBe(Object.keys(codes.serverCodes).length);
    // Sample a known code.
    expect(meta.clientCodes.INVALID_RESPONSE_TYPE).toBe(50001);
    expect(meta.serverCodes.MODEL_NOT_FOUND).toBe(52002);
  });
});
