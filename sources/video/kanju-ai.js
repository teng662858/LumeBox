// LumeSource: {"id":"kanju_ai_video","name":"看剧AI","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://kanju24.com","https://kanju.ai","https://kanju13.com","https://www.kanju24.com"],"network":"direct","icon":"https://kanju24.com/assets/app-icon-180.png"}
// LumeRuntime: javascript
//
// 站点：看剧AI / KANJU.AI（主站 kanju24.com；实测同内容镜像 kanju.ai、kanju13.com、
//       www.kanju24.com；bootstrap 里的 canonical_host 是 main.kanju13.com）
// 形态：React SPA + 同源 `/v1/*` JSON 接口。首页外壳只有 3.6 KB，所有数据都走接口。
//
// ── 签名（每个 /v1 请求都要，缺了返回 401 Missing request signature）──
//   msg = METHOD + "\n" + pathname + search + "\n" + timestamp + "\n" + nonce
//   x-ai-movie-signature = HMAC-SHA256(SIGN_KEY, msg) 的 hex
//   x-ai-movie-timestamp = Date.now()；x-ai-movie-nonce = 16 字节随机 hex
//   参数来自 /assets/movie-card-runtime-*.js（函数 Gi/Qi）。实测只校验这三个头，
//   x-ai-movie-build-version 之类随便填也能过 → 站点换版本不影响本源。
//   沙箱没有 crypto/atob，SHA-256 与 HMAC 都是本源内纯 JS 实现（FIPS 向量核对过）。
//   **站点换 key 时**：把新 main-*.js 里的 lo="…" 抄进 SIGN_KEY 即可。
//
// ── 播放（两层线路，先免费后额度）──
//   1) GET /v1/playback/resolve/{episodeToken} → line_options；
//   2) `resolve_mode:"direct"` 的线路（第三方资源站，占多数）url 就是 m3u8，实测
//      200/206 + `#EXTM3U`，**不需要登录、不扣额度** → 本源默认走这条，逐个探活挑能用
//      的，并把多条可用线路放进 qualities 让用户自己切；
//   3) `resolve://` 票券线路（官方 1080P/4K）要 POST /v1/playback/resolve-line
//      换真地址，必须有会话（POST /v1/users/anonymous 拿游客 Cookie），并按档位扣
//      token（实测 30000–60000/次）。游客额度 900000/天 → 约 15–30 次/天。
//      只有直链全挂时才走这里；用尽时接口 402，本源给可读错误。
//   4) 直链全挂 + 票券也拿不到 → 抛错说明挡在哪层，不编造地址。
//
// ── 分类 / 筛选 ──
//   分类 = 站点的 kind（电视剧/电影/动漫/综艺/短剧），各自内容不同；
//   筛选组（分类/地区/语言/年份/状态/形式/排序）从 /v1/runtime/bootstrap 的
//   catalog_ui 实时取，站点改分类表本源跟着变；选项 id 里编码了真实查询参数
//   （例如 `genre:古装`、`year_gte:1990|year_lte:1999`）。
//   注意：genre 多选站点不认（`genre=古装,爱情` 返回 0 条），本源取第一个并注释。

var HOST = 'https://kanju24.com';
var MIRRORS = ['https://kanju24.com', 'https://kanju.ai', 'https://kanju13.com', 'https://www.kanju24.com'];
var SIGN_KEY = '557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 20;
var PROBE_LINES = 4;   // 探活多少条第三方直链
var TICKET_TRIES = 3;  // 票券线路最多试几条（每条都扣额度）

var CATS = [
  { id: 'series', title: '电视剧' },
  { id: 'movie', title: '电影' },
  { id: 'anime', title: '动漫' },
  { id: 'variety', title: '综艺' },
  { id: 'short_drama', title: '短剧' }
];

var KIND_LABEL = { series: '电视剧', movie: '电影', anime: '动漫', variety: '综艺', short_drama: '短剧' };

// ------------------------------------------------------------------ 基础工具
function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function readJson(file) {
  return LumeSource.fs.readText(file).then(function (text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}
function settingOf(key, fallback) {
  var settings = (LumeSource.config && LumeSource.config.settings) || {};
  var common = (LumeSource.config && LumeSource.config.commonSettings) || {};
  var value = settings[key] != null ? settings[key] : common[key];
  return value == null || value === '' ? fallback : value;
}
function pageSize() {
  var n = Number(settingOf('pageSize', PAGE_SIZE));
  if (!n || n < 1) n = PAGE_SIZE;
  if (n > 50) n = 50;
  return Math.floor(n);
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }
function text(value) { return String(value == null ? '' : value).trim(); }

// ------------------------------------------------- 纯 JS SHA-256 / HMAC-SHA256
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
  var str = String(value);
  for (var i = 0; i < str.length; i++) {
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
  for (var i = 0; i < bytes.length; i++) out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  return out;
}
function sha256Bytes(bytes) {
  var n = bytes.length;
  var total = ((n + 9 + 63) >> 6) << 6;
  var buf = new Array(total);
  var i;
  for (i = 0; i < n; i++) buf[i] = bytes[i];
  buf[n] = 0x80;
  for (i = n + 1; i < total - 8; i++) buf[i] = 0;
  var bitsHi = Math.floor(n / 0x20000000) & 0xffffffff;
  var bitsLo = (n * 8) % 0x100000000;
  buf[total - 8] = (bitsHi >>> 24) & 255; buf[total - 7] = (bitsHi >>> 16) & 255;
  buf[total - 6] = (bitsHi >>> 8) & 255;  buf[total - 5] = bitsHi & 255;
  buf[total - 4] = (bitsLo >>> 24) & 255; buf[total - 3] = (bitsLo >>> 16) & 255;
  buf[total - 2] = (bitsLo >>> 8) & 255;  buf[total - 1] = bitsLo & 255;

  var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  var w = new Array(64);
  for (var off = 0; off < total; off += 64) {
    for (i = 0; i < 16; i++) {
      var p = off + i * 4;
      w[i] = ((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) >>> 0;
    }
    for (i = 16; i < 64; i++) {
      var x = w[i - 15], y = w[i - 2];
      var s0 = (((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3)) >>> 0;
      var s1 = (((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (i = 0; i < 64; i++) {
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
  for (i = 0; i < 8; i++) out.push((H[i] >>> 24) & 255, (H[i] >>> 16) & 255, (H[i] >>> 8) & 255, H[i] & 255);
  return out;
}
function hmacSha256Hex(keyText, msgText) {
  var key = utf8Bytes(keyText);
  if (key.length > 64) key = sha256Bytes(key);
  var ipad = [], opad = [];
  for (var i = 0; i < 64; i++) {
    var kb = i < key.length ? key[i] : 0;
    ipad.push(kb ^ 0x36);
    opad.push(kb ^ 0x5c);
  }
  var inner = sha256Bytes(ipad.concat(utf8Bytes(msgText)));
  return bytesToHex(sha256Bytes(opad.concat(inner)));
}
function randomHex(bytes) {
  var out = '';
  for (var i = 0; i < bytes; i++) {
    var v = Math.floor(Math.random() * 256) & 255;
    out += (v < 16 ? '0' : '') + v.toString(16);
  }
  return out;
}

// ------------------------------------------------------------------ 接口调用
function signHeaders(method, pathAndQuery) {
  var ts = String(Date.now());
  var nonce = randomHex(16);
  var signature = hmacSha256Hex(SIGN_KEY, method + '\n' + pathAndQuery + '\n' + ts + '\n' + nonce);
  return {
    'Accept': 'application/json',
    'x-ai-movie-timestamp': ts,
    'x-ai-movie-nonce': nonce,
    'x-ai-movie-signature': signature
  };
}

var sessionCookie = '';
var sessionLoading = null;

async function request(path, options) {
  var opt = options || {};
  var method = String(opt.method || 'GET').toUpperCase();
  var headers = signHeaders(method, path);
  if (opt.cookie && sessionCookie) headers['Cookie'] = sessionCookie;
  var body = opt.body == null ? null : (typeof opt.body === 'string' ? opt.body : JSON.stringify(opt.body));
  if (body != null) headers['Content-Type'] = 'application/json';
  var reply = await LumeSource.http.request({
    url: base() + path,
    method: method,
    headers: headers,
    body: body == null ? undefined : body
  });
  var raw = reply && reply.body != null ? String(reply.body) : '';
  var json = null;
  try { json = raw ? JSON.parse(raw) : null; } catch (e) { json = null; }
  return { status: (reply && reply.status) || 0, json: json, text: raw, headers: (reply && reply.headers) || {} };
}

function apiError(result) {
  var code = (result.json && (result.json.code || (result.json.error && result.json.error.code))) || '';
  var message = (result.json && (result.json.message || (result.json.error && result.json.error.message))) || '';
  if (code === 'invalid_request_signature' || /Missing request signature/i.test(message)) {
    return '站点签名已变更（源头里的 SIGN_KEY 过期了）：把新 main-*.js 里的 lo="…" 换进 SIGN_KEY';
  }
  if (code === 'playback_user_session_required' || result.status === 401) {
    return '该内容需要站点会话（看剧AI 的官方线路要求游客登录态）';
  }
  if (result.status === 402 || code === 'playback_token_insufficient') {
    return '游客播放额度已用完（每天 900000 token，约 15–30 集），明天再试或换直链线路';
  }
  if (result.status === 429) return '请求太频繁，稍后再试';
  if (result.status === 404) return '站点上没有这一条（可能已下架）';
  return '接口返回 HTTP ' + result.status + (code ? '（' + code + '）' : '') + (message ? '：' + message : '');
}

// 游客会话：POST /v1/users/anonymous（同 anonymous_id 复用同一账号），Cookie 存本地
async function ensureSession(force) {
  if (sessionLoading) return sessionLoading;
  sessionLoading = (async function () {
    var saved = force ? null : await readJson('session.json');
    if (saved && saved.cookie) {
      sessionCookie = String(saved.cookie);
      return sessionCookie;
    }
    var anonId = (saved && saved.anonId) || ('a-' + randomHex(12));
    var result = await request('/v1/users/anonymous', {
      method: 'POST',
      body: { anonymous_id: anonId }
    });
    var setCookie = result.headers['set-cookie'] || result.headers['Set-Cookie'] || '';
    var cookie = '';
    // 宿主可能把多条 Set-Cookie 合并成一个字符串（Expires 里还带逗号），所以按
    // 「名字前缀」定位，不整段切分
    var match = /(?:^|[,\n])\s*(ai_movie_session=[^;,\n]+)/.exec(String(setCookie));
    if (match) cookie = match[1].trim();
    if (!cookie && result.status !== 201 && result.status !== 200) {
      throw new Error('创建游客会话失败：' + apiError(result));
    }
    sessionCookie = cookie;
    await writeJson('session.json', { anonId: anonId, cookie: cookie, at: Date.now() });
    return cookie;
  })();
  try {
    return await sessionLoading;
  } finally {
    sessionLoading = null;
  }
}

// -------------------------------------------------------------- 数据 → 条目
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
  for (var i = 0; i < (cards || []).length; i++) {
    var item = itemOf(cards[i]);
    if (item.id && item.title) out.push(item);
  }
  return out;
}

// ------------------------------------------------------------- 分类 / 筛选
var bootstrapCache = null;

async function loadBootstrap() {
  if (bootstrapCache) return bootstrapCache;
  var result = await request('/v1/runtime/bootstrap');
  if (result.status !== 200 || !result.json) throw new Error(apiError(result));
  bootstrapCache = result.json;
  return bootstrapCache;
}

// 选项 id 编码：`key:value` 多参数用 `|` 连接；App 组内多选用逗号回传
function optionIdOf(params) {
  var keys = Object.keys(params || {});
  var parts = [];
  for (var i = 0; i < keys.length; i++) parts.push(keys[i] + ':' + params[keys[i]]);
  return parts.join('|');
}
function parseOptionIds(value) {
  var out = {};
  var list = text(value).split(',');
  for (var i = 0; i < list.length; i++) {
    var pairs = list[i].split('|');
    for (var j = 0; j < pairs.length; j++) {
      var at = pairs[j].indexOf(':');
      if (at <= 0) continue;
      var key = pairs[j].slice(0, at).trim();
      var val = pairs[j].slice(at + 1).trim();
      if (!key || !val) continue;
      if (out[key] == null) out[key] = val; // 同名参数取第一个
    }
  }
  return out;
}

// ---------------------------------------------------------------- 五入口
var LumeSource = {
  id: 'kanju_ai_video',
  name: '看剧AI',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/assets/app-icon-180.png',
  commonSettings: [
    { key: 'pageSize', default: PAGE_SIZE, min: 1, max: 50 }
  ],
  settings: [
    {
      key: 'lineMode',
      type: 'select',
      title: '线路偏好',
      default: 'direct',
      options: [
        { value: 'direct', title: '第三方直链优先（不耗额度，推荐）' },
        { value: 'official', title: '官方 1080P 优先（扣游客额度）' }
      ],
      description: '直链优先：先用第三方资源站的 m3u8（免费、无需登录）；官方优先：直接换官方票券线路（每次扣 30000–60000 token）。'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '看剧AI（主站 kanju24.com；官方备用域 kanju.ai、kanju13.com，换域名时在源设置里切镜像）。聚合各家资源，默认走免费第三方直链；官方 1080P 线路需要游客会话并消耗站点额度（游客 900000/天）。'
    }
  ],

  async categories() {
    return CATS.slice();
  },

  async filters(argument) {
    var kind = text(argument && argument.categoryId);
    if (!kind) return { groups: [] };
    var boot = await loadBootstrap();
    var catalogs = (boot.catalog_ui && boot.catalog_ui.catalogs) || [];
    var catalog = null;
    for (var i = 0; i < catalogs.length; i++) {
      if (catalogs[i].kind === kind) { catalog = catalogs[i]; break; }
    }
    if (!catalog) return { groups: [] };
    var rows = catalog.rows || [];
    var groups = [];
    for (var r = 0; r < rows.length; r++) {
      var row = rows[r];
      var options = [];
      var list = row.options || [];
      for (var o = 0; o < list.length; o++) {
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
    var result = await request('/v1/feed/home?scope=public&mode=preview&sections=6&cards=12');
    if (result.status !== 200 || !result.json) throw new Error(apiError(result));
    var boards = [];
    var sections = result.json.sections || [];
    for (var i = 0; i < sections.length; i++) {
      var items = itemsOf(sections[i].cards);
      if (!items.length) continue;
      boards.push({ title: text(sections[i].title) || '推荐', items: items });
    }
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = text(args.keyword);
    var category = text(args.categoryId);
    var filters = args.filters || {};
    var limit = pageSize();

    var query = [];
    if (keyword) query.push('q=' + enc(keyword));
    else if (category) query.push('kind=' + enc(category));
    // 筛选参数：选项 id 里就是站点真实参数名（genre/area/language/year/status/orientation/sort）
    var order = ['genre', 'area', 'language', 'year', 'status', 'orientation'];
    var sort = '';
    for (var i = 0; i < order.length; i++) {
      var parsed = parseOptionIds(filters[order[i]]);
      var keys = Object.keys(parsed);
      for (var k = 0; k < keys.length; k++) query.push(enc(keys[k]) + '=' + enc(parsed[keys[k]]));
    }
    var sortParsed = parseOptionIds(filters['sort']);
    sort = text(sortParsed['sort']);
    if (sort) query.push('sort=' + enc(sort));
    else if (!keyword && category) query.push('sort=heat_desc');
    query.push('page=' + page);
    query.push('limit=' + limit);

    var result = await request('/v1/browse/catalog?' + query.join('&'));
    if (result.status !== 200 || !result.json) throw new Error(apiError(result));
    var items = itemsOf(result.json.cards);
    var pagination = result.json.pagination || {};
    var hasMore = pagination.has_more == null ? items.length >= limit : !!pagination.has_more;
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = text(argument && argument.id);
    if (!id) return null;
    var result = await request('/v1/catalog/' + enc(id));
    if (result.status === 404) return null;
    if (result.status !== 200 || !result.json) {
      if (result.status === 0) throw new Error('连不上站点：' + apiError(result));
      return null;
    }
    var data = result.json;
    if (!text(data.title)) return null;
    var bits = [];
    if (KIND_LABEL[data.content_kind]) bits.push(KIND_LABEL[data.content_kind]);
    if (data.year) bits.push(String(data.year));
    if (data.area) bits.push(String(data.area));
    if (data.episode_progress_text || data.remarks) bits.push(text(data.episode_progress_text) || text(data.remarks));
    var desc = [];
    if (data.description) desc.push(text(data.description));
    if (data.actors && data.actors.length) desc.push('演员：' + data.actors.slice(0, 12).join(' / '));
    if (data.directors && data.directors.length) desc.push('导演：' + data.directors.join(' / '));
    if (data.genres && data.genres.length) desc.push('类型：' + data.genres.slice(0, 10).join(' / '));
    return {
      id: id,
      title: text(data.title),
      cover: coverOf(data),
      backdrop: text(data.backdrop_url),
      year: data.year ? String(data.year) : '',
      mediaType: text(data.content_kind),
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
    if (resolved.status === 401) {
      await ensureSession(true);
      resolved = await request('/v1/playback/resolve/' + enc(token), { cookie: true });
    }
    if (resolved.status !== 200 || !resolved.json) throw new Error(apiError(resolved));

    var lines = (resolved.json.line_options || []).slice();
    var direct = [], tickets = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var url = text(line.url);
      if (/^https?:\/\//i.test(url)) direct.push(line);
      else if (/^resolve:\/\//i.test(url) || line.resolve_required === true) tickets.push(line);
    }
    direct.sort(function (a, b) { return (b.preference_weight || 0) - (a.preference_weight || 0); });
    tickets.sort(function (a, b) { return (b.preference_weight || 0) - (a.preference_weight || 0); });

    var preferOfficial = String(settingOf('lineMode', 'direct')) === 'official';
    if (preferOfficial && tickets.length) {
      var official = await resolveTickets(tickets);
      if (official) return official;
    }

    var playable = await probeDirect(direct);
    if (playable.length) {
      return {
        kind: 'video',
        url: playable[0].url,
        qualities: playable.map(function (entry) { return { label: entry.label, url: entry.url }; }),
        headers: { 'User-Agent': UA }
      };
    }

    var ticketed = await resolveTickets(tickets);
    if (ticketed) return ticketed;

    throw new Error('这一集暂时没有可用线路（第三方直链全部失效，官方票券也没换到地址）。可以在站点网页里播放，或换一集再试。');
  }
};

// 详情接口 → 分集列表（章节 id 里存的是站点的 episode token，content() 直接拿它换流）
async function loadChapters(id) {
  if (!id) return [];
  var result = await request('/v1/catalog/' + enc(id));
  if (result.status === 404) return [];
  if (result.status !== 200 || !result.json) throw new Error(apiError(result));
  var episodes = result.json.episodes || [];
  var out = [];
  for (var i = 0; i < episodes.length; i++) {
    var ep = episodes[i];
    if (!ep || !ep.token) continue;
    out.push({
      id: 't:' + ep.token,
      title: text(ep.title) || text(ep.display_name) || ('第 ' + (ep.number || i + 1) + ' 集'),
      line: text(ep.episode_track)
    });
  }
  if (!out.length) throw new Error('这一条在站点上还没有可播放的分集');
  return out;
}

// 探活第三方直链：m3u8 只要 200/206 且正文含 #EXTM3U 就算能用。
// 串行探（沙箱里并发打桥接口不保证顺序/可用），拿到 2 条就停——1 条能播就够，
// 多出来的只用于给用户切换线路。
function probeOne(line) {
  var url = text(line.url);
  if (!url) return Promise.resolve(null);
  return LumeSource.http.request({
    url: url,
    method: 'GET',
    headers: { 'User-Agent': UA, 'Range': 'bytes=0-2047' }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (status !== 200 && status !== 206) return null;
    var body = reply && reply.body != null ? String(reply.body) : '';
    var headers = (reply && reply.headers) || {};
    var type = '';
    var keys = Object.keys(headers);
    for (var k = 0; k < keys.length; k++) {
      if (String(keys[k]).toLowerCase() === 'content-type') type = String(headers[keys[k]]);
    }
    if (body.indexOf('#EXTM3U') < 0 && !/mpegurl|video\//i.test(type)) return null;
    return { label: text(line.label) || text(line.provider_name) || '线路', url: url };
  }).catch(function () { return null; });
}

async function probeDirect(lines) {
  var ok = [];
  for (var i = 0; i < lines.length && i < PROBE_LINES && ok.length < 2; i++) {
    var hit = await probeOne(lines[i]);
    if (!hit) continue;
    hit.label = hit.label || ('线路 ' + (ok.length + 1));
    ok.push(hit);
  }
  return ok;
}

// 票券线路：POST /v1/playback/resolve-line 换真地址（要会话，扣额度）
async function resolveTickets(lines) {
  if (!lines.length) return null;
  var tryList = lines.slice(0, TICKET_TRIES);
  for (var i = 0; i < tryList.length; i++) {
    var ticket = text(tryList[i].url).replace(/^resolve:\/\//, '');
    if (!ticket) continue;
    if (!sessionCookie) await ensureSession(false);
    var result = await request('/v1/playback/resolve-line?view=compact', {
      method: 'POST',
      cookie: true,
      body: { ticket: ticket }
    });
    if (result.status === 401) {
      await ensureSession(true);
      result = await request('/v1/playback/resolve-line?view=compact', {
        method: 'POST',
        cookie: true,
        body: { ticket: ticket }
      });
    }
    if (result.status === 402) throw new Error(apiError(result));
    if (result.status !== 200 && result.status !== 201) continue;
    var line = (result.json && result.json.line) || null;
    var url = line ? text(line.url) : '';
    if (!url) continue;
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA }
    };
  }
  return null;
}
