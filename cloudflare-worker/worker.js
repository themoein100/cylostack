// ════════════════════════════════════════════════════════════════════
//  CircleStack — Cloudflare Worker  (Remote Config + Telegram Bot)
//  KV Binding: CONFIG_KV / CIRCLESTACK_KV
// ════════════════════════════════════════════════════════════════════

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
};

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
  async fetch(request, env) {
    try {
      if (request.method === "GET")  return await handleGet(request, env);
      if (request.method === "POST") return await handlePost(request, env);
    } catch (e) {
      console.error("Worker error:", e);
    }
    return new Response("CircleStack API Active", { status: 200 });
  },
};

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
async function handleGet(request, env) {
  const url   = new URL(request.url);
  const event = url.searchParams.get("event") || "";
  const uuid  = url.searchParams.get("uuid")  || "anon";

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

  // Only count events from a request that proved it came from the app.
  trackEvent(env, event, uuid).catch(() => {});

  // Read config values
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
  const forceUpdate         = forceUpdateRaw  === "true";

  const payload = {
    ads_enabled:              adsEnabled,
    app_open_ads_enabled:     appOpenEnabled,
    interstitial_ads_enabled: interstitialEnabled,
    rewarded_ads_enabled:     rewardedEnabled,
    latest_version:           version      || "1.0.0",
    appstore_url:             appstoreURL  || "",
    privacy_url:              privacyURL   || "",
    force_update:             forceUpdate,
  };

  const body = await encryptPayload(env, payload);

  return new Response(JSON.stringify(body), {
    headers: {
      "Content-Type":  "application/json",
      "Cache-Control": "no-store",
    },
  });
}

// ════════════════════════════════════════════════════════════════════
//  Analytics — Unique User Tracking
// ════════════════════════════════════════════════════════════════════
async function trackEvent(env, event, uuid) {
  if (!getKV(env) || !event || !uuid) return;
  const today = iranToday();

  if (event === "install") {
    const seen = await kv.get(env, `install_${uuid}`);
    if (!seen) {
      await kv.put(env, `install_${uuid}`, "1");
      const total = parseInt(await kv.get(env, "total_installs") || "0") + 1;
      await kv.put(env, "total_installs", total);
    }
  }

  if (event === "active" || event === "install") {
    const dauKey = `dau_${today}_${uuid}`;
    const seen   = await kv.get(env, dauKey);
    if (!seen) {
      await kv.put(env, dauKey, "1", { expirationTtl: 172800 });
      const count = parseInt(await kv.get(env, `dau_count_${today}`) || "0") + 1;
      await kv.put(env, `dau_count_${today}`, count);
    }
  }
}

// ════════════════════════════════════════════════════════════════════
//  POST — Telegram Webhook with Admin Access Security
// ════════════════════════════════════════════════════════════════════
async function handlePost(request, env) {
  const update = await request.json().catch(() => null);
  console.log("=== TELEGRAM WEBHOOK RECEIVED ===", JSON.stringify(update));
  if (!update) return new Response("OK");

  // 📝 Realtime Debug Log: Save last update received to KV
  try {
    await kv.put(env, "debug_last_update", JSON.stringify({
      time: new Date().toISOString(),
      update: update
    }));
  } catch (_) {}

  const msg        = update.message || update.callback_query?.message || update.edited_message;
  const chatId     = msg?.chat?.id;
  const fromUser   = update.message?.from || update.callback_query?.from || update.edited_message?.from || msg?.from || update.from;
  const userId     = fromUser?.id;
  const username   = fromUser?.username;

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
  const replyText  = (update.message?.reply_to_message?.text || "").toLowerCase();

  // ── 0. Backing out ───────────────────────────────────────────────
  // Checked before anything else, so a cancel is never mistaken for the answer to
  // a question the bot is waiting on.
  const pending = await kv.get(env, `pending_${chatId}`);

  if (isCancel(text)) {
    if (pending) await kv.put(env, `pending_${chatId}`, "", { expirationTtl: 60 });
    return await sendMenu(env, chatId, pending ? rtl("↩️ لغو شد.") : null);
  }

  // ── Access management (owner only) ───────────────────────────────
  // Granting access is the one thing an invited admin must never be able to do,
  // otherwise the first person let in can quietly let everyone else in too.
  const isOwner = Number(userId) === MASTER_ADMIN_ID;

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

  // ── 3. Keyboard button presses ──────────────────────────────────
  if (text.includes("خاموش کردن تبلیغات") || text === "DISABLE_ADS") {
    await kv.put(env, "ads_enabled", "false");
    await kv.put(env, "app_open_ads_enabled", "false");
    await kv.put(env, "interstitial_ads_enabled", "false");
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendMenu(env, chatId, rtl("⛔️ همه تبلیغات خاموش شد."));
  }
  if (text.includes("روشن کردن تبلیغات") || text === "ENABLE_ADS") {
    await kv.put(env, "ads_enabled", "true");
    await kv.put(env, "app_open_ads_enabled", "true");
    await kv.put(env, "interstitial_ads_enabled", "true");
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendMenu(env, chatId, rtl("✅ همه تبلیغات روشن شد."));
  }
  // Older keyboards used the English format names, so both spellings are accepted.
  if (text.includes("خاموش کردن ورودی اپ") || text.includes("خاموش کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "false");
    return await sendMenu(env, chatId, rtl("⛔️ تبلیغ ورودی اپ خاموش شد."));
  }
  if (text.includes("روشن کردن ورودی اپ") || text.includes("روشن کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "true");
    return await sendMenu(env, chatId, rtl("✅ تبلیغ ورودی اپ روشن شد."));
  }
  if (text.includes("خاموش کردن بین‌برنامه‌ای") || text.includes("خاموش کردن Interstitial")) {
    await kv.put(env, "interstitial_ads_enabled", "false");
    return await sendMenu(env, chatId, rtl("⛔️ تبلیغ بین‌برنامه‌ای خاموش شد."));
  }
  if (text.includes("روشن کردن بین‌برنامه‌ای") || text.includes("روشن کردن Interstitial")) {
    await kv.put(env, "interstitial_ads_enabled", "true");
    return await sendMenu(env, chatId, rtl("✅ تبلیغ بین‌برنامه‌ای روشن شد."));
  }
  if (text.includes("خاموش کردن جایزه‌دار") || text.includes("خاموش کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendMenu(env, chatId, rtl("⛔️ تبلیغ جایزه‌دار خاموش شد."));
  }
  if (text.includes("روشن کردن جایزه‌دار") || text.includes("روشن کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendMenu(env, chatId, rtl("✅ تبلیغ جایزه‌دار روشن شد."));
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
//  Send Menu (Stats + Buttons)
// ════════════════════════════════════════════════════════════════════
async function sendMenu(env, chatId, headerMsg) {
  const today = iranToday();

  const yesterday = new Date(Date.now() + 3.5 * 3600000 - 86400000).toISOString().slice(0, 10);

  const [adsRaw, appOpenRaw, interstitialRaw, rewardedRaw, version, appstoreURL, privacyURL,
         totalInstalls, todayActive, yesterdayActive, forceUpdateRaw] = await Promise.all([
    kv.get(env, "ads_enabled"),
    kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "interstitial_ads_enabled"),
    kv.get(env, "rewarded_ads_enabled"),
    kv.get(env, "latest_version"),
    kv.get(env, "appstore_url"),
    kv.get(env, "privacy_url"),
    kv.get(env, "total_installs"),
    kv.get(env, `dau_count_${today}`),
    kv.get(env, `dau_count_${yesterday}`),
    kv.get(env, "force_update"),
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
    rtl("— — — تبلیغات — — —"),
    rtl(`📢 کلی: ${dot(adsOn)}`),
    rtl(`🪟 ورودی اپ: ${dot(appOpenOn)}`),
    rtl(`📺 بین‌برنامه‌ای: ${dot(interstitialOn)}`),
    rtl(`🎁 جایزه‌دار: ${dot(rewardedOn)}`),
    "",
    rtl("— — — نسخه — — —"),
    rtl(`🚀 آخرین نسخه: *${version || "1.0.0"}*`),
    rtl(`${forceUpdateOn ? "🔒" : "🔓"} آپدیت اجباری: ${forceUpdateOn ? "*روشن*" : "خاموش"}`),
    "",
    rtl(`🍎 اپ استور: ${appstoreURL || "ثبت نشده"}`),
    rtl(`🔒 حریم خصوصی: ${privacyURL || "ثبت نشده"}`),
  ].join("\n");

  const fullMsg = headerMsg ? `${headerMsg}\n\n${statsMsg}` : statsMsg;

  await sendMsg(env, chatId, fullMsg, {
    keyboard: [
      [
        { text: adsOn ? "⛔️ خاموش کردن تبلیغات" : "✅ روشن کردن تبلیغات" },
      ],
      [
        { text: appOpenOn      ? "⛔️ خاموش کردن ورودی اپ"      : "✅ روشن کردن ورودی اپ"      },
        { text: interstitialOn ? "⛔️ خاموش کردن بین‌برنامه‌ای" : "✅ روشن کردن بین‌برنامه‌ای" },
      ],
      [
        { text: rewardedOn    ? "⛔️ خاموش کردن جایزه‌دار"     : "✅ روشن کردن جایزه‌دار" },
        { text: forceUpdateOn ? "🔓 خاموش کردن آپدیت اجباری" : "🔒 روشن کردن آپدیت اجباری" },
      ],
      [
        { text: "🚀 تنظیم نسخه جدید" },
        { text: "🍎 تنظیم لینک اپ استور" },
      ],
      [
        { text: "🔒 تنظیم لینک حریم خصوصی" },
        { text: "👥 مدیریت دسترسی" },
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

