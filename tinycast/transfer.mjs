// Fetching and unpacking release artifacts through the runtime's `child_process` shim. Both providers
// need exactly this, and a bundle inlines what it imports, so sharing the source costs nothing at
// runtime — while keeping the curl and gunzip flags in one place.
//
// Both are asynchronous, and awaited: the runtime is a single thread, so `execFileSync` would hold every
// query behind a transfer — which is exactly what the first search after an update used to do.

/// Run a child to completion. The shim gives Node's callback shape, so the promise is ours to make.
function run(file, args) {
  const { execFile } = require("child_process");
  return new Promise((resolve, reject) => {
    execFile(file, args, (error) => (error ? reject(error) : resolve()));
  });
}

/// Fetch `url` to `path` through curl, writing beside the target and renaming, so a failed or partial
/// transfer never leaves a truncated file where the loader would open it.
export async function download(url, path) {
  const fs = require("fs");
  await run("/usr/bin/curl", ["-fsSL", "--retry", "3", url, "-o", `${path}.part`]);
  fs.renameSync(`${path}.part`, path);
}

/// Unpack `from` into `to`, again beside the target and renamed. gzip comes from the OS rather than a
/// bundled library, as curl does. `--compressed` cannot make the *download* do this: GitHub serves a
/// release asset as the bytes it was uploaded as, with no `Content-Encoding` to negotiate.
export async function gunzip(from, to) {
  const fs = require("fs");
  await run("/bin/sh", ["-c", `/usr/bin/gunzip -c '${from}' > '${to}.part'`]);
  fs.renameSync(`${to}.part`, to);
}
