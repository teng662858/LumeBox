// LumeSource: {"id":"kkys_video","name":"可可影视","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://www.kkys03.com"],"network":"direct","icon":"https://vf.wkcyvs.cn/vod_pc_static_kkdy/images/p/logo.png"}
// LumeRuntime: javascript
//
// 站点：可可影视（kkys03.com）。
// 形态：自研服务端渲染 HTML，入口带 cdndefend 反爬挑战。
//
// ── 入口挑战（本源自动过）──
//   首访返回 850 + 一段内联脚本：把常量 c 与递增 i 拼起来做 SHA-1，
//   直到摘要第 n1 字节 == 0xB0 且下一字节 == 0x0B，然后写
//   cookie `cdndefend_js_cookie=<c><i>` 再刷新。本源用纯 JS SHA-1 现算（实测约 1.5 秒），
//   把拿到的 cookie 带上重试即可（之后同一实例内复用）。
//
// ── 结构 ──
//   分类：电影 /show/1------.html、连续剧 /show/2-…、动漫 /show/3-…、综艺 /show/4-…
//   筛选：/show/<cat>-<类型>-<地区>-<语言>-<年份>-<排序>-<页码>.html（实测每个参数都换内容且可组合）
//         排序 1=最新 2=最热 3=全部 4=评分
//   搜索：/search?t=<页面令牌>&k=<词>（t 每次从首页/列表页的表单里取，缺了会 503）
//   详情：/detail/<id>.html
//   播放：/play/<id>-<线路>-<集>.html，播放页里直接写着 m3u8（带 sign/timestamp）
//
// ── 线路 ──
//   详情页「切换线路」最多 37 条，每条线路一套自己的分集列表（DOM 里按索引一一对应）。
//   本源按线路分组，把每集都列成一项，线路名带上，用户在选集里可以直接换线路。
//
// 实测：m3u8 200 + #EXTM3U（30 万字节），分片无需额外 Referer。

var HOST = 'https://www.kkys03.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 18;

var CATS = [
  { id: '1', title: '电影' },
  { id: '2', title: '连续剧' },
  { id: '3', title: '动漫' },
  { id: '4', title: '综艺' }
];
var ORDERS = [
  { id: '1', title: '最新' },
  { id: '2', title: '最热' },
  { id: '4', title: '评分' }
];
var YEARS = ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2010_2019', '2000_2009', '1990_1999', '1980_1989', '0_1979'];
var LANGS = ['国语', '粤语', '英语', '日语', '韩语', '法语', '其他'];
var FILTERS = {
  '1': {
    cls: ['剧情', '喜剧', '动作', '爱情', '恐怖', '惊悚', '犯罪', '科幻', '悬疑', '奇幻', '冒险', '战争', '历史', '古装', '家庭', '传记', '武侠', '歌舞', '短片', '动画', '儿童', '职场'],
    area: ['中国大陆', '中国香港', '中国台湾', '美国', '日本', '韩国', '英国', '法国', '德国', '印度', '泰国', '丹麦', '瑞典', '巴西', '加拿大', '俄罗斯', '意大利', '比利时', '爱尔兰', '西班牙', '澳大利亚', '其他']
  },
  '2': {
    cls: ['剧情', '爱情', '喜剧', '犯罪', '悬疑', '古装', '动作', '家庭', '惊悚', '奇幻', '美剧', '科幻', '历史', '战争', '韩剧', '武侠', '言情', '恐怖', '冒险', '都市', '职场'],
    area: ['中国大陆', '中国香港', '韩国', '美国', '日本', '法国', '英国', '德国', '中国台湾', '泰国', '印度', '其他']
  },
  '3': {
    cls: ['动态漫画', '剧情', '动画', '喜剧', '冒险', '动作', '奇幻', '科幻', '儿童', '搞笑', '爱情', '家庭', '短片', '热血', '益智', '悬疑', '经典', '校园', 'Anime', '运动', '亲子', '青春', '恋爱', '武侠', '惊悚'],
    area: ['日本', '中国大陆', '中国台湾', '美国', '中国香港', '韩国', '英国', '法国', '德国', '印度', '泰国', '丹麦', '瑞典', '巴西', '加拿大', '俄罗斯', '意大利', '比利时', '爱尔兰', '西班牙', '澳大利亚', '其他']
  },
  '4': {
    cls: ['纪录', '真人秀', '记录', '脱口秀', '剧情', '历史', '喜剧', '传记', '相声', '节目', '歌舞', '冒险', '运动', 'Season', '犯罪', '短片', '搞笑', '晚会'],
    area: ['中国大陆', '中国香港', '中国台湾', '美国', '日本', '韩国', '其他']
  }
};

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(t) { return encodeURIComponent(String(t == null ? '' : t)); }
function unescapeHtml(t) {
  return String(t == null ? '' : t)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (a, c) { return String.fromCharCode(Number(c)); });
}
function clean(t) {
  return unescapeHtml(String(t == null ? '' : t).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

// ------------------------------------------------------------------ 纯 JS SHA-1（过 cdndefend 挑战）
function sha1Hex(bytes) {
  var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  var ml = bytes.length * 8;
  var data = bytes.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  var hi = Math.floor(ml / 4294967296), lo = ml >>> 0;
  data.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255);
  data.push((lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  var w = new Array(80);
  function rol(x, n) { return ((x << n) | (x >>> (32 - n))) >>> 0; }
  for (var off = 0; off < data.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = ((data[off + i * 4] << 24) | (data[off + i * 4 + 1] << 16) |
              (data[off + i * 4 + 2] << 8) | data[off + i * 4 + 3]) >>> 0;
    }
    for (var j = 16; j < 80; j++) w[j] = rol(w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16], 1);
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var k = 0; k < 80; k++) {
      var f, kk;
      if (k < 20) { f = (b & c) | ((~b) & d); kk = 0x5a827999; }
      else if (k < 40) { f = b ^ c ^ d; kk = 0x6ed9eba1; }
      else if (k < 60) { f = (b & c) | (b & d) | (c & d); kk = 0x8f1bbcdc; }
      else { f = b ^ c ^ d; kk = 0xca62c1d6; }
      var tmp = (rol(a, 5) + (f >>> 0) + e + kk + w[k]) >>> 0;
      e = d; d = c; c = rol(b, 30); b = a; a = tmp;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
  }
  function hex(x) { return ('00000000' + x.toString(16)).slice(-8); }
  return hex(h0) + hex(h1) + hex(h2) + hex(h3) + hex(h4);
}
function utf8Bytes(s) {
  var out = [], t = String(s == null ? '' : s);
  for (var i = 0; i < t.length; i++) {
    var c = t.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}
// 从挑战页里取常量 c 与目标字节位置，算出 cookie
function solveChallenge(html) {
  var m = /let c=a0_0x4457\('0x2'\)/.exec(html) || /'([0-9A-F]{32,})'/.exec(html);
  var hexConst = null;
  var arr = /const a0_0x2a54=\[([\s\S]*?)\];/.exec(html);
  if (arr) {
    var parts = arr[1].split(',').map(function (s) { return s.replace(/^['"]|['"]$/g, ''); });
    for (var i = 0; i < parts.length; i++) {
      if (/^[0-9A-Fa-f]{24,}$/.test(parts[i])) { hexConst = parts[i]; break; }
    }
  }
  if (!hexConst && m) hexConst = m[1];
  if (!hexConst) throw new Error('站点挑战页格式变了，认不出常量');
  var n1 = parseInt(hexConst[0], 16);
  for (var i2 = 0; i2 < 4000000; i2++) {
    var dig = sha1Hex(utf8Bytes(hexConst + i2));
    var b1 = parseInt(dig.substr(n1 * 2, 2), 16);
    var b2 = parseInt(dig.substr((n1 + 1) * 2, 2), 16);
    if (b1 === 0xb0 && b2 === 0x0b) {
      return 'cdndefend_js_cookie=' + hexConst + i2;
    }
  }
  throw new Error('站点挑战没解出来（尝试次数用尽）');
}

// ------------------------------------------------------------------ 会话（cookie + 搜索令牌）
var SESSION = { cookie: '', token: '' };

function request(path, extraHeaders) {
  var headers = {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': base() + '/'
  };
  if (SESSION.cookie) headers['Cookie'] = SESSION.cookie;
  if (extraHeaders) {
    for (var k in extraHeaders) if (Object.prototype.hasOwnProperty.call(extraHeaders, k)) headers[k] = extraHeaders[k];
  }
  return LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: headers
  });
}

async function fetchText(path, referer) {
  var reply = await request(path, referer ? { Referer: referer } : null);
  var status = (reply && reply.status) || 0;
  var body = reply && reply.body != null ? String(reply.body) : '';
  if (status === 200 && body.length > 0) return body;
  // 850 / 503 / 空 body：先过挑战再重试一次
  if (status === 850 || status === 503 || !body) {
    var challenge = await request(path);
    var page = challenge && challenge.body != null ? String(challenge.body) : '';
    if (/cdndefend/i.test(page)) {
      SESSION.cookie = solveChallenge(page);
      var retry = await request(path, referer ? { Referer: referer } : null);
      var s2 = (retry && retry.status) || 0;
      if (s2 === 200 && retry.body) return String(retry.body);
      throw new Error('过完站点挑战后仍返回 HTTP ' + s2);
    }
    if (status === 850 || status === 503) throw new Error('站点返回 HTTP ' + status + '（反爬挑战没通过）');
  }
  if (status === 404) return '';
  if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
  return body;
}

// 搜索需要页面里的 t 令牌；从任意一个列表页的表单取
async function searchToken() {
  if (SESSION.token) return SESSION.token;
  var html = await fetchText('/show/1------.html');
  var m = /name="t"\s+value="([^"]+)"/.exec(html) || /name="t" value="([^"]+)"/.exec(html);
  if (m) SESSION.token = m[1];
  return SESSION.token;
}

// ------------------------------------------------------------------ 解析
function parseCards(html) {
  var src = String(html || '');
  var items = [], seen = {};
  var chunks = src.split(/<a href="\/detail\/(\d+)\.html"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 2600);
    // 列表页卡片用 .v-item-title（其中两个是隐藏的站名占位）；
    // 搜索结果卡片用 .search-result-item-main > .title。两种都取「可见的」。
    var titles = [], reT = /<div class="(?:v-item-title|title)"[^>]*>([\s\S]{0,80}?)<\/div>/g, tm;
    while ((tm = reT.exec(block)) !== null) {
      if (/display:\s*none/i.test(tm[0])) continue;
      var val = clean(tm[1]);
      if (val) titles.push(val);
    }
    var name = titles[0] || '';
    if (!name || /可可影视|kekys/i.test(name)) continue;
    // 封面：跳过占位图/站标，取第一张真实图（标签里有换行，按 <img 切段再取属性）
    var cover = '';
    var segs = block.split(/<img\b/i);
    for (var si = 1; si < segs.length; si++) {
      var tag = segs[si].slice(0, 500);
      var im = /data-original="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
      if (!im) continue;
      var u = String(im[1]).trim();
      if (!u || /placeholder|logo_/i.test(u)) continue;
      cover = u;
      break;
    }
    if (cover && cover.charAt(0) === '/') cover = base() + cover;
    var note = /<div class="v-item-bottom">\s*<span>([\s\S]{0,30}?)<\/span>/i.exec(block)
      || /<div class="search-result-item-header">\s*<div>([\s\S]{0,20}?)<\/div>/i.exec(block);
    seen[id] = true;
    items.push({
      id: id,
      title: name,
      cover: unescapeHtml(cover),
      subtitle: note ? clean(note[1]) : ''
    });
  }
  return items;
}

function parseDetail(html) {
  var src = String(html || '');
  var titleTag = /<title>([^<]*)<\/title>/i.exec(src);
  var title = titleTag ? clean(titleTag[1]).replace(/-高清免费在线观看.*$/, '').replace(/-.*$/, '').trim() : '';
  var h1 = /<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(src);
  if (h1 && clean(h1[1])) title = clean(h1[1]);
  var cover = /<img[^>]+(?:data-original|src)="([^"]*(?:vod|upload|cover)[^"]*)"/i.exec(src);
  var desc = /<div class="[^"]*(?:detail-intro|v-detail-intro|intro)[^"]*"[^>]*>([\s\S]{0,3000}?)<\/div>/i.exec(src);
  var metaDesc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(src);
  var text = desc ? clean(desc[1]) : (metaDesc ? unescapeHtml(metaDesc[1]).trim() : '');
  return {
    title: title,
    cover: cover ? unescapeHtml(cover[1]) : '',
    description: text,
    lines: parseLines(src)
  };
}

// 线路名在 .source-item-label 里；分集在 .episode-list 里，按索引一一对应
function parseLines(html) {
  var src = String(html || '');
  var names = [];
  var reName = /<a href="#" class="source-item[^"]*">\s*<span class="source-item-label">([^<]*)<\/span>/g, m;
  while ((m = reName.exec(src)) !== null) names.push(clean(m[1]) || ('线路 ' + (names.length + 1)));
  var blocks = [];
  var reBlock = /<div class="episode-list"[^>]*>([\s\S]*?)<\/div>/g, b;
  while ((b = reBlock.exec(src)) !== null) {
    var eps = [];
    var reEp = /<a href="(\/play\/\d+-\d+-\d+\.html)"[^>]*>([\s\S]{0,80}?)<\/a>/g, e;
    var seen = {};
    while ((e = reEp.exec(b[1])) !== null) {
      if (seen[e[1]]) continue;
      seen[e[1]] = true;
      eps.push({ path: e[1], label: clean(e[2]) || ('第 ' + (eps.length + 1) + ' 集') });
    }
    blocks.push(eps);
  }
  var out = [];
  var count = Math.max(names.length, blocks.length);
  for (var i = 0; i < count; i++) {
    var eps2 = blocks[i] || [];
    if (!eps2.length) continue;
    out.push({ index: i + 1, title: names[i] || ('线路 ' + (i + 1)), episodes: eps2 });
  }
  return out;
}

// 播放页里直接写着 m3u8（带 sign/timestamp）
function parsePlayUrl(html) {
  var src = String(html || '');
  var m = /src:\s*"([^"]+\.m3u8[^"]*)"/i.exec(src) || /"([^"]+\.m3u8\?[^"]*)"/i.exec(src)
    || /(https?:\\?\/\\?\/[^"'\s]+?\.m3u8[^"'\s]*)/i.exec(src);
  if (!m) return '';
  return m[1].replace(/\\\//g, '/');
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'kkys_video',
  name: '可可影视',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: [HOST],
  network: 'direct',
  icon: 'https://vf.wkcyvs.cn/vod_pc_static_kkdy/images/p/logo.png',
  commonSettings: [
    {
      key: 'playbackMode', title: '播放方式', type: 'select',
      options: [
        { value: 'auto', title: '自动（推荐）' },
        { value: 'direct', title: '直连优先' }
      ],
      default: 'auto'
    }
  ],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '可可影视（kkys03.com）。站点入口有 cdndefend 反爬挑战，本源会用纯 JS 现算 SHA-1 自动通过（首次约 1-2 秒），之后复用。支持电影/连续剧/动漫/综艺，含类型/地区/语言/年份/排序筛选与站内搜索；详情页最多 37 条线路，本源把每条线路的分集都列出来，可直接换线路。播放为站点直出的 m3u8。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    var groups = [];
    for (var i = 0; i < CATS.length; i++) {
      var cat = CATS[i].id, f = FILTERS[cat], catTitle = CATS[i].title;
      if (!f) continue;
      groups.push({
        key: cat + '.cls', title: catTitle + ' · 类型', multiple: false,
        options: f.cls.map(function (v) { return { id: v, title: v }; })
      });
      groups.push({
        key: cat + '.area', title: catTitle + ' · 地区', multiple: false,
        options: f.area.map(function (v) { return { id: v, title: v }; })
      });
    }
    groups.push({
      key: 'lang', title: '语言', multiple: false,
      options: LANGS.map(function (v) { return { id: v, title: v }; })
    });
    groups.push({
      key: 'year', title: '年份', multiple: false,
      options: YEARS.map(function (v) { return { id: v, title: v.replace('_', '-').replace(/^0-/, '1979 及更早-') }; })
    });
    groups.push({
      key: 'order', title: '排序', multiple: false,
      options: ORDERS.map(function (v) { return { id: v.id, title: v.title }; })
    });
    return { groups: groups };
  },

  async home() {
    var html = await fetchText('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最新上线', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var f = args.filters || {};

    if (keyword) {
      var token = await searchToken();
      if (!token) throw new Error('拿不到站内搜索令牌，暂时无法搜索');
      var found = parseCards(await fetchText('/search?t=' + enc(token) + '&k=' + enc(keyword)));
      return { items: found, hasMore: false };
    }

    var cat = '1';
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { cat = category; break; }
    }
    function pick(name) {
      var v = f[cat + '.' + name];
      if (v == null || v === '') v = f[name];
      return v == null ? '' : String(v).trim();
    }
    var cls = pick('cls'), area = pick('area');
    var lang = String(f.lang == null ? '' : f.lang).trim();
    var year = String(f.year == null ? '' : f.year).trim();
    var order = String(f.order == null ? '' : f.order).trim() || '3';

    var path = '/show/' + cat + '-' + (cls ? enc(cls) : '') + '-' + (area ? enc(area) : '') + '-' +
      (lang ? enc(lang) : '') + '-' + (year ? enc(year) : '') + '-' + order + '-' + page + '.html';
    var items = parseCards(await fetchText(path));
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = '';
    try { html = await fetchText('/detail/' + id + '.html'); } catch (e) { return null; }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var total = 0;
    for (var i = 0; i < info.lines.length; i++) total += info.lines[i].episodes.length;
    var bits = [];
    if (info.lines.length > 1) bits.push(info.lines.length + ' 条线路');
    if (total > 1) bits.push('共 ' + total + ' 集');
    bits.push('m3u8 直连');
    return {
      id: id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: info.description,
      tags: []
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return [];
    var html = await fetchText('/detail/' + id + '.html');
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.lines.length) throw new Error('这一条在站点上没有可播放的分集');
    var out = [];
    for (var i = 0; i < info.lines.length; i++) {
      var line = info.lines[i];
      for (var j = 0; j < line.episodes.length; j++) {
        var ep = line.episodes[j];
        var label = info.lines.length > 1 ? (line.title + ' · ' + ep.label) : ep.label;
        out.push({ id: ep.path, title: label });
      }
    }
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.chapterId || '').trim();
    if (!/^\/play\/\d+-\d+-\d+\.html$/.test(path)) {
      var id = String(args.id || '').trim();
      if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
      var dhtml = await fetchText('/detail/' + id + '.html');
      var info = parseDetail(dhtml);
      if (!info.lines.length || !info.lines[0].episodes.length) throw new Error('这一条没有可播放的分集');
      path = info.lines[0].episodes[0].path;
    }
    var page = await fetchText(path);
    if (!page) throw new Error('播放页打不开（可能已下架）');
    var url = parsePlayUrl(page);
    if (!url) throw new Error('这条线路没有给出 m3u8 地址，换一条线路试试');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};
