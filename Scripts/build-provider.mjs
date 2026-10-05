#!/usr/bin/env node
// Bundles each root-search provider into a single self-contained file the resident JS runtime
// (RootSearchProviderHost) can load. `@tinycast/api` and the Node builtins stay external — the
// runtime's module registry resolves them; everything else is inlined.
//
// The output's name is the provider's id: the host keys each provider's support and cache
// directories by it, and the app finds bundles by that convention.
//
//   node Scripts/build-provider.mjs     # writes build/<id>.provider.js for every source

import { build } from "esbuild";
import { copyFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const sources = [
  { id: "movies", entry: "tinycast/movies/provider.js" },
  { id: "wikipedia", entry: "tinycast/wikipedia/provider.js", assets: ["wikipedia.png"] },
];

let failed = false;
for (const source of sources) {
  const outfile = resolve(root, "build", `${source.id}.provider.js`);
  const result = await build({
    entryPoints: [resolve(root, source.entry)],
    outfile,
    bundle: true,
    platform: "browser",
    format: "cjs",
    target: "es2022",
    write: true,
    plugins: [
      // Everything under node:... and node builtins stays external for the runtime's registry.
      {
        name: "external-node",
        setup(b) {
          b.onResolve(
            { filter: /^(fs|path|os|process|child_process|crypto|zlib|node:[^/]+)$/ },
            () => ({ external: true }),
          );
          b.onResolve({ filter: /^@tinycast\/api$/ }, () => ({ external: true }));
        },
      },
    ],
    logLevel: "warning",
  });

  for (const warning of result.warnings) console.warn(warning.text);
  if (result.errors.length) {
    console.error(result.errors.map((e) => e.text).join("\n"));
    failed = true;
    continue;
  }
  // A provider's row icon has to sit beside its bundle: that directory is all the host will resolve a
  // candidate's `iconPath` against.
  for (const name of source.assets ?? []) {
    await copyFile(resolve(root, "tinycast/assets", name), resolve(root, "build", name));
  }
  console.log(`wrote ${outfile}`);
}

if (failed) process.exit(1);
