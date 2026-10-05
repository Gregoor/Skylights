#!/usr/bin/env node
// Compile the JavaScriptCore-compatibility probe into a bundle the runtime can load, then run it
// through the repo's real runtime harness (bare `vm` context + two fs shim).
//
//   node tinycast/test/jsc/build.mjs
//
// Requires esbuild (the repo's raycast-runtime already depends on it).

import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const dir = dirname(fileURLToPath(import.meta.url));
const root = resolve(dir, "..", "..", "..");
// Resolve esbuild from the sibling `npm/` install (npm install esbuild there first).
const esbuild = await import(`${resolve(dir, "npm", "node_modules", "esbuild", "lib", "main.js")}`);
const { buildSync } = esbuild;

const entry = resolve(dir, "search-probe.tsx");
const outfile = resolve(dir, "search-probe.js");

const { errors } = buildSync({
  entryPoints: [entry],
  outfile,
  bundle: true,
  platform: "neutral",
  format: "cjs",
  target: "es2022",
  loader: { ".tsx": "jsx", ".jsx": "jsx", ".mjs": "js", ".js": "js" },
  jsx: "automatic",
  jsxImportSource: "react",
  external: ["@raycast/api", "react", "react/jsx-runtime"],
  packages: "external",
  logLevel: "silent",
});
if (errors.length) {
  console.error(errors.map((e) => e.text).join("\n"));
  process.exit(1);
}
console.log(`bundled ${entry} -> ${outfile}`);