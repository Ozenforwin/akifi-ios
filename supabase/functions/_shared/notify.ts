// Delivery channels shared by smart-notifications, send-weekly-digest and
// check-subscriptions: Telegram Bot API and Firebase Cloud Messaging.
//
// Secrets and logs: the Telegram Bot API puts the bot token in the URL
// PATH (/bot<token>/sendMessage) — unavoidable. Deno's fetch errors quote
// the full URL ("error sending request for url (https://api.telegram.org/
// bot123:ABC…/sendMessage)"), so logging a raw network error used to write
// the bot token into the function logs. Every error that leaves this module
// goes through `redactSecrets` first.

const TELEGRAM_BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";

/** Masks bot tokens, api keys and bearer tokens in free text (error messages). */
export function redactSecrets(text: string): string {
  return text
    .replace(/\/bot\d+:[A-Za-z0-9_-]+/g, "/bot<redacted>")
    .replace(/\b\d{6,}:[A-Za-z0-9_-]{30,}\b/g, "<redacted-bot-token>")
    .replace(/([?&](?:api_?key|apikey|token|key|access_token|x_cg_demo_api_key)=)[^&\s)"']+/gi, "$1<redacted>")
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, "$1<redacted>");
}

/** Safe one-line description of an unknown error. */
export function describeError(err: unknown): string {
  const raw = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
  return redactSecrets(raw).slice(0, 500);
}

/** Escapes user-provided text (category / goal / service names) for parse_mode=HTML. */
export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export const telegramConfigured = (): boolean => TELEGRAM_BOT_TOKEN.length > 0;
export const fcmConfigured = (): boolean => FIREBASE_SERVICE_ACCOUNT_JSON.length > 0;

export interface InlineButton {
  text: string;
  url: string;
}

export async function sendTelegramMessage(
  chatId: string | number,
  text: string,
  opts: { html?: boolean; buttons?: InlineButton[] } = {},
): Promise<void> {
  if (!TELEGRAM_BOT_TOKEN) throw new Error("Telegram is not configured");
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
    disable_web_page_preview: true,
  };
  if (opts.html) body.parse_mode = "HTML";
  if (opts.buttons && opts.buttons.length > 0) {
    body.reply_markup = { inline_keyboard: [opts.buttons.map((b) => ({ text: b.text, url: b.url }))] };
  }
  let res: Response;
  try {
    res = await fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    throw new Error(`Telegram request failed: ${describeError(err)}`);
  }
  const payload = await res.json().catch(() => null);
  if (!res.ok || !payload?.ok) {
    // The API error body ({ ok, error_code, description }) carries no token.
    const description = typeof payload?.description === "string" ? payload.description : "";
    throw new Error(`Telegram API failed (${res.status}): ${redactSecrets(description).slice(0, 200)}`);
  }
}

// ---------------------------------------------------------------------------
// FCM (HTTP v1). Access token cached per isolate until shortly before expiry.
// ---------------------------------------------------------------------------
let fcmAccessToken: string | null = null;
let fcmTokenExpiry = 0;

function base64Url(bytes: Uint8Array | string): string {
  const bin = typeof bytes === "string"
    ? String.fromCharCode(...new TextEncoder().encode(bytes))
    : String.fromCharCode(...bytes);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBuf(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function getFcmAccessToken(): Promise<{ token: string; projectId: string } | null> {
  if (!FIREBASE_SERVICE_ACCOUNT_JSON) return null;
  let sa: { client_email: string; private_key: string; project_id: string };
  try {
    sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
  } catch {
    console.error("FCM: service account JSON is not valid JSON");
    return null;
  }
  if (fcmAccessToken && Date.now() < fcmTokenExpiry) return { token: fcmAccessToken, projectId: sa.project_id };
  try {
    const now = Math.floor(Date.now() / 1000);
    const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const claims = base64Url(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    }));
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToBuf(sa.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
    const assertion = `${header}.${claims}.${base64Url(new Uint8Array(sig))}`;
    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${assertion}`,
      signal: AbortSignal.timeout(10_000),
    });
    const data = await res.json().catch(() => null);
    if (!res.ok || typeof data?.access_token !== "string") {
      console.error(`FCM auth failed (HTTP ${res.status})`);
      return null;
    }
    fcmAccessToken = data.access_token;
    // Refresh a minute early.
    fcmTokenExpiry = Date.now() + Math.max(60, Number(data.expires_in ?? 3500) - 60) * 1000;
    return { token: data.access_token, projectId: sa.project_id };
  } catch (err) {
    console.error("FCM auth error:", describeError(err));
    return null;
  }
}

export async function sendFcmPush(
  fcmToken: string,
  title: string,
  body: string,
  data: Record<string, string> = {},
): Promise<boolean> {
  const auth = await getFcmAccessToken();
  if (!auth) return false;
  try {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${auth.projectId}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${auth.token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token: fcmToken,
          notification: { title, body },
          data,
          apns: { payload: { aps: { sound: "default", badge: 1 } } },
        },
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) console.warn(`FCM send failed (HTTP ${res.status})`);
    return res.ok;
  } catch (err) {
    console.error("FCM send error:", describeError(err));
    return false;
  }
}

/** Plain-text title/body for a push from an HTML Telegram message. */
export function pushTextFromHtml(message: string): { title: string; body: string } {
  const plain = message.replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  const lines = plain.split("\n");
  const title = lines[0].substring(0, 80);
  const body = lines.slice(1).join(" ").replace(/\s+/g, " ").trim().substring(0, 200) || title;
  return { title, body };
}
