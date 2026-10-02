const VERSION = "v2-square180-portrait180x270-blur15-jpeg65";
const CACHE_CONTROL = "public, max-age=31536000, immutable";
const PROVIDERS = Object.freeze({
  // URL inputs are allowlisted by exact origin and path prefix. Add future providers
  // here with their own validation; never fetch an arbitrary caller-supplied URL.
  tmdb: Object.freeze({ origin: "https://image.tmdb.org", pathPrefix: "/t/p/w185/" }),
});

function log(event, fields = {}) {
  console.log(JSON.stringify({ service: "skylights-poster-service", event, ...fields }));
}

function responseHeaders(extra = {}) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Cache-Control": CACHE_CONTROL,
    "X-Content-Type-Options": "nosniff",
    ...extra,
  };
}

function errorResponse(status, message) {
  return new Response(message, {
    status,
    headers: responseHeaders({ "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" }),
  });
}

function parseSourceURL(url) {
  const keys = [...url.searchParams.keys()];
  if (url.pathname !== "/v1/poster" || !url.searchParams.has("url") ||
      url.searchParams.getAll("url").length !== 1 ||
      keys.some((key) => key !== "url" && key !== "size")) {
    return { error: 404, message: "Not found" };
  }
  const size = url.searchParams.get("size") ?? "square";
  if (size !== "square" && size !== "portrait") return { error: 400, message: "Invalid thumbnail size" };

  let source;
  try {
    source = new URL(url.searchParams.get("url"));
  } catch {
    return { error: 400, message: "Invalid source URL" };
  }
  if (source.protocol !== "https:" || source.username || source.password || source.port || source.search || source.hash) {
    return { error: 400, message: "Invalid source URL" };
  }

  const entry = Object.entries(PROVIDERS).find(([, provider]) =>
    source.origin === provider.origin && source.pathname.startsWith(provider.pathPrefix)
  );
  if (!entry) return { error: 403, message: "Image source is not allowlisted" };

  const [providerName, provider] = entry;
  const filename = source.pathname.slice(provider.pathPrefix.length);
  // Accept only a single image filename, never a path or traversal sequence.
  if (!/^[a-zA-Z0-9_-]+\.(?:jpg|jpeg|png|webp)$/i.test(filename)) {
    return { error: 400, message: "Invalid poster path" };
  }
  return { providerName, provider, filename, sourceURL: source.toString(), size };
}

function cacheKey(request, providerName, filename, size) {
  const keyURL = new URL(request.url);
  keyURL.pathname = `/${VERSION}/${providerName}/${size}/${filename}`;
  keyURL.search = "";
  return new Request(keyURL.toString(), { method: "GET" });
}

function imageResponse(body, cacheStatus) {
  return new Response(body, {
    status: 200,
    headers: responseHeaders({
      "Content-Type": "image/jpeg",
      "X-Poster-Cache": cacheStatus,
      "Server-Timing": `poster-cache;desc=${cacheStatus.toLowerCase()}`,
    }),
  });
}

async function handleRequest(request, env, ctx) {
  const startedAt = Date.now();
  const url = new URL(request.url);
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: responseHeaders({ "Cache-Control": "no-store" }) });
  }
  if (request.method !== "GET" && request.method !== "HEAD") {
    return errorResponse(405, "Method not allowed");
  }

  const route = parseSourceURL(url);
  if (route.error) return errorResponse(route.error, route.message);

  const key = cacheKey(request, route.providerName, route.filename, route.size);
  const edgeCache = caches.default;
  const edgeHit = await edgeCache.match(key);
  if (edgeHit) {
    log("cache_hit", { layer: "edge", provider: route.providerName, elapsedMs: Date.now() - startedAt });
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: edgeHit.headers });
    return edgeHit;
  }

  const objectKey = `${VERSION}/${route.providerName}/${route.size}/${route.filename}`;
  const stored = await env.POSTERS.get(objectKey);
  if (stored) {
    const response = imageResponse(stored.body, "R2-HIT");
    ctx.waitUntil(edgeCache.put(key, response.clone()).catch((error) => {
      log("edge_cache_write_failed", { message: String(error) });
    }));
    log("cache_hit", { layer: "r2", provider: route.providerName, elapsedMs: Date.now() - startedAt });
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: response.headers });
    return response;
  }

  let upstream;
  try {
    upstream = await fetch(route.sourceURL, { headers: { Accept: "image/avif,image/webp,image/*" } });
  } catch (error) {
    log("upstream_fetch_failed", { provider: route.providerName, message: String(error) });
    return errorResponse(502, "Poster source unavailable");
  }

  if (upstream.status === 404) {
    log("poster_missing", { provider: route.providerName, elapsedMs: Date.now() - startedAt });
    return errorResponse(404, "Poster not found");
  }
  if (!upstream.ok) {
    log("upstream_error", { provider: route.providerName, status: upstream.status });
    return errorResponse(502, "Poster source returned an error");
  }
  if (!upstream.headers.get("Content-Type")?.toLowerCase().startsWith("image/")) {
    log("invalid_upstream_content_type", { provider: route.providerName, contentType: upstream.headers.get("Content-Type") });
    return errorResponse(502, "Poster source returned an invalid image");
  }

  try {
    const dimensions = route.size === "portrait" ? { width: 180, height: 270 } : { width: 180, height: 180 };
    const transformed = await env.IMAGES
      .input(upstream.body)
      .transform({ ...dimensions, fit: "cover", blur: 15 })
      .output({ format: "image/jpeg", quality: 65 })
      .response();
    if (!transformed.ok || !transformed.body) {
      log("transform_failed", { provider: route.providerName, status: transformed.status });
      return errorResponse(502, "Poster transform failed");
    }

    const response = imageResponse(transformed.body, "MISS");
    const r2Write = env.POSTERS.put(objectKey, response.clone().body, {
      httpMetadata: { contentType: "image/jpeg", cacheControl: CACHE_CONTROL },
    }).then(() => {
      log("cache_write", { layer: "r2", provider: route.providerName });
    }).catch((error) => {
      log("r2_cache_write_failed", { message: String(error) });
    });
    const edgeWrite = edgeCache.put(key, response.clone()).catch((error) => {
      log("edge_cache_write_failed", { message: String(error) });
    });
    ctx.waitUntil(Promise.all([r2Write, edgeWrite]));

    log("poster_transformed", {
      provider: route.providerName,
      size: route.size,
      elapsedMs: Date.now() - startedAt,
      sourceStatus: upstream.status,
      outputType: "image/jpeg",
    });
    if (request.method === "HEAD") return new Response(null, { status: 200, headers: response.headers });
    return response;
  } catch (error) {
    log("transform_failed", { provider: route.providerName, message: String(error), elapsedMs: Date.now() - startedAt });
    return errorResponse(502, "Poster transform failed");
  }
}

export default {
  fetch(request, env, ctx) {
    return handleRequest(request, env, ctx);
  },
};
