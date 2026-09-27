// Keeps the provider's local index cache in step with the release manifest.
//
// The manifest is tiny and always re-fetched; an index file is downloaded only when its recorded
// hash differs from what is already on disk. So a launch is normally one small request, a day's
// update costs only that day's delta, and only a base republish pulls the whole index again.
//
// Everything here is asynchronous, and awaited by its caller: the runtime is a single thread, so a
// transfer that blocked would hold every query behind it.
//
// `fs`, `download` and `hash` are injected: the extension runtime backs them with its fs shim, curl
// (a root-search provider may not fetch) and the crypto shim; tests back them with node equivalents.

export async function syncIndexes({
  manifestURL, cacheDir, fs, download, gunzip, hash, now = Date.now, log = () => {},
}) {
  // A provider that forgets this would download the compressed asset, fail to unpack it, and fall back
  // to the uncompressed one — paying for both, on every sync, to reach the same place.
  if (typeof gunzip !== "function") {
    throw new Error("syncIndexes needs a gunzip(from, to): the published indexes are gzipped");
  }
  fs.mkdirSync(cacheDir, { recursive: true });
  const manifestPath = `${cacheDir}/manifest.json`;
  await download(manifestURL, manifestPath);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

  const wanted = [manifest.base, ...(manifest.deltas ?? []), ...(manifest.files ?? [])].filter(Boolean);
  const dir = manifestURL.slice(0, manifestURL.lastIndexOf("/") + 1);
  const installedPath = `${cacheDir}/installed.json`;
  const installed = fs.existsSync(installedPath)
    ? JSON.parse(fs.readFileSync(installedPath, "utf8"))
    : {};
  const prior = installed.assets ?? {};

  const have = (asset) => {
    const local = `${cacheDir}/${asset.name}`;
    if (prior[asset.name] !== asset.sha256 || !fs.existsSync(local)) return false;
    // A hash mismatch means a truncated or corrupted download; refetch rather than serve it.
    return !hash || hash(local) === asset.sha256;
  };

  const assets = {};
  for (const asset of wanted) {
    const local = `${cacheDir}/${asset.name}`;
    if (!have(asset)) {
      // The wire artifact is gzipped beside the installed one, because the manifest describes what
      // lands in the cache and how it travels is a detail of getting it there. A 20 MB index is
      // 12 MB gzipped and a 16 MB one is 4.6, so this is most of the download. A release published
      // before that convention has no `.gz`, so an uncompressed fetch stays as the fallback.
      log(`downloading ${asset.name}`);
      const packed = `${local}.gz`;
      try {
        try {
          await download(dir + asset.name + ".gz", packed);
          await gunzip(packed, local);
        } catch {
          log(`${asset.name}.gz unavailable — falling back to the uncompressed asset`);
          await download(dir + asset.name, local);
        }
      } catch (error) {
        // A delta the release does not have is a publish that half-finished: the manifest was written, the
        // asset never landed. A delta is additive, so the base and the deltas that did arrive are still a
        // valid index and skipping this one keeps every later update flowing — where throwing loses the
        // whole sync, records nothing, and retries from scratch on the next query. A missing base is fatal,
        // because then there is nothing to read at all.
        if (asset === manifest.base) throw error;
        log(`${asset.name} is listed but not published — skipping it`);
        continue;
      } finally {
        fs.rmSync(packed, { force: true });
      }
      if (hash && hash(local) !== asset.sha256) {
        throw new Error(`${asset.name} failed its hash check`);
      }
    }
    assets[asset.name] = asset.sha256;
  }

  // Drop the assets WE installed that the manifest no longer references (deltas folded into a fresh
  // base). Only files recorded as ours are candidates: anything else in this directory belongs to the
  // user — a config file, a key — and is not ours to sweep away.
  const keep = new Set(wanted.map((a) => a.name));
  for (const name of Object.keys(prior)) {
    if (!keep.has(name)) fs.rmSync(`${cacheDir}/${name}`, { force: true });
  }

  fs.writeFileSync(installedPath, JSON.stringify({ version: manifest.version, assets, checkedAt: now() }));
  // What was actually installed, in the manifest's order — a skipped delta has no file to open, and the
  // caller opens every path this returns.
  return Object.keys(assets).map((name) => `${cacheDir}/${name}`);
}

/// The installed index paths, when the last manifest check is recent enough to skip asking again.
///
/// A mount happens on the first query of every palette session, and the check it would otherwise make is
/// a manifest per language through a spawned process. The freshness window has to outlive the session to
/// mean anything, so `syncIndexes` records when it last looked and this reads it back. Nil means the
/// cache is missing, incomplete, or old enough that the caller must sync first.
/// `maxAgeMs: Infinity` asks whether anything is installed at all, which is what a mount wants before it
/// syncs: a cache that is due a check still holds a valid band, and serving it beats answering nothing.
/// A finite age additionally asks whether the check is recent, and a store that has never been checked
/// cannot claim freshness.
export function installedPaths({ cacheDir, fs, maxAgeMs, now = Date.now }) {
  const installedPath = `${cacheDir}/installed.json`;
  if (!fs.existsSync(installedPath)) return null;
  let installed;
  try {
    installed = JSON.parse(fs.readFileSync(installedPath, "utf8"));
  } catch {
    return null;
  }
  if (Number.isFinite(maxAgeMs) && (!(installed?.checkedAt > 0) || now() - installed.checkedAt > maxAgeMs)) {
    return null;
  }
  const paths = Object.keys(installed.assets ?? {}).map((name) => `${cacheDir}/${name}`);
  // Deltas fold into a fresh base, so a file an older manifest named can be gone: mount only a set that
  // is all still there, and let a missing one send the caller through a full sync.
  return paths.length > 0 && paths.every((path) => fs.existsSync(path)) ? paths : null;
}