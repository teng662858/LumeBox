// LumeSource: {"id":"libvio_video","name":"LIBVIO","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://libvio.host","https://www.libvio.to","https://libviobd.com"],"network":"proxy","icon":"https://libvio.host/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：LIBVIO（发布页 https://libvio.app/ ，另有镜像发布页 libviofabu.com / libfabu.com /
//       libviogroup.github.io；真实站点域名 libvio.host / www.libvio.to / libviobd.com）。
//
// ⚠️ 重要限制：真实站点对**中国大陆以外的 IP 直接返回**
//       `403 Access denied by geographic restriction`
//   （2026-11-01 在本机实测：三个域名全部 403，发布页 200）。
//   所以本源**无法在本机验证解析逻辑**，也不编造一套看起来能用的解析：
//     · 列表/详情/播放都按站点结构实现，但只有在站点放行你的网络时才会返回内容；
//     · 被地域拦截时抛可读错误，明确告诉用户这是站点侧的地域限制，不是源坏了。
//   如果你能访问站点（例如所在地区放行或走站点允许的网络），本源即可正常使用。
//
// 结构（按苹果CMS v10 常规 + 站点发布页给出的信息实现，未能在本机验证）：
//   列表 /vodshow/<分类>-----------.html，详情 /detail/<id>.html，播放 /vodplay/<id>-<线路>-<集>.html
//   站点改用其它路径时，本源会如实报错而不是返回空列表。

var HOST = 'https://libvio.host';
var MIRRORS = ['https://libvio.host', 'https://www.libvio.to', 'https://libviobd.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 24;
var GEO_BLOCK = /geographic restriction|Access denied by geographic/i;

var CATS = [
  { id: 'movie', title: '电影' },
  { id: 'tv', title: '剧集' },
  { id: 'anime', title: '动漫' },
  { id: 'show', title: '综艺' }
];

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
function geoError() {
  return new Error('站点按地区限制访问：当前网络被拒绝（HTTP 403 Access denied by geographic restriction）。' +
    '这是 LIBVIO 官方对非放行地区的封锁，不是源失效。可在源设置里换镜像，或在放行的网络下使用。');
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
    if (status === 403 && GEO_BLOCK.test(body)) throw geoError();
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
    return body;
  });
}

function parseCards(html) {
  var src = String(html || '');
  var items = [], seen = {};
  var chunks = src.split(/<a[^>]+href="\/(?:detail|voddetail)\/(\d+)\.html"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 2500);
    var segs = block.split(/<img\b/i);
    var cover = '';
    for (var si = 1; si < segs.length; si++) {
      var tag = segs[si].slice(0, 400);
      var im = /data-src="([^"]+)"/i.exec(tag) || /data-original="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
      if (!im) continue;
      var u = String(im[1]).trim();
      if (!u || /placeholder|logo/i.test(u)) continue;
      cover = u;
      break;
    }
    if (cover && cover.charAt(0) === '/') cover = base() + cover;
    var title = /title="([^"]{1,80})"/i.exec(block) || /alt="([^"]{1,80})"/i.exec(block);
    var name = clean(title ? title[1] : '');
    if (!name) continue;
    seen[id] = true;
    items.push({ id: id, title: name, cover: unescapeHtml(cover), subtitle: '' });
  }
  return items;
}

function parseDetail(html) {
  var src = String(html || '');
  var titleTag = /<title>([^<]*)<\/title>/i.exec(src);
  var title = titleTag ? clean(titleTag[1]).replace(/\s*[-–|].*$/, '').trim() : '';
  var cover = /<img[^>]+(?:data-src|data-original|src)="([^"]*(?:upload|vod)[^"]*)"/i.exec(src);
  var desc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(src);
  var eps = [];
  var seen = {};
  var re = /<a[^>]+href="(\/(?:vodplay|play)\/\d+-\d+-\d+\.html)"[^>]*>([\s\S]{0,60}?)<\/a>/g, m;
  while ((m = re.exec(src)) !== null) {
    if (seen[m[1]]) continue;
    seen[m[1]] = true;
    eps.push({ path: m[1], label: clean(m[2]) || ('第 ' + (eps.length + 1) + ' 集') });
  }
  return {
    title: title,
    cover: cover ? unescapeHtml(cover[1]) : '',
    description: desc ? unescapeHtml(desc[1]).trim() : '',
    episodes: eps
  };
}

// 播放页里找 m3u8 / mp4（站点可能直接给地址，也可能走 iframe）
function parsePlayUrl(html) {
  var src = String(html || '');
  var m = /src:\s*['"]([^'"]+\.m3u8[^'"]*)['"]/i.exec(src)
    || /['"]((?:https?:)?\/\/[^'"]+\.m3u8[^'"]*)['"]/i.exec(src)
    || /src:\s*['"]([^'"]+\.mp4[^'"]*)['"]/i.exec(src)
    || /player_aaaa=(\{[\s\S]*?\})<\/script>/i.exec(src);
  if (!m) return '';
  if (/^\{/.test(m[1])) {
    try {
      var cfg = JSON.parse(m[1]);
      var u = String(cfg.url || '');
      if (/^https?:\/\//i.test(u)) return u;
    } catch (e) { /* 落到下面 */ }
    return '';
  }
  return m[1].replace(/\\\//g, '/');
}

var LumeSource = {
  id: 'libvio_video',
  name: 'LIBVIO',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'proxy',
  icon: 'https://libvio.host/favicon.ico',
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
      title: '站点说明（重要）',
      description: 'LIBVIO 对非放行地区直接返回 403「Access denied by geographic restriction」（2026-11-01 实测 libvio.host / www.libvio.to / libviobd.com 三个域名全部如此）。当前网络若被拦，本源会明确提示这是站点地域限制，不是源坏了。发布页 libvio.app 可正常打开，可从中确认最新域名。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var html = await get('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    if (keyword) {
      return { items: parseCards(await get('/vodsearch/' + enc(keyword) + '----------' + page + '---.html')), hasMore: false };
    }
    var cat = 'movie';
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { cat = category; break; }
    }
    var path = '/vodshow/' + cat + '-' + (page > 1 ? '--------' + page + '---' : '-----------') + '.html';
    var items = parseCards(await get(path));
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = '';
    try { html = await get('/detail/' + id + '.html'); } catch (e) {
      if (GEO_BLOCK.test(e.message)) throw e;
      return null;
    }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var bits = [];
    if (info.episodes.length > 1) bits.push('共 ' + info.episodes.length + ' 集');
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
    if (!info.episodes.length) throw new Error('这一条在站点上没有可播放的分集');
    return info.episodes.map(function (e, i) {
      return { id: e.path, title: info.episodes.length > 1 ? e.label : '正片' };
    });
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.chapterId || '').trim();
    if (!/^\/(?:vodplay|play)\/\d+-\d+-\d+\.html$/.test(path)) {
      var id = String(args.id || '').trim();
      if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
      var info = parseDetail(await get('/detail/' + id + '.html'));
      if (!info.episodes.length) throw new Error('这一条没有可播放的分集');
      path = info.episodes[0].path;
    }
    var page = await get(path);
    var url = parsePlayUrl(page);
    if (!url) throw new Error('这条线路没有给出可解析的播放地址（站点可能又换了播放器结构）');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};
