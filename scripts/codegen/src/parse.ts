import * as fs from "node:fs";
import * as path from "node:path";

import ts from "typescript";

export interface ParsedSdk {
  /** Absolute path to the resolved @qvac/sdk package.json. */
  packageJsonPath: string;
  /** Name from package.json (`@qvac/sdk`). */
  packageName: string;
  /** Version string from package.json (`0.10.2`). */
  packageVersion: string;
  /** Absolute path to the `.d.ts` we treated as the SDK's public entry. */
  entryDts: string;
  /** Compiler program parsed in declaration mode. */
  program: ts.Program;
  /** Bound type checker — convenient handle for later codegen passes. */
  checker: ts.TypeChecker;
}

/**
 * Resolve `@qvac/sdk` at the given `package.json` path, build a TypeScript
 * Program over its declaration files, and return the package metadata plus
 * the compiler artifacts the later codegen passes (`emit/*`) need.
 *
 * Throws with a clear message when the package.json cannot be read, the
 * `types` entry is missing, or the entry .d.ts does not exist on disk.
 */
export function parseSdk(packageJsonPath: string): ParsedSdk {
  if (!fs.existsSync(packageJsonPath)) {
    throw new Error(`@qvac/sdk package.json not found at: ${packageJsonPath}`);
  }

  const pkgRaw = fs.readFileSync(packageJsonPath, "utf-8");
  let pkg: {
    name?: unknown;
    version?: unknown;
    types?: unknown;
    typings?: unknown;
  };
  try {
    pkg = JSON.parse(pkgRaw) as typeof pkg;
  } catch (err) {
    throw new Error(
      `@qvac/sdk package.json is not valid JSON (${packageJsonPath}): ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }

  if (typeof pkg.name !== "string" || pkg.name.length === 0) {
    throw new Error(`@qvac/sdk package.json is missing "name": ${packageJsonPath}`);
  }
  if (typeof pkg.version !== "string" || pkg.version.length === 0) {
    throw new Error(`@qvac/sdk package.json is missing "version": ${packageJsonPath}`);
  }

  const typesField =
    typeof pkg.types === "string"
      ? pkg.types
      : typeof pkg.typings === "string"
        ? pkg.typings
        : undefined;
  if (typesField === undefined) {
    throw new Error(
      `@qvac/sdk package.json must declare a "types" entry: ${packageJsonPath}`,
    );
  }

  const pkgDir = path.dirname(packageJsonPath);
  const entryDts = path.resolve(pkgDir, typesField);
  if (!fs.existsSync(entryDts)) {
    throw new Error(
      `@qvac/sdk "types" entry does not exist on disk: ${entryDts}. ` +
        "Did you run `pnpm install`?",
    );
  }

  const compilerOptions: ts.CompilerOptions = {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.NodeNext,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    declaration: true,
    skipLibCheck: true,
    strict: true,
    esModuleInterop: true,
  };

  // Pass every .d.ts under the SDK's dist as a root file. Loading just the
  // entry doesn't pull in transitive `.d.ts` (the compiler's symbol resolver
  // follows imports but it doesn't add resolved sources to the program's
  // root list, so `program.getSourceFiles()` only returns files we name
  // explicitly). YK-179's codegen needs to walk every `interface` /
  // `type alias` declared in the SDK, so we widen the roots here.
  const distDir = path.dirname(entryDts);
  const dtsRoots = listDtsFilesRecursively(distDir);

  const program = ts.createProgram(dtsRoots, compilerOptions);
  const checker = program.getTypeChecker();

  return {
    packageJsonPath,
    packageName: pkg.name,
    packageVersion: pkg.version,
    entryDts,
    program,
    checker,
  };
}

/** Recursively list all `.d.ts` files under `dir`. */
function listDtsFilesRecursively(dir: string): string[] {
  const out: string[] = [];
  const stack: string[] = [dir];
  while (stack.length > 0) {
    const current = stack.pop()!;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
      } else if (entry.isFile() && full.endsWith(".d.ts") && !full.endsWith(".d.ts.map")) {
        out.push(full);
      }
    }
  }
  return out.sort();
}

/**
 * Enumerate the exported symbols of the SDK entry file. Deliberately a thin
 * pass for YK-178: later issues (`YK-179`, `YK-180`, `YK-181`) call into this
 * to map symbols → Swift outputs.
 *
 * Returns a stable, alphabetically sorted list so callers don't have to.
 */
export function listEntryExports(parsed: ParsedSdk): Array<{
  name: string;
  flags: ts.SymbolFlags;
  symbol: ts.Symbol;
}> {
  const entry = parsed.program.getSourceFile(parsed.entryDts);
  if (entry === undefined) {
    throw new Error(
      `Compiler program did not produce a source file for ${parsed.entryDts}`,
    );
  }
  const moduleSymbol = parsed.checker.getSymbolAtLocation(entry);
  if (moduleSymbol === undefined) {
    return [];
  }
  const exports = parsed.checker.getExportsOfModule(moduleSymbol);
  return exports
    .map((sym) => ({ name: sym.getName(), flags: sym.flags, symbol: sym }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}
