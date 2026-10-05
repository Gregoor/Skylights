// JavaScriptCore-compatibility probe: runs the real search library inside the extension runtime.
// Compile with esbuild (CJS, @raycast/api + react external), then run via
//   node Scripts/raycast-runtime/test.mjs <this-dir> <command>
// which executes the generated runtime in a bare `vm` context (the closest thing to JavaScriptCore
// Node offers) with the real fs node-shim backed by real file I/O.

import { List } from "@raycast/api";
import { openRuntimeReader } from "../../../src/db/runtime-reader.mjs";
import { MovieIndex } from "../../../src/db/loader.mjs";
import { searchMovies } from "../../../src/movies/search.mjs";

const INDEX = "/tmp/movies-full.index";

export default async function Command() {
  const results = [];
  try {
    const fs = require("fs");
    const index = new MovieIndex({ reader: openRuntimeReader(INDEX, fs) });
    await index.open();
    results.push(`rows=${index.rowCount} terms=${index.termCount} postings=${index.postings.length}`);

    for (const q of ["alien", "matrix 1999", "mulholland drive", "parasite", "café-amélie"]) {
      const res = await searchMovies(index, q, { limit: 3 });
      results.push(
        `${JSON.stringify(q)} -> ${res.map((x) => `${x.title} (${x.year}) imdb=${x.imdbID}`).join(" | ") || "(none)"}`,
      );
    }
  } catch (error) {
    results.push(`ERROR: ${error}`);
  }

  return (
    <List>
      {results.map((line, i) => (
        <List.Item key={String(i)} title={line} />
      ))}
    </List>
  );
}