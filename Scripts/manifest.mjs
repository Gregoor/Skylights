// The shape the rolling release publishes. Kept out of publish.mjs so it can be tested without a
// GitHub release behind it — publish.mjs runs on import.

/// What goes into the manifest for one asset. `local` is for the upload step only; publishing it
/// would leak the build machine's paths into a public file, which is what it used to do.
export function published(asset) {
  return asset ? { name: asset.name, bytes: asset.bytes, sha256: asset.sha256 } : null;
}

/// `files` are assets a provider needs beside its index — the cross-language map — which travel and
/// install exactly like the index does.
export function buildManifest({ prev, base, deltas, bundle, store, files = [] }) {
  return {
    version: (prev?.version ?? 0) + 1,
    generatedAt: new Date().toISOString(),
    base: published(base),
    deltas: deltas.map(published),
    bundle: published(bundle),
    ...(store ? { store: published(store) } : {}),
    ...(files.length ? { files: files.map(published) } : {}),
  };
}

/// Delta or base for this run.
///
/// A base was 74.5 MB for the Oct 2, 2026 store snapshot and every client re-downloads it the moment its hash changes, because a delta is
/// only valid over the base it was built on — so this decision is a client's download cost, not an
/// implementation detail. Cold cache first: without a published marker there is nothing to diff a
/// delta against and the run would otherwise ship the whole corpus as one.
export const BASE_REBUILD_DELTAS = 30;

export function decideMode({ hasMarker, requested = "", deltas = 0 }) {
  if (!hasMarker) return "base";
  if (requested === "base") return "base";
  if (deltas >= BASE_REBUILD_DELTAS) return "base";
  return "delta";
}

/// The delta chain after this publish.
///
/// A new base RESETS the chain rather than extending it, and that is a correctness rule, not tidiness:
/// a delta is built to be applied over one specific base, so leaving the old ones listed beside a new
/// base would have clients apply deltas whose rows predate it and regress those records. Re-adding the
/// same day's delta replaces it rather than duplicating it.
export function nextDeltas({ prevDeltas = [], isBase = false, adding = [] }) {
  if (isBase) return [...adding];
  const names = new Set(adding.map((d) => d.name));
  return [...prevDeltas.filter((d) => !names.has(d.name)), ...adding];
}
