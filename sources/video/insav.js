// LumeSource: {"id":"insav_video","name":"INSAV","version":"1.2.0","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://fnay47.com","https://dcuj77.com","https://pqtn95.com"],"network":"direct","icon":"https://fnay47.com/logo.png","settings":[{"key":"token","type":"text","title":"登录 token（可选，用于原生播放）","description":"站点的播放接口 getVideoUrl 要登录态，而登录强制图形验证码（captcha/get 每次换图），源里没法自动过。做法：在浏览器打开当前站点（镜像第一项）→ 登录 → DevTools → Application → Local Storage → 复制 ins_tokenxyz 的值，粘到这里。填了就走原生播放；留空则播放交给站内网页。"},{"key":"note","type":"info","title":"站点说明","description":"INS AV（接口域每次换，源内会自己问站方跳转服务拿到当前域；日本 AV 厂牌聚合，全站 18+）。分区按 site：1 有码 / 2 无码 / 3 动漫 / 4 4K；type=3 是免费放送。接口参数整体 AES-256 加密 + md5 签名（源内用宿主原生 tools.aes / tools.digest）。旧域会整页跳转，源会自动跟上并把新域缓存 12 小时；也可以在「源设置」里手填当前域名。"}]}
// LumeRuntime: javascript
//
// 站点：INS AV（接口域随机轮换；全站 18+，日本 AV 厂牌聚合）
// 来源：从「暮色」App（com.look.mbox / avbox 1.0.1）的 insav 模块挖出来的站与协议，
//       2026-11-03 按真机反馈的第二轮修复（换域自愈 + 封面 data-uri）。
//
// 一、三件事（缺一个都不通）
//   1. **接口域一直换**：网页和 API 同源（SPA 里就是相对路径 `/api/...`），
//      换域时旧域只剩一张「跳转页」：GET 返回 1.8 KB 的 Loading 页，
//      里面一行 `window.atob("aHR0cHM6...")`，解出来是跳转服务地址，
//      用它拼 `?u=<base64(旧域)>&p=<base64(路径)>` 会 302 到当前域。
//      旧域对 POST 一律 405（静态页服务器不接 POST）——这就是真机上
//      「HTTP 405 (video/indexLists)」的全部原因。
//   2. **请求体整体加密**：参数先算签名，再 `{"post-data": AES(JSON)}`。
//   3. **响应也加密**：`{"code":1,"data":"<base64>","suffix":"<6hex>"}`，AES-256-CBC 解出 JSON。
//
// 二、加密与签名（2026-11-02 用真实请求逐字节核对，2026-11-03 复验）
//   key = "0XxdjmI55ZjjqQLO3nI7gGqrBP0Vz9jS"（32 字节 → AES-256）
//   iv  = "RWf23muavY" + suffix（10 + 6 = 16 字节）
//        请求用 header 里的 suffix（固定 "NWSdef"）；响应用响应体自带的 suffix
//   签名 encode_sign = md5( 参数按 key 排序拼 "k=v&" + "NRkw0g3iJLDvw5tJ5PuVt5276z0SOuyL" )
//     ⚠ 那个 sign_key 里是 **5tJ5**，不是 5t5 —— 抄错一个字符就会一直「签名错误」。
//   参数基线：site=1..4（有码/无码/动漫/4K）+ device（手机 1 / 桌面 2）+ timestamp（毫秒）
//
// 三、接口（全部 POST，body 是 post-data）
//   video/indexLists {site, page, limit, type}  type=1 列表 / type=3 免费放送
//        → {data:{total, per_page, current_page, last_page, data:[{id,title,thumb,preview,
//           actor{name},publisher{name},play,collect_count,subtitle}]}}
//   video/info {vid}   → 详情（title/tags/actor/description/publish_date/zimu 字幕/panorama）
//        ⚠ 参数名是 **vid**，传 id/video_id 都回「视频不存在」
//   video/getVideoUrl {vid} → 需要登录（会在没登录时回 code 2000「登录已失效」）
//   tag/lists、actor/lists、banner/lists、config/lists
//
// 四、封面
//   条目里的 thumb 是相对路径（/ms/syms/.../xxx_ver.jpg），API 域上不是图；
//   真图在图片 CDN `https://yik.yanyunhome.com` + 同一路径。
//   **注意**：这个 CDN 把整张图包成 `data:image/jpeg;base64,…` 纯文本下发
//   （响应头却写着 image/jpeg），所以列表项带
//   `x-lume-image-encoding: data-uri`，由 App 侧解包后再显示。
//
// 五、播放（限制）
//   getVideoUrl 要登录态（登录要图形验证码），本源不做账号体系：
//   content 返回 webplayer（站内详情页），由网页播放器播；要原生播放就在源设置里填 token。

var SEEDS = ['https://fnay47.com', 'https://dcuj77.com', 'https://pqtn95.com'];
var IMG_HOST = 'https://yik.yanyunhome.com';
var AES_KEY = '0XxdjmI55ZjjqQLO3nI7gGqrBP0Vz9jS';
var IV_PREFIX = 'RWf23muavY';
var REQ_SUFFIX = 'NWSdef';
var SIGN_KEY = 'NRkw0g3iJLDvw5tJ5PuVt5276z0SOuyL';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 12;
var HOST_FILE = 'host.json';
var HOST_TTL = 12 * 3600 * 1000;
var COVER_HEADERS = { 'x-lume-image-encoding': 'data-uri' };

var CATEGORIES = [
  { id: 'c1', title: '有码', site: 1, type: 1 },
  { id: 'c2', title: '无码', site: 2, type: 1 },
  { id: 'c3', title: '动漫', site: 3, type: 1 },
  { id: 'c4', title: '4K', site: 4, type: 1 },
  { id: 'free', title: '免费放送', site: 1, type: 3 },
];

/* ══════════════════════════════════════ 换域自愈 ══════════════════════════════════════ */

var ACTIVE_HOST = '';

function readJson(file) {
  return LumeSource.fs.readText(file).then(function (raw) {
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (error) { return null; }
  }).catch(function () { return null; });
}

function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}

function configDomain() {
  var value = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return value ? value.replace(/\/+$/, '') : '';
}

// `https://www.abc.top/x?y=1` → `https://www.abc.top`
function originOf(url) {
  var matched = /^(https?:\/\/[^\/?#]+)/i.exec(String(url == null ? '' : url));
  return matched ? matched[1] : '';
}

function normalizeHost(host) {
  var text = String(host == null ? '' : host).trim().replace(/\/+$/, '');
  if (!text) return '';
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

// 缓存：用户手选 > 上次成功 > 内置种子
async function activeHost() {
  if (ACTIVE_HOST) return ACTIVE_HOST;
  var selected = configDomain();
  var cached = await readJson(HOST_FILE);
  if (cached && cached.host && cached.selected === selected &&
      Date.now() - Number(cached.at || 0) < HOST_TTL) {
    ACTIVE_HOST = String(cached.host);
    return ACTIVE_HOST;
  }
  ACTIVE_HOST = selected || SEEDS[0];
  return ACTIVE_HOST;
}

async function rememberHost(host) {
  var text = normalizeHost(host);
  if (!text) return;
  ACTIVE_HOST = text;
  var selected = configDomain();
  var cached = await readJson(HOST_FILE);
  if (cached && cached.host === text && cached.selected === selected &&
      Date.now() - Number(cached.at || 0) < HOST_TTL / 2) return;
  await writeJson(HOST_FILE, { at: Date.now(), selected: selected, host: text });
}

async function hostCandidates() {
  var out = [];
  function push(host) {
    var text = normalizeHost(host);
    if (text && out.indexOf(text) < 0) out.push(text);
  }
  push(ACTIVE_HOST);
  push(await activeHost());
  push(configDomain());
  for (var i = 0; i < SEEDS.length; i++) push(SEEDS[i]);
  return out;
}

async function b64Encode(text) {
  try { return btoa(text); } catch (error) { /* 老宿主没有垫片 */ }
  try { return await LumeSource.tools.base64Encode(String(text)); } catch (error) { return ''; }
}

// 跳转页里那一行 `window.atob("<base64 的跳转服务地址>")`
async function jumpBaseOf(body) {
  var text = String(body == null ? '' : body);
  if (text.indexOf('atob') < 0) return '';
  var matched = /window\.atob\(\s*["']([A-Za-z0-9+/=]{8,})["']\s*\)/.exec(text);
  if (!matched) return '';
  var plain = '';
  try { plain = atob(matched[1]); } catch (error) { plain = ''; }
  if (!plain) {
    try { plain = await LumeSource.tools.base64Decode(matched[1]); } catch (error) { plain = ''; }
  }
  if (!/^https?:\/\//i.test(String(plain))) return '';
  return String(plain).replace(/\/+$/, '');
}

// 问站方跳转服务要「当前域」：旧域 → 302 → 新域（App 的 HTTP 桥会跟完，reply.url 是终点）
async function discoverFrom(seed) {
  var page = null;
  try {
    page = await LumeSource.http.get(seed + '/', {
      headers: { 'User-Agent': UA, Accept: 'text/html,application/xhtml+xml,*/*;q=0.8' },
    });
  } catch (error) {
    return '';
  }
  if (!page || !page.body) return '';
  var jump = await jumpBaseOf(page.body);
  if (!jump) return '';
  var u = await b64Encode(seed);
  var p = await b64Encode('/');
  if (!u || !p) return '';
  var reply = null;
  try {
    reply = await LumeSource.http.get(
      jump + '/?u=' + encodeURIComponent(u) + '&p=' + encodeURIComponent(p),
      { headers: { 'User-Agent': UA, Accept: 'text/html,*/*', Referer: seed + '/' } },
    );
  } catch (error) {
    return '';
  }
  var host = originOf(reply && reply.url ? reply.url : '');
  if (!host || normalizeHost(host) === normalizeHost(seed)) return '';
  return host;
}

/* ══════════════════════════════════════ 协议 ══════════════════════════════════════ */

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function coverOf(path) {
  var raw = String(path == null ? '' : path).trim();
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return IMG_HOST + (raw.charAt(0) === '/' ? '' : '/') + raw;
}

function categoryOf(id) {
  var key = String(id == null || id === '' ? 'c1' : id);
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === key) return CATEGORIES[i];
  return CATEGORIES[0];
}

// 源设置（目前只有可选的登录 token）
function setting(key) {
  var bag = LumeSource.config && LumeSource.config.settings ? LumeSource.config.settings : {};
  return bag && bag[key] ? String(bag[key]) : '';
}

// 单台主机的请求：返回 { ok, json } / { note, parked }
async function postOnce(host, path, params, extraHeaders) {
  var payload = { site: 1, device: 2, timestamp: Date.now() };
  var extra = params || {};
  for (var k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) payload[k] = extra[k];

  // 签名：参数按 key 排序拼 "k=v&"，末尾接 sign_key，取 md5
  var keys = Object.keys(payload).sort();
  var canon = '';
  for (var i = 0; i < keys.length; i++) canon += keys[i] + '=' + payload[keys[i]] + '&';
  var digest = await LumeSource.tools.digest('md5', canon + SIGN_KEY);
  payload.encode_sign = String(digest).toLowerCase();

  // 请求体整体加密（原生 AES-256-CBC）
  var plainB64 = await LumeSource.tools.base64Encode(JSON.stringify(payload));
  var encrypted = await LumeSource.tools.aes({
    key: btoa(AES_KEY),
    iv: btoa(IV_PREFIX + REQ_SUFFIX),
    data: plainB64,
    mode: 'CBC',
    encrypt: true,
  });

  var reply = null;
  try {
    reply = await LumeSource.http.post(
      host + '/api/' + path + '?_t=' + Date.now(),
      JSON.stringify({ 'post-data': encrypted }),
      {
        headers: Object.assign(
          {
            'User-Agent': UA,
            Accept: 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            suffix: REQ_SUFFIX,
            lang: 'zh',
            Referer: host + '/',
            Origin: host,
          },
          extraHeaders || {},
        ),
      },
    );
  } catch (error) {
    return { note: host + ' 连不上（' + (error && error.message ? error.message : error) + '）', parked: false };
  }

  var status = reply ? reply.status : 0;
  var text = reply && reply.body ? String(reply.body) : '';
  if (status !== 200) {
    // 405 是「这台只剩跳转页」的硬判据：跳转页 GET 得到，POST 一律不接。
    var parked = status === 405 || (status === 403 && text.indexOf('atob') >= 0);
    return { note: path + ' HTTP ' + status + '（' + host + '）', parked: parked };
  }

  var wallet;
  try {
    wallet = JSON.parse(text);
  } catch (error) {
    return { note: path + ' 返回不是 JSON（' + host + '）', parked: text.indexOf('atob') >= 0 };
  }
  if (wallet && typeof wallet.data === 'string') {
    var suffix = String(wallet.suffix || REQ_SUFFIX);
    var decB64 = '';
    try {
      decB64 = await LumeSource.tools.aes({
        key: btoa(AES_KEY),
        iv: btoa(IV_PREFIX + suffix),
        data: wallet.data,
        mode: 'CBC',
        encrypt: false,
      });
    } catch (error) {
      return { note: '响应解不开（换密钥了？）' + path, parked: false };
    }
    var plain = await LumeSource.tools.base64Decode(decB64);
    try {
      return { ok: true, json: JSON.parse(plain) };
    } catch (error) {
      return { note: '响应解不开（换密钥了？）' + path, parked: false };
    }
  }
  return { ok: true, json: wallet };
}

// 一次调用：当前域打不通就问跳转服务要新域，新域打进名单再试一次。
async function api(path, params, extraHeaders) {
  var tried = {};
  var queue = await hostCandidates();
  var note = '';
  for (var i = 0; i < queue.length; i++) {
    var host = queue[i];
    if (tried[host]) continue;
    tried[host] = 1;
    var result = await postOnce(host, path, params, extraHeaders);
    if (result && result.ok) {
      await rememberHost(host);
      return result.json;
    }
    if (result && result.note) note = result.note;
    if (!result || !result.parked) continue;
    var found = await discoverFrom(host);
    if (found && !tried[normalizeHost(found)]) queue.push(normalizeHost(found));
  }
  throw new Error('接口打不开：' + (note || '没有可用的接口域名'));
}

function rowOf(v) {
  if (!v) return null;
  var id = String(v.id == null ? '' : v.id);
  if (!id) return null;
  var title = clean(v.title);
  if (!title) return null;
  var bits = [];
  if (v.actor && v.actor.name) bits.push(clean(v.actor.name));
  if (v.publisher && v.publisher.name) bits.push(clean(v.publisher.name));
  if (v.play) bits.push('播放 ' + v.play);
  return {
    id: id,
    title: title,
    cover: coverOf(v.thumb),
    coverHeaders: COVER_HEADERS,
    subtitle: bits.join(' · '),
  };
}

var RECENT = [];
function remember(rows) {
  if (!rows || !rows.length) return;
  RECENT = rows.concat(RECENT).slice(0, 300);
}

// ---------------- 入口 ----------------
var LumeSource = {
  id: 'insav_video',
  name: 'INS AV',
  version: '1.2.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: SEEDS,

  async categories() {
    return CATEGORIES.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async home() {
    var boards = [];
    var plans = [CATEGORIES[0], CATEGORIES[1], CATEGORIES[4]];
    for (var i = 0; i < plans.length; i++) {
      var cat = plans[i];
      try {
        var data = await api('video/indexLists', { site: cat.site, page: 1, limit: PAGE_SIZE, type: cat.type });
        var list = (data && data.data && data.data.data) || [];
        var rows = [];
        for (var k = 0; k < list.length; k++) {
          var row = rowOf(list[k]);
          if (row) rows.push(row);
        }
        if (rows.length) {
          remember(rows);
          boards.push({ title: cat.title, moreUrl: cat.id, items: rows.slice(0, 12) });
        }
      } catch (error) {
        if (i === 0) throw error;
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口或密钥可能变了');
    return boards;
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    if (clean(a.keyword)) throw new Error('这个站没有站内搜索接口');
    var cat = categoryOf(a.categoryId);
    var data = await api('video/indexLists', { site: cat.site, page: page, limit: PAGE_SIZE, type: cat.type });
    var box = (data && data.data) || {};
    var list = box.data || [];
    var rows = [];
    for (var i = 0; i < list.length; i++) {
      var row = rowOf(list[i]);
      if (row) rows.push(row);
    }
    remember(rows);
    var lastPage = Number(box.last_page) || 0;
    return { items: rows, hasMore: lastPage ? page < lastPage : rows.length >= PAGE_SIZE };
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var v = await api('video/info', { vid: Number(id) });
    if (!v || v.code !== 1 || !v.data) return null;
    var d = v.data;
    var tags = (d.tags || []).map(function (t) { return clean(t.name); }).filter(Boolean);
    var desc = [];
    if (d.mash) desc.push('番号 ' + clean(d.mash));
    if (d.actor && d.actor.name) desc.push('女优 ' + clean(d.actor.name));
    if (d.publisher && d.publisher.name) desc.push('片商 ' + clean(d.publisher.name));
    if (d.publish_date) desc.push('发行 ' + clean(d.publish_date));
    if (tags.length) desc.push('标签 ' + tags.join('・'));
    if (d.description) desc.push('', clean(d.description));
    return {
      id: id,
      title: clean(d.title) || id,
      cover: coverOf(d.thumb),
      coverHeaders: COVER_HEADERS,
      subtitle: [d.mash, d.actor && d.actor.name].filter(Boolean).join(' · '),
      description: desc.join('\n'),
      tags: tags,
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    return [{ id: 'main', title: '正片' }];
  },

  async content(args) {
    var id = String((args && (args.id || args.chapterId)) || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('缺少视频 ID');
    var base = await activeHost();

    // 有 token 就走原生：getVideoUrl 需要登录态（登录要图形验证码，源里不做自动登录，
    // token 由用户在网页登录后粘到源设置里）。
    var token = setting('token');
    if (token) {
      try {
        var play = await api('video/getVideoUrl', { vid: Number(id) }, { token: token });
        var url = (play && play.data && (play.data.url || play.data.play_url || play.data.video_url)) ||
          (play && (play.url || play.play_url));
        if (url) {
          return {
            kind: 'video',
            url: String(url),
            headers: { 'User-Agent': UA, Referer: base + '/' },
          };
        }
        if (play && play.code && play.code !== 1) {
          throw new Error('取播放地址失败：' + (play.msg || play.code) + '（token 可能过期，重新登录再粘一次）');
        }
      } catch (error) {
        if (String(error && error.message).indexOf('token 可能过期') >= 0) throw error;
        // 接口异常也退回网页，不把用户卡死
      }
    }

    return {
      kind: 'webplayer',
      url: base + '/video/info?vid=' + encodeURIComponent(id),
      headers: { 'User-Agent': UA, Referer: base + '/' },
    };
  },
};
