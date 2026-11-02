// LumeSource: {"id":"kkav_video","name":"KKAV","version":"1.2.0","category":"video","contentCategory":"adult","mirrors":["https://www.32auqm.com","https://www.85fazc.com"],"network":"direct","icon":"https://www.32auqm.com/static/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：KKAV（https://www.32auqm.com，原 37tmrj → 73tfhk → 85fazc → 32auqm；成人视频站，全站 18+）
//
// 一、域名沿革（每次换域都从旧域的跳板页里读出来，v1.2.0 起脚本自动做）
//   www.37tmrj.com / www.24nbfp.com / ttss66.com（"永久官网"）都只是一张「换域名」页，
//   页内 `url2.push("下一站")` 给新域。2026-11-02 的链条：85fazc.com → 32auqm.com，
//   www.85fazc.com 现在**只回那张跳板页**，而且 /api/* 一律 406 —— App 里那句
//   「接口打不开：HTTP 406 (/movie/list?page=1&pageSize=20)」就是旧域 85fazc 被拦的结果。
//   新站 www.32auqm.com 实测：/api/config/ini、/api/movie/tags、/api/movie/home_sections、
//   /api/movie/list 全部 200 + XOR2 信封。
//   ⚠ 站点**只收 https**：http:// 的 /api/* 直接 406，所以域名一律强制升到 https。
//
// 一·二、换域名自愈（v1.2.0）
//   SEED_HOSTS 是真站；JUMP_HOSTS 是只回跳板页的旧域。currentHost() 先探种子（/api/movie/tags
//   200 且回 XOR2 信封才算真站），全废就问 JUMP_HOSTS 的根路径 —— 先看 reply.url 的 origin
//   （旧域可能直接 302 到新域），再从跳板页正文里解 `url2.push("新域")`，探到一个能用的就
//   写 host.json（12 小时）。接口中途返回非 200（换域那一刻）会清缓存再走一遍这条链。
//
// 二、接口全部是 XOR2 加密（这就是旧源"渲染后没认出卡片"的原因）
//   响应形如 {"enc":3,"alg":"XOR2","n":"<11 位随机>","d":"<base64url 密文>"}，
//   解密算法抄自站点主包（已用真实响应验证）：
//     key   = mgrEncryptKey（/api/config/ini 里给出，默认 "Mumu2026#"）
//     seed  = FNV-1a(`${key}|${n}`)                     ← 32 位
//     每 4 字节推进一次 xorshift32（t^=t<<13; t^=t>>>17; t^=t<<5），
//     该 4 字节依次取 (seed>>>0)&255、(seed>>>8)&255、(seed>>>16)&255、(seed>>>24)&255 与密文异或。
//
// 三、接口（实测）
//   GET /api/config/ini                     配置（图片/CDN 域、站点名、mgrEncryptKey…）
//   GET /api/movie/tags                     分类 → 子标签（tagid）
//   GET /api/movie/home_sections?pageSize=40 首页分区
//   GET /api/movie/list?page=1&pageSize=20[&tagid=][&tagCateChildId=][&keyword=]
//        → {code:0, data:[{movieid, Topic, smallpic, h264mp4url, formatted_timesize, …}], total}
//   列表项**自带 h264mp4url**，其中 down.baidu.com 这个域名在本机被 RST，
//   换配置里的 down 域 down.mm7878.com 同一路径 → 206 video/mp4（源里自动改写）。
// 18+

var BASE_URL = 'https://www.32auqm.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 20;
var DEFAULT_KEY = 'Mumu2026#';
var DOWN_HOST = 'https://down.mm7878.com';
// smallpic 的 sq.2277ww.com 已经连不上；同路径换到配置里的图片域（实测 200 image/jpeg）
var COVER_HOST = 'https://fengmian.gszy12348.com/data/';
var NAV_TTL_MS = 6 * 3600 * 1000;

// ── 换域名自愈 ──
// 站点 2 周左右换一次域名，换域后**旧域的 /api/* 一律 406**（App 里「接口打不开：HTTP 406」就是它），
// 旧域根路径却还回一张「换域名」跳板页：页内 eval(decodeURIComponent('url2%2Epush%28%22新域%22%29…'))。
// 所以域名候选分两类：
//   SEED_HOSTS：当前真站（/api/* 200 + XOR2 密文）
//   JUMP_HOSTS：只回跳板页的旧域，用来读出下一站域名
var SEED_HOSTS = ['https://www.32auqm.com'];
var JUMP_HOSTS = ['https://www.85fazc.com', 'https://www.73tfhk.com', 'https://www.37tmrj.com', 'https://ttss66.com'];
var HOST_FILE = 'host.json';
var HOST_TTL = 12 * 3600 * 1000;
var FAIL_FILE = 'discover.json';
var FAIL_TTL = 10 * 60 * 1000;
var ACTIVE_HOST = '';

// 站点只收 https：http:// 的 /api/* 一律 406（用户手填域名 / 旧订阅里常有 http）
function normalizeHost(text) {
  var s0 = String(text || '').replace(/\/+$/, '');
  if (!s0) return '';
  if (/^http:\/\//i.test(s0)) return 'https://' + s0.substring(7);
  if (!/^https:\/\//i.test(s0)) return 'https://' + s0.replace(/^\/+/, '');
  return s0;
}

function userDomain() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return domain ? normalizeHost(domain) : '';
}

function base() {
  return ACTIVE_HOST || userDomain() || BASE_URL;
}

// 一台主机是不是真站：/api/movie/tags 必须 200 且回 XOR2 信封（旧域会 406 或回跳板页）
async function probeHost(host) {
  try {
    var reply = await LumeSource.http.get(host + '/api/movie/tags', {
      headers: { 'User-Agent': UA, Accept: 'application/json', Referer: host + '/' },
    });
    if (!reply || reply.status !== 200) return false;
    var body = String(reply.body || '');
    return body.indexOf('"enc"') >= 0 || body.indexOf('"d":"') >= 0;
  } catch (error) {
    return false;
  }
}

// 从跳板页里读域名：`url2.push("xxx.com")`（被 decodeURIComponent 包着），也兼容 `url2 = new Array("a","b")`
function jumpHostsIn(html) {
  var text = String(html || '');
  var decoded = text.replace(/decodeURIComponent\('([^']*)'\)/g, function (all, payload) {
    try { return decodeURIComponent(payload); } catch (error) { return ''; }
  });
  var out = [];
  var push = /url2\.push\(\s*["']([^"']+)["']\s*\)/g;
  var matched;
  while ((matched = push.exec(decoded)) !== null) out.push(matched[1]);
  var array = /url2\s*=\s*new\s+Array\(([^)]*)\)/.exec(decoded);
  if (array) {
    var quote = /["']([^"']+)["']/g;
    var one;
    while ((one = quote.exec(array[1])) !== null) out.push(one[1]);
  }
  var list = [];
  for (var i = 0; i < out.length; i++) {
    var raw = String(out[i] || '').trim().replace(/^www\./i, '');
    if (!raw) continue;
    var host = /^https?:\/\//i.test(raw) ? normalizeHost(raw) : 'https://www.' + raw.replace(/\/+$/, '');
    if (list.indexOf(host) < 0) list.push(host);
  }
  return list;
}

// 已知域名全废时：问跳板页要下一站，探活成功后缓存 12 小时；失败退避 10 分钟
async function discoverHost() {
  var last = await readJson(FAIL_FILE);
  if (last && last.failAt && Date.now() - Number(last.failAt) < FAIL_TTL) return '';
  var note = '';
  for (var i = 0; i < JUMP_HOSTS.length; i++) {
    var jumper = JUMP_HOSTS[i];
    var reply = null;
    try {
      reply = await LumeSource.http.get(jumper + '/', {
        headers: { 'User-Agent': UA, Accept: 'text/html,*/*;q=0.8' },
      });
    } catch (error) {
      note = String((error && error.message) || error);
      continue;
    }
    var body = reply && reply.body ? String(reply.body) : '';
    // 旧域根路径也可能直接 302 到新域：最终地址的 origin 优先试
    var candidates = [];
    if (reply && reply.url) {
      var origin = /^(https?:\/\/[^\/?#]+)/i.exec(String(reply.url));
      if (origin && origin[1] !== jumper) candidates.push(normalizeHost(origin[1]));
    }
    var inPage = jumpHostsIn(body);
    for (var k = 0; k < inPage.length; k++) if (candidates.indexOf(inPage[k]) < 0) candidates.push(inPage[k]);
    for (var j = 0; j < candidates.length; j++) {
      if (await probeHost(candidates[j])) {
        await writeJson(HOST_FILE, { at: Date.now(), host: candidates[j] });
        ACTIVE_HOST = candidates[j];
        return candidates[j];
      }
    }
    if (!candidates.length && body) note = jumper + ' 的跳板页里没读到域名';
  }
  await writeJson(FAIL_FILE, { failAt: Date.now(), note: note });
  return '';
}

// 当前可用主机：内存 → 缓存（12 小时）→ 用户手选 → 种子；都不行就自发现
async function currentHost() {
  if (ACTIVE_HOST) return ACTIVE_HOST;
  var cached = await readJson(HOST_FILE);
  if (cached && cached.host && Date.now() - Number(cached.at || 0) < HOST_TTL) {
    ACTIVE_HOST = normalizeHost(cached.host);
    return ACTIVE_HOST;
  }
  var seeds = [];
  var picked = userDomain();
  if (picked) seeds.push(picked);
  for (var i = 0; i < SEED_HOSTS.length; i++) if (seeds.indexOf(SEED_HOSTS[i]) < 0) seeds.push(SEED_HOSTS[i]);
  for (var j = 0; j < seeds.length; j++) {
    if (await probeHost(seeds[j])) {
      ACTIVE_HOST = seeds[j];
      await writeJson(HOST_FILE, { at: Date.now(), host: ACTIVE_HOST });
      return ACTIVE_HOST;
    }
  }
  var found = await discoverHost();
  if (found) return found;
  ACTIVE_HOST = normalizeHost(picked || BASE_URL);
  return ACTIVE_HOST;
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

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

// ---------------------------------------------------------------- XOR2

var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function b64ToBytes(text) {
  var s = String(text || '').replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i);
    if (ch === '=') break;
    var v = B64.indexOf(ch);
    if (v < 0) continue;
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var c = bytes[i++];
    if (c < 0x80) out += String.fromCharCode(c);
    else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f));
    else if (c < 0xf0) out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    else {
      var cp = (((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)) - 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

function utf8Encode(text) {
  var s = String(text == null ? '' : text);
  var out = [];
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c < 0xd800 || c >= 0xe000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    else {
      i++;
      var cp = 0x10000 + (((c & 0x3ff) << 10) | (s.charCodeAt(i) & 0x3ff));
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    }
  }
  return out;
}

function fnv1a(text) {
  var bytes = utf8Encode(text);
  var h = 2166136261;
  for (var i = 0; i < bytes.length; i++) {
    h = (h ^ bytes[i]) >>> 0;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

function xorshift32(seed) {
  var t = seed >>> 0;
  t = (t ^ ((t << 13) >>> 0)) >>> 0;
  t = (t ^ (t >>> 17)) >>> 0;
  t = (t ^ ((t << 5) >>> 0)) >>> 0;
  return t >>> 0;
}

function xor2Decrypt(payload, keyText) {
  var bytes = b64ToBytes(payload.d);
  var seed = fnv1a(String(keyText || DEFAULT_KEY) + '|' + String(payload.n || '')) || 2166136261;
  var out = [];
  var r = 0;
  for (var i = 0; i < bytes.length; i++) {
    if ((3 & i) === 0) {
      seed = xorshift32(seed);
      r = seed;
    }
    out.push(bytes[i] ^ ((r >>> (8 * (3 & i))) & 0xff));
  }
  return utf8Decode(out);
}

// ---------------------------------------------------------------- 接口

var _apiKey = null;

async function apiKey() {
  if (_apiKey) return _apiKey;
  var cached = await readJson('key.json');
  if (cached && cached.key && Date.now() - Number(cached.at) < 12 * 3600 * 1000) {
    _apiKey = cached.key;
    return _apiKey;
  }
  _apiKey = DEFAULT_KEY;
  try {
    await currentHost();
    var reply = await LumeSource.http.get(base() + '/api/config/ini', {
      headers: { 'User-Agent': UA, Accept: 'application/json' },
    });
    if (reply && reply.status === 200) {
      var raw = JSON.parse(reply.body ? String(reply.body) : '{}');
      var text = typeof raw.d === 'string' ? xor2Decrypt(raw, DEFAULT_KEY) : (reply.body || '');
      var obj = JSON.parse(text);
      var key = obj && obj.data && obj.data.system ? obj.data.system.mgrEncryptKey : '';
      if (key) _apiKey = String(key);
    }
  } catch (error) {
    _apiKey = DEFAULT_KEY;
  }
  await writeJson('key.json', { at: Date.now(), key: _apiKey });
  return _apiKey;
}

async function fetchApi(path) {
  return await LumeSource.http.get(base() + '/api' + path, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: base() + '/' },
  });
}

// 换域名自愈：丢掉主机缓存 + 失败退避，问一次跳板页，探到新域就再取一次
async function rediscover() {
  ACTIVE_HOST = '';
  await writeJson(HOST_FILE, { at: 0, host: '' });
  await writeJson(FAIL_FILE, { failAt: 0, note: '' });
  var found = await discoverHost();
  if (found) return true;
  ACTIVE_HOST = normalizeHost(userDomain() || BASE_URL);
  return false;
}

async function call(path) {
  await currentHost();
  var key = await apiKey();
  var reply = await fetchApi(path);
  if (!reply || reply.status !== 200) {
    // 旧域换域名后 /api/* 直接 406，走的正是这条分支
    if (await rediscover()) reply = await fetchApi(path);
  }
  if (!reply || reply.status !== 200) throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  var text = reply.body ? String(reply.body) : '';
  var raw;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  if (raw && typeof raw.d === 'string') {
    var plain = xor2Decrypt(raw, key);
    try {
      return JSON.parse(plain);
    } catch (error) {
      throw new Error('XOR2 解不开（站点换口令了？）：' + path);
    }
  }
  return raw;
}

function playUrl(item) {
  var url = String((item && (item.h264mp4url || item.mp4url || item.m3u8url)) || '');
  if (!url) return '';
  // down.baidu.com 这个域名在本机被 RST，换同路径的 down 域
  return url.replace(/^https?:\/\/down\.baidu\.com\//i, DOWN_HOST + '/');
}

function coverUrl(item) {
  var raw = String(item.smallpic || item.pic || '');
  if (!raw) return '';
  var path = raw.replace(/^https?:\/\/[^\/]+\//i, '');
  if (/^cover\//.test(path)) return COVER_HOST + path;
  return raw;
}

function mapItem(item) {
  return {
    id: String(item.movieid || item.id || ''),
    title: clean(item.Topic || item.title || ''),
    cover: coverUrl(item),
    subtitle: String(item.formatted_timesize || ''),
  };
}

async function remember(items) {
  if (!items.length) return;
  var cached = (await readJson('items.json')) || { map: {} };
  var map = cached.map || {};
  for (var i = 0; i < items.length; i++) {
    map[items[i].id] = { title: items[i].title, cover: items[i].cover, subtitle: items[i].subtitle, play: items[i].play || '' };
  }
  await writeJson('items.json', { at: Date.now(), map: map });
}

async function navTags() {
  var cached = await readJson('tags.json');
  if (cached && Array.isArray(cached.list) && cached.list.length && Date.now() - Number(cached.at) < NAV_TTL_MS) {
    return cached.list;
  }
  var data = await call('/movie/tags');
  var rows = data && Array.isArray(data.data) ? data.data : [];
  var list = [];
  for (var i = 0; i < rows.length; i++) {
    var group = clean(rows[i].category || rows[i].categoryShow || '');
    var tags = Array.isArray(rows[i].tags) ? rows[i].tags : [];
    for (var j = 0; j < tags.length; j++) {
      var tag = tags[j];
      if (!tag || tag.id == null) continue;
      list.push({
        id: String(tag.id),
        title: (group ? group + '·' : '') + clean(tag.name || tag.nameShort || ('标签 ' + tag.id)),
      });
    }
  }
  if (!list.length) list.push({ id: '', title: '全部' });
  await writeJson('tags.json', { at: Date.now(), list: list });
  return list;
}

var LumeSource = {
  id: 'kkav_video',
  name: 'KKAV',
  version: '1.2.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://www.32auqm.com', 'https://www.85fazc.com'],

  async categories() {
    var list = [{ id: 'all', title: '全部' }];
    try {
      var tags = await navTags();
      for (var i = 0; i < tags.length; i++) list.push({ id: 'tag:' + tags[i].id, title: tags[i].title });
    } catch (error) {
      /* 分类拿不到时至少还能看全部 */
    }
    return list;
  },

  async home() {
    var boards = [];
    try {
      var data = await call('/movie/home_sections?pageSize=40');
      var sections = data && Array.isArray(data.data) ? data.data : [];
      for (var i = 0; i < sections.length && boards.length < 4; i++) {
        var movies = Array.isArray(sections[i].movies) ? sections[i].movies : [];
        if (!movies.length) continue;
        var items = movies.slice(0, 12).map(mapItem);
        for (var k = 0; k < movies.length && k < 12; k++) items[k].play = playUrl(movies[k]);
        await remember(items);
        boards.push({ title: clean(sections[i].tagname || '推荐') || '推荐', moreUrl: sections[i].tagid ? ('tag:' + sections[i].tagid) : 'all', items: items });
      }
    } catch (error) {
      /* 首页分区失败就退回列表第一页 */
    }
    if (!boards.length) {
      try {
        var page = await this.list({ page: 1 });
        if (page.items.length) boards.push({ title: '最新', moreUrl: 'all', items: page.items.slice(0, 12) });
      } catch (error) {
        throw error;
      }
    }
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1) || 1;
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    if (filters.tag) categoryId = 'tag:' + String(filters.tag).replace(/^tag:/, '');
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var path = '/movie/list?page=' + page + '&pageSize=' + PAGE_SIZE;
    if (keyword) path += '&keyword=' + encodeURIComponent(keyword);
    else if (/^tag:/.test(categoryId)) path += '&tagid=' + encodeURIComponent(categoryId.slice(4));

    var data = await call(path);
    var rows = data && Array.isArray(data.data) ? data.data : [];
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var mapped = mapItem(rows[i]);
      if (!mapped.id) continue;
      mapped.play = playUrl(rows[i]);
      items.push(mapped);
    }
    await remember(items);
    var total = Number(data && data.total) || 0;
    var hasMore = total ? page * PAGE_SIZE < total : items.length >= PAGE_SIZE;
    return {
      items: items.map(function (row) {
        return { id: row.id, title: row.title, cover: row.cover, subtitle: row.subtitle };
      }),
      hasMore: hasMore,
    };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var cached = (await readJson('items.json')) || { map: {} };
    var row = cached.map ? cached.map[id] : null;
    return {
      id: id,
      title: row && row.title ? row.title : ('视频 ' + id),
      cover: row && row.cover ? row.cover : '',
      subtitle: row && row.subtitle ? row.subtitle : '',
      description: '源站：' + base() + '\n接口为 XOR2 加密（源内解密）；播放走列表自带 mp4（down 域已改写）。',
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    return [{ id: 'video:' + id, title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('缺少视频 ID');
    var cached = (await readJson('items.json')) || { map: {} };
    var row = cached.map ? cached.map[id] : null;
    var url = row && row.play ? String(row.play) : '';
    if (!url) throw new Error('这条没带播放地址（列表缓存过期了，回列表刷新一次）');
    return { kind: 'video', url: url, headers: { 'User-Agent': UA, Referer: base() + '/' } };
  },
};
