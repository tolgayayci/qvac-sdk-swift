import { mkdirSync, writeFileSync } from "node:fs";
import * as path from "node:path";

import ts from "typescript";

import type { DeclIR, FieldIR, TypeIR } from "../ir/types.js";
import { emitDecl, swiftFieldName } from "../util/typemap.js";

export interface EmitTypesInput {
  /** Parsed `ts.Program` from `parseSdk`. */
  program: ts.Program;
  /** Type checker bound to that program. */
  checker: ts.TypeChecker;
  /** Source-of-truth identifier for the auto-gen banner (e.g. `@qvac/sdk@0.10.2`). */
  source: string;
  /** Allow-list of named top-level type aliases / interfaces to extract.
   *  When omitted, every exported name is attempted; types that don't
   *  cleanly translate are dropped and listed in the returned `skipped`
   *  field along with the reason. */
  include?: ReadonlyArray<string>;
}

export interface EmitTypesResult {
  outDir: string;
  written: string[];
  skipped: Array<{ name: string; reason: string }>;
}

/**
 * Walk the SDK's .d.ts surface and emit one Swift file per extractable
 * type. Designed for forward-compat: any name we can't translate cleanly
 * goes onto the `skipped` list with a reason rather than crashing, so the
 * codegen output is always a coherent subset of what's possible.
 */
export function emitTypes(input: EmitTypesInput, outDir: string): EmitTypesResult {
  const modelsDir = path.join(outDir, "Models");
  mkdirSync(modelsDir, { recursive: true });

  const include = input.include ? new Set(input.include) : null;
  const written: string[] = [];
  const skipped: Array<{ name: string; reason: string }> = [];

  const candidates = collectExportedTypes(input.program, input.checker, include);
  // Sort by name for deterministic output across re-runs.
  candidates.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

  for (const candidate of candidates) {
    try {
      const decl = buildDecl(candidate, input.checker);
      if (!decl) {
        skipped.push({ name: candidate.name, reason: "type did not yield a translatable IR" });
        continue;
      }
      const swift = renderFile(decl, input.source);
      const file = path.join(modelsDir, `${candidate.name}.swift`);
      writeFileSync(file, swift, "utf-8");
      written.push(`Models/${candidate.name}.swift`);
    } catch (err) {
      skipped.push({
        name: candidate.name,
        reason: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return { outDir: modelsDir, written, skipped };
}

interface Candidate {
  name: string;
  symbol: ts.Symbol;
  declaration: ts.Declaration;
}

function collectExportedTypes(
  program: ts.Program,
  checker: ts.TypeChecker,
  include: Set<string> | null,
): Candidate[] {
  const found = new Map<string, Candidate>();

  for (const sourceFile of program.getSourceFiles()) {
    if (!isSdkDeclarationFile(sourceFile.fileName)) continue;
    const moduleSymbol = checker.getSymbolAtLocation(sourceFile);
    if (!moduleSymbol) continue;

    for (const exported of checker.getExportsOfModule(moduleSymbol)) {
      if (found.has(exported.name)) continue;
      if (include && !include.has(exported.name)) continue;
      const decl = exported.declarations?.[0];
      if (!decl) continue;
      if (
        !ts.isTypeAliasDeclaration(decl) &&
        !ts.isInterfaceDeclaration(decl) &&
        !ts.isEnumDeclaration(decl)
      ) {
        continue;
      }
      found.set(exported.name, { name: exported.name, symbol: exported, declaration: decl });
    }
  }

  return [...found.values()];
}

function isSdkDeclarationFile(fileName: string): boolean {
  if (!fileName.endsWith(".d.ts")) return false;
  if (fileName.includes("/node_modules/typescript/")) return false;
  // Only the @qvac/sdk package; skip zod, bare-*, etc.
  return fileName.includes("/@qvac/sdk/");
}

function buildDecl(candidate: Candidate, checker: ts.TypeChecker): DeclIR | null {
  const decl = candidate.declaration;

  if (ts.isEnumDeclaration(decl)) {
    return buildEnumDecl(candidate.name, decl, checker);
  }

  // For type aliases and interfaces: resolve their declared type via the
  // TypeChecker. Zod's `z.infer<...>` evaporates and we get the concrete
  // anonymous shape.
  const declaredType = ts.isTypeAliasDeclaration(decl)
    ? checker.getTypeFromTypeNode(decl.type)
    : checker.getDeclaredTypeOfSymbol(candidate.symbol);

  const ir = mapType(declaredType, checker);

  if (ir.kind === "object") {
    const fields = ir.fields;
    if (fields.length === 0) return null;
    return { kind: "struct", name: candidate.name, fields };
  }

  if (ir.kind === "discriminatedUnion") {
    return {
      kind: "discriminatedEnum",
      name: candidate.name,
      discriminator: ir.discriminator,
      cases: ir.cases,
    };
  }

  if (ir.kind === "union" && allStringLiterals(ir.variants)) {
    return {
      kind: "stringEnum",
      name: candidate.name,
      cases: ir.variants.map((v) => {
        if (v.kind !== "literalString") throw new Error("unreachable");
        return { swift: swiftCaseFromString(v.value), raw: v.value };
      }),
    };
  }

  // Anything else: emit a typealias. Anonymous object types render as
  // AnyCodable, so the call site at least typechecks.
  return { kind: "alias", name: candidate.name, target: ir };
}

function buildEnumDecl(
  name: string,
  decl: ts.EnumDeclaration,
  checker: ts.TypeChecker,
): DeclIR | null {
  const stringCases: { swift: string; raw: string }[] = [];
  const intCases: { swift: string; raw: number }[] = [];
  for (const member of decl.members) {
    if (!ts.isIdentifier(member.name)) continue;
    const memberName = member.name.text;
    const value = checker.getConstantValue(member);
    if (typeof value === "string") {
      stringCases.push({ swift: swiftCaseFromString(memberName), raw: value });
    } else if (typeof value === "number") {
      intCases.push({ swift: swiftCaseFromString(memberName), raw: value });
    } else {
      return null;
    }
  }
  if (stringCases.length > 0 && intCases.length === 0) {
    return { kind: "stringEnum", name, cases: stringCases };
  }
  if (intCases.length > 0 && stringCases.length === 0) {
    return { kind: "intEnum", name, cases: intCases };
  }
  return null;
}

function mapType(type: ts.Type, checker: ts.TypeChecker): TypeIR {
  // Primitive type flags. Order matters — a literal type has both
  // String/Number/Boolean AND the *Literal flag, so check literals first.
  if (type.isStringLiteral()) {
    return { kind: "literalString", value: String(type.value) };
  }
  if (type.isNumberLiteral()) {
    return { kind: "literalNumber", value: Number(type.value) };
  }
  if (
    type.flags & ts.TypeFlags.BooleanLiteral &&
    "intrinsicName" in (type as { intrinsicName?: string })
  ) {
    const intrinsicName = (type as { intrinsicName?: string }).intrinsicName;
    return { kind: "literalBoolean", value: intrinsicName === "true" };
  }
  if (type.flags & ts.TypeFlags.String) return { kind: "string" };
  if (type.flags & ts.TypeFlags.Number) return { kind: "double" };
  if (type.flags & ts.TypeFlags.Boolean) return { kind: "bool" };
  if (type.flags & ts.TypeFlags.Null) return { kind: "literalNull" };
  if (type.flags & ts.TypeFlags.Undefined) return { kind: "void" };
  if (type.flags & ts.TypeFlags.Void) return { kind: "void" };
  if (type.flags & ts.TypeFlags.Any || type.flags & ts.TypeFlags.Unknown) {
    return { kind: "any" };
  }

  // Union types.
  if (type.isUnion()) {
    // TS represents the `boolean` primitive as `true | false`. When a
    // Zod `.boolean().optional()` resolves, we end up with literally
    // `true | false | undefined`, which surfaces here as a union of two
    // BooleanLiteral types (+ optionally void). Collapse that back to a
    // primitive `bool` so the field renders as `Bool` instead of
    // `AnyCodable`.
    const nonNullishVariants = type.types.filter(
      (t) => !(t.flags & ts.TypeFlags.Undefined) && !(t.flags & ts.TypeFlags.Void),
    );
    const allBooleanLiterals =
      nonNullishVariants.length > 0 &&
      nonNullishVariants.every((t) => (t.flags & ts.TypeFlags.BooleanLiteral) !== 0);
    if (allBooleanLiterals) {
      return { kind: "bool" };
    }

    const variants = type.types.map((t) => mapType(t, checker));
    const discriminated = tryBuildDiscriminatedUnion(type, checker);
    if (discriminated) return discriminated;
    return { kind: "union", variants };
  }

  if (type.isIntersection()) {
    // Intersections aren't first-class in Swift's Codable surface;
    // surface as AnyCodable. Common case (`Foo & { extra }`) loses
    // some fidelity but stays valid.
    return { kind: "any" };
  }

  // Named binary-buffer types → Data.
  const symName = type.aliasSymbol?.name ?? type.symbol?.name;
  if (symName === "Uint8Array" || symName === "Buffer" || symName === "ArrayBuffer") {
    return { kind: "data" };
  }

  // Arrays via the type-checker helper.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const isArray = (checker as any).isArrayType?.(type) === true;
  if (isArray) {
    const args = (type as ts.TypeReference).typeArguments ?? [];
    const elem = args[0];
    if (elem) {
      return { kind: "array", of: mapType(elem, checker) };
    }
    return { kind: "array", of: { kind: "any" } };
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const isTuple = (checker as any).isTupleType?.(type) === true;
  if (isTuple) {
    // Swift doesn't have great tuple-Codable support; surface as [AnyCodable].
    return { kind: "array", of: { kind: "any" } };
  }

  // Index signatures → Record-shaped.
  const stringIndex = type.getStringIndexType();
  const numberIndex = type.getNumberIndexType();
  if (stringIndex) {
    return {
      kind: "record",
      key: { kind: "string" },
      value: mapType(stringIndex, checker),
    };
  }
  if (numberIndex) {
    return {
      kind: "record",
      key: { kind: "int" },
      value: mapType(numberIndex, checker),
    };
  }

  // Object types: walk apparent properties so we follow `&` intersections
  // and method-like properties (ZodObject inference flattens them).
  if (type.flags & ts.TypeFlags.Object) {
    const fields = mapObjectFields(type, checker);
    return { kind: "object", fields };
  }

  return { kind: "any" };
}

function mapObjectFields(type: ts.Type, checker: ts.TypeChecker): FieldIR[] {
  const props = type.getProperties();
  const fields: FieldIR[] = [];
  for (const prop of props) {
    const propType = propertyType(prop, checker);
    if (!propType) continue;
    const ir = mapType(propType, checker);
    let optional = (prop.flags & ts.SymbolFlags.Optional) !== 0;
    let unwrapped: TypeIR = ir;
    if (ir.kind === "union") {
      const nonNullish = ir.variants.filter(
        (v) => v.kind !== "literalNull" && v.kind !== "void",
      );
      if (nonNullish.length < ir.variants.length) {
        optional = true;
        unwrapped = nonNullish.length === 1 ? nonNullish[0]! : { ...ir, variants: nonNullish };
      }
    }
    fields.push({ name: prop.getName(), type: unwrapped, optional });
  }
  return fields;
}

function propertyType(prop: ts.Symbol, checker: ts.TypeChecker): ts.Type | null {
  const decl = prop.valueDeclaration ?? prop.declarations?.[0];
  if (!decl) {
    // No source location — `getTypeOfSymbol` is the only fallback. It's
    // less precise but better than nothing.
    return checker.getTypeOfSymbol(prop);
  }
  return checker.getTypeOfSymbolAtLocation(prop, decl);
}

function tryBuildDiscriminatedUnion(
  type: ts.UnionType,
  checker: ts.TypeChecker,
): TypeIR | null {
  // Heuristic: a discriminated union is a union of objects where every
  // member has the same string-literal-typed property whose name we'll
  // use as the discriminator. The conventional name in QVAC is "type".
  const candidates = type.types.map((t) => {
    if (!(t.flags & ts.TypeFlags.Object)) return null;
    const fields = mapObjectFields(t, checker);
    const stringLiteralFields = fields.filter(
      (f) => f.type.kind === "literalString",
    );
    return { fields, stringLiteralFields };
  });
  if (candidates.some((c) => c === null)) return null;

  // Find a property name that's a string literal on EVERY variant.
  const commonNames: Map<string, Set<string>> = new Map();
  for (const c of candidates) {
    for (const f of c!.stringLiteralFields) {
      if (!commonNames.has(f.name)) commonNames.set(f.name, new Set());
      // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
      commonNames.get(f.name)!.add((f.type as { value: string }).value);
    }
  }
  let discriminator: string | null = null;
  for (const [name, values] of commonNames) {
    if (values.size === candidates.length) {
      // Every variant has the same property name with a distinct string
      // literal. Prefer "type" if present; otherwise take the first.
      discriminator = discriminator === null || name === "type" ? name : discriminator;
    }
  }
  if (discriminator === null) return null;

  const cases = candidates.map((c) => {
    const discField = c!.fields.find((f) => f.name === discriminator);
    if (!discField || discField.type.kind !== "literalString") {
      throw new Error("unreachable — discriminator missing on variant");
    }
    const others = c!.fields.filter((f) => f.name !== discriminator);
    return {
      discriminantValue: discField.type.value,
      fields: others,
    };
  });
  return { kind: "discriminatedUnion", discriminator, cases };
}

function allStringLiterals(variants: TypeIR[]): boolean {
  if (variants.length === 0) return false;
  return variants.every((v) => v.kind === "literalString");
}

function swiftCaseFromString(s: string): string {
  // Lowercase first char, sanitize separators. Keeps camelCase intact.
  // Routes through `swiftFieldName` so Swift reserved words (e.g. `is`,
  // `as`, `case`, `class`) get backtick-escaped — otherwise enum cases
  // like `case is` are a parse error.
  const clean = s.replace(/[^a-zA-Z0-9_]/g, "_");
  const lc = clean.charAt(0).toLowerCase() + clean.slice(1);
  return swiftFieldName(lc);
}

function renderFile(decl: DeclIR, source: string): string {
  const banner = [
    "// Auto-generated by scripts/codegen — DO NOT EDIT BY HAND.",
    `// Source: ${source}`,
    "// Re-generate with: pnpm --filter @qvac-swift/codegen run run",
    "",
    "import Foundation",
    "",
  ].join("\n");
  return banner + emitDecl(decl);
}
