const securityHeaders = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin"
};

function corsHeaders(request) {
  const origin = request.headers.get("Origin") || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
    "Access-Control-Allow-Headers": "Accept, Content-Type",
    "Vary": "Origin"
  };
}

function jsonResponse(request, body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...securityHeaders,
      ...corsHeaders(request),
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}

function isSafeReleaseKey(key) {
  return typeof key === "string"
    && key.startsWith("macos/")
    && key.endsWith(".zip")
    && !key.includes("..")
    && !key.includes("//")
    && /^[A-Za-z0-9._\-/]+$/.test(key);
}

function filenameFromKey(key) {
  return key.split("/").pop() || "ThumbleMac.zip";
}

async function latestKey(env) {
  const manifest = await env.RELEASES.get("macos/latest.json");
  if (!manifest) return null;

  try {
    const data = await manifest.json();
    if (isSafeReleaseKey(data.objectKey)) return data.objectKey;
  } catch (error) {
    console.error("mac_release_manifest_parse_failed", error);
  }

  return null;
}

export async function onRequest(context) {
  const { request, env } = context;

  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        ...securityHeaders,
        ...corsHeaders(request)
      }
    });
  }

  if (request.method !== "GET" && request.method !== "HEAD") {
    return jsonResponse(request, { ok: false, message: "Use GET to download Thumble Mac." }, 405);
  }

  if (!env.RELEASES) {
    return jsonResponse(request, { ok: false, message: "Mac release storage is not configured yet." }, 503);
  }

  const url = new URL(request.url);
  let key = url.searchParams.get("file") || "";
  if (!key) key = await latestKey(env) || "";

  if (!isSafeReleaseKey(key)) {
    return jsonResponse(request, { ok: false, message: "No downloadable Mac release was found." }, 404);
  }

  const object = request.method === "HEAD"
    ? await env.RELEASES.head(key)
    : await env.RELEASES.get(key);

  if (!object) {
    return jsonResponse(request, { ok: false, message: "That Mac release is no longer available." }, 404);
  }

  const filename = filenameFromKey(key);
  const headers = new Headers({
    ...securityHeaders,
    ...corsHeaders(request),
    "Cache-Control": "public, max-age=31536000, immutable",
    "Content-Disposition": `attachment; filename="${filename}"`,
    "Content-Type": object.httpMetadata?.contentType || "application/zip",
    "ETag": object.httpEtag
  });

  if (object.size !== undefined) {
    headers.set("Content-Length", String(object.size));
  }

  return new Response(request.method === "HEAD" ? null : object.body, {
    status: 200,
    headers
  });
}
