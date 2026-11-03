// LumeSource: {"id":"dongpiandi_video","name":"懂片帝","version":"1.1.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://dongpiandi.ai"],"network":"direct","icon":"https://dongpiandi.ai/assets/app-icon-180.png","settings":[{"key":"lineMode","type":"select","title":"线路偏好","default":"direct","options":[{"value":"direct","title":"第三方直链优先（免费，推荐）"},{"value":"official","title":"官方线路优先（1080P/4K，扣站点额度）"}]},{"key":"checkAccount","type":"action","action":"source","title":"检查账号与额度"},{"key":"logout","type":"action","action":"source","title":"退出站点登录"},{"key":"note","type":"info","title":"站点说明","description":"懂片帝（dongpiandi.ai，AI 找片 + 片单 + 播放）：React SPA + 同源 /v1/* JSON 接口，全部请求要 HMAC 签名（源内用宿主原生 tools.hmac 算，失败自动退回纯 JS）。浏览/搜索/详情/选集/直链播放都不需要登录；要「官方线路优先」或看站内额度才需在「账号登入」里填站点账号密码。站点若换域名，在「源设置 → 换网址」里填新域名即可。"}]}
// LumeRuntime: javascript
//
// 站点：懂片帝（dongpiandi.ai；懂片帝AI / 懂片AI）
//   React SPA + 同源 `/v1/*` JSON 接口；首页 HTML 只有 4 KB，所有数据都走接口。
//   实测直连可开，站点前面是 CloudFront。
//
// ── 签名（每个 /v1 请求都要，缺了回 401 Missing request signature）────────────
//   msg = METHOD + "\n" + pathname + search + "\n" + timestamp + "\n" + nonce
//   x-ai-movie-signature = HMAC-SHA256(SIGN_KEY, msg) 的 hex
//   x-ai-movie-timestamp = Date.now()（毫秒）；x-ai-movie-nonce = 16 字节随机 hex
//   参数来自 /assets/movie-card-runtime-*.js（函数 Aa / Ta）。实测只校验这三个头，
//   x-ai-movie-client-* / build-version / site-host 之类不填也能过 → 站点换版本不影响本源。
//   站点换 key 时：把新 main-*.js 里的 `Jo="…"` 抄进 SIGN_KEY 即可。
//
// ── 接口 ─────────────────────────────────────────────────────────────────
//   GET  /v1/feed/home                    首页板块（sections[].cards[] + section.browse）
//   GET  /v1/browse/catalog               列表 / 搜索 / 榜单
//        q / kind / genre / area / language / year / sort / hot_list_key / page / limit(≤20)
//   GET  /v1/runtime/bootstrap            分类与筛选表的真身（catalog_ui.catalogs）
//   GET  /v1/catalog/{id}                 详情 + episodes[]（每条带 token）
//   GET  /v1/playback/resolve/{token}     线路表 line_options[]
//   POST /v1/playback/resolve-line        票券线路（resolve://）换真实地址，body {ticket}
//   POST /v1/users/password/login         账号登入 {account, password}（可选，见下）
//   GET  /v1/users/me/quota               站内每日额度（要会话）
//   POST /v1/users/anonymous              游客会话（本源不用：匿名本来就够）
//
// ── 账号要不要填（2026-11-03 用真实账号实测）──────────────────────────────
//   **不填也能用全部片库**：匿名就能拿 34 条线路（25 条直链 + 9 条官方票券），连
//   「新4K-限时等级专属」「4K海外-官方C」这些票券线路匿名换也返回 201 + 真地址，
//   登录前后线路表逐条一致（provider / 权重 / token_scenario 全同）。
//   填账号之后多出来的只有站内那套：/v1/users/me/quota（会员每日 100 万 token 等级额度）、
//   收藏、播放历史、午夜剧场（/v1/midnight-theater/*，还要先确认 18+）。
//   所以本源把账号做成**可选**：填了就在换票券时带上会话（额度记到账号上），
//   没填就匿名换（一样能播）；登录失败不会影响直链播放。
//
// ── 播放（两层线路）──────────────────────────────────────────────────────
//   1) `resolve_mode:"direct"` 的线路（第三方聚合资源站，占绝大多数）：url 直接就是
//      m3u8/mp4，实测 200/206 + #EXTM3U，**不需要登录、不扣额度** → 本源默认走这条。
//   2) `resolve://` 票券线路（官方 1080P/4K）：POST /v1/playback/resolve-line 换地址，
//      画质更好但按站点额度计费。
//   3) 默认「直链优先」，直链一条都没有才换票券；设置里可切成「官方优先」（先换票券，
//      失败再回落直链，并把直链一起放进 qualities）。
//   4) 线路**不逐条探活**（详见 pickDirect 上方注释），按站点权重 + 资源站稳定性排序后
//      直接给地址，前 5 条进 qualities 供切换。
//
// ── 分类 / 筛选 ──────────────────────────────────────────────────────────
//   分类 = 站点 kind（电影/电视剧/动漫/综艺/短剧/纪录片/体育）+ 榜单 hot_list_key +
//   热度排序；筛选组从 /v1/runtime/bootstrap 的 catalog_ui 实时取，站点改分类表本源跟着变。
//   选项 id 里编码了站点真实查询参数（`genre:喜剧`、`year:2026`、`sort:updated_desc`）。
//   注意：genre 多选站点不支持（`genre=古装,爱情` 返回 0 条），本源取第一个并注释说明。

var SEED = 'https://dongpiandi.ai';
var MIRRORS = ['https://dongpiandi.ai'];
var SIGN_KEY = '8b9a908a05eac640e1ee06f52acaa741bfe4ba9e004eeffdbeb635e532e06666';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 20;      // 站点上限就是 20，传更大也会被截到 20
var KEEP_LINES = 5;      // 排序后留几条直链进 qualities（用户可在播放器里切线路）
var TICKET_TRIES = 3;    // 票券线路最多试几条（每条都可能扣额度）
var DETAIL_TTL = 10 * 60 * 1000;

var KIND_LABEL = {
  movie: '电影', series: '电视剧', anime: '动漫', variety: '综艺',
  short_drama: '短剧', documentary: '纪录片', sports: '体育', adult: '18+'
};

// 分类 id 就是「站点查询串」，list() 直接解析；home() 的 moreUrl 也走同一套编码，
// 所以首页任意板块的「更多」都能落回普通列表的分页。
var CATS = [
  { id: 'all', title: '最近更新' },
  { id: 'kind=movie', title: '电影' },
  { id: 'kind=series', title: '电视剧' },
  { id: 'kind=anime', title: '动漫' },
  { id: 'kind=variety', title: '综艺' },
  { id: 'kind=short_drama', title: '短剧' },
  { id: 'kind=documentary', title: '纪录片' },
  { id: 'kind=sports', title: '体育' },
  { id: 'sort=trending&window=day', title: '今日热播' },
  { id: 'hot_list_key=tv_domestic', title: '国产剧榜' },
  { id: 'hot_list_key=tv_korean', title: '韩剧榜' },
  { id: 'hot_list_key=tv_japanese', title: '日剧榜' },
  { id: 'hot_list_key=tv_american', title: '美剧榜' },
  { id: 'hot_list_key=movie_hot', title: '电影热播' },
  { id: 'hot_list_key=movie_high_score', title: '高分电影' },
  { id: 'hot_list_key=movie_nowplaying', title: '院线热映' }
];
var CAT_IDS = {};
for (var ci = 0; ci < CATS.length; ci += 1) CAT_IDS[CATS[ci].id] = true;

// ------------------------------------------------------------------ 基础工具
function text(value) {
  return value == null ? '' : String(value);
}

function enc(value) {
  return encodeURIComponent(text(value));
}

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (domain || SEED).replace(/\/+$/, '');
}

function settingOf(key, fallback) {
  var settings = (LumeSource.config && LumeSource.config.settings) || {};
  var value = settings[key];
  return value == null || value === '' ? fallback : value;
}

function configNumber(key, fallback, min, max) {
  var raw = Number(settingOf(key, fallback));
  if (!isFinite(raw)) return fallback;
  var value = Math.floor(raw);
  if (value < min) value = min;
  if (value > max) value = max;
  return value;
}

function pageSize() {
  return configNumber('pageSize', PAGE_SIZE, 1, PAGE_SIZE);
}

function readJson(file) {
  return LumeSource.fs.readText(file).then(function (raw) {
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (error) { return null; }
  }).catch(function () { return null; });
}

function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}

function randomHex(size) {
  var out = '';
  for (var i = 0; i < size; i += 1) {
    var v = Math.floor(Math.random() * 256) & 255;
    out += (v < 16 ? '0' : '') + v.toString(16);
  }
  return out;
}

// ── 纯 JS HMAC-SHA256（原生 tools.hmac 不可用时的兜底；FIPS 向量核对过）────────
var SHA256_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function utf8Bytes(value) {
  var out = [];
  var str = text(value);
  for (var i = 0; i < str.length; i += 1) {
    var c = str.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      var next = str.charCodeAt(++i);
      var cp = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00);
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}

function bytesToHex(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 1) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  return out;
}

function sha256Bytes(bytes) {
  var n = bytes.length;
  var total = ((n + 9 + 63) >> 6) << 6;
  var buf = new Array(total);
  var i;
  for (i = 0; i < n; i += 1) buf[i] = bytes[i];
  buf[n] = 0x80;
  for (i = n + 1; i < total - 8; i += 1) buf[i] = 0;
  var bitsHi = Math.floor(n / 0x20000000) & 0xffffffff;
  var bitsLo = (n * 8) % 0x100000000;
  buf[total - 8] = (bitsHi >>> 24) & 255; buf[total - 7] = (bitsHi >>> 16) & 255;
  buf[total - 6] = (bitsHi >>> 8) & 255;  buf[total - 5] = bitsHi & 255;
  buf[total - 4] = (bitsLo >>> 24) & 255; buf[total - 3] = (bitsLo >>> 16) & 255;
  buf[total - 2] = (bitsLo >>> 8) & 255;  buf[total - 1] = bitsLo & 255;

  var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  var w = new Array(64);
  for (var off = 0; off < total; off += 64) {
    for (i = 0; i < 16; i += 1) {
      var p = off + i * 4;
      w[i] = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) >>> 0;
    }
    for (i = 16; i < 64; i += 1) {
      var x = w[i - 15], y = w[i - 2];
      var s0 = (((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3)) >>> 0;
      var s1 = (((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (i = 0; i < 64; i += 1) {
      s1 = (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) >>> 0;
      var ch = ((e & f) ^ ((~e) & g)) >>> 0;
      var t1 = (h + s1 + ch + SHA256_K[i] + w[i]) >>> 0;
      s0 = (((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) >>> 0;
      var maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      var t2 = (s0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
  }
  var out = [];
  for (i = 0; i < 8; i += 1) out.push((H[i] >>> 24) & 255, (H[i] >>> 16) & 255, (H[i] >>> 8) & 255, H[i] & 255);
  return out;
}

function hmacSha256HexJs(keyText, msgText) {
  var key = utf8Bytes(keyText);
  if (key.length > 64) key = sha256Bytes(key);
  var ipad = [], opad = [];
  for (var i = 0; i < 64; i += 1) {
    var kb = i < key.length ? key[i] : 0;
    ipad.push(kb ^ 0x36);
    opad.push(kb ^ 0x5c);
  }
  var inner = sha256Bytes(ipad.concat(utf8Bytes(msgText)));
  return bytesToHex(sha256Bytes(opad.concat(inner)));
}

var NATIVE_HMAC = true;

async function signHex(key, message) {
  if (NATIVE_HMAC && LumeSource.tools && typeof LumeSource.tools.hmac === 'function') {
    try {
      var out = await LumeSource.tools.hmac({ algorithm: 'sha256', key: key, data: message });
      var hex = text(out).trim().toLowerCase();
      if (/^[0-9a-f]{64}$/.test(hex)) return hex;
      NATIVE_HMAC = false;
    } catch (error) {
      NATIVE_HMAC = false;
    }
  }
  return hmacSha256HexJs(key, message);
}

// ------------------------------------------------------------------ 接口调用
// 设备时钟偏差会让签名过期；首次 401(invalid_request_signature) 时按响应 Date 校正一次。
var clockSkew = 0;
var skewChecked = false;

function nowMs() {
  return Date.now() + clockSkew;
}

function headersOf(reply) {
  var source = (reply && reply.headers) || {};
  var out = {};
  var keys = Object.keys(source);
  for (var i = 0; i < keys.length; i += 1) out[String(keys[i]).toLowerCase()] = source[keys[i]];
  return out;
}

function dateOf(headers) {
  var raw = headers.date || headers.Date || '';
  var ms = Date.parse(text(raw));
  return isFinite(ms) ? ms : 0;
}

async function rawRequest(pathAndQuery, options) {
  var opt = options || {};
  var method = String(opt.method || 'GET').toUpperCase();
  var ts = String(Math.floor(nowMs()));
  var nonce = randomHex(16);
  var signature = await signHex(SIGN_KEY, method + '\n' + pathAndQuery + '\n' + ts + '\n' + nonce);
  var headers = {
    Accept: 'application/json',
    'User-Agent': UA,
    'x-ai-movie-timestamp': ts,
    'x-ai-movie-nonce': nonce,
    'x-ai-movie-signature': signature
  };
  if (opt.cookie) headers.Cookie = opt.cookie;
  var body = opt.body == null ? null : (typeof opt.body === 'string' ? opt.body : JSON.stringify(opt.body));
  if (body != null) headers['Content-Type'] = 'application/json';
  var reply = await LumeSource.http.request({
    url: base() + pathAndQuery,
    method: method,
    headers: headers,
    body: body == null ? undefined : body
  });
  var raw = reply && reply.body != null ? String(reply.body) : '';
  var json = null;
  try { json = raw ? JSON.parse(raw) : null; } catch (error) { json = null; }
  return { status: (reply && reply.status) || 0, json: json, text: raw, headers: headersOf(reply) };
}

function signatureBroken(result) {
  var code = (result.json && (result.json.code || (result.json.error && result.json.error.code))) || '';
  var message = (result.json && (result.json.message || (result.json.error && result.json.error.message))) || '';
  return code === 'invalid_request_signature' || /request signature/i.test(message);
}

async function request(pathAndQuery, options) {
  var result = await rawRequest(pathAndQuery, options);
  if (!signatureBroken(result) || skewChecked) return result;
  skewChecked = true;
  var serverMs = dateOf(result.headers);
  if (!serverMs) return result;
  clockSkew = serverMs - Date.now();
  if (Math.abs(clockSkew) < 1500) return result;
  return await rawRequest(pathAndQuery, options);
}

// --------------------------------------------------------------- 账号登入（可选）
// 浏览/搜索/详情/选集/直链播放**都不需要登录**（实测匿名就能换到含 4K 在内的全部
// 票券线路）。只有两件事要登录：站点账号的每日额度（`/v1/users/me/quota`）和午夜剧场
// （`/v1/midnight-theater/*`，且要先确认 18+）。所以登录只在「官方线路优先」模式
// 或直链全挂要换票券时按需触发，账号密码走 App 的「源设置 → 账号登入」，源里不写死。
//
// 登录：POST /v1/users/password/login {account, password} → 201，Set-Cookie 里给
// `ai_movie_session=ums2_…`（HttpOnly，有效期一年）。会话存 LumeSource.fs，按账号隔离。
var SESSION_FILE = 'session.json';
var LOGIN_FAIL_FILE = 'login_fail.json';
var LOGIN_FAIL_TTL = 30 * 60 * 1000;   // 密码错了就半小时内别再白试
var sessionCookie = '';
var sessionLoading = null;

function accountOf() {
  var config = LumeSource.config || {};
  return text(config.account).trim();
}

function passwordOf() {
  var config = LumeSource.config || {};
  return text(config.password);
}

async function readSession() {
  var saved = await readJson(SESSION_FILE);
  if (!saved || !saved.cookie) return null;
  var account = accountOf();
  if (saved.account && account && saved.account !== account) return null;
  return saved;
}

// 账号密码的指纹（不落明文，只用来判断「用户是不是换了凭据」）
async function credentialStamp() {
  var account = accountOf();
  if (!account) return '';
  return (await signHex(SIGN_KEY, 'login:' + account + ':' + passwordOf())).slice(0, 20);
}

async function loginRecentlyFailed() {
  var saved = await readJson(LOGIN_FAIL_FILE);
  if (!saved || !saved.stamp) return false;
  if (Date.now() - Number(saved.at || 0) > LOGIN_FAIL_TTL) return false;
  return saved.stamp === (await credentialStamp());
}

async function markLoginFailed(reason) {
  var stamp = await credentialStamp();
  if (!stamp) return;
  await writeJson(LOGIN_FAIL_FILE, { stamp: stamp, reason: text(reason).slice(0, 200), at: Date.now() });
}

function pickSessionCookie(headers) {
  var raw = text(headers['set-cookie']);
  var matched = /ai_movie_session=ums2_[^;,\s]+/.exec(raw);
  return matched ? matched[0] : '';
}

async function doLogin() {
  var account = accountOf();
  if (!account) throw new Error('这个源不需要登录也能看；要用「官方线路优先」或查额度，请在「源设置 → 账号登入」里填站点账号密码');
  if (!passwordOf()) throw new Error('请在「源设置 → 账号登入」里补上密码');
  var result = await request('/v1/users/password/login', {
    method: 'POST',
    body: { account: account, password: passwordOf() }
  });
  if (result.status !== 200 && result.status !== 201) {
    var friendly = apiError(result);
    if (result.status === 400 || result.status === 403) friendly = '账号或密码不正确（站点原话：' + friendly + '）';
    throw new Error(friendly);
  }
  var cookie = pickSessionCookie(result.headers);
  if (!cookie) throw new Error('登录成功但没拿到会话 Cookie，站点可能改了登录流程');
  sessionCookie = cookie;
  await writeJson(SESSION_FILE, { account: account, cookie: cookie, at: Date.now() });
  await LumeSource.fs.remove(LOGIN_FAIL_FILE).catch(function () { return null; });
  return cookie;
}

// 已登录就返回 Cookie（空串＝匿名，不报错：直链本来就不需要会话）
async function ensureSession(force) {
  if (sessionLoading) return sessionLoading;
  if (!force && sessionCookie) return sessionCookie;
  sessionLoading = (async function () {
    if (!force) {
      var saved = await readSession();
      if (saved) {
        sessionCookie = text(saved.cookie);
        return sessionCookie;
      }
    }
    if (!accountOf()) return '';
    if (!force && (await loginRecentlyFailed())) return '';
    try {
      return await doLogin();
    } catch (error) {
      if (force) throw error;
      await markLoginFailed(error && error.message ? error.message : error);
      return '';
    }
  })();
  try {
    return await sessionLoading;
  } finally {
    sessionLoading = null;
  }
}

async function dropSession() {
  sessionCookie = '';
  await LumeSource.fs.remove(SESSION_FILE).catch(function () { return null; });
}

// 设置页里的「检查账号与额度」：强制登录一次，把账号/等级/今日词元摊开给用户看。
function tokenText(value) {
  var n = Number(value);
  if (!isFinite(n)) return text(value);
  if (n >= 10000) return Math.round(n / 1000) / 10 + ' 万';
  return String(n);
}

async function describeAccount() {
  var account = accountOf();
  if (!account) {
    return '还没填账号。本源不登录也能看全部片库（直链免费，官方票券匿名也能换）；想在这个面板看到站内额度，请在「账号登入」里填站点账号密码。';
  }
  var cookie = '';
  try {
    cookie = await ensureSession(true);
  } catch (error) {
    return '登录失败：' + (error && error.message ? error.message : text(error));
  }
  if (!cookie) return '登录没有拿到会话，请检查「账号登入」里的账号密码。';

  var me = await request('/v1/users/me', { cookie: cookie });
  var quota = await request('/v1/users/me/quota', { cookie: cookie });
  var lines = [];
  var profile = me.status === 200 && me.json ? me.json : null;
  lines.push('账号：' + account + (profile && profile.display_name ? '（' + text(profile.display_name) + '）' : ''));
  if (quota.status === 200 && quota.json) {
    var q = quota.json;
    if (q.level_title || q.role) {
      lines.push('等级：' + text(q.level_title || q.role) + (q.role ? '（' + text(q.role) + '）' : ''));
    }
    lines.push('今日词元：已用 ' + tokenText(q.used_tokens) + ' / 上限 ' + tokenText(q.limit_tokens) + '，剩余 ' + tokenText(q.remaining_tokens));
    if (q.reset_at) lines.push('额度重置：' + text(q.reset_at));
  } else {
    lines.push('额度：读取失败（' + apiError(quota) + '）');
  }
  lines.push('说明：直链播放不消耗词元；只有「官方线路优先」或直链全挂时才扣。');
  return lines.join('\n');
}


function apiError(result) {
  var code = (result.json && (result.json.code || (result.json.error && result.json.error.code))) || '';
  var message = (result.json && (result.json.message || (result.json.error && result.json.error.message))) || '';
  if (signatureBroken(result)) {
    return '站点签名已变更（源里的 SIGN_KEY 过期了）：把新 main-*.js 里的 Jo="…" 抄进 SIGN_KEY';
  }
  if (result.status === 402) return '站点额度已用完，稍后再试';
  if (result.status === 401) return '站点要求会话（HTTP 401）';
  if (result.status === 429) return '请求太频繁，稍后再试';
  if (result.status === 404) return '站点上没有这一条（可能已下架）';
  if (!result.status) return '连不上站点：' + (message || '网络请求失败');
  return '接口返回 HTTP ' + result.status + (code ? '（' + code + '）' : '') + (message ? '：' + message : '');
}

// --------------------------------------------------------------- 数据 → 条目
function coverOf(card) {
  var url = text(card.poster_url) || text(card.carousel_url) || text(card.backdrop_url);
  if (!url) return '';
  if (/^\/\//.test(url)) return 'https:' + url;
  return url.replace(/^http:\/\//i, 'https://');
}

function subtitleOf(card) {
  var bits = [];
  if (card.year) bits.push(String(card.year));
  if (card.area) bits.push(String(card.area));
  if (card.remarks) bits.push(String(card.remarks));
  if (!bits.length && card.content_kind && KIND_LABEL[card.content_kind]) {
    bits.push(KIND_LABEL[card.content_kind]);
  }
  return bits.join(' · ');
}

function itemOf(card) {
  return {
    id: text(card.id),
    title: text(card.title) || text(card.normalized_title) || '未命名',
    cover: coverOf(card),
    subtitle: subtitleOf(card),
    updatedAt: card.updated_at || undefined
  };
}

function itemsOf(cards) {
  var out = [];
  var seen = {};
  for (var i = 0; i < (cards || []).length; i += 1) {
    var item = itemOf(cards[i]);
    if (!item.id || !item.title || seen[item.id]) continue;
    seen[item.id] = true;
    out.push(item);
  }
  return out;
}

// --------------------------------------------------------------- 分类 / 筛选
var bootstrapCache = null;

async function loadBootstrap() {
  if (bootstrapCache) return bootstrapCache;
  var result = await request('/v1/runtime/bootstrap');
  if (result.status !== 200 || !result.json) throw new Error(apiError(result));
  bootstrapCache = result.json;
  return bootstrapCache;
}

function catalogOf(bootstrap, kind) {
  var catalogs = (bootstrap && bootstrap.catalog_ui && bootstrap.catalog_ui.catalogs) || [];
  for (var i = 0; i < catalogs.length; i += 1) {
    if (text(catalogs[i] && catalogs[i].kind) === kind) return catalogs[i];
  }
  return null;
}

function optionIdOf(params) {
  var keys = Object.keys(params || {});
  var parts = [];
  for (var i = 0; i < keys.length; i += 1) parts.push(keys[i] + ':' + params[keys[i]]);
  return parts.join('|');
}

// 组内多选时 App 用逗号连回传；站点不支持多值参数，取第一组。
function parseOptionId(value) {
  var first = text(value).split(',')[0] || '';
  var pairs = first.split('|');
  var out = {};
  for (var i = 0; i < pairs.length; i += 1) {
    var at = pairs[i].indexOf(':');
    if (at <= 0) continue;
    var key = pairs[i].slice(0, at).trim();
    var val = pairs[i].slice(at + 1).trim();
    if (key && val) out[key] = val;
  }
  return out;
}

function parseCategoryId(categoryId) {
  var out = {};
  var raw = text(categoryId).trim();
  if (!raw || raw === 'all') return out;
  var pairs = raw.split('&');
  for (var i = 0; i < pairs.length; i += 1) {
    var at = pairs[i].indexOf('=');
    if (at <= 0) continue;
    var key = pairs[i].slice(0, at);
    var value = pairs[i].slice(at + 1);
    if (!key) continue;
    out[key] = decodeURIComponent(value);
  }
  return out;
}

function kindOfCategory(categoryId) {
  var parsed = parseCategoryId(categoryId);
  return text(parsed.kind);
}

// 首页板块的「更多」→ 同一套 categoryId 编码（丢掉 page/limit，由 list 自己加）
function browseUrlOf(section) {
  var params = (section && section.browse && section.browse.params) || {};
  var keys = Object.keys(params);
  var pairs = [];
  for (var i = 0; i < keys.length; i += 1) {
    var key = keys[i];
    if (key === 'page' || key === 'limit') continue;
    pairs.push(key + '=' + enc(params[key]));
  }
  return pairs.join('&') || 'all';
}

// ------------------------------------------------------------------ 详情缓存
function cacheKeyOf(id) {
  var hash = 2166136261;
  var raw = text(id);
  for (var i = 0; i < raw.length; i += 1) {
    hash ^= raw.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return 'detail_' + (hash >>> 0).toString(36) + '.json';
}

async function loadDetail(id) {
  var file = cacheKeyOf(id);
  var cached = await readJson(file);
  if (cached && cached.id === id && Date.now() - Number(cached.at || 0) < DETAIL_TTL) {
    return cached.data;
  }
  var result = await request('/v1/catalog/' + enc(id));
  if (result.status === 404) return null;
  if (result.status !== 200 || !result.json) throw new Error(apiError(result));
  await writeJson(file, { id: id, at: Date.now(), data: result.json });
  return result.json;
}

async function loadChapters(id) {
  var data = await loadDetail(id);
  if (!data) return [];
  var episodes = data.episodes || [];
  var single = episodes.length <= 1;
  var out = [];
  for (var i = 0; i < episodes.length; i += 1) {
    var ep = episodes[i];
    if (!ep || !ep.token) continue;
    var title = text(ep.title) || text(ep.display_name) || ('第 ' + (ep.number || i + 1) + ' 集');
    if (single && text(data.remarks)) title = text(data.remarks);
    out.push({ id: 't:' + text(ep.token), title: title });
  }
  if (!out.length) throw new Error('这一条在站点上还没有可播放的分集');
  return out;
}

// ------------------------------------------------------- 直链线路排序（不探活）
// 为什么不逐条探活：App 单次调用预算 3–5 秒，而聚合资源站的 CDN 里总有一两条
// 已经挂掉、要等宿主 6 秒超时才回（实测某集 4 条串行探活把 content 拖到 16 秒，
// 直接被判超时）。所以改成「按实测稳定性排序 + 一次 resolve 直接给地址」：
// 首选线路正常时 content 只要 0.4 秒，死链由播放器的清晰度/线路按钮切换兜底。
//
// 排序权重 = 站点给的 preference_weight + 资源站实测稳定性修正：
// 长期稳定（m3u8 直链 200/206）：hongniu / xinlang / jszy / hhzy / ikun / subo /
//   wsyzy / mdzy / xigua / subo，以及 bytevod/官方 CDN 的 mp4（权重本来就最高）。
// 实测常挂（403 或连不上）：ffzy / suoni / niuniu / dbzy / maotai / jinying。
var STABLE_PROVIDERS = {
  hongniu: 300, xinlang: 300, jszy: 300, hhzy: 300, ikun: 300, subo: 300,
  wsyzy: 280, mdzy: 280, xigua: 260, maoyan: 120, dytt: 120, zy360: 80,
  liangzi: 60, zuida: 60, wujin: 40, jinying: 0, maotai: 0, dbzy: -60,
  ffzy: -260, suoni: -260, niuniu: -260
};

function lineScore(line) {
  var weight = Number(line && line.preference_weight);
  if (!isFinite(weight)) weight = 0;
  var provider = text(line && line.provider_id);
  var bonus = STABLE_PROVIDERS[provider];
  if (bonus == null) bonus = 0;
  // 直连 http(s) 的 mp4/m3u8 比票券线路快一步，稍微加分
  if (/^https?:\/\//i.test(text(line && line.url))) bonus += 20;
  return weight + bonus;
}

function rankLines(lines) {
  var copy = lines.slice();
  copy.sort(function (a, b) {
    var diff = lineScore(b) - lineScore(a);
    if (diff) return diff;
    return text(a.provider_id) < text(b.provider_id) ? -1 : 1;
  });
  return copy;
}

function labelOf(line) {
  return text(line.display_label) || text(line.label) || text(line.provider_name) || text(line.provider_id) || '线路';
}

// 取排好序的直链里前 KEEP_LINES 条（去重），第一条作默认线路
function pickDirect(lines) {
  var ranked = rankLines(lines);
  var picked = [];
  var seen = {};
  for (var i = 0; i < ranked.length && picked.length < KEEP_LINES; i += 1) {
    var url = text(ranked[i].url);
    if (!/^https?:\/\//i.test(url) || seen[url]) continue;
    seen[url] = true;
    picked.push({ label: labelOf(ranked[i]), url: url });
  }
  return picked;
}

// 票券线路：POST /v1/playback/resolve-line 换真地址。
// 匿名也能换（实测连 4K 都能拿到），登录只是把额度记到账号上、并在会话有效时更稳，
// 所以这里「有会话就带、401 就重登一次、拿不到会话就匿名继续」。
async function resolveTickets(lines) {
  if (!lines.length) return null;
  var session = await ensureSession(false);
  for (var i = 0; i < lines.length && i < TICKET_TRIES; i += 1) {
    var ticket = text(lines[i].url).replace(/^resolve:\/\//, '');
    if (!ticket) continue;
    var result = await request('/v1/playback/resolve-line?view=compact', {
      method: 'POST',
      body: { ticket: ticket },
      cookie: session
    });
    if (result.status === 401 && session) {
      await dropSession();
      session = await ensureSession(true).catch(function () { return ''; });
      result = await request('/v1/playback/resolve-line?view=compact', {
        method: 'POST',
        body: { ticket: ticket },
        cookie: session
      });
    }
    if (result.status !== 200 && result.status !== 201) continue;
    var line = (result.json && result.json.line) || null;
    var url = line ? text(line.url) : '';
    if (!url) continue;
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA },
      qualities: [{ label: labelOf(line) || '官方线路', url: url }]
    };
  }
  return null;
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'dongpiandi_video',
  name: '懂片帝',
  version: '1.1.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: SEED + '/assets/app-icon-180.png',
  commonSettings: [
    { key: 'pageSize', default: PAGE_SIZE, min: 1, max: 20 }
  ],
  settings: [
    {
      key: 'lineMode',
      type: 'select',
      title: '线路偏好',
      default: 'direct',
      options: [
        { value: 'direct', title: '第三方直链优先（免费，推荐）' },
        { value: 'official', title: '官方线路优先（1080P/4K，扣站点额度）' }
      ],
      description: '直链优先：先用聚合资源站的 m3u8（免费、不用登录）；官方优先：直接换官方票券线路（画质更好，按账号额度计费）。两种模式都会在失败时自动回落另一层。'
    },
    {
      key: 'checkAccount',
      type: 'action',
      action: 'source',
      title: '检查账号与额度',
      description: '用「账号登入」里的账号密码登一次站点，显示昵称、等级和今天的词元用量（直链播放本身不扣额度）。'
    },
    {
      key: 'logout',
      type: 'action',
      action: 'source',
      title: '退出站点登录',
      description: '清掉本源保存的会话 Cookie，之后按匿名身份换票券线路（匿名也能用，只是额度记不到账号上）。'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '懂片帝（dongpiandi.ai）：AI 找片 + 片单 + 播放，接口全部要 HMAC 签名（源内用宿主原生 tools.hmac）。浏览、搜索、选集、直链播放都不需要登录；要「官方线路优先」或看站内额度，才需要在「账号登入」里填站点账号密码（只存在本机这份源记录里）。站点换域名时在「源设置 → 换网址」里填新域名。'
    }
  ],

  async settingsAction(argument) {
    var args = argument || {};
    var key = text(args.key);
    if (key === 'checkAccount') return await describeAccount();
    if (key === 'logout') {
      await dropSession();
      return '已清除站点会话。下一部作品会按匿名身份换票券线路（匿名同样能播，只是额度不记到账号上）。';
    }
    return '未知操作：' + key;
  },

  async categories() {
    return CATS.slice();
  },

  async filters(argument) {
    var kind = kindOfCategory(argument && argument.categoryId);
    if (!kind) return { groups: [] };
    var bootstrap = await loadBootstrap();
    var catalog = catalogOf(bootstrap, kind);
    if (!catalog) return { groups: [] };
    var rows = catalog.rows || [];
    var groups = [];
    for (var r = 0; r < rows.length; r += 1) {
      var row = rows[r];
      var options = [];
      var list = row.options || [];
      for (var o = 0; o < list.length; o += 1) {
        var option = list[o];
        if (!option || option.enabled === false) continue;
        var id = optionIdOf(option.params || {});
        if (!id) continue;
        options.push({ id: id, title: text(option.label) || text(option.key) });
      }
      if (!options.length) continue;
      groups.push({ id: text(row.key), title: text(row.label) || text(row.key), options: options });
    }
    return { groups: groups };
  },

  async home() {
    var result = await request('/v1/feed/home');
    if (result.status !== 200 || !result.json) throw new Error(apiError(result));
    var boards = [];
    var sections = result.json.sections || [];
    for (var i = 0; i < sections.length; i += 1) {
      var section = sections[i];
      var items = itemsOf(section.cards);
      if (!items.length) continue;
      var board = {
        title: text(section.title) || '推荐',
        items: items,
        moreUrl: browseUrlOf(section)
      };
      if (text(section.subtitle)) board.subtitle = text(section.subtitle);
      boards.push(board);
    }
    if (!boards.length) throw new Error('首页没有返回任何板块');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = text(args.keyword).trim();
    var categoryId = text(args.categoryId).trim();
    var filters = args.filters || {};
    var limit = pageSize();

    var params = {};
    if (keyword) {
      params.q = keyword;
    } else {
      var fromCategory = parseCategoryId(categoryId);
      var keys = Object.keys(fromCategory);
      for (var i = 0; i < keys.length; i += 1) params[keys[i]] = fromCategory[keys[i]];
      if (!params.sort && !params.hot_list_key && !params.q) params.sort = 'updated_desc';
    }

    // 筛选：选项 id 里就是站点真实参数名（genre / area / language / year / sort）
    var groupKeys = Object.keys(filters || {});
    for (var g = 0; g < groupKeys.length; g += 1) {
      var parsed = parseOptionId(filters[groupKeys[g]]);
      var pkeys = Object.keys(parsed);
      for (var k = 0; k < pkeys.length; k += 1) params[pkeys[k]] = parsed[pkeys[k]];
    }

    params.page = String(page);
    params.limit = String(limit);

    var pairs = [];
    var paramKeys = Object.keys(params);
    for (var n = 0; n < paramKeys.length; n += 1) {
      pairs.push(enc(paramKeys[n]) + '=' + enc(params[paramKeys[n]]));
    }

    var result = await request('/v1/browse/catalog?' + pairs.join('&'));
    if (result.status !== 200 || !result.json) throw new Error(apiError(result));
    var items = itemsOf(result.json.cards);
    var pagination = result.json.pagination || {};
    var hasMore = pagination.has_more == null ? items.length >= limit : !!pagination.has_more;
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = text(argument && argument.id);
    if (!id) return null;
    var data;
    try {
      data = await loadDetail(id);
    } catch (error) {
      throw error;
    }
    if (!data || !text(data.title)) return null;
    var bits = [];
    if (KIND_LABEL[data.content_kind]) bits.push(KIND_LABEL[data.content_kind]);
    if (data.year) bits.push(String(data.year));
    if (data.area) bits.push(String(data.area));
    if (data.episode_progress_text) bits.push(text(data.episode_progress_text));
    else if (data.remarks) bits.push(text(data.remarks));
    var desc = [];
    if (data.description) desc.push(text(data.description));
    if (data.actors && data.actors.length) desc.push('演员：' + data.actors.slice(0, 12).join(' / '));
    if (data.directors && data.directors.length) desc.push('导演：' + data.directors.join(' / '));
    if (data.genres && data.genres.length) desc.push('类型：' + data.genres.slice(0, 12).join(' / '));
    return {
      id: id,
      title: text(data.title),
      cover: coverOf(data),
      backdrop: text(data.backdrop_url),
      year: data.year ? String(data.year) : '',
      mediaType: 'video',
      subtitle: bits.join(' · '),
      description: desc.join('\n'),
      status: data.is_completed ? '已完结' : (data.update_status === 'ongoing' ? '连载中' : ''),
      tags: (data.genres || []).slice(0, 8)
    };
  },

  async chapters(argument) {
    var id = text(argument && argument.id);
    if (!id) return [];
    return await loadChapters(id);
  },

  async content(argument) {
    var args = argument || {};
    var token = text(args.chapterId).replace(/^t:/, '');
    if (!token || !/^av_/.test(token)) {
      // 没有分集（例如从历史记录直接进来）：现取第 1 集
      var list = await loadChapters(text(args.id));
      if (!list.length) throw new Error('没有可播放的分集');
      token = text(list[0].id).replace(/^t:/, '');
    }

    var resolved = await request('/v1/playback/resolve/' + enc(token));
    if (resolved.status !== 200 || !resolved.json) throw new Error(apiError(resolved));

    var lines = (resolved.json.line_options || []).slice();
    var direct = [], tickets = [];
    for (var i = 0; i < lines.length; i += 1) {
      var line = lines[i];
      var url = text(line.url);
      if (/^https?:\/\//i.test(url)) direct.push(line);
      else if (/^resolve:\/\//i.test(url) || line.resolve_required === true) tickets.push(line);
    }
    tickets = rankLines(tickets);
    var picked = pickDirect(direct);
    var officialFirst = String(settingOf('lineMode', 'direct')) === 'official';

    // 官方优先：先换票券（画质更高），换不到再回落直链
    if (officialFirst && tickets.length) {
      var official = await resolveTickets(tickets);
      if (official) {
        if (picked.length) {
          official.qualities = official.qualities.concat(picked.map(function (entry) {
            return { label: entry.label, url: entry.url };
          }));
        }
        return official;
      }
    }

    if (picked.length) {
      return {
        kind: 'video',
        url: picked[0].url,
        headers: { 'User-Agent': UA },
        qualities: picked
      };
    }

    var ticketed = await resolveTickets(tickets);
    if (ticketed) return ticketed;

    throw new Error('这一集暂时没有可用线路（第三方直链全部失效，官方票券也没换到地址）。可以在站点网页里播放，或换一集再试。');
  }
};
