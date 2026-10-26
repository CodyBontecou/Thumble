const securityHeaders = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Cache-Control": "public, max-age=60"
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

function jsonResponse(request, body, status = 200, cacheControl = securityHeaders["Cache-Control"]) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...securityHeaders,
      ...corsHeaders(request),
      "Cache-Control": cacheControl,
      "Content-Type": "application/json; charset=utf-8"
    }
  });
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
    return jsonResponse(request, { ok: false, message: "Use GET to read the latest Mac release." }, 405, "no-store");
  }

  if (!env.RELEASES) {
    return jsonResponse(request, { ok: false, message: "Mac release storage is not configured yet." }, 503, "no-store");
  }

  const object = await env.RELEASES.get("macos/latest.json");
  if (!object) {
    return jsonResponse(request, { ok: false, message: "No Mac release has been uploaded yet." }, 404, "no-store");
  }

  const body = request.method === "HEAD" ? null : await object.text();
  return new Response(body, {
    status: 200,
    headers: {
      ...securityHeaders,
      ...corsHeaders(request),
      "Content-Type": object.httpMetadata?.contentType || "application/json; charset=utf-8",
      "ETag": object.httpEtag,
      "Cache-Control": "public, max-age=60"
    }
  });
}
