import { describe, expect, it } from "vitest";

import type { DeclIR, FieldIR, TypeIR } from "../ir/types.js";
import { emitDecl, mapTypeToSwift, swiftFieldName } from "../util/typemap.js";

describe("mapTypeToSwift — primitives", () => {
  it.each([
    [{ kind: "string" } as TypeIR, "String"],
    [{ kind: "double" } as TypeIR, "Double"],
    [{ kind: "int" } as TypeIR, "Int"],
    [{ kind: "bool" } as TypeIR, "Bool"],
    [{ kind: "data" } as TypeIR, "Data"],
    [{ kind: "void" } as TypeIR, "Void"],
    [{ kind: "any" } as TypeIR, "AnyCodable"],
  ])("%j → %s", (input, expected) => {
    expect(mapTypeToSwift(input)).toBe(expected);
  });
});

describe("mapTypeToSwift — literals", () => {
  it("string literal → String", () => {
    expect(mapTypeToSwift({ kind: "literalString", value: "ping" })).toBe("String");
  });
  it("integer numeric literal → Int", () => {
    expect(mapTypeToSwift({ kind: "literalNumber", value: 50001 })).toBe("Int");
  });
  it("float numeric literal → Double", () => {
    expect(mapTypeToSwift({ kind: "literalNumber", value: 0.5 })).toBe("Double");
  });
  it("boolean literal → Bool", () => {
    expect(mapTypeToSwift({ kind: "literalBoolean", value: true })).toBe("Bool");
  });
  it("null literal → AnyCodable?", () => {
    expect(mapTypeToSwift({ kind: "literalNull" })).toBe("AnyCodable?");
  });
});

describe("mapTypeToSwift — composites", () => {
  it("optional wraps with ?", () => {
    expect(mapTypeToSwift({ kind: "optional", of: { kind: "string" } })).toBe("String?");
  });
  it("array of double → [Double]", () => {
    expect(mapTypeToSwift({ kind: "array", of: { kind: "double" } })).toBe("[Double]");
  });
  it("array of string → [String]", () => {
    expect(mapTypeToSwift({ kind: "array", of: { kind: "string" } })).toBe("[String]");
  });
  it("nested array → [[Int]]", () => {
    expect(
      mapTypeToSwift({
        kind: "array",
        of: { kind: "array", of: { kind: "int" } },
      }),
    ).toBe("[[Int]]");
  });
  it("Record<String, V> → [String: V]", () => {
    expect(
      mapTypeToSwift({
        kind: "record",
        key: { kind: "string" },
        value: { kind: "any" },
      }),
    ).toBe("[String: AnyCodable]");
  });
  it("reference passes name through", () => {
    expect(mapTypeToSwift({ kind: "reference", name: "ModelInfo" })).toBe("ModelInfo");
  });
});

describe("mapTypeToSwift — unions", () => {
  it("T | null collapses to T?", () => {
    expect(
      mapTypeToSwift({
        kind: "union",
        variants: [{ kind: "string" }, { kind: "literalNull" }],
      }),
    ).toBe("String?");
  });

  it("T | undefined (void) collapses to T?", () => {
    expect(
      mapTypeToSwift({
        kind: "union",
        variants: [{ kind: "int" }, { kind: "void" }],
      }),
    ).toBe("Int?");
  });

  it("multi-variant union → AnyCodable", () => {
    expect(
      mapTypeToSwift({
        kind: "union",
        variants: [{ kind: "string" }, { kind: "int" }],
      }),
    ).toBe("AnyCodable");
  });

  it("object kind → AnyCodable (must be hoisted)", () => {
    expect(mapTypeToSwift({ kind: "object", fields: [] })).toBe("AnyCodable");
  });

  it("discriminated union kind → AnyCodable (must be hoisted)", () => {
    expect(
      mapTypeToSwift({
        kind: "discriminatedUnion",
        discriminator: "type",
        cases: [],
      }),
    ).toBe("AnyCodable");
  });
});

describe("swiftFieldName — reserved-word backticks", () => {
  it("rewrites Swift reserved words", () => {
    expect(swiftFieldName("type")).toBe("`type`");
    expect(swiftFieldName("class")).toBe("`class`");
    expect(swiftFieldName("default")).toBe("`default`");
  });
  it("leaves identifiers alone", () => {
    expect(swiftFieldName("modelId")).toBe("modelId");
    expect(swiftFieldName("totalTokens")).toBe("totalTokens");
  });
});

describe("emitDecl — struct", () => {
  it("emits a simple Codable struct with init", () => {
    const decl: DeclIR = {
      kind: "struct",
      name: "PingResponse",
      fields: [
        { name: "type", type: { kind: "string" }, optional: false } as FieldIR,
        { name: "seq", type: { kind: "int" }, optional: true } as FieldIR,
      ],
    };
    const out = emitDecl(decl);
    expect(out).toContain("public struct PingResponse: Codable, Sendable, Equatable {");
    expect(out).toContain("public let `type`: String");
    expect(out).toContain("public let seq: Int?");
    expect(out).toContain("public init(");
    // Reserved-word coding key remapping
    expect(out).toContain("case `type` = \"type\"");
    expect(out).toContain("case seq");
  });

  it("optional fields default to nil in the initializer", () => {
    const out = emitDecl({
      kind: "struct",
      name: "HasOptional",
      fields: [
        { name: "a", type: { kind: "string" }, optional: false } as FieldIR,
        { name: "b", type: { kind: "string" }, optional: true } as FieldIR,
      ],
    });
    expect(out).toContain("a: String,");
    expect(out).toContain("b: String? = nil");
  });
});

describe("emitDecl — string enum", () => {
  it("emits cases with raw values when swift != raw", () => {
    const out = emitDecl({
      kind: "stringEnum",
      name: "LifecycleState",
      cases: [
        { swift: "active", raw: "active" },
        { swift: "suspending", raw: "suspending" },
        { swift: "suspended", raw: "suspended" },
        { swift: "resuming", raw: "resuming" },
      ],
    });
    expect(out).toContain(
      "public enum LifecycleState: String, Codable, Sendable, Equatable, CaseIterable {",
    );
    expect(out).toContain("case active");
    expect(out).toContain("case suspending");
    expect(out).toContain("case suspended");
    expect(out).toContain("case resuming");
  });
});

describe("emitDecl — discriminated enum", () => {
  it("emits cases with associated values, payload structs, and custom Codable", () => {
    const out = emitDecl({
      kind: "discriminatedEnum",
      name: "DeleteCacheRequest",
      discriminator: "type",
      cases: [
        {
          discriminantValue: "deleteCacheAll",
          fields: [
            { name: "all", type: { kind: "literalBoolean", value: true }, optional: false } as FieldIR,
          ],
        },
        {
          discriminantValue: "deleteCacheKey",
          fields: [
            { name: "kvCacheKey", type: { kind: "string" }, optional: false } as FieldIR,
            { name: "modelId", type: { kind: "string" }, optional: true } as FieldIR,
          ],
        },
      ],
    });
    expect(out).toContain("public enum DeleteCacheRequest: Codable, Sendable, Equatable {");
    expect(out).toContain("case deleteCacheAll(all: Bool)");
    expect(out).toContain("case deleteCacheKey(kvCacheKey: String, modelId: String?)");
    expect(out).toContain("public init(from decoder: Decoder)");
    expect(out).toContain("public func encode(to encoder: Encoder)");
    expect(out).toContain("private struct DeleteCacheRequest_deleteCacheAll_Payload");
  });
});
