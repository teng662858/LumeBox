// LumeSource: {"id":"mitaovideo_video","name":"蜜桃视频2","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://1mt8w.sbs","https://1mth5.sbs"],"network":"direct","settings":[{"key":"note","type":"info","title":"站点说明","description":"蜜桃视频（1mt8w.sbs / 1mth5.sbs 同站）：自研 SPA，但列表与详情都服务端注入 window.APP_DATA，curl 即取。六个频道走 /type/<id>/<page>（国产 1089 页、日韩 3339 页…，约 10 万条），首页/推荐是 video_card 多行不分页。详情 /play/<short_id> 给相对 m3u8，播放需 CDN 签名：sign = 秒级时间戳-5位随机-0-md5(path-ts-rand-0-密钥)，密钥取自前端包，已在源内复刻，纯 JS 生成。"}]}
// LumeRuntime: javascript
//
// 站点：蜜桃视频（https://1mt8w.sbs → 1mth5.sbs 系）。前端代码混淆，但数据在 HTML 里：
//   <script>window.APP_DATA = [ {module:'text_link'…}, {module:'video_list', currentPage, totalPages, data:[…]} ]</script>
// 结构（2026-11-02 实测）：
//   列表   /type/<id>           第 1 页
//          /type/<id>/<page>     第 N 页（路径分页；?page= 无效）
//          /                 首页 = 多个 video_card 模块（最新国产/日韩/欧美/动漫）
//          /recommend        推荐 = video_card 模块
//   详情   /play/<short_id>      APP_DATA.data = {short_id,title,m3u8,duration,server,tags,category_id}
//   封面   https://a89hu01.top/<thumbnail>
//   播放   https://p.xionganzhengwu.com<m3u8>?sign=<ts>-<rand>-<uid>-<md5>
//   签名   md5( m3u8 + '-' + ts + '-' + rand + '-' + uid + '-' + SECRET )
//          SECRET = PsTU3c3rSDkzbe42CMozR8（从 play2.js 运行时截获的 md5 入参反推，已实测 200）
//          无 sign 或不带密钥 → CDN 403。

var DEFAULT_DOMAIN = 'https://1mt8w.sbs';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/604.1';
var MEDIA_BASE = 'https://p.xionganzhengwu.com';
var IMG_BASE = 'https://a89hu01.top/';
var SIGN_SECRET = 'PsTU3c3rSDkzbe42CMozR8';
var SIGN_UID = '0';

// 频道：type 页可翻页；home/recommend 是 video_card 多行
var CATS = [
  { id: 'home', title: '最新', path: '/', paged: false },
  { id: 'recommend', title: '推荐', path: '/recommend', paged: false },
  { id: 't2', title: '国产', path: '/type/2', paged: true },
  { id: 't1', title: '日韩', path: '/type/1', paged: true },
  { id: 't6', title: '网黄', path: '/type/6', paged: true },
  { id: 't3', title: '欧美', path: '/type/3', paged: true },
  { id: 't9', title: 'AI剧', path: '/type/9', paged: true },
  { id: 't5', title: '动漫', path: '/type/5', paged: true }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (domain || DEFAULT_DOMAIN).replace(/\/+$/, '');
}
function site() { return base() + '/'; }

async function fetchPage(url) {
  var res = await LumeSource.http.get(url, { headers: { 'User-Agent': UA, Referer: site() } });
  if (!res || res.status < 200 || res.status >= 300) throw new Error('抓取失败 HTTP ' + (res && res.status));
  return res.body || '';
}

function textOf(v) { return v === undefined || v === null ? '' : String(v); }
function clean(s) { return textOf(s).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(); }

// APP_DATA：数组（列表/首页）或对象（详情）
function readAppData(html) {
  var m = /window\.APP_DATA\s*=\s*(\[[\s\S]*?\]|\{[\s\S]*?\})\s*;?\s*<\/script>/.exec(html);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch (_) { return null; }
}

function rowOf(v) {
  var id = textOf(v.short_id);
  if (!id) return null;
  var title = clean(v.title);
  if (!title) return null;
  var thumb = textOf(v.thumbnail);
  return {
    id: id,
    title: title,
    cover: thumb ? IMG_BASE + thumb.replace(/^\/+/, '') : '',
    subtitle: v.duration ? Math.round(Number(v.duration) / 60) + ' 分钟' : ''
  };
}

var known = {};

var LumeSource = {
  id: 'mitaovideo_video',
  name: '蜜桃视频2',
  version: '1.0.0',
  category: 'video',

  async categories() { return CATS.map(function (c) { return { id: c.id, title: c.title }; }); },
  async filters() { return { groups: [] }; },
  async home() { return (await this.list({ page: 1 })).items; },

  async list(args) {
    var a = args || {};
    if (a.keyword) throw new Error('该站点未提供搜索接口');
    if (a.filters && Object.keys(a.filters).length) throw new Error('该站点未提供筛选规则');
    var page = Math.max(1, Number(a.page) || 1);
    var cat = CATS[0];
    var wanted = String(a.categoryId || cat.id);
    CATS.forEach(function (c) { if (c.id === wanted) cat = c; });

    var url;
    if (cat.paged) {
      url = site().replace(/\/$/, '') + cat.path + (page > 1 ? '/' + page : '');
    } else {
      if (page > 1) return { items: [], hasMore: false };
      url = site().replace(/\/$/, '') + cat.path;
    }

    var html = await fetchPage(url);
    var data = readAppData(html);
    if (!data) throw new Error('页面结构变了：没有 APP_DATA');

    var items = [], hasMore = false;
    if (Array.isArray(data)) {
      var list = null;
      data.forEach(function (mod) {
        if (mod && mod.module === 'video_list') list = mod;
      });
      if (list) {
        (list.data || []).forEach(function (v) { var row = rowOf(v); if (row) items.push(row); });
        hasMore = Number(list.currentPage || page) < Number(list.totalPages || 0);
      } else {
        // 首页/推荐：多个 video_card 模块，合并去重
        var seen = {};
        data.forEach(function (mod) {
          if (!mod || mod.module !== 'video_card') return;
          (mod.data || []).forEach(function (v) {
            var row = rowOf(v);
            if (row && !seen[row.id]) { seen[row.id] = true; items.push(row); }
          });
        });
      }
    }
    if (!items.length) {
      if (page > 1) return { items: [], hasMore: false };
      throw new Error('该频道没有解析到条目');
    }
    items.forEach(function (row) { known[row.id] = known[row.id] || {}; });
    return { items: items, hasMore: hasMore };
  },

  async detail(a) {
    var id = String((a && a.id) || '');
    if (!id) return null;
    var html = await fetchPage(site() + 'play/' + id);
    var data = readAppData(html);
    var v = data && data.data ? data.data : null;
    if (!v) return { id: id, title: id, cover: '' };
    if (v.m3u8) known[id] = { m3u8: textOf(v.m3u8) };
    var tags = (v.tags || []).map(function (t) { return textOf(t.Name); }).filter(Boolean);
    return {
      id: id,
      title: clean(v.title) || id,
      cover: v.thumbnail ? IMG_BASE + textOf(v.thumbnail).replace(/^\/+/, '') : '',
      description: tags.length ? '标签：' + tags.join('・') : ''
    };
  },

  async chapters(a) { return [{ id: String((a && a.id) || ''), title: '播放' }]; },

  async content(a) {
    var id = String((a && (a.id || a.chapterId)) || '');
    var row = known[id];
    var m3u8 = row && row.m3u8 ? row.m3u8 : '';
    if (!m3u8) {
      var html = await fetchPage(site() + 'play/' + id);
      var data = readAppData(html);
      if (data && data.data && data.data.m3u8) {
        m3u8 = textOf(data.data.m3u8);
        known[id] = { m3u8: m3u8 };
      }
    }
    if (!m3u8) throw new Error('该条目没有解析到播放地址');
    var path = m3u8.charAt(0) === '/' ? m3u8 : '/' + m3u8;
    return {
      kind: 'video',
      url: MEDIA_BASE + path + '?sign=' + signFor(path),
      headers: { 'User-Agent': UA, Referer: site() }
    };
  }
};

// 播放签名：md5(path + '-' + ts + '-' + rand + '-' + uid + '-' + SECRET)
function randomTag() {
  var chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  var out = '';
  for (var i = 0; i < 5; i++) out += chars.charAt(Math.floor(Math.random() * chars.length));
  return out;
}
function signFor(path) {
  var ts = String(Math.floor(Date.now() / 1000));
  var rand = randomTag();
  var hash = md5Hex(path + '-' + ts + '-' + rand + '-' + SIGN_UID + '-' + SIGN_SECRET);
  return ts + '-' + rand + '-' + SIGN_UID + '-' + hash;
}

// 沙箱没有 crypto / TextEncoder，这里自带 UTF-8 与 MD5
function utf8Bytes(text) {
  var out = [], s = String(text == null ? "" : text);
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      var low = s.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        i++;
        var point = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
        continue;
      }
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return out;
}

// 自写 md5（沙箱无 crypto，也不依赖别的源里可能被切坏的实现）
function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function rol(v, s) { return (v << s) | (v >>> (32 - s)); }
  var bytes = utf8Bytes(String(input == null ? '' : input));
  var bitLen = bytes.length * 8;
  var padded = bytes.slice();
  padded.push(0x80);
  while (padded.length % 64 !== 56) padded.push(0);
  var hi = Math.floor(bitLen / 4294967296);
  var lo = bitLen >>> 0;
  padded.push(lo & 0xff, (lo >>> 8) & 0xff, (lo >>> 16) & 0xff, (lo >>> 24) & 0xff);
  padded.push(hi & 0xff, (hi >>> 8) & 0xff, (hi >>> 16) & 0xff, (hi >>> 24) & 0xff);

  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  var K = [];
  for (var k = 0; k < 64; k++) K[k] = Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0;

  for (var offset = 0; offset < padded.length; offset += 64) {
    var m = [];
    for (var w = 0; w < 16; w++) {
      m[w] = (padded[offset + w * 4] | (padded[offset + w * 4 + 1] << 8) |
        (padded[offset + w * 4 + 2] << 16) | (padded[offset + w * 4 + 3] << 24)) >>> 0;
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (var i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D;
      D = C;
      C = B;
      B = add32(B, rol(add32(add32(A, F & 0xffffffff), add32(K[i], m[g])), S[i]));
      A = tmp;
    }
    a0 = add32(a0, A);
    b0 = add32(b0, B);
    c0 = add32(c0, C);
    d0 = add32(d0, D);
  }

  function hex32(value) {
    var out = '';
    for (var j = 0; j < 4; j++) {
      var byte = (value >>> (j * 8)) & 0xff;
      out += ('0' + byte.toString(16)).slice(-2);
    }
    return out;
  }
  return hex32(a0) + hex32(b0) + hex32(c0) + hex32(d0);
}
