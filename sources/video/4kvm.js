// LumeSource: {"id":"fourk_video","name":"4k影视","version":"1.1.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.4kvms.org","https://www.4kvm.org","https://www.4kvm.tv","https://www.4kvms.com","https://www.4kvm.top","https://www.4kvm.net","https://www.4kvm.cc","https://www.4kvm.me","https://www.4kvm.pro"],"network":"direct","icon":"https://www.4kvms.org/ico.png"}
// LumeRuntime: javascript
//
// 站点：4k影视（发布页 4kvm.site；9 个域名实测同内容、2026-11-03 复测全部 200：
//       4kvms.org / 4kvm.org / 4kvm.tv / 4kvms.com / 4kvm.top / 4kvm.net /
//       4kvm.cc / 4kvm.me / 4kvm.pro；4kvm.com 已不通）
// 形态：Alpine.js 服务端渲染 HTML（首页 ~700 KB）。
//   分类：/filter?classify=1 电影 / 2 电视剧 / 3 动漫 / 4 综艺（综艺当前为空表）；
//         /filter 不带 classify = 全量片库，**真分页**（30 条/页，实测第 184 页还有内容）。
//   筛选：/filter 同一套查询串支持 types=（30 个类型）/ areas=（44 个地区）/ years=（79 个年份），
//         实测可组合（classify+types+areas+years+page 一起拼）。
//   搜索：/search?q=<词>；详情/播放页：/play/<slug>。
//   （旧版本把 /movie /tv /anime 当分类，那三页服务端只有固定一页、页码不生效；
//     现在统一走 /filter，翻页与筛选才真的能用。）
//
// ── 播放：交给 App 的网页播放器（本源有意不猜地址）──
//   /play 页里每个分集给一个 dataid，前端调 /static/wasm/nbmovie_wasm.js 的
//   build_play_url(dataid, slug, 清晰度, userlink) 生成带签名的
//   /video/play?p=&v=&q=&s=&t=&k=，响应里才是 m3u8。
//   实测（Chrome + CDP 钩 fetch）：
//     · s = 32 位 hex，只随 (dataid, slug, t) 变；改 s 任意一位 → 403「你没有权限」；
//     · k 是 userlink 的双层编码：base64(xor(salt, base64(xor(salt, "时间戳:vodID=…"))))，
//       游客传 '0' 时原样输出 '0'；
//     · salt = `nbmovie2024secretkey`（从 wasm 数据段取出），但 s 的算法在 wasm 里，
//       不是 md5/sha1/sha256 的常见拼法（用 p/slug/t + salt 的排列与 HMAC 全试过，均不匹配）。
//   → 所以本源把「播放」交给网页播放器：App 打开源站的 /play/<slug>，由站点自己的 wasm
//     算签名、拉 m3u8（实测 m3u8 200 + #EXTM3U）。不编造、也不假装能直连。
//
// 限制：分集没有 URL 参数（站点用前端切换），所以章节只给「网页播放」一项，选集在播放器里点。
//       与另一家同名站 4kyingshi.net 无关（那家域名已到期被停放，源已停用）。

var HOST = 'https://www.4kvms.org';
var MIRRORS = [
  'https://www.4kvms.org', 'https://www.4kvm.org', 'https://www.4kvm.tv',
  'https://www.4kvms.com', 'https://www.4kvm.top', 'https://www.4kvm.net',
  'https://www.4kvm.cc', 'https://www.4kvm.me', 'https://www.4kvm.pro'
];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 30;

// 分类：分类名与站点 /filter?classify=N 一一对应（classify=0 = 全量）
var CATS = [
  { id: 'filter', title: '全部影片', classify: 0 },
  { id: 'movie', title: '电影', classify: 1 },
  { id: 'tv', title: '电视剧', classify: 2 },
  { id: 'anime', title: '动漫', classify: 3 }
];

// 筛选选项：id 是站点查询串里的数字，标题是站点页面上的原文（2026-11-03 从 /filter 抓取）
var TYPES = [
  ['1', '剧情'], ['2', '悬疑'], ['3', '恐怖'], ['4', '惊悚'], ['5', '喜剧'],
  ['6', '爱情'], ['9', '犯罪'], ['10', '动作'], ['11', '动画'], ['12', '奇幻'],
  ['13', '音乐'], ['14', '科幻'], ['15', '历史'], ['16', '战争'], ['18', '冒险'],
  ['19', '家庭'], ['20', '纪录'], ['27', '古装'], ['29', '同性'], ['31', '武侠'],
  ['35', '短片']
];
var AREAS = [
  ['7', '中国'], ['52', '中国大陆'], ['14', '中国香港'], ['21', '中国台湾'],
  ['5', '美国'], ['11', '日本'], ['12', '韩国'], ['30', '英国'], ['33', '泰国'],
  ['34', '印度'], ['6', '法国'], ['18', '德国'], ['24', '西班牙'], ['78', '其他']
];
var YEARS = [
  ['78', '2027'], ['1', '2026'], ['3', '2025'], ['4', '2024'], ['56', '2023'],
  ['13', '2022'], ['2', '2021'], ['6', '2020'], ['8', '2019'], ['9', '2018']
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
  return LumeSource.http.get(base() + path, {
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
// 卡片形如：<a href="/play/<slug>" ...><img data-src="封面" alt="标题">…</a>
// 按「下一个 /play 链接」切段解析（不依赖 </a> 位置：搜索页的卡片块比列表页长得多）
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

// 单选筛选：App 组内多选时会回传逗号串，站点只认一个值，取第一个并写在这里
function pick(value) {
  var text = String(value == null ? '' : value).split(',')[0].trim();
  return text;
}

function categoryOf(id) {
  var key = String(id == null || id === '' ? 'filter' : id);
  for (var i = 0; i < CATS.length; i++) if (CATS[i].id === key) return CATS[i];
  return CATS[0];
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'fourk_video',
  name: '4k影视',
  version: '1.1.0',
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
      description: '4k影视（4kvms.org，另有 8 个同内容域名）。列表/筛选/详情都是普通网页（分类与筛选走 /filter 的真分页）；播放地址由站点的 wasm 在浏览器里现算签名，本源不复制签名逻辑，播放走 App 的网页播放器（选集也在播放器里点）。注意：这家与已停站的 4kyingshi.net 不是同一个站。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    function group(key, title, list) {
      return {
        key: key, title: title, multiple: false,
        options: list.map(function (pair) { return { id: pair[0], title: pair[1] }; })
      };
    }
    return {
      groups: [
        group('types', '类型', TYPES),
        group('areas', '地区', AREAS),
        group('years', '年份', YEARS)
      ]
    };
  },

  async home() {
    var items = parseCards(await get('/'));
    if (!items.length) return [];
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = categoryOf(args.categoryId);
    var filters = args.filters || {};

    if (keyword) {
      var path = '/search?q=' + enc(keyword);
      var hits = parseCards(await get(path));
      // 站点的搜索页要先有会话 Cookie（首个请求直接搜会返回 0 条）：空结果时先摸一次首页再重搜。
      if (!hits.length) {
        try { await get('/'); } catch (error) { /* 首页打不开就按空结果返回 */ }
        hits = parseCards(await get(path));
      }
      return { items: hits, hasMore: false };
    }

    var query = [];
    if (category.classify) query.push('classify=' + category.classify);
    var types = pick(filters.types);
    var areas = pick(filters.areas);
    var years = pick(filters.years);
    if (types) query.push('types=' + enc(types));
    if (areas) query.push('areas=' + enc(areas));
    if (years) query.push('years=' + enc(years));
    query.push('page=' + page);

    var items = parseCards(await get('/filter?' + query.join('&')));
    return { items: items, hasMore: items.length >= PAGE_SIZE - 5 };
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
