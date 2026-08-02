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

// ─── Admin Check Helper ─────────────────────────────────────────────
async function isAdmin(env, userId) {
  if (!userId) return false;
  if (Number(userId) === MASTER_ADMIN_ID) return true;

  // Check additional authorized admins from KV
  try {
    const rawAdmins = await kv.get(env, "admin_user_ids");
    if (rawAdmins) {
      const adminList = JSON.parse(rawAdmins);
      if (Array.isArray(adminList) && adminList.includes(Number(userId))) {
        return true;
      }
    }
  } catch (_) {}
  return false;
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
//  GET — iOS App fetches remote config
// ════════════════════════════════════════════════════════════════════
async function handleGet(request, env) {
  const url   = new URL(request.url);
  const event = url.searchParams.get("event") || "";
  const uuid  = url.searchParams.get("uuid")  || "anon";

  // Track analytics without blocking response
  trackEvent(env, event, uuid).catch(() => {});

  // Read config values
  const [adsRaw, appOpenRaw, rewardedRaw, version, appstoreURL, privacyURL] = await Promise.all([
    kv.get(env, "ads_enabled"),
    kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "rewarded_ads_enabled"),
    kv.get(env, "latest_version"),
    kv.get(env, "appstore_url"),
    kv.get(env, "privacy_url"),
  ]);

  const adsEnabled      = adsRaw      !== "false";
  const appOpenEnabled  = appOpenRaw  !== null ? appOpenRaw  !== "false" : adsEnabled;
  const rewardedEnabled = rewardedRaw !== null ? rewardedRaw !== "false" : adsEnabled;

  const lastUpdateRaw = await kv.get(env, "debug_last_update");
  let lastUpdate = "NO_UPDATE_RECEIVED_YET";
  try { if (lastUpdateRaw) lastUpdate = JSON.parse(lastUpdateRaw); } catch (_) {}

  const lastSendRaw = await kv.get(env, "debug_last_send_result");
  let lastSend = "NO_SEND_LOGGED_YET";
  try { if (lastSendRaw) lastSend = JSON.parse(lastSendRaw); } catch (_) {}

  return new Response(JSON.stringify({
    ads_enabled:           adsEnabled,
    app_open_ads_enabled:  appOpenEnabled,
    rewarded_ads_enabled:  rewardedEnabled,
    latest_version:        version      || "1.0.0",
    appstore_url:          appstoreURL  || "",
    privacy_url:           privacyURL   || "",
    debug_kv_status:       getKV(env) ? "KV_BOUND" : "KV_NOT_BOUND",
    debug_bot_token_status: env?.BOT_TOKEN ? `SET (len:${env.BOT_TOKEN.length})` : "NOT_SET",
    debug_last_update:     lastUpdate,
    debug_last_send_result: lastSend,
  }), {
    headers: {
      "Content-Type":                "application/json",
      "Access-Control-Allow-Origin": "*",
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
  const fromUser   = update.message?.from || update.callback_query?.from || update.edited_message?.from;
  const userId     = fromUser?.id;

  if (!chatId || !userId) return new Response("OK");

  // 🔒 Security Barrier: Block non-admin users
  const authorized = await isAdmin(env, userId);
  if (!authorized) {
    await sendMsg(env, chatId, `⛔️ *دسترسی غیرمجاز!*\n\nآیدی تلگرام شما (\`${userId}\`) در لیست مدیران تاییدشده ثبت نشده است.`);
    return new Response("OK");
  }

  const text       = (update.message?.text || update.callback_query?.data || "").trim();
  const replyText  = (update.message?.reply_to_message?.text || "").toLowerCase();

  // ── Admin Access Management Commands ─────────────────────────────
  if (text.startsWith("/addadmin ")) {
    const newAdminId = Number(text.slice(10).trim());
    if (isNaN(newAdminId) || newAdminId <= 0) {
      await sendMsg(env, chatId, "❌ آیدی عددی غیرمجاز است.\nمثال: `/addadmin 123456789`");
      return new Response("OK");
    }
    let currentAdmins = [];
    try { currentAdmins = JSON.parse(await kv.get(env, "admin_user_ids") || "[]"); } catch (_) {}
    if (!currentAdmins.includes(newAdminId)) {
      currentAdmins.push(newAdminId);
      await kv.put(env, "admin_user_ids", JSON.stringify(currentAdmins));
    }
    await sendMsg(env, chatId, `✅ آیدی عددی \`${newAdminId}\` با موفقیت به ادمین‌های ربات اضافه شد.`);
    return new Response("OK");
  }

  if (text.startsWith("/removeadmin ")) {
    const remAdminId = Number(text.slice(13).trim());
    let currentAdmins = [];
    try { currentAdmins = JSON.parse(await kv.get(env, "admin_user_ids") || "[]"); } catch (_) {}
    currentAdmins = currentAdmins.filter(id => id !== remAdminId);
    await kv.put(env, "admin_user_ids", JSON.stringify(currentAdmins));
    await sendMsg(env, chatId, `🗑 آیدی عددی \`${remAdminId}\` از ادمین‌ها حذف شد.`);
    return new Response("OK");
  }

  // ── 1. Force Reply responses ────────────────────────────────────
  if (update.message?.reply_to_message) {
    if (replyText.includes("شماره نسخه")) {
      return await handleSetVersion(env, chatId, text);
    }
    if (replyText.includes("اپ استور") || replyText.includes("appstore")) {
      return await handleSetAppstore(env, chatId, text);
    }
    if (replyText.includes("حریم خصوصی") || replyText.includes("privacy")) {
      return await handleSetPrivacy(env, chatId, text);
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
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendMenu(env, chatId, "⛔️ همه تبلیغات خاموش شد.");
  }
  if (text.includes("روشن کردن تبلیغات") || text === "ENABLE_ADS") {
    await kv.put(env, "ads_enabled", "true");
    await kv.put(env, "app_open_ads_enabled", "true");
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendMenu(env, chatId, "✅ همه تبلیغات روشن شد.");
  }
  if (text.includes("خاموش کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "false");
    return await sendMenu(env, chatId, "⛔️ تبلیغ App Open خاموش شد.");
  }
  if (text.includes("روشن کردن App Open")) {
    await kv.put(env, "app_open_ads_enabled", "true");
    return await sendMenu(env, chatId, "✅ تبلیغ App Open روشن شد.");
  }
  if (text.includes("خاموش کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "false");
    return await sendMenu(env, chatId, "⛔️ تبلیغ Rewarded خاموش شد.");
  }
  if (text.includes("روشن کردن Rewarded")) {
    await kv.put(env, "rewarded_ads_enabled", "true");
    return await sendMenu(env, chatId, "✅ تبلیغ Rewarded روشن شد.");
  }
  if (text.includes("نسخه جدید") || text === "/version") {
    await sendForceReply(env, chatId, "📝 شماره نسخه جدید را وارد کنید (مثال: 2.0.0):\n\n💡 یا از دستور مستقیم استفاده کن:\n/setversion 2.0.0");
    return new Response("OK");
  }
  if (text.includes("لینک اپ استور") || text === "/appstore") {
    await sendForceReply(env, chatId, "📝 لینک اپ استور را وارد کنید:\n\n💡 یا از دستور مستقیم:\n/setappstore https://apps.apple.com/app/id...");
    return new Response("OK");
  }
  if (text.includes("حریم خصوصی") || text === "/privacy") {
    await sendForceReply(env, chatId, "📝 لینک حریم خصوصی privacy را وارد کنید:\n\n💡 یا از دستور مستقیم:\n/setprivacy https://...");
    return new Response("OK");
  }

  // ── 4. Default: show stats + menu ──────────────────────────────
  return await sendMenu(env, chatId, null);
}

// ════════════════════════════════════════════════════════════════════
//  Set Helpers
// ════════════════════════════════════════════════════════════════════
async function handleSetVersion(env, chatId, value) {
  if (!/^\d+(\.\d+)+$/.test(value)) {
    await sendMsg(env, chatId, "❌ فرمت نسخه اشتباه است.\nمثال صحیح: 2.0.0 یا 1.2.3");
    return new Response("OK");
  }
  await kv.put(env, "latest_version", value);
  return await sendMenu(env, chatId, `🚀 نسخه با موفقیت ثبت شد: *${value}*`);
}

async function handleSetAppstore(env, chatId, value) {
  if (!value.startsWith("http")) {
    await sendMsg(env, chatId, "❌ لینک باید با https:// شروع شود.");
    return new Response("OK");
  }
  await kv.put(env, "appstore_url", value);
  return await sendMenu(env, chatId, `🍎 لینک App Store ثبت شد:\n${value}`);
}

async function handleSetPrivacy(env, chatId, value) {
  if (!value.startsWith("http")) {
    await sendMsg(env, chatId, "❌ لینک باید با https:// شروع شود.");
    return new Response("OK");
  }
  await kv.put(env, "privacy_url", value);
  return await sendMenu(env, chatId, `🔒 لینک حریم خصوصی ثبت شد:\n${value}`);
}

// ════════════════════════════════════════════════════════════════════
//  Send Menu (Stats + Buttons)
// ════════════════════════════════════════════════════════════════════
async function sendMenu(env, chatId, headerMsg) {
  const today = iranToday();

  const [adsRaw, appOpenRaw, rewardedRaw, version, appstoreURL, privacyURL,
         totalInstalls, todayActive] = await Promise.all([
    kv.get(env, "ads_enabled"),
    kv.get(env, "app_open_ads_enabled"),
    kv.get(env, "rewarded_ads_enabled"),
    kv.get(env, "latest_version"),
    kv.get(env, "appstore_url"),
    kv.get(env, "privacy_url"),
    kv.get(env, "total_installs"),
    kv.get(env, `dau_count_${today}`),
  ]);

  const adsOn      = adsRaw      !== "false";
  const appOpenOn  = appOpenRaw  !== null ? appOpenRaw  !== "false" : adsOn;
  const rewardedOn = rewardedRaw !== null ? rewardedRaw !== "false" : adsOn;

  const statsMsg =
    `📊 *CircleStack کنترل پنل*\n\n` +
    `📥 کل نصب‌ها: *${totalInstalls || 0}*\n` +
    `👥 فعال امروز: *${todayActive  || 0}*\n\n` +
    `📢 تبلیغات:  ${adsOn ? "🟢 روشن" : "🔴 خاموش"}\n` +
    `🪟 App Open: ${appOpenOn  ? "🟢 روشن" : "🔴 خاموش"}\n` +
    `🎁 Rewarded: ${rewardedOn ? "🟢 روشن" : "🔴 خاموش"}\n\n` +
    `🚀 نسخه: *${version || "1.0.0"}*\n` +
    `🍎 App Store: ${appstoreURL || "ثبت نشده"}\n` +
    `🔒 Privacy: ${privacyURL   || "ثبت نشده"}`;

  const fullMsg = headerMsg ? `${headerMsg}\n\n${statsMsg}` : statsMsg;

  await sendMsg(env, chatId, fullMsg, {
    keyboard: [
      [
        { text: adsOn ? "⛔️ خاموش کردن تبلیغات" : "✅ روشن کردن تبلیغات" },
      ],
      [
        { text: appOpenOn  ? "⛔️ خاموش کردن App Open"  : "✅ روشن کردن App Open"  },
        { text: rewardedOn ? "⛔️ خاموش کردن Rewarded" : "✅ روشن کردن Rewarded" },
      ],
      [
        { text: "🚀 تنظیم نسخه جدید" },
      ],
      [
        { text: "🍎 تنظیم لینک اپ استور" },
      ],
      [
        { text: "🔒 تنظیم لینک حریم خصوصی" },
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
async function sendMsg(env, chatId, text, keyboard) {
  const body = {
    chat_id:    chatId,
    text:       text,
    parse_mode: "Markdown",
  };
  if (keyboard) body.reply_markup = { keyboard, resize_keyboard: true };

  try {
    const res = await fetch(`${getTelegramApi(env)}/sendMessage`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify(body),
    });
    const resText = await res.text();
    await kv.put(env, "debug_last_send_result", JSON.stringify({
      status: res.status,
      ok: res.ok,
      response: resText,
      apiUrl: getTelegramApi(env)
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

async function sendForceReply(env, chatId, text) {
  const body = {
    chat_id:      chatId,
    text:         text,
    parse_mode:   "Markdown",
    reply_markup: { force_reply: true, selective: true },
  };

  try {
    const res = await fetch(`${getTelegramApi(env)}/sendMessage`, {
      method:  "POST",
      headers: { "Content-Type": "application/json" },
      body:    JSON.stringify(body),
    });
    if (!res.ok) {
      delete body.parse_mode;
      await fetch(`${getTelegramApi(env)}/sendMessage`, {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify(body),
      });
    }
  } catch (e) {
    console.error("sendForceReply error:", e);
  }
}
