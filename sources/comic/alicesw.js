// LumeSource: {"id":"alicesw_comic","name":"爱丽丝书屋","version":"1.0.0","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.alicesw.com","https://www.alicesw1.homes","https://www.alicesw.tw"],"network":"proxy","icon":"https://www.alicesw.com/favicon.ico","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（alicesw.click）","url":"https://alicesw.click/","description":"官方发布页：海外永久地址 alicesw.com，大陆地址 alicesw.quest，大陆备用 alicesw1.homes，繁体站 alicesw.tw"},{"key":"note","type":"info","title":"站点说明","description":"爱丽丝书屋（成人小说站，全站 18+，diyquge 模板）：题材分类 /lists/{id}.html、总列表 /all/order/{排序}+desc.html、排行 /other/rank_hits/order/hits*.html、详情 /novel/{id}.html、目录 /other/chapters/id/{id}.html、正文 /book/{书号}/{章节}.html。正文是纯文本 <p> 段落。主站与镜像都在境外（解析到 38.46.217.x），源站会按 IP 拒美国 Utah，其他地区正常；本源走代理更稳。"}]}
// LumeRuntime: javascript
//
// 站点：爱丽丝书屋（https://www.alicesw.com，成人网络小说站，全站 18+）
// 发布页：https://alicesw.click/（另有 www.asw5.cc），发布页给的四条地址：
//   海外永久 alicesw.com / 大陆 alicesw.quest（只是发布页）/ 大陆备用 alicesw1.homes / 繁体 alicesw.tw
//   实测：alicesw.quest、asw5.cc、alicesw.click、xn--vcsx64d.als1007.space 都是**发布页**（不提供正文），
//   正文只有 alicesw.com / alicesw1.homes（简体同源）与 alicesw.tw（繁体，结构完全一致）。
//
// 结构（2026-11-03 逐页实测；全部走本机代理出口）：
//   · 首页            /                                   每个 <h2 class="layout-tit"> 一个区块
//       区块内：<div class="item"> 带封面的大卡（.image_cover img + a.ellipsis 标题 + span.author 作者）
//                <ul class="listx"> / <div class="listx"> 若干 <li class="topred"> 纯文字条目
//   · 题材分类        /lists/{分类id}.html?page=N          第 1 页不带 page
//   · 总列表          /all/order/{排序}+desc.html?page=N    排序：update_time / hits / word
//   · 题材+排序       /all/id/{分类id}/order/{排序}+desc.html?page=N
//   · 原创专区        /original.html?page=N
//   · 排行榜          /other/rank_hits/order/hits_day|hits_week|hits_month|hits.html   固定 30 条，**不分页**
//   · 列表条目        <li><span class="s2"><a href="/novel/{id}.html">
//                       <span class="fenleibt">[玄幻] </span> 标题</a></span>
//                       <span class="s5">作者</span>
//                       （排行页多三个 span：.diyhot 热度 / .five 字数 / .six 更新时间）
//   · 搜索            /search.html?q={词}&f=_all&sort=relevance&p={页}   每页 10 条，f 可为 _all/author/tag
//   · 详情            /novel/{id}.html                        h1 标题、.imgbox img 封面、作者/分类/热度/字数/状态、.desc 简介
//   · 目录            /other/chapters/id/{id}.html             .section-list 里 <li><a href="/book/{书号}/{章节}.html">章节名</a></li>
//                                                              **一次给全**（实测 6972 章、666 KB 单页，没有分页参数）
//   · 正文            /book/{书号}/{章节hash}.html             <section class="read-section"> 内 <div class="content_txt"> 的 <p> 段落
//                                                              一章一页，没有正文分页
//
// 注意：/novel/{id} 的 id 与 /book/{书号} 的**书号不是同一个数字**，章节地址只能从目录页取，不能拼。
// 本章源按「文字小说」交付：列表/详情声明 mediaType:'novel'，content 返回 kind:'text'，
// App 会走小说详情与文字阅读器（源归属仍是 comic 板块，见 docs/2026-11-02_小说阅读与综合源类型识别.md）。
//
// 限制：
//   · 站点列表页不给封面（只有首页大卡有），所以列表项没有 cover，封面在详情页才出来；
//   · 排行榜单页 30 条、没有分页，hasMore 恒为 false；
//   · 搜索只走简体词（站点把关键词做简体归一），繁体词命中会偏少；
//   · 章节标题有作者写成纯数字的（"1"、"2"…），本源对纯数字标题补成「第 N 章」。

var SEED = 'https://www.alicesw.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 31; // 站点列表页实测 30–31 条/页

// ---------------------------------------------------------------- 基础设施
function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || SEED).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

function abs(path) {
  var text = String(path == null ? '' : path).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

var ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  ldquo: '“', rdquo: '”', lsquo: '‘', rsquo: '’',
  middot: '·', hellip: '…', mdash: '—', ndash: '–', times: '×',
  laquo: '«', raquo: '»', copy: '©', reg: '®',
};

function entity(text) {
  return String(text == null ? '' : text)
    .replace(/&#x([0-9a-f]+);/gi, function (all, hex) {
      return String.fromCharCode(parseInt(hex, 16));
    })
    .replace(/&#(\d+);/g, function (all, code) {
      return String.fromCharCode(Number(code));
    })
    .replace(/&([a-z]+);/gi, function (all, name) {
      var key = String(name).toLowerCase();
      return ENTITIES[key] == null ? all : ENTITIES[key];
    });
}

// 文本清洗：高亮 <em> 直接去掉（别在词中间插空格），其余标签换空格
function clean(text) {
  return entity(
    String(text == null ? '' : text)
      .replace(/<\/?em>/gi, '')
      .replace(/<\/(?:p|div|section|li|h\d)>|<br\s*\/?>/gi, '\n')
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
  )
    .replace(/[ \t\u00a0]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}

// 单行标题用：把换行也压成空格
function oneLine(text) {
  return clean(text).replace(/\s+/g, ' ').trim();
}

function headers(extra) {
  var out = {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
    Referer: base() + '/',
  };
  for (var key in extra || {}) out[key] = extra[key];
  return out;
}

async function getPage(path, extraHeaders) {
  var url = abs(path);
  var reply;
  try {
    reply = await LumeSource.http.get(url, { headers: headers(extraHeaders) });
  } catch (error) {
    throw new Error('站点打不开（' + url + '）：' + (error && error.message ? error.message : error));
  }
  var status = reply ? Number(reply.status) || 0 : 0;
  var html = String((reply && reply.body) || '');
  if (status === 403 || status === 429 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：爱丽丝书屋返回 HTTP ' + status + '（可能触发了源站风控），请在网页视图里过一遍校验');
  }
  if (status === 404) return { html: '', url: url, status: status };
  if (status !== 200) throw new Error('爱丽丝书屋返回 HTTP ' + status + '：' + url);
  if (html.indexOf('Access Denied') >= 0 && html.indexOf('not accessible in your region') >= 0) {
    throw new Error('源站按 IP 拒绝了这个出口（美国 Utah 被 ban），换一条代理节点再试');
  }
  if (html.length < 400) throw new Error('页面内容不完整（' + html.length + ' 字节）：' + url);
  return { html: html, url: url, status: status };
}

// ---------------------------------------------------------------- 分类表
// path 用于不走「题材+排序」的分类；cid 是站点题材 id（拼 /all/id/{cid}/order/…）
var MENU = [
  { id: 'latest', title: '最近更新', path: '/all/order/update_time+desc.html', sortable: true, paged: true },
  { id: 'rank_day', title: '本日排行', path: '/other/rank_hits/order/hits_day.html', sortable: false, paged: false },
  { id: 'rank_week', title: '本周排行', path: '/other/rank_hits/order/hits_week.html', sortable: false, paged: false },
  { id: 'rank_month', title: '本月排行', path: '/other/rank_hits/order/hits_month.html', sortable: false, paged: false },
  { id: 'rank_all', title: '总排行', path: '/other/rank_hits/order/hits.html', sortable: false, paged: false },
  { id: 'original', title: '原创专区', path: '/original.html', sortable: false, paged: true },
  { id: 't62', title: '玄幻', cid: 62 },
  { id: 't64', title: '都市', cid: 64 },
  { id: 't61', title: '校园', cid: 61 },
  { id: 't70', title: '穿越', cid: 70 },
  { id: 't73', title: '同人', cid: 73 },
  { id: 't71', title: '科幻', cid: 71 },
  { id: 't75', title: '奇幻', cid: 75 },
  { id: 't69', title: '系统', cid: 69 },
  { id: 't68', title: '武侠', cid: 68 },
  { id: 't79', title: '经典', cid: 79 },
  { id: 't63', title: '乡村', cid: 63 },
  { id: 't19', title: '纯爱', cid: 19 },
  { id: 't54', title: 'NTR', cid: 54 },
  { id: 't65', title: '乱伦', cid: 65 },
  { id: 't46', title: '凌辱', cid: 46 },
  { id: 't18', title: '堕落', cid: 18 },
  { id: 't58', title: '调教', cid: 58 },
  { id: 't56', title: '熟女', cid: 56 },
  { id: 't48', title: '萝莉', cid: 48 },
  { id: 't50', title: '正太', cid: 50 },
  { id: 't52', title: '伪娘', cid: 52 },
  { id: 't47', title: '百合', cid: 47 },
  { id: 't82', title: '耽美', cid: 82 },
  { id: 't53', title: '媚黑', cid: 53 },
  { id: 't72', title: '明星', cid: 72 },
  { id: 't22', title: '反差', cid: 22 },
  { id: 't59', title: '言情', cid: 59 },
  { id: 't21', title: '重口', cid: 21 },
  { id: 't57', title: '其他', cid: 57 },
];

var SORTS = [
  { id: 'update_time', title: '最近更新' },
  { id: 'hits', title: '人气最高' },
  { id: 'word', title: '字数最多' },
];

function menuOf(categoryId) {
  var key = String(categoryId == null ? '' : categoryId).trim();
  for (var i = 0; i < MENU.length; i++) if (MENU[i].id === key) return MENU[i];
  // 兼容传站点题材 id（"62"）或 home() 回传的路径
  var byCid = /^(\d+)$/.exec(key);
  if (byCid) {
    for (var k = 0; k < MENU.length; k++) if (String(MENU[k].cid) === byCid[1]) return MENU[k];
  }
  var fromHref = categoryFromHref(key);
  if (fromHref) {
    for (var j = 0; j < MENU.length; j++) if (MENU[j].id === fromHref) return MENU[j];
  }
  return MENU[0];
}

function sortOf(filters) {
  var f = filters || {};
  var raw = String(f.sort == null ? '' : f.sort);
  var first = raw.split(',')[0].trim();
  for (var i = 0; i < SORTS.length; i++) if (SORTS[i].id === first) return first;
  return 'update_time';
}

function categoryFromHref(href) {
  var text = String(href == null ? '' : href);
  if (!text) return '';
  if (text.indexOf('/original.html') >= 0) return 'original';
  var rank = /rank_hits\/order\/hits(_day|_week|_month)?\.html/.exec(text);
  if (rank) return 'rank_' + (rank[1] ? rank[1].slice(1) : 'all');
  if (text.indexOf('/all/order/') >= 0 || text.indexOf('/all/id/') >= 0) return 'latest';
  var list = /\/lists\/(\d+)\.html/.exec(text);
  if (list) return 't' + list[1];
  return '';
}

// ---------------------------------------------------------------- 列表解析
// 统一吃 <li> 里的 s2 标题 + 后续 span（作者/热度/字数/时间）
function parseListItems(html) {
  var out = [];
  var seen = {};
  var itemRe = /<li>\s*<span class="s2"><a href="\/novel\/(\d+)\.html">([\s\S]*?)<\/a><\/span>([\s\S]*?)<\/li>/g;
  var matched;
  while ((matched = itemRe.exec(html)) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    var rawTitle = matched[2];
    var tail = matched[3];
    var tag = /class="fenleibt">\s*\[([^\]]*)\]/.exec(rawTitle);
    var title = oneLine(rawTitle.replace(/<span class="fenleibt">[\s\S]*?<\/span>/g, ''));
    if (!title) continue;
    var author = oneLine((/class="s5">([\s\S]*?)<\/span>/.exec(tail) || [])[1] || '').replace(/^\/\s*/, '');
    var hits = oneLine((/class="diyhot">([\s\S]*?)<\/span>/.exec(tail) || [])[1] || '');
    var words = oneLine((/class="five">([\s\S]*?)<\/span>/.exec(tail) || [])[1] || '');
    var when = oneLine((/class="six">([\s\S]*?)<\/span>/.exec(tail) || [])[1] || '');
    var bits = [];
    if (tag) bits.push('[' + oneLine(tag[1]) + ']');
    if (author) bits.push(author);
    if (words) bits.push(words + '字');
    if (hits) bits.push(hits + '热度');
    if (when) bits.push(when);
    seen[id] = true;
    out.push({
      id: id,
      title: title,
      subtitle: bits.join(' · '),
      mediaType: 'novel',
    });
  }
  return out;
}

// 搜索结果：<div class="list-group-item"> … <p class="time">
function parseSearchItems(html) {
  var out = [];
  var seen = {};
  var re = /<div class="list-group-item">([\s\S]*?)<p class="time">/g;
  var matched;
  while ((matched = re.exec(html)) !== null) {
    var body = matched[1];
    var link = /<a href="\/novel\/(\d+)\.html">([\s\S]*?)<\/a>/.exec(body);
    if (!link) continue;
    var id = link[1];
    if (seen[id]) continue;
    var title = oneLine(link[2]).replace(/^\d+\.\s*/, '');
    if (!title) continue;
    var author = oneLine((/作者：<a[^>]*>([\s\S]*?)<\/a>/.exec(body) || [])[1] || '');
    var words = oneLine((/字数：([\s\S]*?)　/.exec(body) || [])[1] || '');
    var intro = oneLine((/class="content-txt">([\s\S]*?)<\/p>/.exec(body) || [])[1] || '');
    var bits = [];
    if (author) bits.push(author);
    if (words) bits.push(words + '字');
    if (intro && intro !== '暂无简介') bits.push(intro.slice(0, 40));
    seen[id] = true;
    out.push({ id: id, title: title, subtitle: bits.join(' · '), mediaType: 'novel' });
  }
  return out;
}

function pageInfo(html) {
  var matched = /第\s*(\d+)\s*页\s*\/\s*共\s*(\d+)\s*页/.exec(html);
  if (!matched) return null;
  return { page: Number(matched[1]) || 1, total: Number(matched[2]) || 1 };
}

// ---------------------------------------------------------------- 首页
function splitHomeSections(html) {
  var marks = [];
  var re = /<h2 class="layout-tit">/g;
  var matched;
  while ((matched = re.exec(html)) !== null) marks.push(matched.index);
  var sections = [];
  for (var i = 0; i < marks.length; i++) {
    var start = marks[i];
    var end = i + 1 < marks.length ? marks[i + 1] : Math.min(html.length, start + 60000);
    sections.push(html.slice(start, end));
  }
  return sections;
}

function parseHomeSection(segment) {
  var head = /<h2 class="layout-tit">\s*([\s\S]{0,160}?)<a href="([^"]*)"[^>]*>更多\s*\+?<\/a>/.exec(segment);
  if (!head) return null;
  var title = oneLine(head[1]);
  var more = categoryFromHref(head[2]);
  var rows = [];
  var seen = {};

  // 带封面的大卡
  var cardRe = /<div class="item">([\s\S]*?)<\/div>\s*<\/div>/g;
  var matched;
  while ((matched = cardRe.exec(segment)) !== null) {
    var body = matched[1];
    var href = /<div class="image_cover">\s*<a href="\/novel\/(\d+)\.html"/.exec(body);
    var cover = /<img[^>]+src="([^"]+)"/.exec(body);
    var name = /<a class="ellipsis" href="\/novel\/\d+\.html">([\s\S]*?)<\/a>/.exec(body);
    if (!href || !name) continue;
    var id = href[1];
    if (seen[id]) continue;
    var author = oneLine((/<span class="author">([\s\S]*?)<\/span>/.exec(body) || [])[1] || '');
    var intro = oneLine((/<a class="jianjie"[^>]*>([\s\S]*?)<\/a>/.exec(body) || [])[1] || '');
    seen[id] = true;
    rows.push({
      id: id,
      title: oneLine(name[1]),
      cover: cover ? abs(clean(cover[1])) : '',
      subtitle: [author, intro].filter(Boolean).join(' · ').slice(0, 80),
      mediaType: 'novel',
    });
  }

  // 纯文字条目
  var textRe = /<a class="book-list-f" href="\/novel\/(\d+)\.html">([\s\S]*?)<\/a>(?:\s*<span class="s5">([\s\S]*?)<\/span>)?/g;
  while ((matched = textRe.exec(segment)) !== null) {
    var tid = matched[1];
    if (seen[tid]) continue;
    var tTitle = oneLine(matched[2]);
    if (!tTitle) continue;
    var tAuthor = oneLine(matched[3] || '').replace(/^\/\s*/, '');
    seen[tid] = true;
    rows.push({ id: tid, title: tTitle, subtitle: tAuthor, mediaType: 'novel' });
  }

  if (!title || !rows.length) return null;
  return { title: title, moreUrl: more || '', items: rows };
}

// ---------------------------------------------------------------- 入口
var LumeSource = {
  id: 'alicesw_comic',
  name: '爱丽丝书屋',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',

  async categories() {
    return MENU.map(function (item) {
      return { id: item.id, title: item.title };
    });
  },

  async filters() {
    // 排序组对「最近更新 / 题材分类」有效；排行与原创专区走站点固定路径，排序不生效（站点没有对应参数）
    return {
      groups: [
        {
          id: 'sort',
          title: '排序',
          options: SORTS.map(function (item) {
            return { id: item.id, title: item.title };
          }),
        },
      ],
    };
  },

  async home() {
    var page = await getPage('/');
    var sections = splitHomeSections(page.html);
    var boards = [];
    for (var i = 0; i < sections.length && boards.length < 6; i++) {
      var board = parseHomeSection(sections[i]);
      if (!board) continue;
      board.items = board.items.slice(0, 12);
      boards.push(board);
    }
    if (!boards.length) throw new Error('首页没解析出任何板块（站点模板可能改了）');
    return boards;
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    var keyword = oneLine(a.keyword || '');

    if (keyword) {
      var searchPath = '/search.html?q=' + encodeURIComponent(keyword) + '&f=_all&sort=relevance&p=' + page;
      var searchPage = await getPage(searchPath);
      var found = parseSearchItems(searchPage.html);
      var info = pageInfo(searchPage.html);
      return { items: found, hasMore: info ? page < info.total : found.length >= 10 };
    }

    var menu = menuOf(a.categoryId);
    var sort = sortOf(a.filters);
    var path;
    if (menu.cid) path = '/all/id/' + menu.cid + '/order/' + sort + '+desc.html';
    else if (menu.sortable) path = menu.path.replace('update_time', sort);
    else path = menu.path;

    var requestPath = page > 1 ? path + (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page : path;
    var result = await getPage(requestPath);
    var items = parseListItems(result.html);
    var pager = pageInfo(result.html);
    var hasMore;
    if (pager) hasMore = page < pager.total;
    else hasMore = menu.paged ? items.length >= PAGE_SIZE : false;
    if (!items.length && page === 1) throw new Error('这个分类没有取到条目（' + menu.title + '）');
    return { items: items, hasMore: hasMore };
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var page = await getPage('/novel/' + id + '.html');
    if (!page.html) return null;
    var html = page.html;

    var title = oneLine((/<h1>([\s\S]*?)<\/h1>/.exec(html) || [])[1] || '');
    if (!title) return null;
    var cover = (/<div class="imgbox">\s*<img[^>]+src="([^"]+)"/.exec(html) || [])[1] || '';
    var author = oneLine((/作者：(?:<a[^>]*>)?([\s\S]*?)(?:<\/a>)?<\/p>/.exec(html) || [])[1] || '');
    var category = oneLine((/分类：(?:<a[^>]*>)?([\s\S]*?)(?:<\/a>)?<\/p>/.exec(html) || [])[1] || '');
    var heat = oneLine((/热度：([\s\S]*?)<\/p>/.exec(html) || [])[1] || '');
    var size = oneLine((/字数：([\s\S]*?)<\/p>/.exec(html) || [])[1] || '');
    var state = oneLine((/状态：([\s\S]*?)<\/p>/.exec(html) || [])[1] || '');
    var intro = clean((/<div class="desc xs-hidden">([\s\S]*?)<\/div>/.exec(html) || [])[1] || '');
    if (!intro) intro = clean((/<div class="jianjie">([\s\S]*?)<\/div>/.exec(html) || [])[1] || '');
    var tags = [];
    var tagBlock = /<div class="tg">([\s\S]*?)<\/div>/.exec(html);
    if (tagBlock) {
      var tagRe = /<em>#<\/em>([^<]+)/g;
      var matched;
      while ((matched = tagRe.exec(tagBlock[1])) !== null) {
        var tag = oneLine(matched[1]);
        if (tag) tags.push('#' + tag);
      }
    }

    var lines = [];
    if (category) lines.push('分类：' + category);
    if (heat) lines.push('热度：' + heat);
    if (size) lines.push('字数：' + size);
    if (state) lines.push('状态：' + state);
    if (tags.length) lines.push('标签：' + tags.join(' '));
    if (intro) lines.push('', intro);

    return {
      id: id,
      title: title,
      cover: cover ? abs(clean(cover)) : '',
      subtitle: author,
      description: lines.join('\n'),
      mediaType: 'novel',
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    var page = await getPage('/other/chapters/id/' + id + '.html');
    var html = page.html;
    if (!html) throw new Error('这本书没有目录页（' + id + '），可能已下架');
    var out = [];
    var re = /<li><a href="(\/book\/\d+\/[0-9a-z]+\.html)"[^>]*>([\s\S]*?)<\/a><\/li>/g;
    var matched;
    var index = 0;
    while ((matched = re.exec(html)) !== null) {
      index += 1;
      var name = oneLine(matched[2]);
      if (!name || /^\d+$/.test(name)) name = '第 ' + index + ' 章';
      out.push({ id: matched[1], title: name });
    }
    if (!out.length) throw new Error('目录页里没有章节节点（站点模板可能改了）');
    return out;
  },

  async content(args) {
    var chapterId = String((args && (args.chapterId || args.id)) || '').trim();
    if (!chapterId) throw new Error('缺少章节 ID');
    var path = /^https?:\/\//i.test(chapterId) ? chapterId : chapterId;
    var page = await getPage(path);
    var html = page.html;
    if (!html) throw new Error('这一章打不开（可能已删除）：' + chapterId);

    var section = /<section class="read-section[^"]*"[^>]*>([\s\S]*?)<\/section>/.exec(html);
    var bodyHtml = section ? section[1] : html;
    var box = /<div class="content_txt">([\s\S]*?)<\/div>/.exec(bodyHtml);
    var inner = box ? box[1] : '';
    if (!inner) throw new Error('这一章没找到正文容器（站点模板可能改了）');

    var paras = [];
    var pRe = /<p>([\s\S]*?)<\/p>/g;
    var matched;
    while ((matched = pRe.exec(inner)) !== null) {
      var text = clean(matched[1]);
      if (text) paras.push(text);
    }
    if (!paras.length) {
      // 少数章节直接 <br> 分行
      var plain = clean(inner.replace(/<br\s*\/?>/gi, '\n'));
      if (plain) paras = plain.split('\n').map(function (line) { return line.trim(); }).filter(Boolean);
    }
    if (!paras.length) throw new Error('这一章正文是空的');

    var heading = oneLine((/<h3>([\s\S]*?)<\/h3>/.exec(bodyHtml) || [])[1] || '');
    return {
      kind: 'text',
      text: paras.join('\n\n'),
      title: heading || undefined,
    };
  },
};
