// LumeSource: {"id":"libvio_video","name":"LIBVIO","version":"2.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://www.libvio.io","https://libvio.host","https://www.libvio.to"],"network":"direct","icon":"https://www.libvio.io/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：LIBVIO（发布页 libvio.app / libviofabu.com / libfabu.com；真实站 www.libvio.io，
//       旧域名 libvio.host / www.libvio.to / libviobd.com 已停用）。
//
// ── 入口：CDN 浏览器校验（靠 App 的网页视图过一次，不伪造）──
//   www.libvio.io 对非浏览器请求直接回
//     HTTP 403  x-cdn-challenge: required  "browser verification required"
//   实测（2026-11-01，浏览器里跑）：过完校验后，**同源 fetch 直接 200**，
//   列表页 16 KB、播放页 27 KB 都能取到，说明校验一次、会话复用即可。
//   → 本源按项目约定抛 `NEED_WEBVIEW_VERIFY：<URL>`，由 App 拉起内置网页视图，
//     由用户本人完成站点校验；拿到会话后 App 自动重试同一次调用，后续调用都带着走。
//     本源不做任何校验绕过（不伪造 UA/指纹、不逆向挑战算法）。
//
// ── 结构 ──
//   栏目  /type/1.html 电影、/type/2.html 剧集、/type/4.html 番剧、/type/15.html 日韩、/type/16.html 欧美
//   列表  /type/<cat>-<page>.html（实测 265 页）
//         /show/<cat>-<地区>---------<年份>.html（地区/年份筛选，实测生效）
//   详情  /detail/<id>.html
//   播放  /w/<id>-<线路>-<集>.html
//   搜索  /search/-------------.html?wd=<词>
//
// ── 播放 ──
//   播放页里有 `var player_aaaa={...,"url":"https://v.vimsec.app/.../xxx.mp4","from":"vr2"}`
//   —— 地址是**明文**（encrypt 字段为 3 但 url 未加密），直接就是站点给的正片 mp4。
//   注意：该 CDN 前置 Cloudflare，普通 HTTP 客户端取会 403，但在通过校验的浏览器会话里
//   是 200 + video/mp4（实测 893 MB）。所以播放地址交给 App 播放内核（走系统网络/WebKit 会话）。
//
// 限制：站点有网盘线路（夸克/迅雷）不在线播放，本源只取网页播放线路；
//       站点没有排序控件，只有地区/年份筛选，本源如实不声明排序。

var HOST = 'https://www.libvio.io';
var MIRRORS = ['https://www.libvio.io', 'https://libvio.host', 'https://www.libvio.to'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 24;

var CATS = [
  { id: '1', title: '电影' },
  { id: '2', title: '剧集' },
  { id: '4', title: '番剧' },
  { id: '15', title: '日韩' },
  { id: '16', title: '欧美' }
];
var AREAS = ['中国大陆', '中国香港', '中国台湾', '美国', '法国', '英国', '日本', '韩国', '德国', '泰国', '印度', '意大利', '西班牙', '加拿大', '其他'];
var YEARS = [];
for (var y = 2026; y >= 2003; y--) YEARS.push(String(y));

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

// 站点用 CDN 浏览器校验挡非浏览器请求：按约定交给 App 的网页视图，绝不自己伪造
function verifyError(path) {
  return new Error('NEED_WEBVIEW_VERIFY：LIBVIO 需要先完成站点的人机校验（HTTP 403 x-cdn-challenge）。' +
    '请在网页视图里打开 ' + base() + path + ' 完成校验，之后会自动重试。');
}
function get(path, referer) {
  return LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer || (base() + '/')
    }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    var body = reply && reply.body != null ? String(reply.body) : '';
    if (status === 403) throw verifyError(path);
    if (status === 503 || status === 429) throw verifyError(path);
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
    return body;
  });
}

// ------------------------------------------------------------------ 解析
function parseCards(html) {
  var src = String(html || '');
  var items = [], seen = {};
  var chunks = src.split(/<a[^>]+href="\/detail\/(\d+)\.html"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 2600);
    // 标题：卡片里的 <h4> 或 title/alt 属性
    var name = '';
    var h4 = /<h4[^>]*>([\s\S]{0,120}?)<\/h4>/i.exec(block);
    if (h4) name = clean(h4[1]);
    if (!name) {
      var t = /title="([^"]{1,80})"/i.exec(block) || /alt="([^"]{1,80})"/i.exec(block);
      if (t) name = clean(t[1]);
    }
    if (!name) continue;
    // 封面：这个主题把图挂在 <a class="stui-vodlist__thumb" data-original="..."> 上，
    // 也有站点用 <img>；两种都取，跳过占位图
    var cover = '';
    var direct = /data-original="([^"]+)"/i.exec(block);
    if (direct) {
      var du = String(direct[1]).trim();
      if (du && !/placeholder|lazy\.|logo|blank\./i.test(du)) cover = du;
    }
    if (!cover) {
      var segs = block.split(/<img\b/i);
      for (var si = 1; si < segs.length; si++) {
        var tag = segs[si].slice(0, 500);
        var im = /data-original="([^"]+)"/i.exec(tag) || /data-src="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
        if (!im) continue;
        var u = String(im[1]).trim();
        if (!u || /placeholder|lazy\.|logo|blank\./i.test(u)) continue;
        cover = u;
        break;
      }
    }
    if (cover && cover.charAt(0) === '/') cover = base() + cover;
    var note = /<span[^>]*class="[^"]*(?:pic-text|note|state)[^"]*"[^>]*>([\s\S]{0,20}?)<\/span>/i.exec(block);
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
  var title = titleTag ? clean(titleTag[1]).replace(/\s*[-–|].*$/, '').trim() : '';
  var h1 = /<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(src);
  if (h1 && clean(h1[1])) title = clean(h1[1]);
  var cover = '';
  var segs = src.split(/<img\b/i);
  for (var si = 1; si < segs.length; si++) {
    var tag = segs[si].slice(0, 500);
    var im = /data-original="([^"]+)"/i.exec(tag) || /data-src="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
    if (!im) continue;
    var u = String(im[1]).trim();
    if (!u || /placeholder|lazy|logo|blank/i.test(u)) continue;
    cover = u;
    break;
  }
  if (cover && cover.charAt(0) === '/') cover = base() + cover;
  var intro = /<div[^>]*class="[^"]*(?:detail-content|desc|intro)[^"]*"[^>]*>([\s\S]{0,3000}?)<\/div>/i.exec(src);
  var metaDesc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(src);
  var desc = intro ? clean(intro[1]) : (metaDesc ? unescapeHtml(metaDesc[1]).trim() : '');
  return { title: title, cover: cover, description: desc, lines: parseLines(src) };
}

// 线路标题在 <h3>（如「BD5播放」）里，分集是 /w/<id>-<line>-<ep>.html
function parseLines(html) {
  var src = String(html || '');
  var heads = [], reH = /<h3[^>]*>([\s\S]{0,40}?)<\/h3>/g, hm;
  while ((hm = reH.exec(src)) !== null) {
    var t = clean(hm[1]);
    if (t && /播放|线路|BD|高清|超清|4K/i.test(t)) heads.push(t);
  }
  var lines = {}, order = [], seen = {};
  var re = /href="\/w\/(\d+)-(\d+)-(\d+)\.html"[^>]*>([\s\S]{0,50}?)<\/a>/g, m;
  while ((m = re.exec(src)) !== null) {
    var line = Number(m[2]), ep = Number(m[3]);
    var key = line + '-' + ep;
    if (seen[key]) continue;
    seen[key] = true;
    var label = clean(m[4]);
    // 分集区的第一个链接常是「立即播放」按钮，不是集名：统一按集号命名
    if (!label || /立即播放|播放|追剧|收藏/.test(label)) label = '第' + (ep < 10 ? '0' + ep : ep) + '集';
    if (!lines[line]) { lines[line] = []; order.push(line); }
    lines[line].push({
      ep: ep,
      path: '/w/' + m[1] + '-' + m[2] + '-' + m[3] + '.html',
      label: label
    });
  }
  order.sort(function (a, b) { return a - b; });
  var out = [];
  for (var i = 0; i < order.length; i++) {
    var ln = order[i];
    lines[ln].sort(function (a, b) { return a.ep - b.ep; });
    out.push({ index: ln, title: heads[i] || ('线路 ' + ln), episodes: lines[ln] });
  }
  return out;
}

// 播放页 player_aaaa 里就是明文地址
function parsePlayUrl(html) {
  var src = String(html || '');
  var m = /var\s+player_\w+\s*=\s*(\{[\s\S]*?\})<\/script>/i.exec(src)
    || /var\s+player_\w+\s*=\s*(\{[\s\S]{0,2000}?\})\s*;?\s*<\/script>/i.exec(src);
  if (m) {
    try {
      var cfg = JSON.parse(m[1]);
      var u = String(cfg.url || '');
      if (/^https?:\/\//i.test(u)) return u;
    } catch (e) { /* 落到下面 */ }
  }
  var direct = /(https?:\\?\/\\?\/[^"'\s]+?\.(?:mp4|m3u8)[^"'\s]*)/i.exec(src);
  if (direct) return direct[1].replace(/\\\//g, '/');
  return '';
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'libvio_video',
  name: 'LIBVIO',
  version: '2.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/favicon.ico',
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
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://libvio.app/',
      description: '站点换域名时先看这里（发布页列出全部可用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: 'LIBVIO（www.libvio.io；旧域名 libvio.host / www.libvio.to 已停用）。站点用 CDN 浏览器校验挡非浏览器请求，首次使用请按提示在内置网页视图里完成校验，之后会自动重试并复用会话。支持电影/剧集/番剧/日韩/欧美，含地区与年份筛选、站内搜索；播放页直接给出正片 mp4 地址，多条线路全部保留。站点另有夸克/迅雷网盘线路，不在线播放，本源不列。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    return {
      groups: [
        {
          key: 'area', title: '地区', multiple: false,
          options: AREAS.map(function (v) { return { id: v, title: v }; })
        },
        {
          key: 'year', title: '年份', multiple: false,
          options: YEARS.map(function (v) { return { id: v, title: v }; })
        }
      ]
    };
  },

  async home() {
    var html = await get('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var f = args.filters || {};

    if (keyword) {
      var found = parseCards(await get('/search/-------------.html?wd=' + enc(keyword)));
      return { items: found, hasMore: false };
    }

    var cat = '1';
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { cat = category; break; }
    }
    var area = String(f.area == null ? '' : f.area).trim();
    var year = String(f.year == null ? '' : f.year).trim();

    var path;
    if (area || year) {
      // 筛选：/show/<cat>-<地区>----------<年份>.html（地区后固定 10 个短横线）
      path = '/show/' + cat + '-' + (area ? enc(area) : '') + '----------' + year + '.html';
    } else {
      path = '/type/' + cat + (page > 1 ? '-' + page : '') + '.html';
    }
    var items = parseCards(await get(path));
    // 每页 12 条；筛选页不翻页（站点筛选页本身也只给一页）
    return { items: items, hasMore: !area && !year && items.length >= 12 };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = '';
    try { html = await get('/detail/' + id + '.html'); } catch (e) { throw e; }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var total = 0;
    for (var i = 0; i < info.lines.length; i++) total += info.lines[i].episodes.length;
    var bits = [];
    if (info.lines.length > 1) bits.push(info.lines.length + ' 条线路');
    if (total > 1) bits.push('共 ' + total + ' 集');
    bits.push('直连播放');
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
    var html = await get('/detail/' + id + '.html');
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.lines.length) throw new Error('这一条在站点上没有可播放的分集');
    var out = [];
    for (var i = 0; i < info.lines.length; i++) {
      var line = info.lines[i];
      for (var j = 0; j < line.episodes.length; j++) {
        var ep = line.episodes[j];
        out.push({
          id: ep.path,
          title: info.lines.length > 1 ? (line.title + ' · ' + ep.label) : ep.label
        });
      }
    }
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.chapterId || '').trim();
    if (!/^\/w\/\d+-\d+-\d+\.html$/.test(path)) {
      var id = String(args.id || '').trim();
      if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
      var info = parseDetail(await get('/detail/' + id + '.html'));
      if (!info.lines.length || !info.lines[0].episodes.length) throw new Error('这一条没有可播放的分集');
      path = info.lines[0].episodes[0].path;
    }
    var page = await get(path);
    if (!page) throw new Error('播放页打不开（可能已下架）');
    var url = parsePlayUrl(page);
    if (!url) throw new Error('这条线路没有给出可播放地址，换一条线路试试');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};
