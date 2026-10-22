import ts from "typescript";
import { dirname, resolve, sep } from "node:path";

const root = resolve(import.meta.dir, "..");
export function checkPortableSource(
  path: string,
  source: string,
  name: "contracts" | "domain" | "application" | "client",
): void {
  const ast = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true);
  function dependency(module: string): void {
    if (module.startsWith(".")) {
      const target = resolve(root, dirname(path), module);
      if (!target.startsWith(resolve(root, `packages/${name}/src`) + sep))
        throw new Error(`Package escape in ${path}`);
    } else if (
      !(
        name !== "contracts" &&
        /^@thumble\/contracts(?:\/(?:receiver|mobile-input|pairing|json))?$/.test(
          module,
        )
      )
    ) {
      throw new Error(`Nonportable dependency ${module} in ${path}`);
    }
  }
  function visit(node: ts.Node): void {
    if (
      (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier
    ) {
      if (!ts.isStringLiteral(node.moduleSpecifier))
        throw new Error(`Nonliteral module: ${path}`);
      dependency(node.moduleSpecifier.text);
    }
    if (ts.isImportTypeNode(node)) {
      if (
        !ts.isLiteralTypeNode(node.argument) ||
        !ts.isStringLiteral(node.argument.literal)
      )
        throw new Error(`Nonliteral type dependency: ${path}`);
      dependency(node.argument.literal.text);
    }
    if (ts.isImportEqualsDeclaration(node))
      throw new Error(`CommonJS dependency in ${path}`);
    if (
      ts.isCallExpression(node) &&
      (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
        (ts.isIdentifier(node.expression) &&
          ["require", "eval"].includes(node.expression.text)))
    )
      throw new Error(`Dynamic dependency in ${path}`);
    ts.forEachChild(node, visit);
  }
  visit(ast);
}

if (import.meta.main) {
  for (const name of [
    "contracts",
    "domain",
    "application",
    "client",
  ] as const) {
    for await (const scanned of new Bun.Glob(
      `packages/${name}/src/**/*.ts`,
    ).scan({
      cwd: root,
    })) {
      const path = scanned.replaceAll("\\", "/");
      if (name === "client" && path === "packages/client/src/local.ts")
        continue;
      checkPortableSource(
        path,
        await Bun.file(resolve(root, path)).text(),
        name,
      );
    }
  }
  console.log("Portable contracts/domain import boundaries verified");
}
