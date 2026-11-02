// LumeSource: {"id":"insav_video","name":"INSAV","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://pqtn95.com"],"network":"direct","icon":"https://pqtn95.com/logo.png"}
// LumeRuntime: javascript
//
// 站点：INS AV（网页入口 dcuj77.com，接口在随机域 pqtn95.com；全站 18+，日本 AV 厂牌聚合）
// 来源：从「暮色」App（com.look.mbox / avbox 1.0.1）的 insav 模块挖出来的站与协议。
//
// 一、三件事（缺一个都不通）
//   1. **API 主机不是网页域**：网页 `dcuj77.com` 是 React SPA，`POST /api/*` 一律 405；
//      真接口在另一个随机域（本次 `pqtn95.com`），App 里 `flutter.insav` 只存网页域。
//      定位方法：模拟器里把 DNS 劫持到宿主记录查询（这一轮抓到的就是 pqtn95.com）。
//   2. **请求体整体加密**：参数先算签名，再 `{"post-data": AES(JSON)}`。
//   3. **响应也加密**：`{"code":1,"data":"<base64>","suffix":"<6hex>"}`，AES-256-CBC 解出 JSON。
//
// 二、加密与签名（2026-11-02 用真实请求逐字节核对）
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
//   video/getVideoUrl {vid} → 需要登录（游客 token），本源不做登录，播放走网页
//   tag/lists、actor/lists、banner/lists、config/lists
//
// 四、封面
//   条目里的 thumb 是相对路径（/ms/syms/.../xxx_ver.jpg），pqtn95 上 404；
//   真图在图片 CDN `https://yik.yanyunhome.com` + 同一路径，实测 200 image/jpeg。
//
// 五、播放（限制）
//   getVideoUrl 要登录态，暮色里的游客 token 已过期，本源不做账号体系：
//   content 返回 webplayer（站内详情页），由网页播放器播；要原生播放得先接入登录。

var SITE = 'https://pqtn95.com';
var IMG_HOST = 'https://yik.yanyunhome.com';
var AES_KEY = '0XxdjmI55ZjjqQLO3nI7gGqrBP0Vz9jS';
var IV_PREFIX = 'RWf23muavY';
var REQ_SUFFIX = 'NWSdef';
var SIGN_KEY = 'NRkw0g3iJLDvw5tJ5PuVt5276z0SOuyL';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 12;

var CATEGORIES = [
  { id: 'c1', title: '有码', site: 1, type: 1 },
  { id: 'c2', title: '无码', site: 2, type: 1 },
  { id: 'c3', title: '动漫', site: 3, type: 1 },
  { id: 'c4', title: '4K', site: 4, type: 1 },
  { id: 'free', title: '免费放送', site: 1, type: 3 },
];

function siteBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || SITE).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

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

// ---------------- 协议 ----------------
async function api(path, params) {
  var root = siteBase();
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

  var reply = await LumeSource.http.post(
    root + '/api/' + path + '?_t=' + Date.now(),
    JSON.stringify({ 'post-data': encrypted }),
    {
      headers: {
        'User-Agent': UA,
        Accept: 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        suffix: REQ_SUFFIX,
        lang: 'zh',
        Referer: root + '/',
        Origin: root,
      },
    },
  );
  if (!reply || reply.status !== 200) {
    throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  }
  var wallet;
  try {
    wallet = JSON.parse(String(reply.body || ''));
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  if (typeof wallet.data === 'string') {
    var suffix = String(wallet.suffix || REQ_SUFFIX);
    var decB64 = await LumeSource.tools.aes({
      key: btoa(AES_KEY),
      iv: btoa(IV_PREFIX + suffix),
      data: wallet.data,
      mode: 'CBC',
      encrypt: false,
    });
    var plain = await LumeSource.tools.base64Decode(decB64);
    try {
      return JSON.parse(plain);
    } catch (error) {
      throw new Error('响应解不开（换密钥了？）：' + path);
    }
  }
  return wallet;
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
  return { id: id, title: title, cover: coverOf(v.thumb), subtitle: bits.join(' · ') };
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
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://pqtn95.com'],

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
    // 该站的 getVideoUrl 需要登录态，本源不做账号体系：交给站内网页播放器。
    return {
      kind: 'webplayer',
      url: siteBase() + '/video/info?vid=' + encodeURIComponent(id),
      headers: { 'User-Agent': UA, Referer: siteBase() + '/' },
    };
  },
};
