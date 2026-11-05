// LumeSource: {"id":"tingyou_video","name":"听友听书","version":"1.0.0","category":"video","contentCategory":"movie","contentTypes":["audio","video"],"settingsApiVersion":2,"network":"direct","mirrors":["https://fmfm.tingyou.fm","https://www.tingyou.fm","https://tingyou.fm"],"icon":"https://fmfm.tingyou.fm/favicon.svg","settings":[{"key":"note","type":"info","title":"站点说明","description":"听友听书（tingyou.fm）综合站：左侧听书（有声小说 / 评书 / 榜单，mp3 直链）、右侧影视（电影 / 连续剧 / 动漫 / 短剧 / 综艺，HLS）。影视播放用站点自己的游客身份（首次自动领一个匿名游客账号，不需要手机号），线路表里标了 VIP 的线路不走；听书不需要登录。接口域名由站方轮换，脚本会自己探活并缓存可用域名。"}]}

// 听友听书 · 综合源（听书 audio + 影视 video）
//
// 站点：https://tingyou.fm（tingyou.fm / www.tingyou.fm / fmfm.tingyou.fm 都 302 到 /listening，同内容）
// 前端：Nuxt3 SSR 外壳，数据全走接口。两套接口完全不同：
//
// 一、听书（明文 JSON，只要一个会话头）
//   GET  {api}/h5/listening/filters                        → {sorts[], statuses[], categories[{id,name,types[]}]}
//   GET  {api}/h5/listening/category?category=&type=&sort=&page=N  → {data[], page, pages}
//   GET  {api}/h5/listening/rank?section=&page=N            → {items[], has_more, group}
//   GET  {api}/h5/listening/album/{id}                      → 专辑（synopsis / count / cat / type / cover_url）
//   GET  {api}/h5/listening/chapters/{id}                   → {chapters[{id,index,title,duration}]}（一次给全，实测 5329 章）
//   POST {api}/h5/listening/play  {album_id, chapter_idx}   → {play_url}（mp3 直链，带 ts/sign，现取现用）
//   POST {api}/h5/listening/search {keyword, page}          → {results[], has_more}
//   请求头必须带 x-listening-session（v4 UUID）、x-listening-timezone，以及 Origin / Referer；
//   缺 Origin/Referer 时接口直接 404（踩过）。
//
// 二、影视（全部请求与响应都加密，见下）
//   POST {api}/web/v1/tv/call  {operation, params, query, payload?, idempotency_key?}
//   operation：pages.list / catalog.works / catalog.work / catalog.episodes /
//              catalog.work_filters / search.works / playback.lines / playback.session
//
//   加密是站点自己的「伪安全通道」：
//     · 请求体 = AES-256-CBC(PKCS7, key/iv 固定) 的 JSON，整段 base64 后当 body 发（文本，不是 JSON）
//     · 请求头 X-Post-Signature = base64(HMAC-SHA256(8 字节固定密钥, 上面那段 base64 文本))
//     · 请求头 X-Device-Id = 安装 ID（v4 UUID），JSON 里同名字段也带一份
//     · 响应体 = base64(AES-256-CBC(同一固定 key/iv)) → JSON
//   缺签名时服务端回加密的 {"code":400,"message":"missing signature"}（实测）。
//   播放要账号：匿名会回 {"code":401,"message":"需要登录"}；站点 web 端自己会静默领一个
//   「游客账号」（POST /web/user/register/temp），本源照做——首次自动注册、token 存 fs 复用，
//   401 时重领一次。播放地址 = playback.session 回的 manifest_url（自带 EdDSA 签名的 HLS 地址），
//   实测 200 + #EXTM3U；线路表里 is_vip 的线路不取。
//
// 接口域名轮换：站方用一份 AES 加密的「启动头」文件下发当前 api_hosts
//   GET https://toudnbbaa.tou*laopao.cc/api/startup-head/h5api.dat
//   字节布局 = [密文][key 32B][iv 16B]，AES-256-CBC 无填充解出 JSON（api_hosts[] / next_heads[]）。
//   本源会解这个头拿最新域名并探活，失败就退回内置的三个备用域名（都实测过 200）。
//   实测 appp.fdhtbz.cn 会阶段性 404（同一时刻另两个域名 200），所以「探活 + 失败换台」是必需的。
//
// 封面：听书是普通 jpg；影视封面是站方自研的 TVIMAGE1 信封（见 coverHeaders），
//   由 App 侧解码（x-lume-image-encoding: tvimage1）。

var SITE_SEED = 'https://fmfm.tingyou.fm';
var UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';

// 内置备用 API 域名（按优先级；实测三个都能回 /time/seconds）
var API_FALLBACKS = [
  'https://appp.fdhtbz.cn/api',
  'https://ffggewvge.dasfrvvbbhhafdgserqw.cc/api',
  'https://fsfggqwewrr.dsafasfvvaaee.cc/api'
];
// 站方的启动头（下发改过名的 api_hosts / next_heads）
var HEAD_URLS = [
  'https://toudnbbaa.tou1laopao.cc/api/startup-head/h5api.dat',
  'https://toudnbbaa.toulaopao1.cc/api/startup-head/h5api.dat'
];

// 影视接口的固定密钥（站点前端常量，换 key 时改这三行即可）
var AES_KEY_HEX = '11059a4c989dd9d4837778b013d164baa0ad4d7b0076e722369f6f085814293f';
var AES_IV_HEX = 'dd3ea319024c649d2ebcd1bda551a307';
var MAC_KEY_HEX = '51c5b55800a7efd1';
var AES_KEY_B64 = 'EQWaTJid2dSDd3iwE9FkuqCtTXsAduciNp9vCFgUKT8=';
var AES_IV_B64 = '3T6jGQJMZJ0uvNG9pVGjBw==';
var MAC_KEY_B64 = 'UcW1WACn79E=';

var VIDEO_LIMIT = 24;      // catalog.works 单页条数（站点上限 50）
var AUDIO_PAGE = 20;       // 听书分类页站方固定 20 条/页
var GUEST_TTL = 3 * 86400 * 1000;
var API_TTL = 6 * 3600 * 1000;

var CAT_VIDEO = [
  { id: 'v:sort:updated_desc', title: '影视 · 最近更新' },
  { id: 'v:sort:popularity_desc', title: '影视 · 热度榜' },
  { id: 'v:sort:published_desc', title: '影视 · 最新发布' },
  { id: 'v:kind:movie', title: '影视 · 电影' },
  { id: 'v:kind:series', title: '影视 · 连续剧' },
  { id: 'v:kind:short', title: '影视 · 短剧' },
  { id: 'v:kind:anime', title: '影视 · 动漫' },
  { id: 'v:kind:variety', title: '影视 · 综艺' },
  { id: 'v:state:ongoing', title: '影视 · 连载中' },
  { id: 'v:state:completed', title: '影视 · 已完结' }
];

// 听书的「连载榜 / 评书榜」两个 tab 站方返回的内容与「最新上架 / 评书分类」逐条相同
// （实测 section=serial 与 section=latest 前 5 条一致，storytelling 与 category=1 一致），
// 所以这里不重复声明，免得用户点了两个分类看到同一份列表。
var CAT_AUDIO = [
  { id: 'ar:hot', title: '听书 · 热门榜' },
  { id: 'ar:recommend', title: '听书 · 推荐榜' },
  { id: 'ar:latest', title: '听书 · 最新上架' },
  { id: 'a:2', title: '听书 · 有声小说' },
  { id: 'a:1', title: '听书 · 评书' }
];

// ------------------------------------------------------------------ 基础工具

function text(value) {
  return value == null ? '' : String(value);
}

function num(value, fallback) {
  var parsed = Number(value);
  return isFinite(parsed) ? parsed : fallback;
}

function trimSlash(value) {
  return text(value).replace(/\/+$/, '');
}

function siteOrigin() {
  var domain = '';
  try {
    domain = text(LumeSource.config && LumeSource.config.domain);
  } catch (error) {
    domain = '';
  }
  var base = domain || SITE_SEED;
  if (!/^https?:\/\//i.test(base)) base = 'https://' + base;
  return trimSlash(base);
}

// 沙箱里没有 Buffer / TextEncoder，也不保证有 atob，所以自带一套字节工具。
var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function bytesToB64(bytes) {
  var out = '';
  var i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) +
      B64_CHARS.charAt((n >> 6) & 63) + B64_CHARS.charAt(n & 63);
  }
  var rest = bytes.length - i;
  if (rest === 1) {
    var a = bytes[i] << 16;
    out += B64_CHARS.charAt((a >> 18) & 63) + B64_CHARS.charAt((a >> 12) & 63) + '==';
  } else if (rest === 2) {
    var b = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += B64_CHARS.charAt((b >> 18) & 63) + B64_CHARS.charAt((b >> 12) & 63) +
      B64_CHARS.charAt((b >> 6) & 63) + '=';
  }
  return out;
}

function b64ToBytes(input) {
  var raw = text(input).replace(/[^A-Za-z0-9+/=]/g, '');
  var bytes = [];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < raw.length; i += 1) {
    var ch = raw.charAt(i);
    if (ch === '=') break;
    var value = B64_CHARS.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 0xff);
    }
  }
  return bytes;
}

function utf8Bytes(value) {
  var str = text(value);
  var bytes = [];
  for (var i = 0; i < str.length; i += 1) {
    var code = str.charCodeAt(i);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      var next = str.charCodeAt(i + 1);
      var pair = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
      i += 1;
      bytes.push(0xf0 | (pair >> 18), 0x80 | ((pair >> 12) & 0x3f), 0x80 | ((pair >> 6) & 0x3f), 0x80 | (pair & 0x3f));
    } else {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return bytes;
}

function bytesToUtf8(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var byte = bytes[i];
    if (byte < 0x80) {
      out += String.fromCharCode(byte);
      i += 1;
    } else if (byte >= 0xf0) {
      var cp = ((byte & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      i += 4;
    } else if (byte >= 0xe0) {
      out += String.fromCharCode(((byte & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f));
      i += 3;
    } else if (byte >= 0xc0) {
      out += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
      i += 2;
    } else {
      i += 1;
    }
  }
  return out;
}

function hexToBytes(hex) {
  var out = [];
  var clean = text(hex).replace(/[^0-9a-f]/gi, '');
  for (var i = 0; i + 1 < clean.length; i += 2) {
    out.push(parseInt(clean.substr(i, 2), 16));
  }
  return out;
}

function bytesToHex(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 1) {
    var part = bytes[i].toString(16);
    out += part.length === 1 ? '0' + part : part;
  }
  return out;
}

function uuid4() {
  var out = '';
  var i;
  for (i = 0; i < 36; i += 1) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      out += '-';
    } else if (i === 14) {
      out += '4';
    } else if (i === 19) {
      out += '89ab'.charAt(Math.floor(Math.random() * 4));
    } else {
      out += Math.floor(Math.random() * 16).toString(16);
    }
  }
  return out;
}

function needs(value) {
  return value != null && text(value).length > 0;
}

// ------------------------------------------------------------------ 沙箱存储

async function readJson(key) {
  try {
    var raw = await LumeSource.fs.readText(key);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

async function writeJson(key, value) {
  try {
    await LumeSource.fs.writeText(key, JSON.stringify(value));
  } catch (error) {
    /* 存储失败不影响本次调用 */
  }
}

var memoIds = {};
var idPending = {};

async function idOf(key) {
  if (memoIds[key]) return memoIds[key];
  if (idPending[key]) return await idPending[key];
  var work = (async function () {
    var saved = await readJson(key);
    if (saved && needs(saved.value)) return text(saved.value);
    var value = uuid4();
    await writeJson(key, { value: value });
    return value;
  })();
  idPending[key] = work;
  try {
    var resolved = await work;
    memoIds[key] = resolved;
    return resolved;
  } finally {
    delete idPending[key];
  }
}

// ------------------------------------------------------------------ 加密（影视接口）

async function toolsCall(name, payload) {
  var tools = LumeSource.tools;
  if (!tools || typeof tools[name] !== 'function') {
    throw new Error('当前运行环境缺少 tools.' + name + '（影视接口需要宿主原生加解密）');
  }
  return await tools[name](payload);
}

async function aesCbc(dataB64, encrypt) {
  var out = await toolsCall('aes', {
    key: AES_KEY_B64,
    iv: AES_IV_B64,
    data: dataB64,
    mode: 'CBC',
    encrypt: !!encrypt
  });
  return text(out);
}

async function sealText(plainText) {
  return await aesCbc(bytesToB64(utf8Bytes(plainText)), true);
}

async function openText(cipherB64) {
  var plainB64 = await aesCbc(cipherB64, false);
  return bytesToUtf8(b64ToBytes(plainB64));
}

async function signCipher(cipherB64) {
  var hex = await toolsCall('hmac', {
    algorithm: 'sha256',
    key: MAC_KEY_B64,
    keyEncoding: 'base64',
    data: cipherB64
  });
  return bytesToB64(hexToBytes(hex));
}

function deviceMeta() {
  return {
    brand: 'BROWSER',
    model: 'Chrome',
    appVer: '155',
    osVer: '1',
    timestamp: Math.floor(Date.now() / 1000)
  };
}

// ------------------------------------------------------------------ 接口域名解析

var apiState = { base: '', at: 0 };

function apiCandidates() {
  var list = [];
  for (var i = 0; i < API_FALLBACKS.length; i += 1) list.push(API_FALLBACKS[i]);
  return list;
}

function normalizeApiBase(value) {
  var base = trimSlash(text(value));
  if (!/^https?:\/\//i.test(base)) return '';
  // 站方头里的 host 有时没带 /api 后缀
  return /\/api$/i.test(base) ? base : base + '/api';
}

async function decodeHead(reply) {
  var b64 = reply && (reply.bodyBase64 || (reply.binaryBody) || '');
  if (!needs(b64)) return null;
  var bytes = b64ToBytes(b64);
  if (bytes.length < 96) return null;
  var keyB64 = bytesToB64(bytes.slice(bytes.length - 48, bytes.length - 16));
  var ivB64 = bytesToB64(bytes.slice(bytes.length - 16));
  var cipherB64 = bytesToB64(bytes.slice(0, bytes.length - 48));
  // WebCrypto 的 AES-CBC 一定带 PKCS#7，所以头部也是补过位的（实测尾部 07×7）。
  var plainB64 = '';
  try {
    plainB64 = await toolsCall('aes', {
      key: keyB64,
      iv: ivB64,
      data: cipherB64,
      mode: 'CBC',
      encrypt: false
    });
  } catch (error) {
    plainB64 = await toolsCall('aes', {
      key: keyB64,
      iv: ivB64,
      data: cipherB64,
      mode: 'CBC',
      encrypt: false,
      padding: 'none'
    });
  }
  var plain = bytesToUtf8(b64ToBytes(text(plainB64))).replace(/[\u0000-\u001f]+$/, '').trim();
  return JSON.parse(plain);
}

async function hostsFromHead() {
  for (var i = 0; i < HEAD_URLS.length; i += 1) {
    try {
      var reply = await LumeSource.http.request({
        url: HEAD_URLS[i],
        method: 'GET',
        binary: true,
        headers: { 'User-Agent': UA, 'Accept': 'application/octet-stream' }
      });
      if (!reply || reply.status !== 200) continue;
      if (!needs(reply.bodyBase64)) break; // 宿主不支持二进制回包：别白试第二个头地址
      var json = await decodeHead(reply);
      if (!json) continue;
      var hosts = [];
      if (json && json.api_hosts && json.api_hosts.length) {
        for (var h = 0; h < json.api_hosts.length; h += 1) {
          var base = normalizeApiBase(json.api_hosts[h]);
          if (base) hosts.push(base);
        }
      }
      var contracts = json && json.api_host_contracts;
      if (contracts && contracts.length) {
        for (var c = 0; c < contracts.length; c += 1) {
          var cb = normalizeApiBase(contracts[c] && contracts[c].base_url);
          if (cb && hosts.indexOf(cb) < 0) hosts.push(cb);
        }
      }
      if (hosts.length) return hosts;
    } catch (error) {
      /* 换下一个头地址 */
    }
  }
  return [];
}

async function probeApi(base) {
  try {
    var reply = await LumeSource.http.request({
      url: base + '/time/seconds',
      method: 'GET',
      headers: { 'User-Agent': UA, 'Accept': 'application/json', 'Origin': siteOrigin(), 'Referer': siteOrigin() + '/' }
    });
    if (!reply || reply.status !== 200) return false;
    var json = null;
    try { json = JSON.parse(text(reply.body)); } catch (error) { json = null; }
    return !!(json && num(json.code, -1) === 0);
  } catch (error) {
    return false;
  }
}

var apiPending = null;

async function resolveApiBase() {
  var saved = await readJson('api.json');
  if (saved && needs(saved.base) && Date.now() - num(saved.at, 0) < API_TTL) {
    apiState.base = text(saved.base);
    apiState.at = num(saved.at, 0);
    return apiState.base;
  }
  var candidates = [];
  var headed = await hostsFromHead();
  for (var i = 0; i < headed.length; i += 1) {
    if (candidates.indexOf(headed[i]) < 0) candidates.push(headed[i]);
  }
  var fallback = apiCandidates();
  for (var f = 0; f < fallback.length; f += 1) {
    if (candidates.indexOf(fallback[f]) < 0) candidates.push(fallback[f]);
  }
  for (var c = 0; c < candidates.length; c += 1) {
    if (await probeApi(candidates[c])) {
      apiState.base = candidates[c];
      apiState.at = Date.now();
      await writeJson('api.json', { base: apiState.base, at: apiState.at });
      return apiState.base;
    }
  }
  throw new Error('听友的接口域名都探不通（站方在轮换域名，稍后再试）');
}

// 并发调用（home 的五个板块）要共用同一次域名解析，否则会重复探活
async function apiBase(force) {
  if (!force && apiState.base && Date.now() - apiState.at < API_TTL) return apiState.base;
  if (apiPending) return await apiPending;
  apiPending = resolveApiBase();
  try {
    return await apiPending;
  } finally {
    apiPending = null;
  }
}

// ------------------------------------------------------------------ 听书接口（明文 JSON）

async function listeningSession() {
  return await idOf('listening-session.json');
}

async function h5(pathAndQuery, options) {
  var opt = options || {};
  var base = await apiBase();
  var session = await listeningSession();
  var origin = siteOrigin();
  var headers = {
    'User-Agent': UA,
    'Accept': 'application/json, text/plain, */*',
    'Origin': origin,
    'Referer': origin + '/',
    'x-listening-session': session,
    'x-listening-timezone': 'Asia/Shanghai'
  };
  var body;
  if (opt.method === 'POST') {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(opt.body || {});
  }
  var reply = await LumeSource.http.request({
    url: base + pathAndQuery,
    method: opt.method || 'GET',
    headers: headers,
    body: body
  });
  var status = num(reply && reply.status, 0);
  var raw = reply && reply.body != null ? text(reply.body) : '';
  var json = null;
  try { json = raw ? JSON.parse(raw) : null; } catch (error) { json = null; }
  if (json) return json;
  if (status === 404 || status === 405) {
    // 接口域名阶段性 404（实测 appp 会这样）：换台重来一次
    var retryBase = await apiBase(true);
    var retry = await LumeSource.http.request({
      url: retryBase + pathAndQuery,
      method: opt.method || 'GET',
      headers: headers,
      body: body
    });
    var retryRaw = retry && retry.body != null ? text(retry.body) : '';
    var retryJson = null;
    try { retryJson = retryRaw ? JSON.parse(retryRaw) : null; } catch (error) { retryJson = null; }
    if (retryJson) return retryJson;
    throw new Error('听书接口暂时打不开（HTTP ' + num(retry && retry.status, 0) + '）');
  }
  throw new Error('听书接口返回异常（HTTP ' + status + '）');
}

// ------------------------------------------------------------------ 影视接口（加密）

async function postSecure(pathAndQuery, cipherText, token) {
  var base = await apiBase();
  var origin = siteOrigin();
  var headers = {
    'User-Agent': UA,
    'Accept': 'application/json, text/plain, */*',
    'Content-Type': 'application/x-www-form-urlencoded',
    'Origin': origin,
    'Referer': origin + '/',
    'X-Post-Signature': await signCipher(cipherText),
    'X-Device-Id': await idOf('device.json')
  };
  if (token) headers.Authorization = 'Bearer ' + token;
  var reply = await LumeSource.http.request({
    url: base + pathAndQuery,
    method: 'POST',
    headers: headers,
    body: cipherText
  });
  var raw = reply && reply.body != null ? text(reply.body).trim() : '';
  if (!raw) throw new Error('影视接口没有返回内容（HTTP ' + num(reply && reply.status, 0) + '）');
  var plain = '';
  try {
    plain = await openText(raw);
  } catch (error) {
    throw new Error('影视接口返回解不开（站点换密钥了？HTTP ' + num(reply && reply.status, 0) + '）');
  }
  var json = null;
  try { json = JSON.parse(plain); } catch (error) { json = null; }
  if (!json) throw new Error('影视接口返回不是 JSON：' + plain.slice(0, 120));
  return json;
}

var guestPending = null;

async function guestToken(force) {
  if (!force) {
    var saved = await readJson('guest.json');
    if (saved && needs(saved.token) && Date.now() - num(saved.at, 0) < GUEST_TTL) return text(saved.token);
  }
  if (guestPending) return await guestPending;
  guestPending = (async function () {
    var plain = JSON.stringify(Object.assign({ content: '' }, deviceMeta(), { device_id: await idOf('device.json') }));
    var cipher = await sealText(plain);
    var reply = await postSecure('/web/user/register/temp', cipher, '');
    var token = reply && reply.data && reply.data.tokens ? text(reply.data.tokens.accessToken) : '';
    if (!token) throw new Error('游客登录失败：' + text((reply && (reply.message || reply.code)) || ''));
    await writeJson('guest.json', { token: token, at: Date.now() });
    return token;
  })();
  try {
    return await guestPending;
  } finally {
    guestPending = null;
  }
}

async function tvCall(operation, options) {
  var opt = options || {};
  var body = { operation: operation, params: opt.params || {}, query: opt.query || {} };
  if (opt.payload) body.payload = opt.payload;
  if (opt.idempotency_key) body.idempotency_key = opt.idempotency_key;
  Object.assign(body, deviceMeta(), { device_id: await idOf('device.json') });
  var cipher = await sealText(JSON.stringify(body));
  var token = await guestToken(false);
  var reply = await postSecure('/web/v1/tv/call', cipher, token);
  if (num(reply && reply.code, 0) === 401) {
    token = await guestToken(true);
    reply = await postSecure('/web/v1/tv/call', cipher, token);
  }
  return reply;
}

function tvData(reply, label) {
  if (!reply) throw new Error((label || '影视接口') + '没有响应');
  var code = num(reply.code, 0);
  if (code === 200) return reply.data || {};
  var message = text(reply.message || (reply.extra && reply.extra.reason) || '');
  throw new Error((label || '影视接口') + '失败（' + code + '）' + (message ? '：' + message : ''));
}

// ------------------------------------------------------------------ 听书数据

function audioCover(raw) {
  var url = text(raw && raw.cover_url);
  if (!url) return '';
  return url.replace(/^http:\/\//i, 'https://');
}

function audioItem(raw) {
  var title = text(raw && raw.title) || '未命名专辑';
  var parts = [];
  if (needs(raw && raw.teller)) parts.push('播音 ' + text(raw.teller));
  else if (needs(raw && raw.author)) parts.push('作者 ' + text(raw.author));
  if (needs(raw && raw.cat)) parts.push(text(raw.cat));
  if (num(raw && raw.count, 0) > 0) parts.push(num(raw.count, 0) + ' 集');
  return {
    id: 'a:' + text(raw && raw.id),
    title: title,
    cover: audioCover(raw),
    subtitle: parts.join(' · '),
    mediaType: 'audio'
  };
}

async function audioList(query) {
  var q = query || {};
  var path = '/h5/listening/category?page=' + num(q.page, 1) + '&sort=' + text(q.sort || 'comprehensive');
  if (needs(q.category)) path += '&category=' + encodeURIComponent(text(q.category));
  if (needs(q.type)) path += '&type=' + encodeURIComponent(text(q.type));
  var json = await h5(path);
  var rows = json && json.data && json.data.length ? json.data : [];
  var page = num(json && json.page, num(q.page, 1));
  var pages = num(json && json.pages, page);
  var items = [];
  for (var i = 0; i < rows.length; i += 1) {
    if (rows[i] && needs(rows[i].id) && needs(rows[i].title)) items.push(audioItem(rows[i]));
  }
  return { items: items, hasMore: pages > page };
}

async function audioRank(section, page) {
  var json = await h5('/h5/listening/rank?page=' + num(page, 1) + '&section=' + encodeURIComponent(text(section || 'hot')));
  var rows = json && json.items && json.items.length ? json.items : [];
  var items = [];
  for (var i = 0; i < rows.length; i += 1) {
    if (rows[i] && needs(rows[i].id) && needs(rows[i].title)) items.push(audioItem(rows[i]));
  }
  return { items: items, hasMore: !!(json && json.has_more) };
}

async function audioSearch(keyword, page) {
  var json = await h5('/h5/listening/search', { method: 'POST', body: { keyword: text(keyword), page: num(page, 1) } });
  var rows = json && json.results && json.results.length ? json.results : (json && json.items ? json.items : []);
  var items = [];
  for (var i = 0; i < rows.length; i += 1) {
    if (rows[i] && needs(rows[i].id) && needs(rows[i].title)) items.push(audioItem(rows[i]));
  }
  return { items: items, hasMore: !!(json && json.has_more) };
}

async function audioAlbum(albumId) {
  var json = await h5('/h5/listening/album/' + encodeURIComponent(albumId));
  if (!json || !needs(json.id)) return null;
  return json;
}

async function audioChapters(albumId) {
  var json = await h5('/h5/listening/chapters/' + encodeURIComponent(albumId));
  var rows = json && json.chapters && json.chapters.length ? json.chapters : [];
  var list = [];
  for (var i = 0; i < rows.length; i += 1) {
    var row = rows[i];
    if (!row) continue;
    var index = num(row.index, i + 1);
    if (index < 1) index = i + 1;
    list.push({ index: index, title: text(row.title) || ('第 ' + index + ' 集') });
  }
  list.sort(function (a, b) { return a.index - b.index; });
  var out = [];
  for (var k = 0; k < list.length; k += 1) {
    out.push({ id: String(list[k].index), title: list[k].title });
  }
  return out;
}

async function audioContent(albumId, chapterId) {
  var index = num(chapterId, 0);
  if (!(index > 0)) throw new Error('章节序号无效：' + text(chapterId));
  var json = await h5('/h5/listening/play', {
    method: 'POST',
    body: { album_id: text(albumId), chapter_idx: index }
  });
  var url = text(json && json.play_url);
  if (!/^https?:\/\//i.test(url)) throw new Error('站点没有给出播放地址（该集可能需要登录或已下架）');
  var album = null;
  try { album = await audioAlbum(albumId); } catch (error) { album = null; }
  var title = album ? text(album.title) : '';
  return {
    kind: 'audio',
    url: url,
    title: title,
    headers: { 'User-Agent': UA, 'Referer': siteOrigin() + '/' }
  };
}

// ------------------------------------------------------------------ 影视数据

var TVIMAGE_HEADERS = { 'x-lume-image-encoding': 'tvimage1' };

function coverOf(work) {
  if (!work) return '';
  var cover = work.cover || {};
  if (needs(cover.ciphertext_url)) return text(cover.ciphertext_url);
  var covers = work.covers || {};
  if (covers.original && needs(covers.original.ciphertext_url)) return text(covers.original.ciphertext_url);
  if (covers.scaled && needs(covers.scaled.ciphertext_url)) return text(covers.scaled.ciphertext_url);
  return '';
}

function kindLabel(kind) {
  var map = { movie: '电影', series: '连续剧', anime: '动漫', short: '短剧', variety: '综艺', comic: '漫剧', documentary: '纪录片' };
  return map[text(kind)] || '';
}

function videoItem(work, presentation) {
  var w = work || {};
  var cover = coverOf(w) || text(presentation && presentation.image && presentation.image.ciphertext_url);
  var parts = [];
  if (needs(kindLabel(w.kind))) parts.push(kindLabel(w.kind));
  if (needs(w.area)) parts.push(text(w.area));
  if (needs(w.release_year)) parts.push(text(w.release_year));
  if (needs(w.continuation)) parts.push(text(w.continuation));
  else if (needs(w.subtitle)) parts.push(text(w.subtitle));
  var item = {
    id: 'v:' + text(w.id),
    title: text(w.title) || '未命名影片',
    cover: cover,
    subtitle: parts.join(' · '),
    mediaType: 'video'
  };
  if (cover) item.coverHeaders = TVIMAGE_HEADERS;
  return item;
}

function videoQueryOf(categoryId) {
  var id = text(categoryId);
  var query = { limit: String(VIDEO_LIMIT) };
  var sort = 'updated_desc';
  if (id.indexOf('v:kind:') === 0) query.kind = id.slice(7);
  else if (id.indexOf('v:sort:') === 0) sort = id.slice(7);
  else if (id.indexOf('v:state:') === 0) query.serial_state = id.slice(8);
  query.sort = sort || 'updated_desc';
  return query;
}

function chainKey(categoryId) {
  return 'cur-' + text(categoryId).replace(/[^A-Za-z0-9]+/g, '_') + '.json';
}

async function videoList(categoryId, page) {
  var query = videoQueryOf(categoryId);
  var key = chainKey(categoryId);
  var target = Math.max(1, num(page, 1));
  var chain = (await readJson(key)) || { cursors: [] };
  if (!chain || !chain.cursors) chain = { cursors: [] };
  var cursors = chain.cursors;
  // cursors[i] = 取第 i+2 页要用的 cursor（cursors[0] 对应第 2 页）
  var need = target - 1;
  var hops = 0;
  while (cursors.length < need) {
    var cursorForWalk = cursors.length ? cursors[cursors.length - 1] : '';
    if (hops >= 3) throw new Error('这个分类只能从第 1 页顺序往后翻（站方用游标分页）');
    var walk = await tvCall('catalog.works', { query: Object.assign({}, query, cursorForWalk ? { cursor: cursorForWalk } : {}) });
    var walkData = tvData(walk, '影视列表');
    hops += 1;
    if (!walkData.has_more || !needs(walkData.next_cursor)) throw new Error('已经翻到最后一页了');
    cursors.push(text(walkData.next_cursor));
  }
  var cursor = need > 0 ? text(cursors[need - 1]) : '';
  var reply = await tvCall('catalog.works', { query: Object.assign({}, query, cursor ? { cursor: cursor } : {}) });
  var data = tvData(reply, '影视列表');
  var rows = data.items && data.items.length ? data.items : [];
  var items = [];
  for (var i = 0; i < rows.length; i += 1) {
    var work = rows[i] && rows[i].work ? rows[i].work : rows[i];
    if (work && needs(work.id) && needs(work.title)) items.push(videoItem(work, rows[i] && rows[i].presentation));
  }
  if (needs(data.next_cursor) && cursors.length < need + 1) {
    cursors.push(text(data.next_cursor));
    if (cursors.length > 400) cursors = cursors.slice(cursors.length - 400);
  }
  chain.cursors = cursors;
  await writeJson(key, chain);
  return { items: items, hasMore: !!data.has_more };
}

async function videoWork(workId) {
  var reply = await tvCall('catalog.work', { params: { id: text(workId) } });
  var data = tvData(reply, '影视详情');
  if (!data || !needs(data.id)) return null;
  return data;
}

async function videoEpisodes(workId) {
  var all = [];
  var cursor = '';
  var started = Date.now();
  for (var round = 0; round < 14; round += 1) {
    var query = { limit: '100' };
    if (cursor) query.cursor = cursor;
    var reply = await tvCall('catalog.episodes', { params: { id: text(workId) }, query: query });
    var data = tvData(reply, '影视选集');
    var rows = data.items && data.items.length ? data.items : [];
    for (var i = 0; i < rows.length; i += 1) all.push(rows[i]);
    var next = text(data.next_cursor);
    if (!data.has_more || !next || next === cursor) break;
    if (Date.now() - started > 2600) break;
    cursor = next;
  }
  all.sort(function (a, b) {
    var sa = num(a && a.sort_order, num(a && a.episode_number, 0));
    var sb = num(b && b.sort_order, num(b && b.episode_number, 0));
    return sa - sb;
  });
  var out = [];
  for (var k = 0; k < all.length; k += 1) {
    var ep = all[k];
    if (!ep || !needs(ep.id)) continue;
    var title = text(ep.title);
    if (!title || /^\d+$/.test(title)) title = '第 ' + num(ep.episode_number, k + 1) + ' 集';
    out.push({ id: text(ep.id), title: title });
  }
  if (!out.length) {
    // 单片（电影）也走 episodes，真没有就退化成一条「正片」
    out.push({ id: '0', title: '正片' });
  }
  return out;
}

async function videoContent(episodeId) {
  if (!needs(episodeId) || episodeId === '0') {
    throw new Error('这条影片没有可播放的分集');
  }
  var session = await tvCall('playback.session', {
    payload: { episode_id: text(episodeId), platform: 'web', app_version: '1.0.0' },
    idempotency_key: uuid4()
  });
  var data = tvData(session, '影视播放');
  var url = text(data.manifest_url);
  if (!/^https?:\/\//i.test(url)) throw new Error('站点没有给出播放地址（可能需要会员）');
  var qualities = [{ label: '默认线路', url: url }];
  // 线路表：只取非 VIP 线路，最多再补两条
  try {
    var lines = await tvCall('playback.lines', { query: { episode_id: text(episodeId) } });
    var lineData = lines && num(lines.code, 0) === 200 ? lines.data || {} : {};
    var list = lineData.items && lineData.items.length ? lineData.items : [];
    var used = 0;
    for (var i = 0; i < list.length && used < 2; i += 1) {
      var line = list[i];
      if (!line || !needs(line.id) || line.is_vip === true || line.requires_vip === true) continue;
      if (text(line.name) === text(data.line && data.line.name)) continue;
      try {
        var alt = await tvCall('playback.session', {
          payload: { episode_id: text(episodeId), platform: 'web', app_version: '1.0.0', preferred_line_id: text(line.id), manual_line_selection: true },
          idempotency_key: uuid4()
        });
        var altUrl = text(alt && alt.data && alt.data.manifest_url);
        if (/^https?:\/\//i.test(altUrl)) {
          qualities.push({ label: text(line.name) || ('线路 ' + (i + 1)), url: altUrl });
          used += 1;
        }
      } catch (error) {
        /* 这条线路不通就跳过 */
      }
    }
  } catch (error) {
    /* 线路表拿不到就用默认线路 */
  }
  var result = {
    kind: 'video',
    url: url,
    headers: { 'User-Agent': UA, 'Referer': siteOrigin() + '/' }
  };
  // 只有一条线路时不给 qualities：给 1 条反而会让播放器的「清晰度」按钮变成无效入口
  if (qualities.length > 1) result.qualities = qualities;
  return result;
}

// ------------------------------------------------------------------ 搜索

async function searchAll(keyword) {
  var tasks = [
    audioSearch(keyword, 1).catch(function () { return { items: [], hasMore: false }; }),
    (async function () {
      var reply = await tvCall('search.works', { query: { q: text(keyword), limit: '30' } });
      var data = tvData(reply, '影视搜索');
      var rows = data.items && data.items.length ? data.items : [];
      var items = [];
      for (var i = 0; i < rows.length; i += 1) {
        if (rows[i] && needs(rows[i].id) && needs(rows[i].title)) items.push(videoItem(rows[i]));
      }
      return { items: items, hasMore: false };
    })().catch(function () { return { items: [], hasMore: false }; })
  ];
  var results = await Promise.all(tasks);
  var items = [];
  var hasMore = false;
  for (var i = 0; i < results.length; i += 1) {
    if (results[i].hasMore) hasMore = true;
    for (var k = 0; k < results[i].items.length; k += 1) items.push(results[i].items[k]);
  }
  return { items: items, hasMore: hasMore };
}

// ------------------------------------------------------------------ 分类解析

function categoryOf(categoryId) {
  var id = text(categoryId);
  if (id.indexOf('ar:') === 0) return { kind: 'audio-rank', section: id.slice(3) };
  if (id.indexOf('a:') === 0) {
    var rest = id.slice(2);
    var parts = rest.split(':');
    return { kind: 'audio', category: parts[0], type: parts[1] || '' };
  }
  if (id.indexOf('t:') === 0) return { kind: 'audio', category: '', type: id.slice(2) };
  if (id.indexOf('v:') === 0) return { kind: 'video' };
  return { kind: 'video' };
}

async function audioTypeCategories() {
  var json = await h5('/h5/listening/filters');
  var cats = json && json.categories && json.categories.length ? json.categories : [];
  var out = [];
  for (var i = 0; i < cats.length; i += 1) {
    var cat = cats[i];
    if (!cat || !cat.types || !cat.types.length) continue;
    for (var k = 0; k < cat.types.length; k += 1) {
      var type = cat.types[k];
      if (!type || !needs(type.id)) continue;
      out.push({ id: 't:' + text(type.id), title: '听书 · ' + text(type.name) });
    }
  }
  return out;
}

// ------------------------------------------------------------------ 五个入口

var LumeSource = {
  async categories() {
    var list = [];
    var i;
    for (i = 0; i < CAT_AUDIO.length; i += 1) list.push(CAT_AUDIO[i]);
    try {
      var types = await audioTypeCategories();
      for (i = 0; i < types.length; i += 1) list.push(types[i]);
    } catch (error) {
      /* 题材拿不到就只给固定分类，不影响浏览 */
    }
    for (i = 0; i < CAT_VIDEO.length; i += 1) list.push(CAT_VIDEO[i]);
    return list;
  },

  async home() {
    // 五个板块并发拉，冷启动（探域名 + 领游客账号）也能压在一次调用的预算里
    var results = await Promise.all([
      audioRank('hot', 1).catch(function () { return { items: [] }; }),
      audioRank('recommend', 1).catch(function () { return { items: [] }; }),
      videoList('v:sort:popularity_desc', 1).catch(function () { return { items: [] }; }),
      videoList('v:kind:movie', 1).catch(function () { return { items: [] }; }),
      videoList('v:kind:short', 1).catch(function () { return { items: [] }; })
    ]);
    var sections = [];
    var plan = [
      { index: 0, title: '听书 · 热门', moreUrl: 'ar:hot' },
      { index: 1, title: '听书 · 推荐', moreUrl: 'ar:recommend' },
      { index: 2, title: '影视 · 热播', moreUrl: 'v:sort:popularity_desc' },
      { index: 3, title: '影视 · 电影', moreUrl: 'v:kind:movie' },
      { index: 4, title: '影视 · 短剧', moreUrl: 'v:kind:short' }
    ];
    for (var i = 0; i < plan.length; i += 1) {
      var got = results[plan[i].index];
      if (got && got.items && got.items.length) {
        sections.push({ title: plan[i].title, moreUrl: plan[i].moreUrl, items: got.items.slice(0, 12) });
      }
    }
    return sections;
  },

  async list(argument) {
    var arg = argument || {};
    var page = Math.max(1, num(arg.page, 1));
    var keyword = text(arg.keyword).trim();
    if (keyword) return await searchAll(keyword);
    var categoryId = text(arg.categoryId);
    var parsed = categoryOf(categoryId);
    if (parsed.kind === 'audio-rank') return await audioRank(parsed.section, page);
    if (parsed.kind === 'audio') {
      // 站方的分类页只有「综合排序」这一个稳定口径（sort=popular/updated 也认，但和分类叠加时会漏条），
      // 所以分类走综合排序，热度/最新由上面的榜单分类承担。
      return await audioList({ category: parsed.category, type: parsed.type, page: page, sort: 'comprehensive' });
    }
    return await videoList(categoryId || 'v:sort:updated_desc', page);
  },

  async detail(argument) {
    var id = text(argument && argument.id);
    if (id.indexOf('a:') === 0) {
      var album = await audioAlbum(id.slice(2));
      if (!album) return null;
      var parts = [];
      if (needs(album.teller)) parts.push('播音 ' + text(album.teller));
      if (needs(album.author)) parts.push('作者 ' + text(album.author));
      if (needs(album.cat)) parts.push(text(album.cat));
      if (num(album.count, 0) > 0) parts.push(num(album.count, 0) + ' 集');
      return {
        id: id,
        title: text(album.title) || '未命名专辑',
        cover: audioCover(album),
        subtitle: parts.join(' · '),
        description: text(album.synopsis),
        mediaType: 'audio',
        author: text(album.author)
      };
    }
    if (id.indexOf('v:') === 0) {
      var work = await videoWork(id.slice(2));
      if (!work) return null;
      var labels = [];
      if (needs(kindLabel(work.kind))) labels.push(kindLabel(work.kind));
      if (needs(work.area)) labels.push(text(work.area));
      if (needs(work.release_year)) labels.push(text(work.release_year));
      if (num(work.score, 0) > 0) labels.push('评分 ' + num(work.score, 0));
      var cover = coverOf(work);
      var detail = {
        id: id,
        title: text(work.title) || '未命名影片',
        cover: cover,
        subtitle: labels.join(' · '),
        description: text(work.description),
        mediaType: 'video'
      };
      if (cover) detail.coverHeaders = TVIMAGE_HEADERS;
      return detail;
    }
    return null;
  },

  async chapters(argument) {
    var id = text(argument && argument.id);
    if (id.indexOf('a:') === 0) return await audioChapters(id.slice(2));
    if (id.indexOf('v:') === 0) return await videoEpisodes(id.slice(2));
    return [];
  },

  async content(argument) {
    var arg = argument || {};
    var id = text(arg.id);
    var chapterId = text(arg.chapterId);
    if (id.indexOf('a:') === 0) return await audioContent(id.slice(2), chapterId);
    if (id.indexOf('v:') === 0) return await videoContent(chapterId);
    throw new Error('未知内容：' + id);
  }
};
