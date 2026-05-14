/**
 * Convert a SCREAMING_SNAKE_CASE token to lowerCamelCase, matching Swift
 * enum case conventions.
 *
 * Examples:
 *   INVALID_RESPONSE_TYPE  -> invalidResponseType
 *   MODEL_NOT_FOUND        -> modelNotFound
 *   OCR_FAILED             -> ocrFailed
 *   RPC_NO_HANDLER         -> rpcNoHandler
 *
 * Numeric segments are preserved as-is. Pre-existing camelCase or
 * unconventional input is best-effort.
 */
export function snakeToLowerCamel(input: string): string {
  if (input.length === 0) return input;
  // If the input contains no underscores, treat it as already-camelCase
  // (or PascalCase) and only lowercase the first character. This handles
  // discriminated-union case names like "deleteCacheAll" that should
  // preserve their internal capitalization.
  if (!input.includes("_")) {
    return input.charAt(0).toLowerCase() + input.slice(1);
  }
  const parts = input.toLowerCase().split("_").filter((p) => p.length > 0);
  if (parts.length === 0) return input;
  return parts
    .map((part, i) => {
      if (i === 0) return part;
      return part.charAt(0).toUpperCase() + part.slice(1);
    })
    .join("");
}

/** Convert SCREAMING_SNAKE_CASE to UpperCamelCase / PascalCase. */
export function snakeToUpperCamel(input: string): string {
  const lc = snakeToLowerCamel(input);
  return lc.charAt(0).toUpperCase() + lc.slice(1);
}
