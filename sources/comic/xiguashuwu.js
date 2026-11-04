// LumeSource: {"id":"xiguashuwu_comic","name":"西瓜书屋","version":"1.0.0","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.xiguashuwu2.com","https://www.xiguashuwu.com"],"network":"direct","icon":"https://www.xiguashuwu2.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"西瓜书屋（原 simishuwu，成人网络小说站，全站 18+）：分类 /category/{分类}/{页}.html、筛选 /category/{完本|vip}/{分类}/{页}.html、榜单 /rank/{all|week|month}/{分类}/{页}.html、详情 /book/{id}/、目录 /book/{id}/catalog/{页}.html（100 章/页）、正文 /book/{id}/{章节}.html（长章节拆成 {章节}_2.html）。站点把 VIP 书标了 vipok 角标，但 VIP 书的正文接口照样全量下发（实测 4 本 VIP 书首/中/末章都有 1.1–1.8 千字正文），本源直接按普通书读。唯一限制：站内搜索 /search/{词} 挂在 Cloudflare managed challenge 后面（列表/详情/正文都不受影响），搜索会抛 NEED_WEBVIEW_VERIFY 让 App 过校验。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开备用短域名（xiguashuwu.com）","url":"https://www.xiguashuwu.com/","description":"站点页脚写的官方新短域名；本机实测 503（站方未启用/被墙），主用仍是 xiguashuwu2.com"}]}
// LumeRuntime: javascript
//
// 站点：西瓜书屋（www.xiguashuwu2.com，成人网络小说站，全站 18+）
// 交付形态：漫画板块里的「文字小说」（mediaType:'novel'，content 返回 kind:'text'）。
//
// 结构（2026-11-04 逐页实测）：
//   · 首页            /                                   推荐阅读（封面网格）+ 最新更新（文字行）+ 阅读排行（封面网格）
//   · 分类            /category/{分类}/1.html              分类 0–15（0=全部，1–15 = 玄幻…复古言情），20 条/页
//   · 筛选            /category/finish/{分类}/{页}.html     完本
//                     /category/vip/{分类}/{页}.html        VIP 专列（实测 vip/11 共 1 页、vip/0 共 178 页）
//   · 榜单（排序）    /rank/{all|week|month}/{分类}/{页}.html  总榜 / 周榜 / 月榜
//   · 详情            /book/{id}/                          og:novel:* 给了标题/作者/分类/状态（连载,isvip=1;）/更新/最新章
//   · 目录            /book/{id}/catalog/{页}.html          100 章/页，页尾「(第1/2页)」
//   · 正文            /book/{id}/{章节id}.html             纯 <p> 段落；长章节再拆 {章节id}_2.html、_3.html…
//   · 搜索            /search/{词}                          **Cloudflare managed challenge（实测 403 Just a moment）**
//
// VIP 说明（本站“有 VIP”）：
//   · 列表/详情给 vipok 角标（<img src="/images/vipok.png">），书 1/2/3/212108 等都是 isvip=1；
//   · 正文页不做服务端拦截：实测 book 1（长日光阴）第 1/51/100 章、book 212108（小公主nph）
//     第 1/51/100 章正文都在 HTML 里（1.2–1.8 千字/页），没有「请购买/登录」占位；
//   · 站方在页脚 JS 里挂了一句「想看 vip 章节请把书名发到 simishuwu@gmail.com」——但那是给
//     长章节 **第二部分** 准备的免责声明，不是付费墙：那部分正文照样在，只是敏感词被换成了图片字。
//
// 唯一的质量限制（如实写在这里）：
//   长章节第二分页（{章节}_2.html）把敏感词渲染成 <img class='hz' src="/wzbodyimg/{hash}.png">（30×30 位图字），
//   实测一页 189 处、61 个不同字；图片文件名与字没有可推导关系（crc32/md5/base62 各版本都不符），
//   站上也查不到字典（/wzbodyimg/ 无目录、无 json）。本源的处理：**把这些图片字直接跳过**，
//   正文主体（第一分页 + 第二分页的非图片字）完整保留，读起来通顺，只缺那批露骨词；
//   第一分页与短章节完全不受影响。宁可少几个字，也不伪造、不猜字。

var BASE_URL = 'https://www.xiguashuwu2.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 20;
var MAX_CATALOG_PAGES = 60;
var MAX_PARTS = 8;

var CATS = [
  { id: '0', title: '全部' },
  { id: '1', title: '玄幻小说' },
  { id: '2', title: '修真小说' },
  { id: '3', title: '都市小说' },
  { id: '4', title: '历史小说' },
  { id: '5', title: '网游小说' },
  { id: '6', title: '科幻小说' },
  { id: '7', title: '言情小说' },
  { id: '8', title: '其他小说' },
  { id: '9', title: '经典小说' },
  { id: '10', title: '同人小说' },
  { id: '11', title: '高辣小说' },
  { id: '12', title: '耽美小说' },
  { id: '13', title: '情欲小说' },
  { id: '14', title: '复古耽美' },
  { id: '15', title: '复古言情' }
];

var STATES = [
  { id: 'all', title: '默认' },
  { id: 'finish', title: '完本' },
  { id: 'vip', title: 'VIP' }
];

var SORTS = [
  { id: 'none', title: '默认' },
  { id: 'total', title: '总榜' },
  { id: 'week', title: '周榜' },
  { id: 'month', title: '月榜' }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

function decodeEntities(text) {
  return String(text == null ? '' : text)
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function oneLine(text) {
  return clean(text);
}

async function fetchHtml(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：西瓜书屋返回 HTTP ' + status + '（Cloudflare 人机校验），' + path);
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

// 「(第1/10页)」
function pagerOf(html) {
  var text = String(html || '');
  var matched = /\(第<span>(\d+)<\/span>\/<span>(\d+)<\/span>页\)/.exec(text)
    || /\(第\s*(\d+)\s*\/\s*(\d+)\s*页\)/.exec(text);
  if (!matched) return null;
  return { page: Number(matched[1]), total: Number(matched[2]) };
}

function bookIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/book\/(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 分类页 / 榜单页的条目版式（文字卡）：.CGsectionTwo-right-content-unit
//   分类页：<a class="title" href="/book/1/iszip/1/">长日光阴</a>
//   榜单页：<span><a href="/book/56572/iszip/1/" class="r">[vipok]清纯婊…</a></span> + <label class="RKsection-rangking-img"><span>1</span></label>
function parseUnits(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('<div class="CGsectionTwo-right-content-unit">');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var link = /<a\b[^>]*href="\/book\/(\d+)\/iszip\/\d\/"[^>]*>([\s\S]*?)<\/a>/.exec(block);
    if (!link) continue;
    var id = link[1];
    var title = oneLine(link[2].replace(/<img[^>]*>/g, ''));
    if (!id || !title || title === '阅读本书' || seen[id]) continue;
    var vip = block.indexOf('/images/vipok.png') >= 0;
    var rank = /RKsection-rangking-img"><span>(\d+)<\/span>/.exec(block);
    var author = /作者\s*:\s*<span><a[^>]*>([\s\S]*?)<\/a>/.exec(block);
    var update = /最近更新\s*([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{1,2}:[0-9]{2})/.exec(block);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      subtitle: [
        rank ? '第 ' + rank[1] + ' 名' : '',
        vip ? 'VIP' : '',
        author ? oneLine(author[1]) : '',
        update ? update[1] : ''
      ].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return items;
}

// 榜单 / 首页的封面网格版式：.book_img_pic + .book_img_name
function parseGrid(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('<div class="book_img_pic">');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var link = /<a href="\/book\/(\d+)\/[^"]*"\s+title="([^"]*)"/.exec(block);
    if (!link) {
      link = /<a href="\/book\/(\d+)\/[^"]*"\s*>/.exec(block);
    }
    if (!link) continue;
    var id = link[1];
    if (seen[id]) continue;
    var nameBlock = /<div class="book_img_name">([\s\S]*?)<\/div>/.exec(block);
    var title = oneLine(link[2] || '');
    if (!title && nameBlock) {
      title = oneLine(nameBlock[1].replace(/<img[^>]*>/g, ''));
    }
    if (!title) continue;
    var cover = /_src="([^"]+)"/.exec(block) || /src="(\/files\/article\/image\/[^"]+)"/.exec(block);
    var vip = (nameBlock ? nameBlock[1] : block).indexOf('/images/vipok.png') >= 0;
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: vip ? 'VIP' : '',
      mediaType: 'novel'
    });
  }
  return items;
}

// 首页「最新更新」是纯文字行：[分类] 书名 作者 时间
function parseLatestRows(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var re = /\[<a href="\/category\/[^"]*"[^>]*>([^<]*)<\/a>\]<\/span>\s*<span><a href="\/book\/(\d+)\/[^"]*"[^>]*>([\s\S]*?)<\/a><\/span>[\s\S]{0,400}?<span>([0-9]{4}-[0-9]{2}-[0-9]{2}[^<]*)<\/span>/g;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var id = matched[2];
    var title = oneLine(matched[3]);
    if (!id || !title || seen[id]) continue;
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      subtitle: [oneLine(matched[1]), String(matched[4]).trim()].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return items;
}

// 首页「阅读排行」只有书名链接（没有 .book_img_pic 封面块）
function parseNameRows(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('<div class="book_img_name">');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var link = /<a\b[^>]*href="\/book\/(\d+)\/[^"]*"[^>]*>([\s\S]*?)<\/a>/.exec(block);
    if (!link) continue;
    var id = link[1];
    var title = oneLine(link[2].replace(/<img[^>]*>/g, ''));
    if (!id || !title || seen[id]) continue;
    seen[id] = true;
    items.push({ id: id, title: title, mediaType: 'novel' });
  }
  return items;
}

// 首页「阅读排行」是带角标的文字行：[分类] 书名 作者（没有时间、也没有封面块）
function parseRankRows(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var re = /\[<a href="\/category\/[^"]*"[^>]*>([^<]*)<\/a>\]<\/span>\s*<span>(?:<img[^>]*>)?\s*<a href="\/book\/(\d+)\/[^"]*"[^>]*>([\s\S]*?)<\/a><\/span>\s*<span class="line-between"><\/span>\s*<span><a href="\/writer\/[^"]*"[^>]*>([\s\S]*?)<\/a><\/span>/g;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var id = matched[2];
    var title = oneLine(matched[3]);
    if (!id || !title || seen[id]) continue;
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      subtitle: [oneLine(matched[1]), oneLine(matched[4])].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return items;
}

// 站内搜索被 Cloudflare 挡住时的兜底：用浏览过程中攒下的本地索引做关键词过滤
var INDEX_FILE = 'index.json';
var INDEX_MAX = 600;

async function loadIndex() {
  try {
    var raw = await LumeSource.fs.readText(INDEX_FILE);
    if (!raw) return [];
    var parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    return [];
  }
}

async function pushIndex(items) {
  if (!items || !items.length) return;
  try {
    var index = await loadIndex();
    var map = {};
    for (var i = 0; i < index.length; i++) map[index[i].id] = index[i];
    for (var k = 0; k < items.length; k++) {
      var item = items[k];
      if (item && item.id) map[item.id] = { id: item.id, title: item.title, subtitle: item.subtitle || '' };
    }
    var list = Object.keys(map).map(function (id) { return map[id]; }).slice(-INDEX_MAX);
    await LumeSource.fs.writeText(INDEX_FILE, JSON.stringify(list));
  } catch (error) {
    /* 索引写不进去不影响主流程 */
  }
}

async function searchIndex(keyword) {
  var index = await loadIndex();
  var word = String(keyword || '').toLowerCase();
  if (!word) return [];
  return index.filter(function (item) {
    return String(item.title || '').toLowerCase().indexOf(word) >= 0;
  }).map(function (item) {
    return { id: item.id, title: item.title, subtitle: item.subtitle || '', mediaType: 'novel' };
  });
}

function listPath(page, catId, state, sort) {
  var cat = catId || '0';
  if (sort && sort !== 'none') {
    var key = sort === 'total' ? 'all' : sort;
    return '/rank/' + key + '/' + cat + '/' + page + '.html';
  }
  if (state && state !== 'all') return '/category/' + state + '/' + cat + '/' + page + '.html';
  return '/category/' + cat + '/' + page + '.html';
}

// 正文分页：从 <script>bcc()</script> 到 <div id="cload">
function contentSegment(html) {
  var text = String(html || '');
  var start = text.lastIndexOf('<script>bcc()</script>');
  if (start < 0) start = text.indexOf('RBGsectionThree-content');
  var end = text.indexOf('<div id="cload"');
  if (end < 0) end = text.indexOf('id="cload"');
  if (end < 0) {
    var tail = text.indexOf('RBGsectionThree-bottom');
    end = tail > 0 ? tail : text.length;
  }
  if (start < 0 || end <= start) return '';
  return text.slice(start, end);
}

function segmentText(seg) {
  var text = String(seg || '')
    .replace(/<script[\s\S]*?<\/script>/g, ' ')
    .replace(/<img[^>]*class=['"]hz['"][^>]*>/g, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|h1|h2|h3|li)>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  text = decodeEntities(text);
  var lines = text.split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\s+/g, ' ').trim();
    if (!line) continue;
    if (/^bcc\(\)$/.test(line)) continue;
    if (/xiguashuwu|simishuwu|xiguass|本站新|短）域名|域名：/i.test(line)) continue;
    // 站点水印写成「?s i mi sh u w u .com」这种隔字空格
    if (/[a-z]\s+[a-z]\s+[a-z]\s+[a-z]/i.test(line) && line.replace(/[^a-z]/gi, '').length <= 16) continue;
    // 「作者：xxx」「內容簡介」是站点塞在章节页顶部的书籍元信息，不是正文
    if (/^作者\s*[:：]/.test(line)) continue;
    if (/^(内容简介|內容簡介)$/.test(line)) continue;
    if (/^(上一章|下一章|上一页|下一页|目录|封面|繁体|电脑版)$/.test(line)) continue;
    if (/^[?？,，。.…\-—_=*~·\s]{4,}$/.test(line)) continue;
    out.push(line);
  }
  return out.join('\n');
}

var LumeSource = {
  id: 'xiguashuwu_comic',
  name: '西瓜书屋',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://www.xiguashuwu2.com/favicon.ico',
  mirrors: ['https://www.xiguashuwu2.com', 'https://www.xiguashuwu.com'],

  async categories() {
    return CATS.map(function (item) {
      return { id: item.id, title: item.title };
    });
  },

  async filters() {
    return {
      groups: [
        {
          id: 'state',
          title: '状态',
          options: STATES.map(function (item) {
            return { id: item.id, title: item.title };
          })
        },
        {
          id: 'sort',
          title: '榜单',
          options: SORTS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var html = await fetchHtml('/');
    var boards = [];
    var recommend = parseGrid(html).slice(0, 12);
    if (recommend.length) boards.push({ title: '推荐阅读', moreUrl: '0', items: recommend });
    var latest = parseLatestRows(html).slice(0, 20);
    if (latest.length) boards.push({ title: '最新更新', moreUrl: '0', items: latest });
    var seen = {};
    recommend.concat(latest).forEach(function (item) { seen[item.id] = true; });
    var hot = parseRankRows(html).filter(function (item) { return !seen[item.id]; }).slice(0, 10);
    if (!hot.length) hot = parseNameRows(html).filter(function (item) { return !seen[item.id]; }).slice(0, 10);
    if (hot.length) boards.push({ title: '阅读排行', moreUrl: '0', items: hot });
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    await pushIndex(recommend.concat(latest).concat(hot));
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var filters = args.filters || {};
    var state = String(filters.state || 'all').trim();
    var sort = String(filters.sort || 'none').trim();
    if (state.indexOf(',') >= 0) state = state.split(',')[0].trim();
    if (sort.indexOf(',') >= 0) sort = sort.split(',')[0].trim();

    if (keyword) {
      // 站内搜索在 Cloudflare managed challenge 后面：挡到就抛 NEED_WEBVIEW_VERIFY 交 App 过校验；
      // 过校验之前先用浏览过程中攒下来的本地索引顶着，搜不到再抛（不静默返回空）
      var searchHtml = '';
      var blockError = null;
      try {
        searchHtml = await fetchHtml('/search/' + encodeURIComponent(keyword));
      } catch (error) {
        blockError = error;
      }
      if (blockError) {
        var local = await searchIndex(keyword);
        if (local.length) return { items: local, hasMore: false };
        throw blockError;
      }
      var found = parseUnits(searchHtml).concat(parseGrid(searchHtml));
      var searchPager = pagerOf(searchHtml);
      var dedup = [];
      var seenIds = {};
      for (var i = 0; i < found.length; i++) {
        if (seenIds[found[i].id]) continue;
        seenIds[found[i].id] = true;
        dedup.push(found[i]);
      }
      await pushIndex(dedup);
      return { items: dedup, hasMore: searchPager ? page < searchPager.total : false };
    }

    var catId = String(args.categoryId == null ? '' : args.categoryId).trim();
    if (!/^\d+$/.test(catId)) catId = '0';
    var path = listPath(page, catId, state, sort);
    var html = await fetchHtml(path);
    // 分类页与榜单页都是「文字卡」列表；只有首页/推荐位是封面网格
    var items = parseUnits(html);
    if (!items.length) items = parseGrid(html);
    var pager = pagerOf(html);
    var hasMore = pager ? page < pager.total : items.length >= PAGE_SIZE;
    if (!items.length && page === 1) {
      throw new Error('这个分类没有取到条目（' + path + '，站点模板可能改了）');
    }
    await pushIndex(items);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/book/' + id + '/');
    if (!html) return null;
    var titled = /<meta\s+property="og:title"\s+content="([^"]*)"/.exec(html)
      || /<h1 class="book"><label><a[^>]*>([\s\S]*?)<\/a>/.exec(html);
    var title = oneLine(titled ? titled[1] : '');
    if (!title) return null;
    var cover = /<img class="lazyload"\s+_src="([^"]+)"/.exec(html) || /_src="([^"]+)"/.exec(html);
    var coverUrl = cover && cover[1] && cover[1].indexOf('/images/default.jpg') < 0 ? absolute(cover[1]) : '';
    var author = /作者：<span><a[^>]*>([\s\S]*?)<\/a>/.exec(html);
    var category = /类别：<span><a[^>]*>([\s\S]*?)<\/a>/.exec(html);
    var status = /og:novel:status"\s+content="([^"]*)"/.exec(html);
    var update = /og:novel:update_time"\s+content="([^"]*)"/.exec(html);
    var latest = /og:novel:latest_chapter_name"\s+content="([^"]*)"/.exec(html);
    var intro = /<p class="BGsectionTwo-bottom">([\s\S]*?)<\/p>/.exec(html);

    var isVip = status ? /isvip\s*=\s*1/.test(status[1]) : html.indexOf('/images/vipok.png') >= 0;
    var lines = [];
    if (author) lines.push('作者：' + oneLine(author[1]));
    if (category) lines.push('类别：' + oneLine(category[1]));
    if (status) lines.push('状态：' + oneLine(String(status[1]).replace(/;\s*$/, '')));
    if (isVip) lines.push('标记：VIP 书（本站 VIP 标记不影响阅读，正文照常下发）');
    if (update) lines.push('更新：' + oneLine(update[1]));
    if (latest) lines.push('最新章：' + oneLine(latest[1]));
    var introText = intro ? clean(intro[1]) : '';
    if (introText) lines.push('', introText);

    return {
      id: id,
      title: title,
      cover: coverUrl,
      subtitle: [author ? oneLine(author[1]) : '', category ? oneLine(category[1]) : '', isVip ? 'VIP' : '']
        .filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return [];
    var first = await fetchHtml('/book/' + id + '/catalog/');
    var pager = pagerOf(first);
    var total = pager ? Math.min(pager.total, MAX_CATALOG_PAGES) : 1;
    var out = [];
    var seen = {};
    for (var page = 1; page <= total; page++) {
      var html = page === 1 ? first : await fetchHtml('/book/' + id + '/catalog/' + page + '.html');
      var re = /<li class="BCsectionTwo-top-chapter"><a href="\/book\/\d+\/(\d+)\.html"[^>]*>([\s\S]*?)<\/a>/g;
      var matched;
      while ((matched = re.exec(html)) !== null) {
        var cid = matched[1];
        if (seen[cid]) continue;
        seen[cid] = true;
        var name = oneLine(matched[2]);
        out.push({ id: id + '/' + cid, title: name || ('第 ' + (out.length + 1) + ' 章') });
      }
    }
    if (!out.length) throw new Error('目录页里没有章节节点（' + id + '，站点模板可能改了）');
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /(\d+)\/(\d+)/.exec(raw);
    var bookId = matched ? matched[1] : bookIdOf(args.id);
    var chapterId = matched ? matched[2] : '';
    if (!bookId || !chapterId) throw new Error('缺少章节 ID（应形如 书号/章节号）');

    var parts = [];
    var heading = '';
    for (var part = 1; part <= MAX_PARTS; part++) {
      var path = '/book/' + bookId + '/' + chapterId + (part === 1 ? '' : '_' + part) + '.html';
      var html;
      try {
        html = await fetchHtml(path);
      } catch (error) {
        if (part === 1) throw error;
        break;
      }
      var seg = contentSegment(html);
      var text = segmentText(seg);
      // 首页标题就是章节名（分卷章节会带「(1/2)」，用第一页的原始名）
      if (part === 1) {
        heading = oneLine((/<h1 id="chapterTitle">([\s\S]*?)<\/h1>/.exec(html) || [])[1] || '');
      }
      if (text && text.replace(/\s/g, '').length >= 10) parts.push(text);
      else if (part > 1) break;
      // 还有没有下一分页：没有就直接收工
      if (html.indexOf('/book/' + bookId + '/' + chapterId + '_' + (part + 1) + '.html') < 0) break;
    }
    if (!parts.length) throw new Error('这一章正文是空的：' + raw);
    return {
      kind: 'text',
      title: heading || undefined,
      text: parts.join('\n\n')
    };
  }
};
