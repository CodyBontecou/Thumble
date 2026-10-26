import { normalizeAttribution } from '../../attribution.mjs';

const CONSENT_TEXT = "By joining, you agree to receive launch updates.";
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/i;

const securityHeaders = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Cache-Control": "no-store"
};

function corsHeaders(request) {
  const origin = request.headers.get("Origin") || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Accept",
    "Vary": "Origin"
  };
}

function wantsHtml(request) {
  const accept = request.headers.get("Accept") || "";
  return accept.includes("text/html") && !accept.includes("application/json");
}

function jsonResponse(request, body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...securityHeaders,
      ...corsHeaders(request),
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}

function htmlResponse(message, status = 200) {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Thumble waitlist</title><link rel="stylesheet" href="/styles.css"></head><body class="privacy-page"><main class="section-shell privacy-copy"><section class="pixel-panel"><p class="eyebrow">Thumble waitlist</p><h1>${escapeHtml(message)}</h1><p><a class="pixel-button" href="https://thumble.io/">Back to site</a></p></section></main></body></html>`, {
    status,
    headers: {
      ...securityHeaders,
      "Content-Type": "text/html; charset=utf-8"
    }
  });
}

function fail(request, message, status = 400) {
  if (wantsHtml(request)) return htmlResponse(message, status);
  return jsonResponse(request, { ok: false, message }, status);
}

function ok(request, message = "You're on the launch list. 🕹️") {
  if (wantsHtml(request)) return Response.redirect(new URL("https://thumble.io/thanks"), 303);
  return jsonResponse(request, { ok: true, message });
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;"
  })[char]);
}

async function readPayload(request) {
  const contentType = request.headers.get("Content-Type") || "";

  if (contentType.includes("application/json")) {
    return await request.json();
  }

  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    const form = await request.formData();
    return Object.fromEntries(form.entries());
  }

  return {};
}

function normalizeConsent(value) {
  return value === true || value === "true" || value === "on" || value === "1";
}

async function sha256(value) {
  const encoded = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function verifyTurnstile({ request, env, token, ip }) {
  if (!env.TURNSTILE_SECRET_KEY) return true;

  if (!token) return false;

  const formData = new FormData();
  formData.append("secret", env.TURNSTILE_SECRET_KEY);
  formData.append("response", token);
  if (ip) formData.append("remoteip", ip);

  const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: formData
  });

  if (!response.ok) return false;
  const result = await response.json();
  return result.success === true;
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

  if (request.method !== "POST") {
    return fail(request, "Use POST to join the waitlist.", 405);
  }

  let payload;
  try {
    payload = await readPayload(request);
  } catch {
    return fail(request, "Could not read that signup. Please try again.", 400);
  }

  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return fail(request, "Invalid signup payload.", 400);

  // Honeypot field. Real users never see this input, so treat a value as a bot and return success.
  if (String(payload.company || "").trim()) {
    return ok(request);
  }

  const email = String(payload.email || "").trim().toLowerCase();
  const consent = normalizeConsent(payload.consent);
  const source = String(payload.source || "landing").trim().slice(0, 64) || "landing";

  if (!EMAIL_RE.test(email) || email.length > 254) {
    return fail(request, "Please enter a valid email address.", 422);
  }

  if (!consent) {
    return fail(request, "Please confirm you want Thumble launch updates.", 422);
  }

  if (!env.DB) {
    return fail(request, "Waitlist storage is not configured yet. Add the Cloudflare D1 DB binding named DB.", 503);
  }

  const ip = request.headers.get("CF-Connecting-IP") || "";
  const turnstileOk = await verifyTurnstile({
    request,
    env,
    token: payload.turnstileToken || request.headers.get("CF-Turnstile-Token") || "",
    ip
  });

  if (!turnstileOk) {
    return fail(request, "Please retry the anti-spam check.", 403);
  }

  const attribution = normalizeAttribution(payload.attribution);
  const now = new Date().toISOString();
  const userAgent = String(request.headers.get("User-Agent") || "").slice(0, 500);
  const country = String(request.cf?.country || request.headers.get("CF-IPCountry") || "").slice(0, 8);
  const ipHash = ip ? await sha256(`${env.IP_HASH_SALT || "pocketpad"}:${ip}`) : null;

  try {
    const subscriber = env.DB.prepare(`
      INSERT INTO waitlist_subscribers (
        email,
        status,
        source,
        consent_text,
        consented_at,
        created_at,
        updated_at,
        user_agent,
        country,
        ip_hash
      ) VALUES (?, 'subscribed', ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(email) DO UPDATE SET
        status = 'subscribed',
        source = excluded.source,
        consent_text = excluded.consent_text,
        consented_at = excluded.consented_at,
        updated_at = excluded.updated_at,
        user_agent = excluded.user_agent,
        country = excluded.country,
        ip_hash = excluded.ip_hash
    `).bind(
      email,
      source,
      CONSENT_TEXT,
      now,
      now,
      now,
      userAgent,
      country,
      ipHash
    );
    const acquisition = env.DB.prepare(`
      INSERT INTO waitlist_attribution (
        subscriber_id, first_source, latest_source, first_touch, latest_touch, created_at, updated_at
      ) SELECT id, ?, ?, ?, ?, ?, ? FROM waitlist_subscribers WHERE email = ?
      ON CONFLICT(subscriber_id) DO UPDATE SET
        latest_source = excluded.latest_source,
        latest_touch = excluded.latest_touch,
        updated_at = excluded.updated_at
    `).bind(source, source, JSON.stringify(attribution.first), JSON.stringify(attribution.latest), now, now, email);
    // D1 batches commit together: do not report a saved signup if its writes failed.
    await env.DB.batch([subscriber, acquisition]);
  } catch (error) {
    console.error("waitlist_insert_failed", error);
    return fail(request, "Could not save your email right now. Please try again soon.", 500);
  }

  return ok(request);
}
