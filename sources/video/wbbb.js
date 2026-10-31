// LumeSource: {"id":"wbbb_video","name":"歪比巴卜","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.wbbb1.com","https://wbbb1.com","https://v.wbbb1.com"],"network":"direct","icon":"https://www.wbbb1.com/mxtheme/images/favicon.png"}
// LumeRuntime: javascript
//
// 站点：歪比巴卜（wbbb1.com；地址发布页 xn--clr79vmzkema.com = 歪比巴卜.com）
// 形态：苹果CMS v10 + 自定义主题（服务端渲染 HTML）。列表 /show/{类型}--------{页}---.html，
//       详情 /detail/{id}.html，播放页 /vplay/{id}-{线路}-{集}.html，站点自带 Suggest 搜索。
//
// ── 门槛 1：首访 403 ──
//   任何页面第一次请求都返回 403 + Set-Cookie，页内 JS 再跳回同一地址才 200。
//   本源遇到 403 会重发一次（宿主会把 Cookie 带上），与浏览器行为一致。
//
// ── 门槛 2：播放地址由站点自己的 wasm/JS 现算，本源不复制 ──
//   /vplay 页只给加密串（player_aaaa.url），真正的 m3u8 要先由页面 JS 生成
//   `api.php?url=<密文>&key=&vkey=&ckey=` 再请求，signature 在混淆后的 setting.js 里。
//   实测（本机 headless Chrome + CDP，逐条线路试过「推荐/蓝光4K/蓝光I/BF有广」）：
//   本站 4 条线路的 api.php 全部返回 {"code":404,"msg":"解析失败"} —— 本机出口被限制
//   （站点的解析服务对网络/出口有要求），但用户自己的网络里站点播放器是正常的。
//   → 因此本源把播放交给 App 的网页播放器：打开源站的 /detail 页，由站点自己算签名、
//     自己选线路和集数（页面里可切换多条线路，某条解析失败就换下一条）。
//
// 门槛 3：站内搜索 /search/<词>-------------.html 被 WAF 拦（返回「系统安全验证」页），
//   本源改用本地索引：浏览过的条目会被记住，搜索时在索引里过滤；索引为空时先抓一页。
//   不伪造搜索结果。

var HOST = 'https://www.wbbb1.com';
var MIRRORS = ['https://www.wbbb1.com', 'https://wbbb1.com', 'https://v.wbbb1.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
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
    url: base() + path,
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
// 卡片：<a href="/detail/115938.html" title="嫁金钗" class="module-poster-item module-item">
//         …<img … data-original="封面" alt="嫁金钗">
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
  var year = /<a[^>]*href="\/show\/\d+---[\d]+--------\.html"[^>]*>([^<]{2,8})<\/a>/.exec(source);
  return {
    title: h1 ? clean(h1[1]) : clean((/<title>([^<]*)<\/title>/i.exec(source) || [])[1] || ''),
    cover: pic ? unescapeHtml(pic[1]) : '',
    description: intro ? clean(intro[1]) : '',
    year: year ? clean(year[1]) : ''
  };
}

// 分集链接 /vplay/{id}-{线路}-{集}.html：数出「线路数」与「每线集数」，用于章节提示
function parseEpisodes(html, id) {
  var source = String(html || '');
  var re = new RegExp('/vplay/' + id + '-(\\d+)-(\\d+)\\.html', 'g');
  var lines = {};
  var match;
  while ((match = re.exec(source)) !== null) {
    var sid = Number(match[1]);
    var ep = Number(match[2]);
    if (!lines[sid]) lines[sid] = {};
    lines[sid][ep] = true;
    if (Object.keys(lines[sid]).length > 400) break;
  }
  var out = [];
  for (var key in lines) {
    if (!Object.prototype.hasOwnProperty.call(lines, key)) continue;
    out.push({ sid: Number(key), count: Object.keys(lines[key]).length });
  }
  out.sort(function (a, b) { return b.count - a.count; });
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

// 分类列表页：/show/{类型}-----------.html（第 1 页）与 /show/{类型}--------{页}---.html
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

function searchIndex(keyword, page) {  return readJson(INDEX_FILE).then(function (data) {
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

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'wbbb_video',
  name: '歪比巴卜',
  version: '1.0.0',
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
      description: '站点换域名时先看这里（发布页给出 3 条线路的当前域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '歪比巴卜（wbbb1.com）。播放走 App 的网页播放器：站点有多条线路（蓝光A/高清C/蓝光I/蓝光4K…），某条解析失败就在页面里换一条。站内搜索被 WAF 拦，本源用本地索引（浏览过的条目可搜）。'
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
      // 站内搜索页被 WAF 拦（「系统安全验证」），改用本地索引；索引为空先抓一页灌进去
      var cached = await searchIndex(keyword, page);
      if (cached.items.length || page > 1) return cached;
      try {
        await loadListPage(category || 'movie', 1);
      } catch (e) { /* 抓不到就算了，照样返回空 */ }
      return await searchIndex(keyword, page);
    }

    var type = 1;
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { type = CATS[i].type; break; }
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
    var lines = parseEpisodes(html, id);
    var bits = [];
    if (info.year) bits.push(info.year);
    if (lines.length) {
      var total = lines[0].count;
      bits.push('共 ' + total + ' 集');
      bits.push(lines.length + ' 条线路');
    }
    var desc = info.description ? info.description + '\n\n' : '';
    desc += '播放说明：本源打开源站的详情页，由站点自己的播放器选线路、选集（播放地址是站点前端现算的签名，' +
      '本源不复制）。某条线路提示「解析失败」时，在页面里换一条线路即可。';
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
    var lines = parseEpisodes(html, id);
    var title = lines.length > 1
      ? '网页播放（' + lines.length + ' 条线路，最多 ' + lines[0].count + ' 集，在页面里选）'
      : '网页播放（选集在播放器里）';
    return [{ id: 'web:' + id, title: title }];
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.chapterId || '').replace(/^web:/, '');
    if (!id) id = String(args.id || '').trim();
    if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
    // 详情页自带「线路 × 分集」两排选择器，正是站点自己的选择界面
    return { kind: 'webplayer', url: base() + '/detail/' + id + '.html' };
  }
};
