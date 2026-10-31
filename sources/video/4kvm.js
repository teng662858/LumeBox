// LumeSource: {"id":"fourk_video","name":"4k影视","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.4kvms.org","https://www.4kvm.org","https://www.4kvm.tv","https://www.4kvms.com","https://www.4kvm.top","https://www.4kvm.net","https://www.4kvm.cc","https://www.4kvm.me","https://www.4kvm.pro"],"network":"direct","icon":"https://www.4kvms.org/ico.png"}
// LumeRuntime: javascript
//
// 站点：4k影视（发布页 4kvm.site；9 个域名实测同内容：4kvms.org / 4kvm.org / 4kvm.tv /
//       4kvms.com / 4kvm.top / 4kvm.net / 4kvm.cc / 4kvm.me / 4kvm.pro；4kvm.com 已不通）
// 形态：Alpine.js 服务端渲染 HTML（首页 716 KB）。分类 /movie /tv /anime，全量片库 /filter?page=N
//       （30 条/页，实测到第 300 页为空），搜索 /search?q=<词>，详情/播放页 /play/<slug>。
//
// ── 播放：交给 App 的网页播放器（本源有意不猜地址）──
//   站点的播放地址不是明文：/play 页里每个分集给一个 dataid，前端调
//   /static/wasm/nbmovie_wasm.js 的 build_play_url(dataid, slug, 清晰度, userlink)
//   生成带签名的 /video/play?p=&v=&q=&s=&t=&k= 再请求，响应里才是 m3u8。
//   实测（Chrome + CDP 钩 fetch）：
//     · s = 32 位 hex，只随 (dataid, slug, t) 变；改 s 任意一位 → 403「你没有权限」；
//     · k 是 userlink 的双层编码：base64(xor(salt, base64(xor(salt, "时间戳:vodID=…"))))，
//       游客传 '0' 时原样输出 '0'；
//     · salt = `nbmovie2024secretkey`（从 wasm 数据段取出），但 s 的算法在 wasm 里，
//       不是 md5/sha1/sha256 的常见拼法（用 p/slug/t + salt 的排列与 HMAC 全试过，均不匹配）。
//   → 所以本源把「播放」交给网页播放器：App 打开源站的 /play/<slug>，由站点自己的 wasm
//     算签名、拉 m3u8（实测 m3u8 200 + #EXTM3U）。不编造、也不假装能直连。
//
// 限制：分类页（/movie /tv /anime）服务端只有一页（?page= 不换内容），全量分页在 /filter；
//       分集没有 URL 参数（站点用前端切换），所以章节给的是「网页播放」这一项，选集在播放器里点。

var HOST = 'https://www.4kvms.org';
var MIRRORS = [
  'https://www.4kvms.org', 'https://www.4kvm.org', 'https://www.4kvm.tv',
  'https://www.4kvms.com', 'https://www.4kvm.top', 'https://www.4kvm.net',
  'https://www.4kvm.cc', 'https://www.4kvm.me', 'https://www.4kvm.pro'
];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 30;

// 分类：前三个是站点的栏目（服务端单页），最后一个是全量片库（真分页）
var CATS = [
  { id: 'filter', title: '全部影片', path: '/filter' },
  { id: 'movie', title: '电影', path: '/movie' },
  { id: 'tv', title: '剧集', path: '/tv' },
  { id: 'anime', title: '动漫', path: '/anime' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }

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
function get(path) {
  return LumeSource.http.request({
    url: base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + '/'
    }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
    return reply.body == null ? '' : String(reply.body);
  });
}

// ------------------------------------------------------------------ HTML 解析
// 卡片形如：<div ... movie-card ... data-vod-id="x"><a href="/play/<slug>" data-vod="y">…<img data-src="封面" alt="标题">
// 按「下一个 /play 链接」切段解析（不依赖 </a> 的位置：搜索页的卡片块比列表页长得多）
function parseCards(html) {
  var source = String(html || '');
  var items = [];
  var seen = {};
  var chunks = source.split(/<a\s[^>]*href="\/play\/([A-Za-z0-9]+)"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var slug = chunks[i];
    if (!slug || seen[slug]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 2500);
    var img = /<img\s[^>]*>/i.exec(block);
    if (!img) continue;
    var tag = img[0];
    var title = /alt="([^"]*)"/i.exec(tag);
    var cover = /data-src="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
    var name = unescapeHtml(title ? title[1] : '').trim();
    if (!name || name === 'item.title' || name === '4k影视') continue; // 跳过 Alpine 模板占位
    var pic = cover ? unescapeHtml(cover[1]) : '';
    if (/placeholder/.test(pic)) pic = '';
    var badge = /<span[^>]*>([^<]{1,20})<\/span>/i.exec(block);
    seen[slug] = true;
    items.push({
      id: slug,
      title: name,
      cover: pic,
      subtitle: badge ? clean(badge[1]) : ''
    });
  }
  return items;
}

function parseDetail(html) {
  var source = String(html || '');
  var ogImage = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
  var desc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(source);
  var keywords = /<meta\s+name="keywords"\s+content="([^"]*)"/i.exec(source);
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  var heading = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(source);
  var title = clean(heading ? heading[1] : '');
  if (!title && titleTag) {
    // 形如「凡人修仙传 - 第1集 -4k影视」
    title = clean(titleTag[1]).replace(/\s*-\s*第\s*\d+\s*集\s*/g, ' ').replace(/\s*-\s*4k影视\s*$/, '').trim();
  }
  var keywordsText = keywords ? unescapeHtml(keywords[1]) : '';
  return {
    title: title,
    cover: ogImage ? unescapeHtml(ogImage[1]) : '',
    description: desc ? unescapeHtml(desc[1]).trim() : '',
    keywords: keywordsText,
    episodes: parseEpisodes(source)
  };
}

// 分集按钮：data-line="1" data-episode="N" dataid="123"
function parseEpisodes(html) {
  var source = String(html || '');
  var out = [];
  var seen = {};
  var re = /data-line="(\d+)"[^>]*data-episode="(\d+)"[^>]*dataid="(\d+)"/g;
  var match;
  while ((match = re.exec(source)) !== null) {
    var number = Number(match[2]);
    if (!number || seen[number]) continue;
    seen[number] = true;
    out.push({ number: number, dataid: match[3], line: Number(match[1]) || 1 });
  }
  out.sort(function (a, b) { return a.number - b.number; });
  return out;
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'fourk_video',
  name: '4k影视',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/ico.png',
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://4kvm.site/',
      description: '站点换域名时先看这里（发布页列出全部可用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '4k影视（4kvms.org，另有 8 个同内容域名）。列表/详情都是普通网页；播放地址由站点的 wasm 在浏览器里现算签名，本源不复制签名逻辑，播放走 App 的网页播放器（选集也在播放器里点）。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点的「筛选」是 Alpine 前端交互，参数不进 URL（/filter?page=N 以外没有可拼的查询串），
    // 所以这里如实返回空组：不硬编一套看起来能用、实际不生效的标签。
    return { groups: [] };
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
    if (!category) category = 'filter';

    var path;
    if (keyword) {
      path = '/search?q=' + enc(keyword);
    } else {
      var cat = null;
      for (var i = 0; i < CATS.length; i++) {
        if (CATS[i].id === category) { cat = CATS[i]; break; }
      }
      if (!cat) cat = CATS[0];
      // 只有「全部影片」是真分页；/movie /tv /anime 服务端固定一页
      if (cat.id === 'filter') path = cat.path + '?page=' + page;
      else path = page === 1 ? cat.path : '';
    }
    if (!path) return { items: [], hasMore: false };

    var items = parseCards(await get(path));
    // 站点的搜索页要先有会话 Cookie（首个请求直接搜会返回 0 条）：空结果时先摸一次首页再重搜。
    if (keyword && !items.length) {
      try { await get('/'); } catch (e) { /* 首页打不开就按空结果返回 */ }
      items = parseCards(await get(path));
    }
    var paginated = !keyword && category === 'filter';
    return { items: items, hasMore: paginated && items.length >= PAGE_SIZE - 5 };
  },

  async detail(argument) {
    var slug = String((argument && argument.id) || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(slug)) return null;
    var html = await get('/play/' + slug);
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var bits = [];
    if (info.episodes.length > 1) bits.push('共 ' + info.episodes.length + ' 集');
    else if (info.episodes.length === 1) bits.push('正片');
    bits.push('网页播放');
    var tags = info.keywords.split(/[,，]/).map(function (t) { return t.trim(); }).filter(function (t) {
      return t && t.length <= 12;
    }).slice(0, 6);
    return {
      id: slug,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: (info.description || '') +
        (info.description ? '\n\n' : '') +
        '播放说明：本源用 App 的网页播放器打开源站播放页（站点用 wasm 现算播放签名），' +
        '分集请在播放器下方点选集。',
      tags: tags
    };
  },

  async chapters(argument) {
    var slug = String((argument && argument.id) || '').trim();
    if (!slug) return [];
    var html = await get('/play/' + slug);
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var episodes = parseEpisodes(html);
    // 分集没有 URL 参数（站点在前端切集），所以只给一项：打开播放页后在播放器里选集
    var title = episodes.length > 1
      ? '网页播放（共 ' + episodes.length + ' 集，在播放器里选集）'
      : '网页播放';
    return [{ id: 'web:' + slug, title: title }];
  },

  async content(argument) {
    var args = argument || {};
    var slug = String(args.chapterId || '').replace(/^web:/, '');
    if (!slug) slug = String(args.id || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(slug)) throw new Error('条目参数无效，请重新打开详情页');
    return {
      kind: 'webplayer',
      url: base() + '/play/' + slug
    };
  }
};
