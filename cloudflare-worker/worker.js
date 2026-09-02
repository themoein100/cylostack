// ════════════════════════════════════════════════════════════════════
//  CircleStack — Cloudflare Worker  (Remote Config + Telegram Bot)
//  KV Binding: CONFIG_KV / CIRCLESTACK_KV
// ════════════════════════════════════════════════════════════════════
import { verifyAttestation, verifyAssertion, bytesToB64, b64ToBytes } from "./appattest.js";

/// Team ID + bundle identifier, the "app id" App Attest binds keys to.
const APP_ATTEST_APP_ID = "HR6SBNSUB5.com.CyloStack.app";

// Telegram Bot API Helper
function getTelegramApi(env) {
  const token = (env?.BOT_TOKEN || "").trim();
  return `https://api.telegram.org/bot${token}`;
}

// 👑 Master Admin User ID (Moein)
const MASTER_ADMIN_ID = 1067160779;

// ─── KV Helper ──────────────────────────────────────────────────────
function getKV(env) {
  return env.CONFIG_KV || env.CIRCLESTACK_KV || null;
}

const kv = {
  get: async (env, key) => {
    const store = getKV(env);
    return store ? await store.get(key) : null;
  },
  put: async (env, key, val, opts) => {
    const store = getKV(env);
    if (store) await store.put(key, String(val), opts);
  },
  delete: async (env, key) => {
    const store = getKV(env);
    if (store) await store.delete(key);
  },
};

// Remote config is shared, public data (ad switches, store URL, minimum version),
// so it is safe to cache at Cloudflare's edge.  Device tokens, notification
// records, and admin data must never use this cache.
const REMOTE_CONFIG_CACHE_TTL_SECONDS = 60;

async function getRemoteConfig(env, request, ctx) {
  const cache = caches.default;
  // Deliberately omit the query string: every authenticated device receives the
  // same configuration and a per-device cache key would defeat the cache.
  const cacheKey = new Request(new URL("/_internal/cylostack-remote-config-v1", request.url).toString());
  const cached = await cache.match(cacheKey);
  if (cached) return cached.json();

  const [adsRaw, appOpenRaw, interstitialRaw, rewardedRaw, version, appstoreURL, privacyURL, forceUpdateRaw] = await Promise.all([
    kv.get(env, "ads_enabled"),
    kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "interstitial_ads_enabled"),
    kv.get(env, "rewarded_ads_enabled"),
    kv.get(env, "latest_version"),
    kv.get(env, "appstore_url"),
    kv.get(env, "privacy_url"),
    kv.get(env, "force_update"),
  ]);

  const adsEnabled          = adsRaw          !== "false";
  const appOpenEnabled      = appOpenRaw      !== null ? appOpenRaw      !== "false" : adsEnabled;
  const interstitialEnabled = interstitialRaw !== null ? interstitialRaw !== "false" : adsEnabled;
  const rewardedEnabled     = rewardedRaw     !== null ? rewardedRaw     !== "false" : adsEnabled;
  const payload = {
    ads_enabled:              adsEnabled,
    app_open_ads_enabled:     appOpenEnabled,
    interstitial_ads_enabled: interstitialEnabled,
    rewarded_ads_enabled:     rewardedEnabled,
    latest_version:           version      || "1.0.0",
    appstore_url:             appstoreURL  || "",
    privacy_url:              privacyURL   || "",
    force_update:             forceUpdateRaw === "true",
  };

  const response = new Response(JSON.stringify(payload), {
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": `max-age=${REMOTE_CONFIG_CACHE_TTL_SECONDS}`,
    },
  });
  const save = cache.put(cacheKey, response.clone()).catch(() => {});
  if (ctx?.waitUntil) ctx.waitUntil(save); else await save;
  return payload;
}

// ─── Today's date (Iran time UTC+3:30) ──────────────────────────────
function iranToday() {
  return new Date(Date.now() + 3.5 * 3600000).toISOString().slice(0, 10);
}

// ─── Text direction ─────────────────────────────────────────────────
// Telegram picks a line's direction from its first strong character, so a line
// starting with "App Open" renders left-to-right while the Persian line above it
// renders right-to-left — which is what made the panel look ragged. Prefixing every
// line with a right-to-left mark pins the whole message to one direction, and the
// embedded Latin words still read correctly inside it.
const RLM = "‏";

function rtl(line) {
  return RLM + line;
}

/// Applies the mark to every line of a multi-line block.
function rtlBlock(text) {
  return text.split("\n").map(line => (line ? RLM + line : line)).join("\n");
}

// ─── Cancel / back ──────────────────────────────────────────────────
const CANCEL_BUTTON = "🔙 انصراف";

/// Anything a person reasonably reaches for to back out of what they started.
function isCancel(text) {
  return /انصراف|لغو|بازگشت|برگشت/.test(text) || text === "/cancel" || text === "/start";
}

// ─── Admin Check Helper ─────────────────────────────────────────────
//
// Access is granted by Telegram @username. Telegram has no API to turn a username
// into a user id, so instead of resolving it up front we compare against the
// username Telegram itself attaches to every incoming update — which is the
// authoritative value at the moment the person actually uses the bot.
function normalizeUsername(name) {
  return String(name || "").trim().replace(/^@/, "").toLowerCase();
}

async function readAdmins(env) {
  try {
    const parsed = JSON.parse(await kv.get(env, "admin_usernames") || "[]");
    return Array.isArray(parsed) ? parsed.map(normalizeUsername).filter(Boolean) : [];
  } catch (_) {
    return [];
  }
}

async function isAdmin(env, userId, username) {
  if (Number(userId) === MASTER_ADMIN_ID) return true;

  const handle = normalizeUsername(username);
  if (!handle) return false;

  const admins = await readAdmins(env);
  return admins.includes(handle);
}

// ════════════════════════════════════════════════════════════════════
//  MAIN HANDLER
// ════════════════════════════════════════════════════════════════════
export default {
  async fetch(request, env, ctx) {
    try {
      const action = new URL(request.url).searchParams.get("action");
      if (action === "challenge") return await handleChallenge(env);
      if (action === "attest")    return await handleAttest(request, env);
      if (action === "push-token") return await handlePushToken(request, env);
      if (action === "clear-badge") return await handleClearBadge(request, env);
      if (action === "schedule-date-picker") return schedulePickerPage("date");
      if (action === "schedule-time-picker") return schedulePickerPage("time");

      if (request.method === "GET")  return await handleGet(request, env, ctx);
      if (request.method === "POST") return await handlePost(request, env, ctx);
    } catch (e) {
      console.error("Worker error:", e);
    }
    return new Response("CircleStack API Active", { status: 200 });
  },

  async queue(batch, env, ctx) {
    await handlePushQueue(batch, env, ctx);
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(runScheduledPush(env));
  },
};

// ════════════════════════════════════════════════════════════════════
//  Push notification device registration
// ════════════════════════════════════════════════════════════════════
//
// A device token is never accepted on trust: the request must carry a fresh App
// Attest assertion. This prevents anyone who discovers the Worker URL from using
// it as a free APNs relay or filling KV with arbitrary tokens.
async function sha256Base64Url(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return toBase64Url(new Uint8Array(digest));
}

async function handlePushToken(request, env) {
  if (request.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  const url = new URL(request.url);
  const event = url.searchParams.get("event") || "";
  const uuid = url.searchParams.get("uuid") || "";
  if (event !== "push_token" || !uuid) return jsonResponse({ error: "bad_request" }, 400);

  const attested = await verifyAttestedRequest(env, {
    keyId: url.searchParams.get("keyId"),
    assertion: url.searchParams.get("assertion"),
    challenge: url.searchParams.get("challenge"),
    event,
    uuid,
  });
  if (!attested) return jsonResponse({ error: "attestation_required" }, 401);

  const body = await request.json().catch(() => null);
  const token = typeof body?.token === "string" ? body.token.trim() : "";
  const environment = body?.environment === "sandbox" ? "sandbox" : "production";
  // APNs device tokens are hex strings. Validating them keeps malformed values out
  // of the delivery queue and avoids ever exposing the token in logs or key names.
  if (!/^[0-9a-fA-F]{64,256}$/.test(token)) {
    return jsonResponse({ error: "invalid_token" }, 400);
  }

  const tokenID = await sha256Base64Url(token);
  await kv.put(env, `push_token_${tokenID}`, JSON.stringify({
    token,
    environment,
    badge: 0,
    updatedAt: new Date().toISOString(),
  }));
  return jsonResponse({ ok: true }, 200);
}

async function handleClearBadge(request, env) {
  if (request.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);
  const url = new URL(request.url);
  const event = url.searchParams.get("event") || "";
  const uuid = url.searchParams.get("uuid") || "";
  if (event !== "clear_badge" || !uuid) return jsonResponse({ error: "bad_request" }, 400);
  const attested = await verifyAttestedRequest(env, {
    keyId: url.searchParams.get("keyId"), assertion: url.searchParams.get("assertion"),
    challenge: url.searchParams.get("challenge"), event, uuid,
  });
  if (!attested) return jsonResponse({ error: "attestation_required" }, 401);
  const body = await request.json().catch(() => null);
  const token = typeof body?.token === "string" ? body.token.trim() : "";
  if (!/^[0-9a-fA-F]{64,256}$/.test(token)) return jsonResponse({ error: "invalid_token" }, 400);
  const key = `push_token_${await sha256Base64Url(token)}`;
  const raw = await kv.get(env, key);
  let record;
  try { record = JSON.parse(raw || ""); } catch (_) { record = null; }
  if (record?.token) await kv.put(env, key, JSON.stringify({ ...record, badge: 0, updatedAt: new Date().toISOString() }));
  return jsonResponse({ ok: true }, 200);
}

// ════════════════════════════════════════════════════════════════════
//  App Attest endpoints
// ════════════════════════════════════════════════════════════════════
const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

/// A one-time nonce. Attestations and assertions are both bound to one of these,
/// so a captured request cannot be replayed.
/// base64url, because these values travel in a query string: standard base64's
/// "+" arrives as a space and the value no longer matches what was signed.
function toBase64Url(bytes) {
  return bytesToB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// Accepts either alphabet and returns one canonical form, so a key registered as
/// base64 and later presented as base64url still resolves to the same record.
function canonicalKeyId(value) {
  try {
    return toBase64Url(b64ToBytes(value));
  } catch (_) {
    return "";
  }
}

async function handleChallenge(env) {
  const challenge = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
  await kv.put(env, `challenge_${challenge}`, "1", { expirationTtl: 300 });
  return jsonResponse({ challenge });
}

async function consumeChallenge(env, challenge) {
  if (!challenge) return false;
  const key = `challenge_${challenge}`;
  if (!await kv.get(env, key)) return false;
  // Burn it so the same nonce cannot be used twice.
  await kv.put(env, key, "", { expirationTtl: 60 });
  return true;
}

/// Registers a device key after Apple has vouched for it.
async function handleAttest(request, env) {
  if (request.method !== "PUT") return jsonResponse({ error: "method_not_allowed" }, 405);

  const body = await request.json().catch(() => null);
  if (!body?.keyId || !body?.challenge || !body?.attestation) {
    return jsonResponse({ error: "missing_fields" }, 400);
  }

  if (!await consumeChallenge(env, body.challenge)) {
    return jsonResponse({ error: "unknown_challenge" }, 401);
  }

  try {
    const { publicKey, signCount, environment } = await verifyAttestation({
      attestation: body.attestation,
      keyId: body.keyId,
      challenge: body.challenge,
      appId: APP_ATTEST_APP_ID,
      // Defaults to allowing development keys so testing from Xcode works. Flip
      // APP_ATTEST_ALLOW_DEV to "false" in wrangler.toml once the app has shipped.
      allowDevelopment: env.APP_ATTEST_ALLOW_DEV !== "false",
    });

    await kv.put(env, `attest_${canonicalKeyId(body.keyId)}`,
      JSON.stringify({ publicKey, signCount, environment }));
    console.log(`App Attest: registered ${environment} key`, body.keyId);
    return jsonResponse({ ok: true });
  } catch (e) {
    console.log("App Attest: rejected attestation —", e.message);
    return jsonResponse({ error: e.message }, 401);
  }
}

/// Checks a per-request assertion. Returns true only when the request provably
/// came from a device key Apple already vouched for.
async function verifyAttestedRequest(env, { keyId, assertion, challenge, event, uuid }) {
  if (!keyId || !assertion || !challenge) return false;

  const canonical = canonicalKeyId(keyId);
  const raw = await kv.get(env, `attest_${canonical}`);
  if (!raw) return false;

  let record;
  try { record = JSON.parse(raw); } catch (_) { return false; }

  if (!await consumeChallenge(env, challenge)) return false;

  try {
    const { signCount } = await verifyAssertion({
      assertion,
      publicKey: record.publicKey,
      clientData: `${challenge}|${event}|${uuid}`,
      appId: APP_ATTEST_APP_ID,
      lastCount: record.signCount,
    });

    await kv.put(env, `attest_${canonical}`, JSON.stringify({ ...record, signCount }));
    return true;
  } catch (e) {
    console.log("App Attest: rejected assertion —", e.message);
    return false;
  }
}

// ════════════════════════════════════════════════════════════════════
//  Transport security
//
//  TLS already protects this traffic on the wire. What it does not do is stop
//  anyone who knows the URL from reading the config or forging analytics events —
//  the endpoint was wide open, so install and DAU counts could be inflated by
//  anybody with curl. These two layers close that:
//
//    · requests carry an HMAC-SHA256 signature over event+uuid+timestamp
//    · responses are returned AES-256-GCM encrypted
//
//  Both use APP_SECRET, a Worker secret shared with the app. Honest limitation:
//  a secret compiled into a client binary can be extracted by someone determined
//  enough. This raises the bar from "trivial" to "needs to reverse the app"; it is
//  not a substitute for server-side auth on anything that really matters.
// ════════════════════════════════════════════════════════════════════
const SIGNATURE_WINDOW_SECONDS = 300;

function bytesToHex(buffer) {
  return [...new Uint8Array(buffer)].map(b => b.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64(buffer) {
  return btoa(String.fromCharCode(...new Uint8Array(buffer)));
}

async function secretKeyBytes(env) {
  // The shared secret is stretched into a fixed 256-bit key, so the raw secret can
  // be any length or format without weakening the cipher.
  return await crypto.subtle.digest("SHA-256", new TextEncoder().encode(env.APP_SECRET));
}

async function expectedSignature(env, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.APP_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return bytesToHex(sig);
}

/// Constant-time compare, so a wrong signature cannot be discovered byte by byte.
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifyRequest(env, { event, uuid, ts, sig }) {
  if (!env.APP_SECRET) return { ok: false, reason: "server_not_configured" };
  if (!ts || !sig) return { ok: false, reason: "unsigned" };

  const age = Math.abs(Math.floor(Date.now() / 1000) - Number(ts));
  if (!Number.isFinite(age) || age > SIGNATURE_WINDOW_SECONDS) {
    return { ok: false, reason: "stale" };
  }

  const expected = await expectedSignature(env, `${event}|${uuid}|${ts}`);
  return timingSafeEqual(expected, String(sig).toLowerCase())
    ? { ok: true }
    : { ok: false, reason: "bad_signature" };
}

async function encryptPayload(env, payload) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey(
    "raw", await secretKeyBytes(env), { name: "AES-GCM" }, false, ["encrypt"]
  );
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(JSON.stringify(payload))
  );
  return { v: 1, iv: bytesToBase64(iv), data: bytesToBase64(ciphertext) };
}

// ════════════════════════════════════════════════════════════════════
//  GET — iOS App fetches remote config
// ════════════════════════════════════════════════════════════════════
async function handleGet(request, env, ctx) {
  const url   = new URL(request.url);
  const event = url.searchParams.get("event") || "";
  const uuid  = url.searchParams.get("uuid")  || "anon";

  // Two ways in, strongest first.
  //
  // App Attest is the real guarantee: the signing key lives in the Secure Enclave,
  // so there is nothing extractable from the binary. Devices that cannot do it —
  // the Simulator, older hardware — fall back to the shared-key signature, which
  // is weaker but keeps the app working rather than locking anyone out.
  const attested = await verifyAttestedRequest(env, {
    keyId:     url.searchParams.get("keyId"),
    assertion: url.searchParams.get("assertion"),
    challenge: url.searchParams.get("challenge"),
    event,
    uuid,
  });

  if (!attested) {
    const auth = await verifyRequest(env, {
      event,
      uuid,
      ts:  url.searchParams.get("ts"),
      sig: url.searchParams.get("sig"),
    });

    if (!auth.ok) {
      return new Response(JSON.stringify({ error: auth.reason }), {
        status: auth.reason === "server_not_configured" ? 500 : 401,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }
  }

  // Must be handed to waitUntil: a Worker kills any pending async work the moment
  // the response is returned, which was cutting trackEvent off part-way. The
  // per-device marker got written and the counter never did, so the panel showed
  // zero installs and zero daily actives no matter how much the game was played.
  const tracking = trackEvent(env, event, uuid).catch(() => {});
  if (ctx?.waitUntil) ctx.waitUntil(tracking);

  // KV is read only on an edge-cache miss. Each device still gets a separately
  // encrypted response, so the cached payload never exposes another user's data.
  const payload = await getRemoteConfig(env, request, ctx);

  const body = await encryptPayload(env, payload);

  return new Response(JSON.stringify(body), {
    headers: {
      "Content-Type":  "application/json",
      "Cache-Control": "no-store",
      // Tells the app which path actually authenticated it. Without this an app
      // whose key the server has forgotten would fall back to the shared key
      // forever and never notice it should attest again.
      "X-Attested":    attested ? "1" : "0",
    },
  });
}

// ════════════════════════════════════════════════════════════════════
//  Analytics — Unique User Tracking
// ════════════════════════════════════════════════════════════════════
/// Records one marker key per device, per event. No counters.
///
/// The counters this replaces were read-modify-write: two devices opening the app
/// at the same moment both read the same number and both wrote the same number
/// plus one, so one of them was lost. Undetectable at one user and steadily
/// wrong at a thousand. The markers are the truth; they get counted on demand.
async function trackEvent(env, event, uuid) {
  if (!getKV(env) || !event || !uuid) return;
  if (event !== "install" && event !== "active") return;

  // Any device that reaches this endpoint is, by definition, an install. Keying on
  // the "install" event alone made the two numbers able to disagree — a device
  // whose first request never landed would report itself active every day while
  // never being counted as installed, which is how the panel ended up showing
  // more daily actives than installs in total.
  const installKey = `install_${uuid}`;
  if (!await kv.get(env, installKey)) await kv.put(env, installKey, "1");

  // Two days of retention so "yesterday" is still countable after midnight.
  const dauKey = `dau_${iranToday()}_${uuid}`;
  if (!await kv.get(env, dauKey)) await kv.put(env, dauKey, "1", { expirationTtl: 172800 });
}

/// Exact count of the keys under a prefix, following the cursor so the answer
/// stays correct past the 1000-key page limit.
async function countKeys(env, prefix) {
  const store = getKV(env);
  if (!store) return 0;

  let total = 0;
  let cursor;

  do {
    const page = await store.list({ prefix, cursor, limit: 1000 });
    total += page.keys.length;
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);

  return total;
}

// ════════════════════════════════════════════════════════════════════
//  POST — Telegram Webhook with Admin Access Security
// ════════════════════════════════════════════════════════════════════
async function handlePost(request, env, ctx) {
  const update = await request.json().catch(() => null);
  if (!update) return new Response("OK");

  const msg        = update.message || update.callback_query?.message || update.edited_message;
  const chatId     = msg?.chat?.id;
  const fromUser   = update.message?.from || update.callback_query?.from || update.edited_message?.from || msg?.from || update.from;
  const userId     = fromUser?.id;
  const username   = fromUser?.username;

  // Keep operational diagnostics useful without retaining announcement text,
  // device tokens, or other user-provided content in KV/logs.
  const updateKind = update.callback_query ? "callback" : update.edited_message ? "edited_message" : update.message ? "message" : "other";
  console.log(JSON.stringify({ event: "telegram_update", updateID: update.update_id, kind: updateKind }));
  await kv.put(env, "debug_last_update", JSON.stringify({
    time: new Date().toISOString(), updateID: update.update_id, kind: updateKind,
    chatId: chatId || null, fromUserID: userId || null,
  })).catch(() => {});

  if (!chatId || !userId) return new Response("OK");

  // 🔒 Security Barrier: Block anyone who is not the owner or an invited admin
  if (!await isAdmin(env, userId, username)) {
    await sendMsg(env, chatId,
      rtl("⛔️ *دسترسی ندارید*") + "\n\n" +
      (username
        ? rtl(`آیدی تلگرام شما: @${username}`) + "\n" +
          rtl("اگر باید دسترسی داشته باشید، این آیدی را برای مالک ربات بفرست.")
        : rtl("برای گرفتن دسترسی باید اول در تنظیمات تلگرام برای خودت یک Username بسازی.")));
    return new Response("OK");
  }

  const text       = (update.message?.text || update.callback_query?.data || "").trim();
  const webAppData = update.message?.web_app_data?.data || "";
  const replyText  = (update.message?.reply_to_message?.text || "").toLowerCase();

  // ── 0. Backing out ───────────────────────────────────────────────
  // Checked before anything else, so a cancel is never mistaken for the answer to
  // a question the bot is waiting on.
  const pending = await kv.get(env, `pending_${chatId}`);

  if (isCancel(text)) {
    if (pending) await kv.put(env, `pending_${chatId}`, "", { expirationTtl: 60 });
    await kv.delete(env, `${PUSH_DRAFT_PREFIX}${chatId}`);
    await kv.delete(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`);
    return await sendMenu(env, chatId, pending ? rtl("↩️ لغو شد.") : null);
  }

  // ── Access management (owner only) ───────────────────────────────
  // Granting access is the one thing an invited admin must never be able to do,
  // otherwise the first person let in can quietly let everyone else in too.
  const isOwner = Number(userId) === MASTER_ADMIN_ID;

  if (isOwner && webAppData) {
    let selection;
    try { selection = JSON.parse(webAppData); } catch (_) { selection = null; }
    if (selection?.action === "schedule_date") {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(selection.date || "")) {
        return await sendScheduleDatePicker(env, chatId, rtl("❌ تاریخ نامعتبر است."));
      }
      await kv.put(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`, JSON.stringify({ date: selection.date }), { expirationTtl: 900 });
      return await sendScheduleTimePicker(env, chatId);
    }
    if (selection?.action === "schedule_time") {
      if (!/^(0[1-9]|1[0-2]):[0-5]\d (AM|PM)$/.test(selection.time || "")) {
        return await sendScheduleTimePicker(env, chatId, rtl("❌ ساعت نامعتبر است."));
      }
      return await handlePickedScheduleTime(env, chatId, selection.time);
    }
    return await sendPushPanel(env, chatId, rtl("❌ انتخاب معتبر نبود؛ دوباره تلاش کن."));
  }

  const wantsAccessPanel = text === "/admins" || text.includes("مدیریت دسترسی");
  const wantsAddAdmin    = text.includes("افزودن دسترسی") || text.startsWith("/addadmin");
  const wantsRemoveAdmin = text.includes("حذف دسترسی")   || text.startsWith("/removeadmin");
  const isReplyToAdd     = replyText.includes("افزودن دسترسی");
  const isReplyToRemove  = replyText.includes("گرفتن دسترسی");

  if (!isOwner && (wantsAccessPanel || wantsAddAdmin || wantsRemoveAdmin || isReplyToAdd || isReplyToRemove)) {
    await sendMsg(env, chatId, rtl("⛔️ فقط مالک ربات می‌تواند دسترسی‌ها را تغییر دهد."));
    return new Response("OK");
  }

  if (isOwner && isReplyToAdd) {
    return await handleAddAdmin(env, chatId, text);
  }
  if (isOwner && isReplyToRemove) {
    return await handleRemoveAdmin(env, chatId, text);
  }

  if (isOwner && text.startsWith("/addadmin ")) {
    return await handleAddAdmin(env, chatId, text.slice(10).trim());
  }
  if (isOwner && text.startsWith("/removeadmin ")) {
    return await handleRemoveAdmin(env, chatId, text.slice(13).trim());
  }

  if (isOwner && wantsAddAdmin) {
    return await sendPrompt(env, chatId, "addadmin",
      rtl("➕ *افزودن دسترسی*") + "\n\n" +
      rtl("آیدی تلگرام کاربر را بفرست، مثل: `@username`") + "\n" +
      rtl("طرف مقابل باید در تنظیمات تلگرام Username داشته باشد."));
  }

  if (isOwner && wantsRemoveAdmin) {
    return await sendPrompt(env, chatId, "removeadmin",
      rtl("🗑 *گرفتن دسترسی*") + "\n\n" +
      rtl("آیدی تلگرام کاربری که می‌خواهی حذف شود را بفرست، مثل: `@username`"));
  }

  if (isOwner && wantsAccessPanel) {
    return await sendAccessPanel(env, chatId, null);
  }

  // ── 1. Answer to a question the bot is waiting on ────────────────
  // Matched two ways: the remembered pending action, and — as a fallback for
  // prompts sent by an older deploy — a direct reply to the prompt message.
  const answering = pending
    || (replyText.includes("شماره نسخه") ? "version" : "")
    || (replyText.includes("اپ استور") ? "appstore" : "")
    || (replyText.includes("حریم خصوصی") ? "privacy" : "")
    || (replyText.includes("افزودن دسترسی") ? "addadmin" : "")
    || (replyText.includes("گرفتن دسترسی") ? "removeadmin" : "");

  if (answering) {
    await kv.put(env, `pending_${chatId}`, "", { expirationTtl: 60 });

    switch (answering) {
      case "version":     return await handleSetVersion(env, chatId, text);
      case "appstore":    return await handleSetAppstore(env, chatId, text);
      case "privacy":     return await handleSetPrivacy(env, chatId, text);
      case "push_broadcast": return isOwner ? await handlePushDraft(env, chatId, text)
                                             : await sendMenu(env, chatId, null);
      case "push_test":   return isOwner ? await handlePushTest(env, chatId, text)
                                          : await sendMenu(env, chatId, null);
      case "push_schedule_date": return isOwner ? await handlePushScheduleDate(env, chatId, text)
                                                  : await sendMenu(env, chatId, null);
      case "push_schedule_body": return isOwner ? await handlePushScheduleBody(env, chatId, text)
                                                  : await sendMenu(env, chatId, null);
      case "addadmin":    return isOwner ? await handleAddAdmin(env, chatId, text)
                                         : await sendMenu(env, chatId, null);
      case "removeadmin": return isOwner ? await handleRemoveAdmin(env, chatId, text)
                                         : await sendMenu(env, chatId, null);
    }
  }

  // ── 2. Direct slash commands ────────────────────────────────────
  if (text.startsWith("/setversion ")) {
    return await handleSetVersion(env, chatId, text.slice(12).trim());
  }
  if (text.startsWith("/setappstore ")) {
    return await handleSetAppstore(env, chatId, text.slice(13).trim());
  }
  if (text.startsWith("/setprivacy ")) {
    return await handleSetPrivacy(env, chatId, text.slice(12).trim());
  }

  // Sending an announcement reaches every opted-in device, so it is deliberately
  // restricted to the owner even when the bot has other operational admins.
  if (isOwner && text === "📣 ارسال اعلان") {
    return await sendPushPanel(env, chatId);
  }
  if (isOwner && (text === "/broadcast" || text === "⚡️ ارسال فوری")) {
    return await sendPrompt(env, chatId, "push_broadcast", rtlBlock(
      "متن نوتیف را بفرست."));
  }
  if (isOwner && text === "✅ تأیید و ارسال") {
    return await queuePushBroadcast(env, chatId);
  }
  if (isOwner && (text === "/pushtest" || text === "🧪 تست یک دستگاه")) {
    return await sendPrompt(env, chatId, "push_test", rtlBlock(
      "توکن دستگاه را بفرست."));
  }
  if (isOwner && (text === "/schedule" || text === "🗓 ارسال زمان‌دار")) {
    return await sendScheduleDatePicker(env, chatId);
  }
  if (isOwner && (text === "/pushreports" || text === "📊 گزارش ارسال‌ها")) {
    return await sendPushReports(env, chatId);
  }
  if (isOwner && text.startsWith("cancel_schedule:")) {
    return await cancelScheduledPush(env, chatId, text.slice("cancel_schedule:".length));
  }
  if (isOwner && text.startsWith("report_page:")) {
    const page = Number(text.slice("report_page:".length));
    const messageID = update.callback_query?.message?.message_id;
    return await sendPushReports(env, chatId, Number.isInteger(page) && page >= 0 ? page : 0, messageID);
  }
  if (text === "📦 نسخه‌ها") return await sendVersionsPanel(env, chatId);
  if (text === "🔗 مدیریت لینک‌ها") return await sendLinksPanel(env, chatId);

  // ── 3. Keyboard button presses ──────────────────────────────────
  if (text === "📢 تبلیغات") {
    return await sendAdsPanel(env, chatId);
  }
  if (text.includes("خاموش کردن تبلیغات") || text === "DISABLE_ADS") {
    await kv.put(env, "ads_enabled", "false");
    await kv.put(env, "app_open_ads_enabled", "false");
    await kv.put(env, "interstitial_ads_enabled", "false");
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendAdsPanel(env, chatId, rtl("⛔️ همه تبلیغات خاموش شد."));
  }
  if (text.includes("روشن کردن تبلیغات") || text === "ENABLE_ADS") {
    await kv.put(env, "ads_enabled", "true");
    await kv.put(env, "app_open_ads_enabled", "true");
    await kv.put(env, "interstitial_ads_enabled", "true");
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendAdsPanel(env, chatId, rtl("✅ همه تبلیغات روشن شد."));
  }
  // Older keyboards used the English format names, so both spellings are accepted.
  if (text.includes("خاموش کردن ورودی اپ") || text.includes("خاموش کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "false");
    return await sendAdsPanel(env, chatId, rtl("⛔️ تبلیغ ورودی اپ خاموش شد."));
  }
  if (text.includes("روشن کردن ورودی اپ") || text.includes("روشن کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "true");
    return await sendAdsPanel(env, chatId, rtl("✅ تبلیغ ورودی اپ روشن شد."));
  }
  if (text.includes("خاموش کردن بین‌برنامه‌ای") || text.includes("خاموش کردن Interstitial")) {
    await kv.put(env, "interstitial_ads_enabled", "false");
    return await sendAdsPanel(env, chatId, rtl("⛔️ تبلیغ بین‌برنامه‌ای خاموش شد."));
  }
  if (text.includes("روشن کردن بین‌برنامه‌ای") || text.includes("روشن کردن Interstitial")) {
    await kv.put(env, "interstitial_ads_enabled", "true");
    return await sendAdsPanel(env, chatId, rtl("✅ تبلیغ بین‌برنامه‌ای روشن شد."));
  }
  if (text.includes("خاموش کردن جایزه‌دار") || text.includes("خاموش کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendAdsPanel(env, chatId, rtl("⛔️ تبلیغ جایزه‌دار خاموش شد."));
  }
  if (text.includes("روشن کردن جایزه‌دار") || text.includes("روشن کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendAdsPanel(env, chatId, rtl("✅ تبلیغ جایزه‌دار روشن شد."));
  }
  if (text.includes("خاموش کردن آپدیت اجباری")) {
    await kv.put(env, "force_update", "false");
    return await sendMenu(env, chatId, rtl("🔓 آپدیت اجباری خاموش شد."));
  }
  if (text.includes("روشن کردن آپدیت اجباری")) {
    await kv.put(env, "force_update", "true");
    return await sendMenu(env, chatId, rtl("🔒 آپدیت اجباری روشن شد."));
  }
  if (text.includes("نسخه جدید") || text === "/version") {
    return await sendPrompt(env, chatId, "version", rtlBlock(
      "📝 *شماره نسخه جدید*\n\nمثال: 2.0.0"));
  }
  if (text.includes("لینک اپ استور") || text === "/appstore") {
    return await sendPrompt(env, chatId, "appstore", rtlBlock(
      "📝 *لینک اپ استور*\n\nآدرس کامل را بفرست."));
  }
  if (text.includes("حریم خصوصی") || text === "/privacy") {
    return await sendPrompt(env, chatId, "privacy", rtlBlock(
      "📝 *لینک حریم خصوصی*\n\nآدرس کامل را بفرست."));
  }

  // ── 4. Default: show stats + menu ──────────────────────────────
  return await sendMenu(env, chatId, null);
}

// ════════════════════════════════════════════════════════════════════
//  Access Management
// ════════════════════════════════════════════════════════════════════
/// Telegram usernames are 5–32 chars of letters, digits and underscores, and must
/// start with a letter — so a bare number like "12345" is a user id, not a handle,
/// and is rejected rather than silently stored as an entry that can never match.
function isValidUsername(handle) {
  return /^[a-z][a-z0-9_]{4,31}$/.test(handle);
}

async function handleAddAdmin(env, chatId, value) {
  const handle = normalizeUsername(value);
  if (!isValidUsername(handle)) {
    return await sendPrompt(env, chatId, "addadmin", rtlBlock(
      "❌ آیدی معتبر نیست.\n\nآیدی تلگرام بفرست، مثل: `@username`"));
  }

  const admins = await readAdmins(env);
  if (admins.includes(handle)) {
    return await sendAccessPanel(env, chatId, rtl(`ℹ️ @${handle} از قبل دسترسی داشت.`));
  }

  admins.push(handle);
  await kv.put(env, "admin_usernames", JSON.stringify(admins));
  return await sendAccessPanel(env, chatId, rtl(`✅ به @${handle} دسترسی داده شد.`));
}

async function handleRemoveAdmin(env, chatId, value) {
  const handle = normalizeUsername(value);
  if (!handle) {
    return await sendPrompt(env, chatId, "removeadmin", rtlBlock(
      "❌ آیدی معتبر نیست.\n\nآیدی تلگرام بفرست، مثل: `@username`"));
  }

  const admins = await readAdmins(env);
  if (!admins.includes(handle)) {
    return await sendAccessPanel(env, chatId, rtl(`ℹ️ @${handle} در لیست نبود.`));
  }

  await kv.put(env, "admin_usernames", JSON.stringify(admins.filter(h => h !== handle)));
  return await sendAccessPanel(env, chatId, rtl(`🗑 دسترسی @${handle} گرفته شد.`));
}

async function sendAccessPanel(env, chatId, headerMsg) {
  const admins = await readAdmins(env);

  const list = admins.length
    ? admins.map((h, i) => rtl(`${i + 1}. @${h}`)).join("\n")
    : rtl("_هیچ‌کس دیگری دسترسی ندارد._");

  const body =
    rtl("👥 *مدیریت دسترسی*") + "\n\n" +
    rtl("👑 مالک: شما") + "\n\n" +
    rtl(`🔑 دسترسی‌های اضافه (${admins.length}):`) + "\n" +
    list + "\n\n" +
    rtl("با آیدی تلگرام اضافه کن، مثل `@username`.") + "\n" +
    rtl("طرف مقابل باید در تنظیمات تلگرام Username داشته باشد.");

  const fullMsg = headerMsg ? `${headerMsg}\n\n${body}` : body;

  await sendMsg(env, chatId, fullMsg, {
    keyboard: [
      [
        { text: "➕ افزودن دسترسی" },
        { text: "🗑 حذف دسترسی" },
      ],
      [
        { text: "🔙 بازگشت به پنل" },
      ],
    ],
    resize_keyboard: true,
  });

  return new Response("OK");
}

// ════════════════════════════════════════════════════════════════════
//  Set Helpers
// ════════════════════════════════════════════════════════════════════
async function handleSetVersion(env, chatId, value) {
  // A rejected value re-asks rather than dumping the user back at the panel, so a
  // typo costs one more message instead of starting the whole task again.
  if (!/^\d+(\.\d+)+$/.test(value)) {
    return await sendPrompt(env, chatId, "version", rtlBlock(
      "❌ فرمت نسخه اشتباه است.\n\nدوباره بفرست، مثل: 2.0.0"));
  }
  await kv.put(env, "latest_version", value);
  return await sendMenu(env, chatId, rtl(`🚀 نسخه ثبت شد: *${value}*`));
}

async function handleSetAppstore(env, chatId, value) {
  if (!value.startsWith("http")) {
    return await sendPrompt(env, chatId, "appstore", rtlBlock(
      "❌ لینک باید با https:// شروع شود.\n\nدوباره بفرست."));
  }
  await kv.put(env, "appstore_url", value);
  return await sendMenu(env, chatId, rtl("🍎 لینک اپ استور ثبت شد."));
}

async function handleSetPrivacy(env, chatId, value) {
  if (!value.startsWith("http")) {
    return await sendPrompt(env, chatId, "privacy", rtlBlock(
      "❌ لینک باید با https:// شروع شود.\n\nدوباره بفرست."));
  }
  await kv.put(env, "privacy_url", value);
  return await sendMenu(env, chatId, rtl("🔒 لینک حریم خصوصی ثبت شد."));
}

// ════════════════════════════════════════════════════════════════════
//  Push notification broadcasts (Telegram owner → Queue → APNs)
// ════════════════════════════════════════════════════════════════════
const PUSH_DRAFT_PREFIX = "push_draft_";
const PUSH_BROADCAST_PREFIX = "push_broadcast_";
const PUSH_SCHEDULE_PREFIX = "push_scheduled_";
const PUSH_SCHEDULE_DRAFT_PREFIX = "push_schedule_draft_";

function isPushConfigured(env) {
  return Boolean(env.PUSH_QUEUE && env.APNS_TEAM_ID && env.APNS_KEY_ID &&
                 env.APNS_PRIVATE_KEY && env.APNS_TOPIC);
}

async function handlePushDraft(env, chatId, value) {
  // 512 characters keeps announcements concise and comfortably below APNs's
  // payload ceiling after the title and JSON envelope are included.
  const body = value.replace(/\s+/g, " ").trim();
  if (!body || body.length > 512) {
    return await sendPrompt(env, chatId, "push_broadcast", rtlBlock(
      "❌ متن باید بین ۱ تا ۵۱۲ کاراکتر باشد. دوباره بفرست."));
  }

  await kv.put(env, `${PUSH_DRAFT_PREFIX}${chatId}`, JSON.stringify({
    title: "CyloStack",
    body,
    createdAt: new Date().toISOString(),
  }), { expirationTtl: 900 });

  const recipients = await countKeys(env, "push_token_");
  await sendMsg(env, chatId,
    rtl("🔎 *پیش‌نمایش اعلان*") + "\n\n" +
    rtl("عنوان: CyloStack") + "\n" +
    rtl(`متن: ${body}`) + "\n\n" +
    rtl(`گیرنده‌های آماده: *${recipients}* دستگاه`) + "\n" +
    rtl("با تأیید، اعلان در صف امن ارسال قرار می‌گیرد."), {
      keyboard: [
        [{ text: "✅ تأیید و ارسال" }],
        [{ text: "📣 ارسال اعلان" }, { text: CANCEL_BUTTON }],
      ],
      resize_keyboard: true,
    });
  return new Response("OK");
}

async function queuePushBroadcast(env, chatId) {
  const raw = await kv.get(env, `${PUSH_DRAFT_PREFIX}${chatId}`);
  let draft;
  try { draft = JSON.parse(raw || ""); } catch (_) { draft = null; }
  if (!draft?.body) {
    return await sendMenu(env, chatId, rtl("⚠️ پیش‌نویس اعلان پیدا نشد؛ دوباره متن را بفرست."));
  }
  const recipients = await enqueuePushBroadcast(env, draft, "manual");
  if (recipients === null) {
    return await sendMenu(env, chatId, rtl("⚠️ ارسال اعلان هنوز روی سرور فعال نشده است."));
  }
  await kv.delete(env, `${PUSH_DRAFT_PREFIX}${chatId}`);

  return await sendMenu(env, chatId, rtl(`✅ اعلان برای *${recipients}* دستگاه در صف ارسال قرار گرفت.`));
}

/// Stores a short-lived broadcast record and hands off fan-out to Cloudflare
/// Queues. Both the manual confirmation and the daily scheduler use this same
/// path, so large audiences are always delivered with the same retry rules.
async function enqueuePushBroadcast(env, draft, source) {
  if (!isPushConfigured(env)) return null;

  const broadcastID = crypto.randomUUID();
  const recipients = await countKeys(env, "push_token_");
  await kv.put(env, `${PUSH_BROADCAST_PREFIX}${broadcastID}`, JSON.stringify({
    title: "CyloStack",
    body: draft.body,
    source,
    requestedAt: new Date().toISOString(),
    recipients,
    trackingVersion: 1,
  }), { expirationTtl: 604800 });

  // The page job fans out at most 1,000 stored device records at a time. It
  // schedules its own continuation, so large audiences never depend on one
  // Telegram webhook request staying alive.
  await env.PUSH_QUEUE.send({ kind: "broadcast_page", broadcastID, cursor: null });
  return recipients;
}

async function handlePushTest(env, chatId, value) {
  const input = String(value || "").trim();
  const prefixed = input.match(/^(sandbox|production)\s*:\s*(.+)$/i);
  const environment = prefixed ? prefixed[1].toLowerCase() : "sandbox";
  const token = (prefixed ? prefixed[2] : input).replace(/[\s<>]/g, "");
  if (!/^[0-9a-fA-F]{64,256}$/.test(token)) {
    return await sendPrompt(env, chatId, "push_test", rtlBlock(
      "❌ توکن معتبر نیست. دوباره فقط توکن hex را بفرست؛ نمونه: `sandbox:abc...`"));
  }
  if (!isPushConfigured(env)) {
    return await sendMenu(env, chatId, rtl("⚠️ ارسال اعلان هنوز روی سرور فعال نشده است."));
  }

  try {
    const authorization = await makeAPNsAuthorization(env);
    const result = await sendAPNs(env, authorization, { token, environment }, "CyloStack", "Test notification ✅");
    if (result.ok) {
      return await sendMenu(env, chatId, rtl("✅ اعلان آزمایشی به APNs تحویل شد. نمایش آن به تنظیمات نوتیفیکیشن همان دستگاه بستگی دارد."));
    }
    return await sendMenu(env, chatId, rtl(`❌ APNs اعلان آزمایشی را نپذیرفت: ${result.reason || `HTTP ${result.status}`}`));
  } catch (error) {
    console.error("APNs test notification failed", error);
    return await sendMenu(env, chatId, rtl("❌ ارسال تست انجام نشد؛ تنظیمات APNs سرور را بررسی کن."));
  }
}

async function handlePushScheduleDate(env, chatId, value) {
  const match = String(value || "").trim().match(/^(\d{4})-(\d{2})-(\d{2})\s+([01]\d|2[0-3]):([0-5]\d)$/);
  if (!match) {
    return await sendPrompt(env, chatId, "push_schedule_date", rtlBlock(
      "❌ فرمت درست نیست. نمونه: `2026-08-26 21:00` (UTC)"));
  }
  const scheduleAt = new Date(`${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:00.000Z`);
  if (Number.isNaN(scheduleAt.getTime()) || scheduleAt.getTime() <= Date.now() + 60_000) {
    return await sendPrompt(env, chatId, "push_schedule_date", rtlBlock(
      "❌ تاریخ باید حداقل یک دقیقه در آینده باشد و با UTC نوشته شود."));
  }
  await kv.put(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`, JSON.stringify({
    scheduleAt: scheduleAt.toISOString(), displayAt: `${match[1]}-${match[2]}-${match[3]} ${match[4]}:${match[5]} UTC`,
  }), { expirationTtl: 900 });
  return await sendPrompt(env, chatId, "push_schedule_body", rtlBlock("✍️ حالا متن اعلان را بفرست."));
}

async function sendScheduleDatePicker(env, chatId, headerMsg) {
  const text = rtl("🗓 تاریخ ارسال را به وقت جهانی UTC انتخاب کن.");
  await sendMsg(env, chatId, headerMsg ? `${headerMsg}\n\n${text}` : text, {
    keyboard: [[{
      text: "📅 انتخاب تاریخ",
      web_app: { url: `${env.PUBLIC_WORKER_URL}?action=schedule-date-picker` },
    }], [{ text: CANCEL_BUTTON }]],
    resize_keyboard: true,
  });
  return new Response("OK");
}

async function sendScheduleTimePicker(env, chatId, headerMsg) {
  const text = rtl("🕒 ساعت ارسال را به وقت جهانی UTC انتخاب کن.");
  await sendMsg(env, chatId, headerMsg ? `${headerMsg}\n\n${text}` : text, {
    keyboard: [[{
      text: "🕒 انتخاب ساعت",
      web_app: { url: `${env.PUBLIC_WORKER_URL}?action=schedule-time-picker` },
    }], [{ text: CANCEL_BUTTON }]],
    resize_keyboard: true,
  });
  return new Response("OK");
}

async function handlePickedScheduleTime(env, chatId, time) {
  const raw = await kv.get(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`);
  let draft;
  try { draft = JSON.parse(raw || ""); } catch (_) { draft = null; }
  if (!draft?.date) return await sendPushPanel(env, chatId, rtl("⚠️ تاریخ انتخاب‌شده پیدا نشد؛ دوباره شروع کن."));

  const match = time.match(/^(\d{2}):(\d{2}) (AM|PM)$/);
  let hour = Number(match[1]) % 12;
  if (match[3] === "PM") hour += 12;
  const scheduleAt = new Date(`${draft.date}T${String(hour).padStart(2, "0")}:${match[2]}:00.000Z`);
  if (Number.isNaN(scheduleAt.getTime()) || scheduleAt.getTime() <= Date.now() + 60_000) {
    await sendMsg(env, chatId, rtl("❌ تاریخ یا ساعت باید حداقل یک دقیقه در آینده باشد."));
    return await sendScheduleDatePicker(env, chatId);
  }
  await kv.put(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`, JSON.stringify({
    scheduleAt: scheduleAt.toISOString(),
    displayAt: `${draft.date} ${time} UTC`,
  }), { expirationTtl: 900 });
  return await sendPrompt(env, chatId, "push_schedule_body", rtlBlock("✍️ حالا متن اعلان را بفرست."));
}

function schedulePickerPage(mode) {
  const isDate = mode === "date";
  const title = isDate ? "انتخاب تاریخ (UTC)" : "انتخاب ساعت (UTC)";
  const control = isDate
    ? '<div class="date"><label>سال<select id="year"></select></label><label>ماه<select id="month"></select></label><label>روز<select id="day"></select></label></div>'
    : '<div class="times"><select id="hour"></select><span>:</span><select id="minute"></select><select id="ampm"><option>AM</option><option>PM</option></select></div>';
  const script = isDate
    ? 'const value=`${year.value}-${month.value}-${day.value}`;Telegram.WebApp.sendData(JSON.stringify({action:"schedule_date",date:value}));'
    : 'const value=`\${hour.value}:\${minute.value} \${ampm.value}`;Telegram.WebApp.sendData(JSON.stringify({action:"schedule_time",time:value}));';
  const setup = isDate
    ? 'const n=new Date(),y=n.getUTCFullYear();for(let i=y;i<=y+5;i++)year.add(new Option(i,i));for(let i=1;i<=12;i++)month.add(new Option(String(i).padStart(2,"0"),String(i).padStart(2,"0")));month.value=String(n.getUTCMonth()+1).padStart(2,"0");function days(){const c=Number(day.value)||n.getUTCDate(),max=new Date(Date.UTC(Number(year.value),Number(month.value),0)).getUTCDate();day.innerHTML="";for(let i=1;i<=max;i++)day.add(new Option(String(i).padStart(2,"0"),String(i).padStart(2,"0")));day.value=String(Math.min(c,max)).padStart(2,"0");}year.onchange=days;month.onchange=days;days();'
    : 'for(let i=1;i<=12;i++)hour.add(new Option(String(i).padStart(2,"0")));for(let i=0;i<60;i++)minute.add(new Option(String(i).padStart(2,"0")));';
  const hint = isDate ? "سال، ماه و روز را انتخاب کن" : "ساعت و دقیقه را انتخاب کن";
  return new Response(`<!doctype html><html lang="fa" dir="rtl"><head><meta name="viewport" content="width=device-width,initial-scale=1"><script src="https://telegram.org/js/telegram-web-app.js"></script><style>body{margin:0;background:#101828;color:#fff;font:16px -apple-system,BlinkMacSystemFont,sans-serif}.wrap{padding:28px 20px;text-align:center}h1{font-size:21px;margin-bottom:8px}.hint{color:#cbd5e1}.card{margin-top:24px;background:#1d2939;padding:22px;border-radius:20px}select{font-size:18px;padding:12px 8px;border-radius:12px;border:0;background:#fff;color:#111;min-width:72px}.date,.times{display:flex;gap:8px;justify-content:center;align-items:center;direction:ltr}.date label{display:flex;flex-direction:column;gap:7px;color:#cbd5e1;font-size:13px;direction:rtl}.date #year{min-width:92px}.times select{width:82px}button{margin-top:28px;border:0;border-radius:14px;padding:14px 24px;background:#2f80ed;color:#fff;font-size:16px;font-weight:700;width:100%}</style></head><body><div class="wrap"><h1>${title}</h1><div class="hint">${hint}</div><div class="card">${control}</div><button onclick='submitChoice()'>تأیید</button></div><script>const Telegram=window.Telegram;Telegram.WebApp.ready();${setup}function submitChoice(){${script}}</script></body></html>`, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

async function handlePushScheduleBody(env, chatId, value) {
  const body = String(value || "").replace(/\s+/g, " ").trim();
  const raw = await kv.get(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`);
  let draft;
  try { draft = JSON.parse(raw || ""); } catch (_) { draft = null; }
  if (!draft?.scheduleAt) {
    return await sendMenu(env, chatId, rtl("⚠️ زمان انتخاب‌شده پیدا نشد؛ دوباره زمان‌بندی را شروع کن."));
  }
  if (!body || body.length > 512) {
    return await sendPrompt(env, chatId, "push_schedule_body", rtlBlock("❌ متن باید بین ۱ تا ۵۱۲ کاراکتر باشد."));
  }
  const id = crypto.randomUUID();
  await kv.put(env, `${PUSH_SCHEDULE_PREFIX}${id}`, JSON.stringify({
    id, title: "CyloStack", body, scheduleAt: draft.scheduleAt, displayAt: draft.displayAt,
    status: "scheduled", createdAt: new Date().toISOString(),
  }), { expirationTtl: 2592000 });
  await kv.delete(env, `${PUSH_SCHEDULE_DRAFT_PREFIX}${chatId}`);
  return await sendMenu(env, chatId, rtl(`✅ اعلان برای *${draft.displayAt}* زمان‌بندی شد.`));
}

async function runScheduledPush(env) {
  const store = getKV(env);
  if (!store) return;
  const now = Date.now();
  let cursor;
  do {
    const page = await store.list({ prefix: PUSH_SCHEDULE_PREFIX, cursor, limit: 1000 });
    for (const { name } of page.keys) {
      const raw = await kv.get(env, name);
      let schedule;
      try { schedule = JSON.parse(raw || ""); } catch (_) { schedule = null; }
      if (!schedule || schedule.status !== "scheduled" || Date.parse(schedule.scheduleAt) > now) continue;
      // The state is changed before enqueueing, so the job is dispatched only once.
      schedule.status = "queued";
      schedule.queuedAt = new Date().toISOString();
      await kv.put(env, name, JSON.stringify(schedule), { expirationTtl: 2592000 });
      const recipients = await enqueuePushBroadcast(env, schedule, "scheduled");
      if (recipients === null) {
        schedule.status = "scheduled";
        await kv.put(env, name, JSON.stringify(schedule), { expirationTtl: 2592000 });
        continue;
      }
      schedule.status = "sent_to_queue";
      schedule.recipients = recipients;
      await kv.put(env, name, JSON.stringify(schedule), { expirationTtl: 2592000 });
      console.log(JSON.stringify({ event: "scheduled_push_queued", scheduleID: schedule.id, recipients }));
    }
    cursor = page.list_complete ? null : page.cursor;
  } while (cursor);
}

function base64UrlText(value) {
  return toBase64Url(new TextEncoder().encode(value));
}

function pemToArrayBuffer(pem) {
  const base64 = String(pem).replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  return Uint8Array.from(binary, char => char.charCodeAt(0)).buffer;
}

async function makeAPNsAuthorization(env) {
  const header = base64UrlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const payload = base64UrlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("pkcs8", pemToArrayBuffer(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(signingInput));
  return `bearer ${signingInput}.${toBase64Url(new Uint8Array(signature))}`;
}

async function sendAPNs(env, authorization, record, title, body, badge) {
  const host = record.environment === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
  const response = await fetch(`${host}/3/device/${encodeURIComponent(record.token)}`, {
    method: "POST",
    headers: {
      authorization,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title, body }, sound: "default", ...(Number.isInteger(badge) ? { badge } : {}) },
    }),
  });
  let reason = "";
  if (!response.ok) {
    const json = await response.json().catch(() => null);
    reason = typeof json?.reason === "string" ? json.reason : "APNsError";
  }
  return { ok: response.ok, status: response.status, reason };
}

async function handleBroadcastPage(env, job) {
  const raw = await kv.get(env, `${PUSH_BROADCAST_PREFIX}${job.broadcastID}`);
  let broadcast;
  try { broadcast = JSON.parse(raw || ""); } catch (_) { broadcast = null; }
  if (!broadcast?.body) return;

  const store = getKV(env);
  if (!store || !env.PUSH_QUEUE) return;
  const page = await store.list({ prefix: "push_token_", cursor: job.cursor || undefined, limit: 1000 });
  const deviceJobs = page.keys.map(({ name }) => ({
    body: { kind: "deliver", broadcastID: job.broadcastID, tokenKey: name, title: broadcast.title, body: broadcast.body },
  }));
  for (let index = 0; index < deviceJobs.length; index += 100) {
    await env.PUSH_QUEUE.sendBatch(deviceJobs.slice(index, index + 100));
  }
  if (!page.list_complete) {
    await env.PUSH_QUEUE.send({ kind: "broadcast_page", broadcastID: job.broadcastID, cursor: page.cursor });
  }
}

async function handlePushQueue(batch, env, _ctx) {
  if (!isPushConfigured(env)) {
    for (const message of batch.messages) message.ack();
    console.error("Push queue received a job before APNs was configured");
    return;
  }

  const authorization = await makeAPNsAuthorization(env);
  for (const message of batch.messages) {
    const job = message.body;
    if (job?.kind === "broadcast_page") {
      await handleBroadcastPage(env, job);
      message.ack();
      continue;
    }
    if (job?.kind !== "deliver" || !job.tokenKey) {
      message.ack();
      continue;
    }

    const raw = await kv.get(env, job.tokenKey);
    let record;
    try { record = JSON.parse(raw || ""); } catch (_) { record = null; }
    if (!record?.token) {
      message.ack();
      continue;
    }

    const nextBadge = Math.max(0, Number(record.badge) || 0) + 1;
    let result = await sendAPNs(env, authorization, record, job.title, job.body, nextBadge);
    if (result.reason === "BadDeviceToken") {
      // APNs device tokens are bound to sandbox or production. A build can be
      // installed in a different channel than its compile configuration implies,
      // so make one safe fallback attempt before treating the token as invalid.
      const alternateEnvironment = record.environment === "sandbox" ? "production" : "sandbox";
      const alternate = { ...record, environment: alternateEnvironment };
      const alternateResult = await sendAPNs(env, authorization, alternate, job.title, job.body, nextBadge);
      if (alternateResult.ok) {
        record.environment = alternateEnvironment;
        await kv.put(env, job.tokenKey, JSON.stringify(record));
        result = alternateResult;
      } else {
        result = alternateResult;
      }
    }
    if (result.ok) {
      await kv.put(env, job.tokenKey, JSON.stringify({ ...record, badge: nextBadge }));
      await recordPushOutcome(env, job.broadcastID, "accepted", job.tokenKey);
      message.ack();
    } else if (result.status === 410 || (result.status === 400 && ["BadDeviceToken", "Unregistered"].includes(result.reason))) {
      // Only these APNs responses prove that this particular device token is no
      // longer usable. Other HTTP 400 responses can be a topic/configuration
      // problem and must not silently delete a valid subscriber.
      await kv.delete(env, job.tokenKey);
      await recordPushOutcome(env, job.broadcastID, "invalid", job.tokenKey, result);
      message.ack();
    } else if ((result.status === 429 || result.status >= 500) && message.attempts < 5) {
      message.retry({ delaySeconds: Math.min(300, 30 * message.attempts) });
    } else {
      console.error(`APNs delivery failed: HTTP ${result.status} (${result.reason})`);
      await recordPushOutcome(env, job.broadcastID, "failed", job.tokenKey, result);
      message.ack();
    }
  }
}

/// Each device outcome is its own KV marker instead of a shared counter: Queue
/// consumers run concurrently, so read-modify-write counters would lose results.
async function recordPushOutcome(env, broadcastID, outcome, tokenKey, result = null) {
  if (!broadcastID || !tokenKey) return;
  const tokenID = tokenKey.replace(/^push_token_/, "");
  const detail = result ? `${result.status}:${result.reason || "APNsError"}` : "ok";
  await kv.put(env, `push_outcome_${broadcastID}_${outcome}_${tokenID}`, detail, { expirationTtl: 604800 });
}

async function latestPushOutcomeDetail(env, prefix) {
  const store = getKV(env);
  if (!store) return "";
  const page = await store.list({ prefix, limit: 1 });
  return page.keys[0] ? (await kv.get(env, page.keys[0].name) || "") : "";
}

async function sendPushPanel(env, chatId) {
  await sendMsg(env, chatId, rtl("🔔 *ارسال اعلان*\n\nنوع ارسال را انتخاب کن."), {
    keyboard: [
      [{ text: "⚡️ ارسال فوری" }, { text: "🗓 ارسال زمان‌دار" }],
      [{ text: "🧪 تست یک دستگاه" }, { text: "📊 گزارش ارسال‌ها" }],
      [{ text: "🔙 بازگشت به پنل" }],
    ],
    resize_keyboard: true,
  });
  return new Response("OK");
}

async function sendPushReports(env, chatId, requestedPage = 0, editMessageID = null) {
  const store = getKV(env);
  if (!store) return await sendMenu(env, chatId, rtl("⚠️ گزارش در دسترس نیست."));
  const [broadcastPage, scheduledPage] = await Promise.all([
    store.list({ prefix: PUSH_BROADCAST_PREFIX, limit: 1000 }),
    store.list({ prefix: PUSH_SCHEDULE_PREFIX, limit: 1000 }),
  ]);
  const items = [];
  for (const { name } of broadcastPage.keys) {
    const raw = await kv.get(env, name);
    try {
      const broadcast = JSON.parse(raw || "");
      if (broadcast?.requestedAt) items.push({ kind: "broadcast", id: name.slice(PUSH_BROADCAST_PREFIX.length), sortAt: broadcast.requestedAt, ...broadcast });
    } catch (_) {}
  }
  for (const { name } of scheduledPage.keys) {
    const raw = await kv.get(env, name);
    try {
      const schedule = JSON.parse(raw || "");
      if (schedule?.status === "scheduled" && schedule?.scheduleAt) items.push({ kind: "scheduled", id: name.slice(PUSH_SCHEDULE_PREFIX.length), sortAt: schedule.scheduleAt, ...schedule });
    } catch (_) {}
  }
  if (!items.length) {
    await sendMsg(env, chatId, rtl("📊 هنوز هیچ اعلانی ارسال نشده است."), {
      keyboard: [[{ text: "📣 ارسال اعلان" }], [{ text: "🔙 بازگشت به پنل" }]], resize_keyboard: true,
    });
    return new Response("OK");
  }

  items.sort((a, b) => Date.parse(b.sortAt) - Date.parse(a.sortAt));
  const perPage = 3;
  const totalPages = Math.ceil(items.length / perPage);
  const page = Math.min(requestedPage, totalPages - 1);
  const pageItems = items.slice(page * perPage, (page + 1) * perPage);
  const rows = await Promise.all(pageItems.map(async item => {
    if (item.kind === "scheduled") {
      return [rtl(`🗓 زمان‌دار: ${item.displayAt || new Date(item.scheduleAt).toISOString()}`), rtl(`متن: ${item.body.slice(0, 80)}`)].join("\n");
    }
    const when = new Date(item.requestedAt).toISOString().replace("T", " ").slice(0, 16) + " UTC";
    if (item.trackingVersion !== 1) return [rtl(`📨 ${when}`), rtl(`متن: ${item.body.slice(0, 80)}`), rtl("ℹ️ نتیجهٔ تحویل برای این ارسال قدیمی ثبت نشده است.")].join("\n");
    const prefix = `push_outcome_${item.id}_`;
    const [accepted, invalid, failed] = await Promise.all([
      countKeys(env, `${prefix}accepted_`), countKeys(env, `${prefix}invalid_`), countKeys(env, `${prefix}failed_`),
    ]);
    const queued = Math.max(0, (item.recipients || 0) - accepted - invalid - failed);
    return [rtl(`📨 ${when}`), rtl(`متن: ${item.body.slice(0, 80)}`), rtl(`✅ تحویل APNs: ${accepted} | ⏳ در صف: ${queued} | ❌ ناموفق: ${invalid + failed}`)].join("\n");
  }));
  const inlineKeyboard = pageItems.filter(item => item.kind === "scheduled").map(item => ([{
    text: `لغو ${item.displayAt || "زمان‌بندی"}`, callback_data: `cancel_schedule:${item.id}`,
  }]));
  const navigation = [];
  if (page > 0) navigation.push({ text: "◀️ قبلی", callback_data: `report_page:${page - 1}` });
  if (page < totalPages - 1) navigation.push({ text: "بعدی ▶️", callback_data: `report_page:${page + 1}` });
  if (navigation.length) inlineKeyboard.push(navigation);
  const reportText = rtl(`📊 *گزارش‌ها — صفحه ${page + 1} از ${totalPages}*`) + "\n\n" + rows.join("\n\n");
  if (editMessageID) {
    await editMsg(env, chatId, editMessageID, reportText, { inline_keyboard: inlineKeyboard });
  } else {
    await sendMsg(env, chatId, reportText, { inline_keyboard: inlineKeyboard });
  }
  return new Response("OK");
}

async function cancelScheduledPush(env, chatId, id) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return await sendPushReports(env, chatId);
  const key = `${PUSH_SCHEDULE_PREFIX}${id}`;
  const raw = await kv.get(env, key);
  let schedule;
  try { schedule = JSON.parse(raw || ""); } catch (_) { schedule = null; }
  if (!schedule || schedule.status !== "scheduled") {
    await sendMsg(env, chatId, rtl("⚠️ این زمان‌بندی دیگر قابل لغو نیست."));
    return await sendPushReports(env, chatId);
  }
  await kv.delete(env, key);
  await sendMsg(env, chatId, rtl("🛑 ارسال زمان‌دار لغو شد."));
  return await sendPushReports(env, chatId);
}

async function sendAdsPanel(env, chatId, headerMsg) {
  const [adsRaw, appOpenRaw, interstitialRaw, rewardedRaw] = await Promise.all([
    kv.get(env, "ads_enabled"), kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "interstitial_ads_enabled"), kv.get(env, "rewarded_ads_enabled"),
  ]);
  const adsOn = adsRaw !== "false";
  const appOpenOn = appOpenRaw !== null ? appOpenRaw !== "false" : adsOn;
  const interstitialOn = interstitialRaw !== null ? interstitialRaw !== "false" : adsOn;
  const rewardedOn = rewardedRaw !== null ? rewardedRaw !== "false" : adsOn;
  const dot = on => on ? "🟢 روشن" : "🔴 خاموش";
  const body = [
    rtl("📢 *تبلیغات*"), "",
    rtl(`کلی: ${dot(adsOn)}`),
    rtl(`ورودی اپ: ${dot(appOpenOn)}`),
    rtl(`بین‌برنامه‌ای: ${dot(interstitialOn)}`),
    rtl(`جایزه‌دار: ${dot(rewardedOn)}`),
  ].join("\n");
  await sendMsg(env, chatId, headerMsg ? `${headerMsg}\n\n${body}` : body, {
    keyboard: [
      [{ text: adsOn ? "⛔️ خاموش کردن تبلیغات" : "✅ روشن کردن تبلیغات" }],
      [
        { text: appOpenOn ? "⛔️ خاموش کردن ورودی اپ" : "✅ روشن کردن ورودی اپ" },
        { text: interstitialOn ? "⛔️ خاموش کردن بین‌برنامه‌ای" : "✅ روشن کردن بین‌برنامه‌ای" },
      ],
      [{ text: rewardedOn ? "⛔️ خاموش کردن جایزه‌دار" : "✅ روشن کردن جایزه‌دار" }],
      [{ text: "🔙 بازگشت به پنل" }],
    ],
    resize_keyboard: true,
  });
  return new Response("OK");
}

async function sendVersionsPanel(env, chatId) {
  const [version, forceUpdateRaw] = await Promise.all([
    kv.get(env, "latest_version"), kv.get(env, "force_update"),
  ]);
  const forceUpdateOn = forceUpdateRaw === "true";
  await sendMsg(env, chatId, [
    rtl("📦 *نسخه‌ها*"), "",
    rtl(`نسخهٔ فعلی: *${version || "1.0.0"}*`),
    rtl(`آپدیت اجباری: ${forceUpdateOn ? "روشن" : "خاموش"}`),
  ].join("\n"), {
    keyboard: [
      [{ text: "🚀 تنظیم نسخه جدید" }],
      [{ text: forceUpdateOn ? "🔓 خاموش کردن آپدیت اجباری" : "🔒 روشن کردن آپدیت اجباری" }],
      [{ text: "🔙 بازگشت به پنل" }],
    ],
    resize_keyboard: true,
  });
  return new Response("OK");
}

async function sendLinksPanel(env, chatId) {
  const [appstoreURL, privacyURL] = await Promise.all([
    kv.get(env, "appstore_url"), kv.get(env, "privacy_url"),
  ]);
  await sendMsg(env, chatId, [
    rtl("🔗 *مدیریت لینک‌ها*"), "",
    rtl(`اپ استور: ${appstoreURL || "ثبت نشده"}`),
    rtl(`حریم خصوصی: ${privacyURL || "ثبت نشده"}`),
  ].join("\n"), {
    keyboard: [
      [{ text: "🍎 تنظیم لینک اپ استور" }],
      [{ text: "🔒 تنظیم لینک حریم خصوصی" }],
      [{ text: "🔙 بازگشت به پنل" }],
    ],
    resize_keyboard: true,
  });
  return new Response("OK");
}

// ════════════════════════════════════════════════════════════════════
//  Send Menu (Stats + Buttons)
// ════════════════════════════════════════════════════════════════════
async function sendMenu(env, chatId, headerMsg) {
  const today = iranToday();

  const yesterday = new Date(Date.now() + 3.5 * 3600000 - 86400000).toISOString().slice(0, 10);

  const [adsRaw, appOpenRaw, interstitialRaw, rewardedRaw, version,
         totalInstalls, todayActive, yesterdayActive, forceUpdateRaw, pushRecipients] = await Promise.all([
    kv.get(env, "ads_enabled"),
    kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "interstitial_ads_enabled"),
    kv.get(env, "rewarded_ads_enabled"),
    kv.get(env, "latest_version"),
    countKeys(env, "install_"),
    countKeys(env, `dau_${today}_`),
    countKeys(env, `dau_${yesterday}_`),
    kv.get(env, "force_update"),
    countKeys(env, "push_token_"),
  ]);

  const adsOn          = adsRaw          !== "false";
  const appOpenOn      = appOpenRaw      !== null ? appOpenRaw      !== "false" : adsOn;
  const interstitialOn = interstitialRaw !== null ? interstitialRaw !== "false" : adsOn;
  const rewardedOn     = rewardedRaw     !== null ? rewardedRaw     !== "false" : adsOn;
  const forceUpdateOn  = forceUpdateRaw  === "true";

  const dot = on => (on ? "🟢 روشن" : "🔴 خاموش");

  // Every line carries the RTL mark so the Latin ad-format names sit inside a
  // right-to-left paragraph instead of flipping their own line's alignment.
  const statsMsg = [
    rtl("📊 *پنل کنترل CyloStack*"),
    "",
    rtl(`📥 کل نصب‌ها: *${totalInstalls || 0}*`),
    rtl(`👥 فعال امروز: *${todayActive || 0}*`),
    rtl(`📆 فعال دیروز: *${yesterdayActive || 0}*`),
    "",
    rtl("— — — نسخه — — —"),
    rtl(`🚀 آخرین نسخه: *${version || "1.0.0"}*`),
    rtl(`🔔 دستگاه‌های آمادهٔ اعلان: *${pushRecipients || 0}*`),
  ].join("\n");

  const fullMsg = headerMsg ? `${headerMsg}\n\n${statsMsg}` : statsMsg;

  await sendMsg(env, chatId, fullMsg, {
    keyboard: [
      [
        { text: "📢 تبلیغات" },
      ],
      [
        { text: "📦 نسخه‌ها" },
        { text: "🔗 مدیریت لینک‌ها" },
      ],
      [
        { text: "👥 مدیریت دسترسی" },
      ],
      [
        { text: "📣 ارسال اعلان" },
      ],
      [
        { text: "📊 بروزرسانی آمار" },
      ],
    ],
    resize_keyboard: true,
  });

  return new Response("OK");
}

// ════════════════════════════════════════════════════════════════════
//  Telegram API Helpers
// ════════════════════════════════════════════════════════════════════
async function editMsg(env, chatId, messageID, text, replyMarkup) {
  const body = {
    chat_id: chatId,
    message_id: messageID,
    text,
    parse_mode: "Markdown",
    reply_markup: replyMarkup,
  };
  try {
    await fetch(`${getTelegramApi(env)}/editMessageText`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
  } catch (error) {
    console.error("editMsg error:", error);
  }
}

async function sendMsg(env, chatId, text, replyMarkup) {
  const body = {
    chat_id:    chatId,
    text:       text,
    parse_mode: "Markdown",
  };
  if (replyMarkup) {
    if (Array.isArray(replyMarkup)) {
      body.reply_markup = { keyboard: replyMarkup, resize_keyboard: true };
    } else if (replyMarkup.keyboard && Array.isArray(replyMarkup.keyboard)) {
      body.reply_markup = replyMarkup;
    } else if (replyMarkup.inline_keyboard && Array.isArray(replyMarkup.inline_keyboard)) {
      body.reply_markup = replyMarkup;
    } else {
      body.reply_markup = { keyboard: replyMarkup, resize_keyboard: true };
    }
  }

  try {
    const res = await fetch(`${getTelegramApi(env)}/sendMessage`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify(body),
    });
    const resText = await res.text();
    // Never persist the API URL here — it contains the bot token.
    await kv.put(env, "debug_last_send_result", JSON.stringify({
      status: res.status,
      ok: res.ok,
      response: resText.slice(0, 500),
    })).catch(() => {});
    if (!res.ok) {
      delete body.parse_mode;
      await fetch(`${getTelegramApi(env)}/sendMessage`, {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify(body),
      });
    }
  } catch (e) {
    await kv.put(env, "debug_last_send_result", JSON.stringify({
      error: String(e)
    })).catch(() => {});
    console.error("sendMsg error:", e);
  }
}

/// Asks for a value and leaves a visible way out.
///
/// This used to use `force_reply`, which hides the custom keyboard — so once the bot
/// asked a question there was no button to press and the only way back was to answer
/// it. Now the pending question is remembered and a cancel key stays on screen, so
/// changing your mind mid-task is one tap.
async function sendPrompt(env, chatId, action, text) {
  await kv.put(env, `pending_${chatId}`, action, { expirationTtl: 900 });
  await sendMsg(env, chatId, text, {
    keyboard: [[{ text: CANCEL_BUTTON }]],
    resize_keyboard: true,
  });
  return new Response("OK");
}
