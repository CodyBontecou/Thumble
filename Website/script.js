const CURRENT_YEAR = new Date().getFullYear();
const yearNode = document.querySelector("#year");
if (yearNode) yearNode.textContent = String(CURRENT_YEAR);

const tickerTrack = document.querySelector(".ticker div");
if (tickerTrack) {
  tickerTrack.innerHTML += tickerTrack.innerHTML;
}

function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (!Number.isFinite(value) || value <= 0) return "—";
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

async function hydrateMacRelease() {
  const link = document.querySelector("[data-mac-download-link]");
  const versionNode = document.querySelector("[data-mac-release-version]");
  const statusNode = document.querySelector("[data-mac-release-status]");
  const shaNode = document.querySelector("[data-mac-release-sha]");
  if (!link || !versionNode || !statusNode || !shaNode) return;

  link.addEventListener("click", (event) => {
    if (link.getAttribute("aria-disabled") === "true") event.preventDefault();
  });

  try {
    const response = await fetch("/api/releases/latest-mac", {
      headers: { Accept: "application/json" }
    });
    const release = await response.json().catch(() => ({}));
    if (!response.ok || release.ok === false) {
      throw new Error(release.message || "Mac build coming soon");
    }

    link.href = release.downloadURL || release.downloadPath || "/api/download-mac";
    link.textContent = `download v${release.version || "1.0"}`;
    link.removeAttribute("aria-disabled");
    versionNode.textContent = `${release.version || "—"} (${release.buildNumber || "—"})`;
    statusNode.textContent = `${release.notarized ? "notarized" : "unsigned preview"} · ${formatBytes(release.sizeBytes)}`;
    shaNode.textContent = release.sha256 ? release.sha256.slice(0, 16) + "…" : "—";
  } catch (error) {
    link.textContent = "mac build coming soon";
    link.setAttribute("aria-disabled", "true");
    versionNode.textContent = "not uploaded yet";
    statusNode.textContent = error.message || "waiting for first release";
    shaNode.textContent = "—";
  }
}

hydrateMacRelease();

const TURNSTILE_SITE_KEY = window.THUMBLE_TURNSTILE_SITE_KEY || window.THUMBCONSOLE_TURNSTILE_SITE_KEY || window.POCKETPAD_TURNSTILE_SITE_KEY || "";
let turnstileReady = Promise.resolve(null);

if (TURNSTILE_SITE_KEY) {
  turnstileReady = new Promise((resolve, reject) => {
    if (window.turnstile) {
      resolve(window.turnstile);
      return;
    }

    const script = document.createElement("script");
    script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
    script.async = true;
    script.defer = true;
    script.onload = () => resolve(window.turnstile);
    script.onerror = () => reject(new Error("Cloudflare Turnstile could not load."));
    document.head.appendChild(script);
  });
}

function setStatus(form, message, tone = "success") {
  const status = form.querySelector(".form-status");
  if (!status) return;
  status.textContent = message;
  status.dataset.tone = tone;
}

function payloadFromForm(form) {
  const data = new FormData(form);
  return {
    email: String(data.get("email") || "").trim(),
    consent: data.get("consent") === "on" || data.get("consent") === "true",
    source: String(data.get("source") || form.dataset.source || "landing").slice(0, 64),
    company: String(data.get("company") || ""),
    turnstileToken: String(data.get("turnstileToken") || "")
  };
}

function resetTurnstile(form) {
  const widgetId = form.dataset.turnstileWidgetId;
  if (window.turnstile && widgetId) {
    window.turnstile.reset(widgetId);
  }
}

async function mountTurnstile(form) {
  if (!TURNSTILE_SITE_KEY) return;

  const slot = document.createElement("div");
  slot.className = "turnstile-slot";

  const hidden = document.createElement("input");
  hidden.type = "hidden";
  hidden.name = "turnstileToken";

  const status = form.querySelector(".form-status");
  form.insertBefore(slot, status || null);
  form.insertBefore(hidden, status || null);

  try {
    const turnstile = await turnstileReady;
    const widgetId = turnstile.render(slot, {
      sitekey: TURNSTILE_SITE_KEY,
      theme: "dark",
      callback: (token) => {
        hidden.value = token;
        setStatus(form, "");
      },
      "expired-callback": () => {
        hidden.value = "";
      },
      "error-callback": () => {
        hidden.value = "";
        setStatus(form, "Anti-spam check failed. Please try again.", "error");
      }
    });
    form.dataset.turnstileWidgetId = String(widgetId);
  } catch (error) {
    setStatus(form, error.message || "Anti-spam check could not load.", "error");
  }
}

for (const form of document.querySelectorAll(".waitlist-form")) {
  mountTurnstile(form);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const button = form.querySelector("button[type='submit']");
    const payload = payloadFromForm(form);

    if (!payload.email) {
      setStatus(form, "Enter your email first.", "error");
      return;
    }

    if (!payload.consent) {
      setStatus(form, "Please confirm you want Thumble launch updates.", "error");
      return;
    }

    if (TURNSTILE_SITE_KEY && !payload.turnstileToken) {
      setStatus(form, "Complete the anti-spam check, then submit again.", "error");
      return;
    }

    if (payload.company) {
      form.reset();
      resetTurnstile(form);
      setStatus(form, "You're on the launch list. 🕹️");
      return;
    }

    try {
      button?.setAttribute("disabled", "true");
      setStatus(form, "Saving…");

      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/json"
        },
        body: JSON.stringify(payload)
      });

      const result = await response.json().catch(() => ({}));
      if (!response.ok || result.ok === false) {
        throw new Error(result.message || "Could not save your email. Try again in a minute.");
      }

      form.reset();
      resetTurnstile(form);
      setStatus(form, result.message || "You're on the launch list. 🕹️");
    } catch (error) {
      setStatus(form, error.message || "Something went wrong. Try again.", "error");
    } finally {
      button?.removeAttribute("disabled");
    }
  });
}
