import { snakeToLowerCamel, snakeToUpperCamel } from "./case.js";
import type { DeclIR, FieldIR, TypeIR } from "../ir/types.js";

/**
 * Render a `TypeIR` as a Swift type expression — e.g. `String`, `[Int]?`,
 * `[String: AnyCodable]`. Anonymous object types render as `AnyCodable`
 * (since they have no name); callers should hoist nested objects to
 * named decls before mapping if they want concrete struct types.
 */
export function mapTypeToSwift(t: TypeIR): string {
  switch (t.kind) {
    case "string":
      return "String";
    case "double":
      return "Double";
    case "int":
      return "Int";
    case "bool":
      return "Bool";
    case "data":
      return "Data";
    case "void":
      return "Void";
    case "any":
      return "AnyCodable";
    case "literalString":
      return "String"; // literal values flow through; the field constrains them
    case "literalNumber":
      return Number.isInteger(t.value) ? "Int" : "Double";
    case "literalBoolean":
      return "Bool";
    case "literalNull":
      return "AnyCodable?";
    case "optional":
      return `${mapTypeToSwift(t.of)}?`;
    case "array":
      return `[${mapTypeToSwift(t.of)}]`;
    case "record":
      return `[${mapTypeToSwift(t.key)}: ${mapTypeToSwift(t.value)}]`;
    case "reference":
      return t.name;
    case "object":
      // Anonymous objects can't be named at the call site — fall back to
      // AnyCodable. The walker should hoist nested objects to named decls
      // before reaching this point.
      return "AnyCodable";
    case "union":
      return unionToSwift(t.variants);
    case "discriminatedUnion":
      // Discriminated unions can only render as a named Swift enum; an
      // inline expression is meaningless. Callers that have a discriminated
      // union as a field type should hoist it to a named decl.
      return "AnyCodable";
  }
}

function unionToSwift(variants: TypeIR[]): string {
  // Collapse `T | null` and `T | undefined` to `T?`.
  const nonNullish = variants.filter(
    (v) => v.kind !== "literalNull" && v.kind !== "void",
  );
  if (nonNullish.length === 1 && nonNullish.length < variants.length) {
    return `${mapTypeToSwift(nonNullish[0]!)}?`;
  }
  // All-string-literal unions render as `String` inline (the value is
  // constrained by the wire schema; Swift doesn't have anonymous string
  // unions). At the top-level decl layer they become a Swift enum.
  if (nonNullish.length > 0 && nonNullish.every((v) => v.kind === "literalString")) {
    return "String";
  }
  // All-numeric-literal unions → Int / Double depending on shape.
  if (nonNullish.length > 0 && nonNullish.every((v) => v.kind === "literalNumber")) {
    const allInt = nonNullish.every(
      (v) =>
        v.kind === "literalNumber" && Number.isInteger((v as { value: number }).value),
    );
    return allInt ? "Int" : "Double";
  }
  return "AnyCodable";
}

/**
 * Render a `DeclIR` as the full body of a Swift file (banner not included —
 * the emitter prepends a shared banner).
 */
export function emitDecl(decl: DeclIR): string {
  switch (decl.kind) {
    case "struct":
      return emitStruct(decl);
    case "stringEnum":
      return emitStringEnum(decl);
    case "intEnum":
      return emitIntEnum(decl);
    case "discriminatedEnum":
      return emitDiscriminatedEnum(decl);
    case "alias":
      return emitAlias(decl);
  }
}

function emitStruct(decl: Extract<DeclIR, { kind: "struct" }>): string {
  const out: string[] = [];
  if (decl.doc) out.push(...docBlock(decl.doc));
  out.push(`public struct ${decl.name}: Codable, Sendable, Equatable {`);
  for (const f of decl.fields) {
    out.push(`  public let ${swiftFieldName(f.name)}: ${fieldType(f)}`);
  }
  out.push("");
  out.push(`  public init(`);
  out.push(
    decl.fields
      .map((f) => {
        const param = `${swiftFieldName(f.name)}: ${fieldType(f)}`;
        const defaultExpr = f.optional ? " = nil" : "";
        return `    ${param}${defaultExpr}`;
      })
      .join(",\n"),
  );
  out.push(`  ) {`);
  for (const f of decl.fields) {
    const swiftName = swiftFieldName(f.name);
    out.push(`    self.${swiftName} = ${swiftName}`);
  }
  out.push(`  }`);

  // Wire field-name overrides for CodingKeys when the Swift identifier
  // diverges from the wire name (snake_case → camelCase, reserved words).
  const overrides = decl.fields
    .map((f) => ({ swift: swiftFieldName(f.name), wire: f.name }))
    .filter((f) => f.swift !== f.wire);
  if (overrides.length > 0) {
    out.push("");
    out.push(`  private enum CodingKeys: String, CodingKey {`);
    for (const f of decl.fields) {
      const swift = swiftFieldName(f.name);
      if (swift === f.name) {
        out.push(`    case ${swift}`);
      } else {
        out.push(`    case ${swift} = "${f.name}"`);
      }
    }
    out.push(`  }`);
  }

  out.push(`}`);
  return out.join("\n") + "\n";
}

function emitStringEnum(decl: Extract<DeclIR, { kind: "stringEnum" }>): string {
  const out: string[] = [];
  if (decl.doc) out.push(...docBlock(decl.doc));
  out.push(`public enum ${decl.name}: String, Codable, Sendable, Equatable, CaseIterable {`);
  for (const c of decl.cases) {
    if (c.swift === c.raw) {
      out.push(`  case ${c.swift}`);
    } else {
      out.push(`  case ${c.swift} = "${c.raw}"`);
    }
  }
  out.push(`}`);
  return out.join("\n") + "\n";
}

function emitIntEnum(decl: Extract<DeclIR, { kind: "intEnum" }>): string {
  const out: string[] = [];
  if (decl.doc) out.push(...docBlock(decl.doc));
  out.push(`public enum ${decl.name}: Int, Codable, Sendable, Equatable, CaseIterable {`);
  for (const c of decl.cases) {
    out.push(`  case ${c.swift} = ${c.raw}`);
  }
  out.push(`}`);
  return out.join("\n") + "\n";
}

function emitDiscriminatedEnum(
  decl: Extract<DeclIR, { kind: "discriminatedEnum" }>,
): string {
  const out: string[] = [];
  if (decl.doc) out.push(...docBlock(decl.doc));
  out.push(`public enum ${decl.name}: Codable, Sendable, Equatable {`);
  for (const c of decl.cases) {
    const swiftCase = snakeToLowerCamel(c.discriminantValue.replace(/[-\s]/g, "_"));
    if (c.fields.length === 0) {
      out.push(`  case ${swiftCase}`);
    } else {
      const params = c.fields
        .map((f) => `${swiftFieldName(f.name)}: ${fieldType(f)}`)
        .join(", ");
      out.push(`  case ${swiftCase}(${params})`);
    }
  }

  // Encode/decode by discriminator.
  out.push("");
  out.push(`  private enum DiscriminatorKey: String, CodingKey {`);
  out.push(`    case ${swiftFieldName(decl.discriminator)} = "${decl.discriminator}"`);
  out.push(`  }`);
  out.push("");
  out.push(`  public init(from decoder: Decoder) throws {`);
  out.push(`    let container = try decoder.container(keyedBy: DiscriminatorKey.self)`);
  out.push(
    `    let discriminant = try container.decode(String.self, forKey: .${swiftFieldName(decl.discriminator)})`,
  );
  out.push(`    switch discriminant {`);
  for (const c of decl.cases) {
    const swiftCase = snakeToLowerCamel(c.discriminantValue.replace(/[-\s]/g, "_"));
    out.push(`    case "${c.discriminantValue}":`);
    if (c.fields.length === 0) {
      out.push(`      self = .${swiftCase}`);
    } else {
      out.push(`      let payload = try ${decl.name}_${swiftCase}_Payload(from: decoder)`);
      const args = c.fields
        .map((f) => `${swiftFieldName(f.name)}: payload.${swiftFieldName(f.name)}`)
        .join(", ");
      out.push(`      self = .${swiftCase}(${args})`);
    }
  }
  out.push(`    default:`);
  out.push(
    `      throw DecodingError.dataCorruptedError(forKey: .${swiftFieldName(decl.discriminator)}, in: container, debugDescription: "Unknown ${decl.discriminator}=\\(discriminant)")`,
  );
  out.push(`    }`);
  out.push(`  }`);

  out.push("");
  out.push(`  public func encode(to encoder: Encoder) throws {`);
  out.push(`    var container = encoder.container(keyedBy: DiscriminatorKey.self)`);
  out.push(`    switch self {`);
  for (const c of decl.cases) {
    const swiftCase = snakeToLowerCamel(c.discriminantValue.replace(/[-\s]/g, "_"));
    if (c.fields.length === 0) {
      out.push(`    case .${swiftCase}:`);
      out.push(
        `      try container.encode("${c.discriminantValue}", forKey: .${swiftFieldName(decl.discriminator)})`,
      );
    } else {
      const binds = c.fields.map((f) => `let ${swiftFieldName(f.name)}`).join(", ");
      out.push(`    case .${swiftCase}(${binds}):`);
      out.push(
        `      try container.encode("${c.discriminantValue}", forKey: .${swiftFieldName(decl.discriminator)})`,
      );
      const fieldArgs = c.fields
        .map((f) => `${swiftFieldName(f.name)}: ${swiftFieldName(f.name)}`)
        .join(", ");
      out.push(
        `      try ${decl.name}_${swiftCase}_Payload(${fieldArgs}).encode(to: encoder)`,
      );
    }
  }
  out.push(`    }`);
  out.push(`  }`);
  out.push(`}`);

  // Emit a private payload struct for each non-empty case so encode/decode
  // can round-trip extra fields with synthesized Codable.
  for (const c of decl.cases) {
    if (c.fields.length === 0) continue;
    const swiftCase = snakeToLowerCamel(c.discriminantValue.replace(/[-\s]/g, "_"));
    out.push("");
    out.push(`private struct ${decl.name}_${swiftCase}_Payload: Codable {`);
    for (const f of c.fields) {
      out.push(`  let ${swiftFieldName(f.name)}: ${fieldType(f)}`);
    }
    const overrides = c.fields
      .map((f) => ({ swift: swiftFieldName(f.name), wire: f.name }))
      .filter((f) => f.swift !== f.wire);
    if (overrides.length > 0) {
      out.push(`  private enum CodingKeys: String, CodingKey {`);
      for (const f of c.fields) {
        const swift = swiftFieldName(f.name);
        if (swift === f.name) {
          out.push(`    case ${swift}`);
        } else {
          out.push(`    case ${swift} = "${f.name}"`);
        }
      }
      out.push(`  }`);
    }
    out.push(`}`);
  }
  return out.join("\n") + "\n";
}

function emitAlias(decl: Extract<DeclIR, { kind: "alias" }>): string {
  const out: string[] = [];
  if (decl.doc) out.push(...docBlock(decl.doc));
  out.push(`public typealias ${decl.name} = ${mapTypeToSwift(decl.target)}`);
  return out.join("\n") + "\n";
}

function fieldType(f: FieldIR): string {
  const base = mapTypeToSwift(f.type);
  if (f.optional) {
    return base.endsWith("?") ? base : `${base}?`;
  }
  return base;
}

function docBlock(doc: string): string[] {
  return doc
    .split("\n")
    .map((line) => `/// ${line.trimEnd()}`);
}

/**
 * Render a TypeScript identifier as a Swift field name. Handles:
 *  - kebab-case → camelCase (so `llamacpp-completion` becomes `llamacppCompletion`)
 *  - non-identifier characters → underscores
 *  - identifiers starting with a digit → prefixed with `_`
 *  - Swift reserved words → backtick-escaped
 */
export function swiftFieldName(name: string): string {
  let safe = name;
  if (safe.includes("-") || safe.includes(" ") || safe.includes(".")) {
    // kebab-case → camelCase, preserving inner capitalization
    const parts = safe.split(/[-.\s]+/).filter((p) => p.length > 0);
    safe = parts
      .map((part, i) =>
        i === 0
          ? part.charAt(0).toLowerCase() + part.slice(1)
          : part.charAt(0).toUpperCase() + part.slice(1),
      )
      .join("");
  }
  // Replace any remaining non-identifier characters with underscores.
  safe = safe.replace(/[^A-Za-z0-9_]/g, "_");
  if (/^\d/.test(safe)) safe = `_${safe}`;
  if (SWIFT_RESERVED.has(safe)) return `\`${safe}\``;
  return safe;
}

const SWIFT_RESERVED = new Set([
  "self", "Type", "type", "init", "deinit", "class", "struct", "enum",
  "protocol", "extension", "associatedtype", "var", "let", "func", "import",
  "case", "switch", "for", "while", "if", "else", "return", "throw", "throws",
  "rethrows", "try", "catch", "do", "guard", "defer", "where", "in", "is",
  "as", "any", "some", "static", "public", "private", "internal", "fileprivate",
  "open", "weak", "unowned", "true", "false", "nil", "default", "Self",
  "_", "operator", "precedencegroup", "infix", "prefix", "postfix",
  "associativity", "left", "right", "none",
]);

export { snakeToLowerCamel, snakeToUpperCamel };
