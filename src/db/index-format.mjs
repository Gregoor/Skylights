// The on-disk binary index format, defined once and consumed by both the importer (Node) and the
// query loader (JavaScriptCore or Node). Layout is explicit; every integer is little-endian and read
// through a DataView, so no platform assumption leaks in. This file must stay dependency-free and
// JS-standard-only — it ships inside the extension bundle and runs in a bare JavaScriptCore context.

export const MAGIC = "TCIDX001";
export const VERSION = 7;

export const HEADER_BYTES = 128;
export const ROW_RECORD_BYTES = 42;

// Physical section order (section offsets live in the header; the superseded section uses a u32):
//   [0] header          HEADER_BYTES fixed
//   [1] rowMeta         rowCount * ROW_RECORD_BYTES
//   [2] termCount       u32
//   [3] termOffsets     termCount * u32  (byte offset of each term's start inside termsBlob; sorted ascending)
//   [4] termsBlob       packed UTF-8 of every distinct normalized term, concatenated
//   [5] termRanges      termCount * 2 * u32  (start, end) into postings, per term
//   [6] postings        postingsCount * u32  (ascending row indices per term)
//   [7] titlePool       titlePoolBytes of UTF-8
//   [8] originalPool    originalPoolBytes of UTF-8
//   [9] posterPool      posterPoolBytes of UTF-8
//   [10] superseded     supersededCount * u32 stable keys this file replaces (deltas only)
//   [11] spotlight ops  checksummed JSON row-operation frames; offsets at 112 and 120
//
// Row record (42 bytes), indexed by row (postings reference row indices):
//   u32 tmdbID | u32 titleOffset | u16 titleLength | u32 originalOffset | u16 originalLength |
//   u16 year (0 unknown) | u32 imdbNum (0 = absent; else the `tt\d+` numeric part) | f32 popularity |
//   u32 voteCount | u32 posterOffset | u16 posterLength | u8 mediaType | u8 scores × 3 | u16 seasonCount
//
// The imdb id is stored as the numeric part of `tt{N}` because it is always well-formed or absent in
// the dataset (Orphan "None" strings are dropped at import). Display subtitle = `${year}` greyed;
// both tmdbID and imdbNum feed future lookups (Rotten Tomatoes, TMDB page) without a re-import.
// `posterOffset`/`posterLength` index the row's `poster_path`, from which a deterministic TMDB
// poster URL (`https://image.tmdb.org/t/p/w92{path}`) is derived.
//
// The loader keeps [3][4][5][6] in memory (the inverted index) and leaves [1][7][8][9] on disk,
// paging only candidate rows via readRange.

import { bytesToBase64, base64ToBytes } from "./base64.mjs";
import { utf8Decode, utf8Encode } from "./utf8.mjs";

export const ROW_LAYOUT = Object.freeze({
  TMDB_ID: [0, 4],
  TITLE_OFFSET: [4, 4],
  TITLE_LENGTH: [8, 2],
  ORIGINAL_OFFSET: [10, 4],
  ORIGINAL_LENGTH: [14, 2],
  YEAR: [16, 2],
  IMDB_NUM: [18, 4],
  POPULARITY: [22, 4],
  VOTE_COUNT: [26, 4],
  POSTER_OFFSET: [30, 4],
  POSTER_LENGTH: [34, 2],
  MEDIA_TYPE: [36, 1],
  SEASON_COUNT: [40, 2],
});

// u64 section offsets, [offset, byteLength].
export const SECTIONS = Object.freeze({
  ROW_META: [HEADER_BYTES, null],
  TERM_COUNT: [null, 4],
  TERM_OFFSETS: [null, null],
  TERMS_BLOB: [null, null],
  TERM_RANGES: [null, null],
  POSTINGS: [null, null],
  TITLE_POOL: [null, null],
  ORIGINAL_POOL: [null, null],
});

export const STREAM_OFFSET_FIELD = 112;
export const STREAM_LENGTH_FIELD = 120;

/// Encode a single row record into `view` (DataView over a big buffer) at byte offset `at`.
export function encodeRow(view, at, rec) {
  view.setUint32(at + 0, rec.tmdbID, true);
  view.setUint32(at + 4, rec.titleOffset, true);
  view.setUint16(at + 8, rec.titleLength, true);
  view.setUint32(at + 10, rec.originalOffset, true);
  view.setUint16(at + 14, rec.originalLength, true);
  view.setUint16(at + 16, rec.year, true);
  view.setUint32(at + 18, rec.imdbNum, true);
  view.setFloat32(at + 22, rec.popularity, true);
  view.setUint32(at + 26, rec.voteCount, true);
  view.setUint32(at + 30, rec.posterOffset, true);
  view.setUint16(at + 34, rec.posterLength, true);
  view.setUint8(at + 36, rec.mediaType, true);
  view.setUint8(at + 37, rec.rtScore, true);
  view.setUint8(at + 38, rec.metacriticScore, true);
  view.setUint8(at + 39, rec.imdbRating, true);
  view.setUint16(at + 40, rec.seasonCount, true);
}

/// Decode one row record from a DataView at byte offset `at`.
export function decodeRow(view, at) {
  return {
    tmdbID: view.getUint32(at + 0, true),
    titleOffset: view.getUint32(at + 4, true),
    titleLength: view.getUint16(at + 8, true),
    originalOffset: view.getUint32(at + 10, true),
    originalLength: view.getUint16(at + 14, true),
    year: view.getUint16(at + 16, true),
    imdbNum: view.getUint32(at + 18, true),
    popularity: view.getFloat32(at + 22, true),
    voteCount: view.getUint32(at + 26, true),
    posterOffset: view.getUint32(at + 30, true),
    posterLength: view.getUint16(at + 34, true),
    mediaType: view.getUint8(at + 36),
    // 0-100, or 255 when the title has no score from that source.
    rtScore: view.getUint8(at + 37),
    metacriticScore: view.getUint8(at + 38),
    imdbRating: view.getUint8(at + 39),
    seasonCount: view.getUint16(at + 40, true),
  };
}

/// A rating byte: 0-100, or 255 for "no score".
export function ratingByte(value) {
  return Number.isInteger(value) && value >= 0 && value <= 100 ? value : 255;
}

/// Serialize the whole index into one contiguous byte buffer. `rows`, `termOffsets`, `termRanges`
/// and `postings` are TypedArrays; `termsBlob`, `titlePool`, `originalPool`, `posterPool` are
/// Uint8Array.
export function serializeIndex({ rows, termOffsets, termsBlob, termRanges, postings, titlePool, originalPool, posterPool, supersededKeys = new Uint32Array(0) }) {
  const termCount = termOffsets.length;
  const header = new Uint8Array(HEADER_BYTES);
  const h = new DataView(header.buffer);
  setAscii(header, 0, MAGIC);
  h.setUint32(8, VERSION, true);
  h.setUint32(12, rows.length, true);
  h.setUint32(16, termCount, true);
  h.setUint32(20, postings.length, true);
  h.setUint32(24, titlePool.length, true);
  h.setUint32(28, originalPool.length, true);
  h.setUint32(92, posterPool.length, true);
  h.setUint32(104, supersededKeys.length, true);

  let off = HEADER_BYTES;
  const offRowMeta = off;
  off += rows.length * ROW_RECORD_BYTES;
  const offTermCount = off;
  off += 4;
  const offTermOffsets = off;
  off += termOffsets.length * 4;
  const offTermsBlob = off;
  off += termsBlob.length;
  const offTermRanges = off;
  off += termRanges.length * 4;
  const offPostings = off;
  off += postings.length * 4;
  const offTitlePool = off;
  off += titlePool.length;
  const offOriginalPool = off;
  off += originalPool.length;
  const offPosterPool = off;
  off += posterPool.length;
  const offSuperseded = off;
  off += supersededKeys.length * 4;
  const total = off;

  // u64 little-endian written as two u32 halves (DataView has no setUint64).
  const putU64 = (view, at, value) => {
    view.setUint32(at, value & 0xffffffff, true);
    view.setUint32(at + 4, (value >> 32) & 0xffffffff, true);
  };
  putU64(h, 36, offRowMeta);
  h.setUint32(44, offTermCount, true);
  putU64(h, 48, offTermOffsets);
  putU64(h, 56, offTermsBlob);
  putU64(h, 64, offTermRanges);
  putU64(h, 72, offPostings);
  putU64(h, 80, offTitlePool);
  putU64(h, 88, offOriginalPool);
  putU64(h, 96, offPosterPool);
  // Superseded data begins well below 4 GiB for every supported index. Keep this as a u32 because
  // the spotlight stream's u64 offset starts at byte 112 and occupies 112–119.
  h.setUint32(108, offSuperseded, true);

  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);
  out.set(header, 0);

  for (let r = 0; r < rows.length; r++) encodeRow(view, offRowMeta + r * ROW_RECORD_BYTES, rows[r]);
  view.setUint32(offTermCount, termCount, true);
  out.set(asBytes(termOffsets), offTermOffsets);
  out.set(termsBlob, offTermsBlob);
  out.set(asBytes(termRanges), offTermRanges);
  out.set(asBytes(postings), offPostings);
  out.set(titlePool, offTitlePool);
  out.set(originalPool, offOriginalPool);
  out.set(posterPool, offPosterPool);
  out.set(asBytes(supersededKeys), offSuperseded);
  return out;
}

/// Read the fixed header, returning decoded u32/u64 fields (no validation here).
export function parseHeader(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  const u32 = (o) => view.getUint32(o, true);
  // u64 little-endian assembled from two u32 halves (DataView has no getUint64 everywhere).
  const u64 = (o) => u32(o) | (u32(o + 4) << 32);
  return {
    magic: asciiAt(bytes, 0, MAGIC.length),
    version: u32(8),
    rowCount: u32(12),
    termCount: u32(16),
    postingsCount: u32(20),
    titlePoolBytes: u32(24),
    originalPoolBytes: u32(28),
    posterPoolBytes: u32(92),
    supersededCount: u32(104),
    offRowMeta: u64(36),
    offTermCount: u32(44),
    offTermOffsets: u64(48),
    offTermsBlob: u64(56),
    offTermRanges: u64(64),
    offPostings: u64(72),
    offTitlePool: u64(80),
    offOriginalPool: u64(88),
    offPosterPool: u64(96),
    // u32 to avoid overlap with the spotlight stream offset stored at byte 112.
    offSuperseded: u32(108),
    streamOffset: u64(112),
    streamLength: u64(120),
  };
}

export function headerBytes(h) {
  return h.offSuperseded + h.supersededCount * 4;
}

function asBytes(typed) {
  // TypedArray -> a fresh Uint8Array view; DataView is just a window into the underlying buffer.
  return new Uint8Array(typed.buffer.slice(0, typed.length * typed.BYTES_PER_ELEMENT));
}

function setAscii(bytes, at, text) {
  for (let i = 0; i < text.length; i++) bytes[at + i] = text.charCodeAt(i);
}
function asciiAt(bytes, at, len) {
  let s = "";
  for (let i = 0; i < len; i++) s += String.fromCharCode(bytes[at + i]);
  return s;
}
