/**
 * Intermediate representation of a TypeScript type, in a form that's
 * trivial to convert into Swift source. Decouples the TS-Compiler-API
 * walker (which fishes types out of the program) from the Swift emitter
 * (which writes the actual source text). All test surface lives on this
 * IR, so the walker can be exercised end-to-end without rebuilding a
 * compiler program in every test.
 */

/** A TypeScript type, as understood by the Swift emitter. */
export type TypeIR =
  | { kind: "string" }
  | { kind: "double" }
  | { kind: "int" }
  | { kind: "bool" }
  | { kind: "data" }                    // Uint8Array / Buffer / ArrayBuffer
  | { kind: "void" }                    // for empty unit responses
  | { kind: "any" }                     // unknown / any → AnyCodable
  | { kind: "literalString"; value: string }
  | { kind: "literalNumber"; value: number }
  | { kind: "literalBoolean"; value: boolean }
  | { kind: "literalNull" }
  | { kind: "optional"; of: TypeIR }
  | { kind: "array"; of: TypeIR }
  | { kind: "record"; key: TypeIR; value: TypeIR }
  | { kind: "reference"; name: string }
  /** Object literal — anonymous; needs to be hoisted into a nested struct
   *  by the emitter. Properties are in declaration order. */
  | { kind: "object"; fields: FieldIR[] }
  /** Plain union (not discriminated). When all variants are string literals,
   *  the emitter renders a string-raw-value enum; otherwise an `AnyCodable`. */
  | { kind: "union"; variants: TypeIR[] }
  /** Discriminated union — every variant is an object with the same
   *  discriminator field carrying a string literal. The emitter renders
   *  a Swift enum with associated values + custom Codable. */
  | { kind: "discriminatedUnion"; discriminator: string; cases: DiscriminatedCaseIR[] };

export interface FieldIR {
  name: string;
  type: TypeIR;
  optional: boolean;
}

export interface DiscriminatedCaseIR {
  discriminantValue: string;
  fields: FieldIR[]; // does NOT include the discriminator field
}

/** A top-level declaration to emit as a Swift file. */
export type DeclIR =
  | { kind: "struct"; name: string; fields: FieldIR[]; doc?: string }
  | { kind: "stringEnum"; name: string; cases: { swift: string; raw: string }[]; doc?: string }
  | { kind: "intEnum"; name: string; cases: { swift: string; raw: number }[]; doc?: string }
  | { kind: "discriminatedEnum"; name: string; discriminator: string; cases: DiscriminatedCaseIR[]; doc?: string }
  | { kind: "alias"; name: string; target: TypeIR; doc?: string };
