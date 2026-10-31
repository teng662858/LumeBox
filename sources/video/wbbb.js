// LumeSource: {"id":"wbbb_video","name":"歪比巴卜","version":"2.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.wbbb1.com","https://wbbb1.com","https://v.wbbb1.com"],"network":"direct","icon":"https://www.wbbb1.com/mxtheme/images/favicon.png"}
// LumeRuntime: javascript
//
// 站点：歪比巴卜（wbbb1.com；地址发布页 xn--clr79vmzkema.com = 歪比巴卜.com）
// 形态：苹果CMS v10 + 自定义主题（服务端渲染 HTML）。列表 /show/{类型}--------{页}---.html，
//       详情 /detail/{id}.html，播放页 /vplay/{id}-{线路}-{集}.html。
//
// ── 门槛 1：首访 403 ──
//   任何页面第一次请求都返回 403 + Set-Cookie，页内 JS 再跳回同一地址才 200。
//   本源遇到 403 会重发一次（宿主会把 Cookie 带上），与浏览器行为一致。
//
// ── v2.0.0 改了什么 ──
//   v1.0.0 的 `content()` 把 **详情页** `/detail/{id}.html` 交给网页播放器，那是片库页而不是播放器，
//   所以看着“不像在播放”。v2 做了三件事：
//     1. 详情页解析出「播放源」列表（`#y-playList` 里的 tab：推荐/蓝光A/蓝光B/高清C/BF有广/LZ有广…）
//        与每个 tab 对应的分集面板，**线路 × 分集** 全部列进章节（章节 id = `<sid>-<nid>`）；
//     2. `content()` 先取出这一集的 `/vplay/{id}-{sid}-{nid}.html`，读出 `player_aaaa` 里的密文 `url`
//        和 `link_next`，再据此拼出站点自己用的播放器地址
//        `https://xn--qvr2v.850088.xyz/player/?url=<密文>&next=<下一集>&title=<页标题>`，
//        交给 App 的网页播放器 —— 打开就是这一线路这一集的播放器，不再是详情页；
//     3. 解析接口的签名已经逆出来了（下面「签名」一节），实测能拿到 `{"code":200,...}` 的播放载荷。
//
// ── 签名（已逆出，实测被服务端接受）──
//   播放器把整条 query 当 `url` 传：`Q = <密文> + '&next=' + <'//'+域名+link_next 或 '//'>`
//   key22  = md5(Q) 的后 20 位 hex + ' P'          （calculate）
//   key    = base64( rc4(key22, md5(Q + 'stray')) )  （enplay）
//   vkey   = base64( rc4(key22, 秒级时间戳 + md5(key22 + 'stray')) )
//   ckey   = base64( rc4(key22, md5(播放器域名 + 'stray')) )
//   POST https://xn--qvr2v.850088.xyz/player/api.php  {url:Q, key, vkey, ckey} → 200 + 载荷
//   （其中 aesplay = 标准 RC4；enplay/deplay 都是它。）
//   **但是** 载荷里的媒体地址是二次加密的（响应自带 `aes_key` / `aes_iv`，由播放器自己的
//   CryptoJS 现解），这一层还没解出来 —— 所以本源不伪造 `video()`，仍走网页播放器，
//   只是把「打开哪一集」这件事做对了。
//
// 门槛 3：站内搜索 /search/<词>-------------.html 被 WAF 拦（返回「系统安全验证」页），
//   本源改用本地索引：浏览过的条目会被记住，搜索时在索引里过滤；索引为空时先抓一页。
//   不伪造搜索结果。

var HOST = 'https://www.wbbb1.com';
var MIRRORS = ['https://www.wbbb1.com', 'https://wbbb1.com', 'https://v.wbbb1.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
// 站点 parse.js 里写死的解析播放器
var PLAYER_HOST = 'https://xn--qvr2v.850088.xyz';
var PAGE_SIZE = 20;
var INDEX_FILE = 'index.json';
var INDEX_CAP = 4000;

var CATS = [
  { id: 'movie', type: 1, title: '电影' },
  { id: 'tv', type: 2, title: '剧集' },
  { id: 'anime', type: 3, title: '动漫' },
  { id: 'variety', type: 4, title: '综艺' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }
function readJson(file) {
  return LumeSource.fs.readText(file).then(function (text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}
function unescapeHtml(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#x27;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code)); });
}
function clean(text) {
  return unescapeHtml(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

// 403 = 首访门（站点先塞 Cookie 再让刷新），重发一次即可；「系统安全验证」= WAF 页，如实报错
async function fetchHtml(path, retried) {
  var reply = await LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + '/'
    }
  });
  var status = (reply && reply.status) || 0;
  var body = reply && reply.body != null ? String(reply.body) : '';
  if (!status) throw new Error('连不上站点：' + base() + path);
  if (status === 403 && !retried) return await fetchHtml(path, true);
  if (status === 429) throw new Error('站点限流（HTTP 429），稍后再试');
  if (status === 404) return '';
  if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + path);
  if (body.indexOf('系统安全验证') >= 0) throw new Error('这一页触发了站点的安全验证（WAF），请稍后再试');
  return body;
}

// ------------------------------------------------------------------ HTML 解析
function parseCards(html) {
  var source = String(html || '');
  var chunks = source.split(/<a\s[^>]*href="\/detail\/(\d+)\.html"/);
  var items = [];
  var seen = {};
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 1500);
    var img = /<img\s[^>]*>/i.exec(block);
    var name = '';
    var cover = '';
    if (img) {
      var alt = /alt="([^"]*)"/i.exec(img[0]);
      var pic = /data-original="([^"]+)"/i.exec(img[0]) || /data-src="([^"]+)"/i.exec(img[0]) || /src="([^"]+)"/i.exec(img[0]);
      name = alt ? unescapeHtml(alt[1]).trim() : '';
      cover = pic ? unescapeHtml(pic[1]) : '';
    }
    if (/load\.gif|errorpic/.test(cover)) cover = '';
    if (!name) continue;
    var note = /module-item-note">([^<]{1,30})</.exec(block);
    seen[id] = true;
    items.push({ id: id, title: name, cover: cover, subtitle: note ? clean(note[1]) : '' });
  }
  return items;
}

function parseDetail(html) {
  var source = String(html || '');
  var h1 = /<h1[^>]*>([\s\S]{0,160}?)<\/h1>/i.exec(source);
  var pic = /class="mac_history_set"[^>]*data-pic="([^"]*)"/i.exec(source)
    || /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
  var intro = /module-info-introduction-content[^>]*>([\s\S]{0,1500}?)<\/div>/i.exec(source);
  return {
    title: h1 ? clean(h1[1]) : clean((/<title>([^<]*)<\/title>/i.exec(source) || [])[1] || ''),
    cover: pic ? unescapeHtml(pic[1]) : '',
    description: intro ? clean(intro[1]) : ''
  };
}

// 播放源（线路）+ 每个线路的分集：tab 名称与分集面板按出现顺序一一对应
function parseSources(html, id) {
  var source = String(html || '');
  var names = [];
  var tabRe = /data-dropdown-value="([^"]+)"[^>]*>\s*<span>[^<]*<\/span>\s*<small>(\d+)<\/small>/g;
  var m;
  while ((m = tabRe.exec(source)) !== null) names.push({ name: unescapeHtml(m[1]).trim(), count: Number(m[2]) });

  // 分集面板：每个 module-play-list 块里是同一线路的分集链接
  var panels = [];
  var parts = source.split(/class="module-play-list-content([^"]*)"/);
  for (var i = 1; i < parts.length; i += 2) {
    var block = String(parts[i + 1] || '');
    var eps = [];
    var re = new RegExp('/vplay/' + id + '-(\\d+)-(\\d+)\\.html"[^>]*>\\s*<span>([^<]*)</', 'g');
    var hit;
    while ((hit = re.exec(block)) !== null) {
      eps.push({ sid: Number(hit[1]), nid: Number(hit[2]), label: clean(hit[3]) });
    }
    if (eps.length) panels.push(eps);
  }

  var out = [];
  for (var p = 0; p < panels.length; p++) {
    var eps = panels[p];
    var name = names[p] ? names[p].name : ('线路 ' + (p + 1));
    for (var k = 0; k < eps.length; k++) {
      out.push({ sid: eps[k].sid, nid: eps[k].nid, label: eps[k].label, line: name });
    }
  }
  return out;
}

function indexOf(items) {
  if (!items || !items.length) return Promise.resolve(null);
  return readJson(INDEX_FILE).then(function (current) {
    var map = (current && current.map) || {};
    for (var i = 0; i < items.length; i++) {
      map[items[i].id] = { title: items[i].title, cover: items[i].cover };
    }
    var keys = Object.keys(map);
    if (keys.length > INDEX_CAP) {
      for (var k = 0; k < keys.length - INDEX_CAP; k++) delete map[keys[k]];
    }
    return writeJson(INDEX_FILE, { at: Date.now(), map: map });
  });
}

async function loadListPage(category, page) {
  var type = 1;
  for (var i = 0; i < CATS.length; i++) {
    if (CATS[i].id === category) { type = CATS[i].type; break; }
  }
  var path = page <= 1
    ? '/show/' + type + '-----------.html'
    : '/show/' + type + '--------' + page + '---.html';
  var html = await fetchHtml(path);
  var items = parseCards(html);
  await indexOf(items);
  return { items: items, hasMore: items.length >= PAGE_SIZE - 5 };
}

function searchIndex(keyword, page) {
  return readJson(INDEX_FILE).then(function (data) {
    var map = (data && data.map) || {};
    var only = keyword.toLowerCase();
    var hits = [];
    for (var id in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id)) continue;
      if (String(map[id].title || '').toLowerCase().indexOf(only) < 0) continue;
      hits.push({ id: id, title: map[id].title, cover: map[id].cover || '', subtitle: '' });
    }
    var start = (page - 1) * PAGE_SIZE;
    return { items: hits.slice(start, start + PAGE_SIZE), hasMore: hits.length > start + PAGE_SIZE };
  });
}

// 播放页 → player_aaaa（密文 url / link_next / 页标题）
// 注意：电影页是原样 JSON，剧集页是「转义过的 JSON 字符串」（\"flag\":…），两种都要认。
function parsePlayer(html) {
  var source = String(html || '');
  var m = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*(?:;|<\/script>)/.exec(source);
  if (!m) return null;
  var raw = String(m[1]).replace(/\\"/g, '"').replace(/\\\//g, '/');
  var data = null;
  try { data = JSON.parse(raw); } catch (e) { return null; }
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  return {
    url: String(data.url || ''),
    from: String(data.from || ''),
    next: String(data.link_next || ''),
    title: titleTag ? clean(titleTag[1]) : ''
  };
}

// 站点 parse.js 拼的播放器地址：?url=<密文>&next=//<域名><下一集>&title=<标题前半段>
function playerUrl(info) {
  var domain = base().replace(/^https?:\/\//, '');
  var nextPart = info.next ? '//' + domain + info.next : '//';
  var title = String(info.title || '').split('-')[0].trim();
  return PLAYER_HOST + '/player/?url=' + encodeURIComponent(info.url) +
    '&next=' + nextPart + '&title=' + enc(title);
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'wbbb_video',
  name: '歪比巴卜',
  version: '2.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/mxtheme/images/favicon.png',
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://www.xn--clr79vmzkema.com/',
      description: '站点换域名时先看这里（发布页给出当前可用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '歪比巴卜（wbbb1.com）。v2 起选集按「线路 × 分集」全部展开，点哪一集就用网页播放器直接打开那一集（不再是详情页）。站点把媒体地址做了二次加密，原生播放要再破一层，目前仍走网页播放器。站内搜索被 WAF 拦，本源用本地索引。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点分类页没有可用 URL 传参的筛选（地区/年份都在导航里，且翻页只吃 show 路径），如实返回空组。
    return { groups: [] };
  },

  async home() {
    var html = await fetchHtml('/');
    var items = parseCards(html);
    if (!items.length) return [];
    await indexOf(items);
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var cached = await searchIndex(keyword, page);
      if (cached.items.length || page > 1) return cached;
      try {
        await loadListPage(category || 'movie', 1);
      } catch (e) { /* 抓不到就算了，照样返回空 */ }
      return await searchIndex(keyword, page);
    }
    return await loadListPage(category || 'movie', page);
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = await fetchHtml('/detail/' + id + '.html');
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var eps = parseSources(html, id);
    var lines = {};
    for (var i = 0; i < eps.length; i++) lines[eps[i].line] = (lines[eps[i].line] || 0) + 1;
    var names = Object.keys(lines);
    var bits = [];
    if (names.length) {
      bits.push(names.length + ' 条线路');
      var maxEp = 0;
      for (var k = 0; k < names.length; k++) if (lines[names[k]] > maxEp) maxEp = lines[names[k]];
      bits.push(maxEp > 1 ? '共 ' + maxEp + ' 集' : '正片');
    }
    var desc = info.description ? info.description + '\n\n' : '';
    desc += '播放说明：选集里按「线路 · 分集」列出站点全部线路，点哪一集就用 App 的网页播放器打开站点对应那一集的播放器；' +
      '某条线路提示「解析失败」时换一条线路即可。';
    return {
      id: id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: desc
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var html = await fetchHtml('/detail/' + id + '.html');
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var eps = parseSources(html, id);
    if (!eps.length) throw new Error('这一条在站点上还没有播放源');
    return eps.map(function (ep) {
      var extra = ep.label && ep.label !== String(ep.nid) ? ep.label + ' · ' : '';
      return { id: ep.sid + '-' + ep.nid, title: ep.line + ' · ' + extra + '第 ' + ep.nid + ' 集' };
    });
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.itemId || '').trim();
    var chapter = String(args.chapterId || '').trim();
    var hit = /^(\d+)-(\d+)$/.exec(chapter);
    var sid = hit ? hit[1] : '';
    var nid = hit ? hit[2] : '';
    if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
    if (!sid || !nid) {
      // 没带章节：退回详情页里第一条线路的第一集
      var page = await fetchHtml('/detail/' + id + '.html');
      var eps = parseSources(page, id);
      if (!eps.length) throw new Error('这一条在站点上没有播放源');
      sid = String(eps[0].sid);
      nid = String(eps[0].nid);
    }
    var vplay = await fetchHtml('/vplay/' + id + '-' + sid + '-' + nid + '.html');
    if (!vplay) throw new Error('播放页打不开（可能已下架）');
    var info = parsePlayer(vplay);
    if (!info || !info.url) throw new Error('播放页里没有取到播放参数（站点可能改版）');
    return {
      kind: 'webplayer',
      pageUrl: playerUrl(info),
      headers: { 'User-Agent': UA, 'Referer': base() + '/' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
