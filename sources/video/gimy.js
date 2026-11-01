// LumeSource: {"id":"gimy_video","name":"劇迷","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://gimy.org"],"network":"direct","icon":"https://gimy.org/static/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：劇迷 Gimy（gimy.org，台湾镜像站，面向海外的华语剧集聚合站）。
//   形态：服务端渲染的 Bootstrap 模板，页面 15–40 KB，解析开销小。
//
//   栏目   /tv/?country=cn|hk|tw|kr|jp|us&page=N      （大陆/港/台/韩/日/美）
//          /movie/?page=N  /variety/?page=N  /anime/?page=N
//          列表 24 条/页，真分页（第 2 页内容不同）
//   搜索   /search?q=<词>&page=N（同样 24 条）
//   详情   /video/{id}.html      标题、/gimypic/{id}.jpg 封面、簡介、分集（/vplay/{id}/{ep}.html）
//   播放   GET /_gimy_plays/{id}/{ep}  → JSON {"video_plays":[{"play_data":"…index.m3u8","src_site":"mdzy"}]}
//          返回 3–8 条线路（魔都/紅牛/極速/金鷹/愛坤…），全部是 m3u8 直链，实测 200 + #EXTM3U。
//          电影的分集 id 是 `default`，剧集是 `ep1…epN`。
//
//   说明：站点的分集列表以详情页为准 —— 老剧可能只挂 1 集（站点自身就没补全），本源如实返回，不编造集数。

var HOST = 'https://gimy.org';
var MIRRORS = ['https://gimy.org'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var PAGE_SIZE = 24;

var CATS = [
  { id: 'tv-cn', title: '大陸劇' },
  { id: 'tv-hk', title: '港劇' },
  { id: 'tv-tw', title: '台劇' },
  { id: 'tv-kr', title: '韓劇' },
  { id: 'tv-jp', title: '日劇' },
  { id: 'tv-us', title: '美劇' },
  { id: 'movie', title: '電影' },
  { id: 'variety', title: '綜藝' },
  { id: 'anime', title: '動漫' }
];

// 线路代号 → 站内叫法（播放器里给用户看）
var SITE_LABEL = {
  mdzy: '魔都', hnzy: '紅牛', jszy: '極速', jyzy: '金鷹', ikzy: '愛坤', lzzy: '量子',
  bfzym3u8: '暴風', ffm3u8: '非凡', '1080zyk': '1080', ukm3u8: 'U咖', sdm3u8: '閃電',
  wjm3u8: '無極', xlm3u8: '迅狼', gsm3u8: '光速', hnm3u8: '紅牛雲', tkm3u8: '天空',
  wwzy: '完美', tyyszy: '天涯', jisuplay: '極速', subplay: '速播', huyaplay: '虎牙',
  suoniplay: '少年', moduplay: '萌動', iqyplay: '奇緣', '360zy': '360', rym3u8: '睿映'
};

// ------------------------------------------------------------------ 基础工具
function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function clean(t) {
  return String(t == null ? '' : t)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}
function abs(u) {
  var s = String(u || '').trim();
  if (!s) return '';
  if (/^https?:\/\//i.test(s)) return s;
  if (/^\/\//.test(s)) return 'https:' + s;
  return base() + (s.charAt(0) === '/' ? s : '/' + s);
}
function get(url, opt) {
  var options = opt || {};
  return LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      'Accept': options.json ? 'application/json, text/javascript, */*; q=0.01' : 'text/html,application/xhtml+xml,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': options.referer || base() + '/'
    }
  }).then(function (r) {
    var s = r ? r.status : 0;
    if (!s) throw new Error('连不上站点，请检查网络或到「源设置 → 站点网络」配置代理');
    if (s === 403 && /just a moment|challenge|cf-/i.test(String(r.body || '').slice(0, 400))) {
      throw new Error('NEED_WEBVIEW_VERIFY: ' + url);
    }
    if (s !== 200) throw new Error('站点返回 HTTP ' + s);
    return r.body ? String(r.body) : '';
  });
}
function readJson(file) {
  return LumeSource.fs.readText(file).then(function (t) {
    if (!t) return null;
    try { return JSON.parse(t); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function writeJson(file, v) {
  return LumeSource.fs.writeText(file, JSON.stringify(v)).catch(function () { return null; });
}

// ------------------------------------------------------------------ 列表
function listPath(cat, page, kw) {
  if (kw) return base() + '/search?q=' + encodeURIComponent(kw) + '&page=' + page;
  var m = /^tv-([a-z]{2})$/.exec(cat || '');
  if (m) return base() + '/tv/?country=' + m[1] + '&page=' + page;
  if (cat === 'movie') return base() + '/movie/?page=' + page;
  if (cat === 'variety') return base() + '/variety/?page=' + page;
  if (cat === 'anime') return base() + '/anime/?page=' + page;
  return base() + '/tv/?page=' + page;
}
function parseCards(html) {
  var text = String(html || ''), out = [], seen = {};
  // 列表页把 gimy-card-item 写在 class 开头，搜索页写在末尾 —— 直接锚定卡片链接最稳
  var re = /<a class="gimy-card-thumb-x" href="\/video\/(\d+)\.html" title="([^"]{0,100})">([\s\S]{0,600}?)<\/a>/g;
  var m;
  while ((m = re.exec(text)) !== null) {
    var id = m[1];
    if (seen[id]) continue;
    var inner = m[3] || '';
    var cover = (/(?:data-original|src)="([^"]+)"/.exec(inner) || [])[1] || ('/gimypicth/' + id + '.jpg');
    var title = clean(m[2] || (/(?:<img[^>]+alt="([^"]{1,80})")/.exec(inner) || [])[1] || '').replace(/線上看$/, '');
    if (!title) continue;
    var after = text.slice(m.index + m[0].length, m.index + m[0].length + 400);
    var sub = clean((/<div class="small">([^<]{0,40})<\/div>/.exec(after) || [])[1] || '');
    seen[id] = 1;
    out.push({ id: id, title: title, cover: abs(cover), subtitle: sub });
  }
  return out;
}

// ------------------------------------------------------------------ 详情
function parseDetail(html, id) {
  var text = String(html || '');
  var info = { title: '', cover: '', description: '', subtitle: '', eps: [] };
  info.title = clean((/<h3 class="title">([\s\S]{0,120}?)<\/h3>/.exec(text) || [])[1] || '');
  info.cover = base() + '/gimypic/' + id + '.jpg';
  info.description = clean((/<p class="desc[^"]*">([\s\S]{0,1200}?)<\/p>/.exec(text) || [])[1] || '');
  var meta = clean((/<p class="data">([\s\S]{0,400}?)<\/p>/.exec(text) || [])[1] || '').replace(/簡介：[\s\S]*$/, '');
  info.subtitle = meta.slice(0, 80);

  var seen = {};
  var re = /href="\/vplay\/\d+\/([a-z0-9]+)\.html"[^>]*>([^<]{0,24}?)</g;
  var m;
  while ((m = re.exec(text)) !== null) {
    var ep = m[1];
    if (seen[ep]) continue;
    seen[ep] = 1;
    info.eps.push({ ep: ep, title: clean(m[2]) });
  }
  info.eps.sort(function (a, b) {
    var na = /^ep(\d+)$/.exec(a.ep), nb = /^ep(\d+)$/.exec(b.ep);
    if (na && nb) return Number(na[1]) - Number(nb[1]);
    if (na) return -1;
    if (nb) return 1;
    return a.ep < b.ep ? -1 : 1;
  });
  return info;
}

// ------------------------------------------------------------------ 入口
var LumeSource = {
  id: 'gimy_video',
  name: '劇迷',
  version: '1.0.0',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '劇迷（gimy.org）：台湾镜像站，华人剧集聚合，大陆剧/港剧/台剧/韩剧更新快，单集给 3–8 条 m3u8 线路（魔都/紅牛/極速/金鷹…），直接在播放器里换线。老剧的分集以站点为准（部分只有 1 集）。打不开时可到「源设置 → 站点网络」配代理。'
    }
  ],

  async categories() { return CATS; },

  async list(argument) {
    var a = argument || {};
    var page = Math.max(1, Number(a.page || 1) || 1);
    var kw = String(a.keyword || '').trim();
    var cat = String(a.categoryId || '').trim() || 'tv-cn';
    var html = await get(listPath(cat, page, kw));
    var items = parseCards(html);
    if (!items.length) return { items: [], hasMore: false };

    var cache = (await readJson('items.json')) || { map: {} };
    var map = cache.map || {};
    for (var i = 0; i < items.length; i++) map[items[i].id] = { title: items[i].title, cover: items[i].cover };
    await writeJson('items.json', { at: Date.now(), map: map });
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return null;
    var cache = (await readJson('items.json')) || { map: {} };
    var row = cache.map ? cache.map[id] : null;
    var info = null;
    try {
      info = parseDetail(await get(base() + '/video/' + id + '.html'), id);
    } catch (e) {
      if (!row) throw e;
    }
    if (!info && !row) return null;
    return {
      id: id,
      title: (info && info.title) || (row && row.title) || ('作品 ' + id),
      cover: (info && info.cover) || (row && row.cover) || (base() + '/gimypic/' + id + '.jpg'),
      subtitle: (info && info.subtitle) || '',
      description: (info && info.description) || '劇迷（gimy.org）'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return [];
    var info = parseDetail(await get(base() + '/video/' + id + '.html'), id);
    if (!info.eps.length) return [];
    return info.eps.map(function (e) {
      var title = e.title || (e.ep === 'default' ? '正片' : e.ep.toUpperCase());
      return { id: e.ep, title: title.indexOf('第') === 0 || /[\u4e00-\u9fa5]/.test(title) ? title : ('第' + title + '集') };
    });
  },

  async content(argument) {
    var a = argument || {};
    var id = String(a.id || '').replace(/\D/g, '');
    var ep = String(a.chapterId || '').replace(/[^a-z0-9]/gi, '') || 'default';
    if (!id) throw new Error('缺少作品 id');
    var raw = await get(base() + '/_gimy_plays/' + id + '/' + ep, {
      json: true,
      referer: base() + '/vplay/' + id + '/' + ep + '.html'
    });
    var payload = null;
    try { payload = JSON.parse(raw); } catch (e) { payload = null; }
    var plays = (payload && payload.video_plays) || [];
    if (!plays.length) throw new Error('站点没有给出播放地址（可能该集未上线或已下架）');
    var qualities = [];
    for (var i = 0; i < plays.length; i++) {
      var url = plays[i] && plays[i].play_data ? String(plays[i].play_data) : '';
      if (!/^https?:\/\//i.test(url)) continue;
      var code = String(plays[i].src_site || '');
      var label = SITE_LABEL[code] || code || ('線路' + (i + 1));
      qualities.push({ label: label, url: url });
    }
    if (!qualities.length) throw new Error('站点返回的播放地址为空');

    // 站点线路时好时坏（有的 CDN 对本机 404/403），按顺序探活，取第一条真能播的放默认线路，
    // 其余仍留在 qualities 里供播放器换线。
    var pick = 0;
    var tryMax = Math.min(qualities.length, 4);
    for (var j = 0; j < tryMax; j++) {
      var ok = await probeMedia(qualities[j].url);
      if (ok) { pick = j; break; }
    }
    var ordered = qualities.slice(pick).concat(qualities.slice(0, pick));
    return {
      kind: 'video',
      url: ordered[0].url,
      headers: { 'User-Agent': UA, 'Referer': base() + '/' },
      qualities: ordered
    };
  }
};

// 探活一条 m3u8/mp4：200/206 且响应体像播放清单才算可用
async function probeMedia(url) {
  try {
    var r = await LumeSource.http.get(url, {
      headers: { 'User-Agent': UA, 'Referer': base() + '/' }
    });
    var s = r ? r.status : 0;
    if (s !== 200 && s !== 206) return false;
    var body = String((r && r.body) || '');
    return body.indexOf('#EXTM3U') >= 0 || body.indexOf('ftyp') >= 0;
  } catch (e) {
    return false;
  }
}
