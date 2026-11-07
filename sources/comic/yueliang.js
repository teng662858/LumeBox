// LumeSource: {"id":"yueliang_comic","name":"月亮小说","version":"1.0.3","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://yueliangxiaoshuo.com"],"network":"direct","icon":"https://yueliangxiaoshuo.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"月亮小说（yueliangxiaoshuo.com，中文小说社区，含 R-18 分区）：新书 /novel/new?p=N（30 条/页、实测 100 页）；榜单 /novel/ranking?mode=daily|weekly|monthly|rookie|total&r18=0|1|2（0 普通 / 1 全部 / 2 R-18，实测三档内容不同）；系列（书） /novel/series/{id}（目录 30 章/页，?p=N，最长实测 47 页）；单章 /novel/show/{id}（正文 div#novel-body）；搜索 /search/novels?q=&p=。全部免费、不需要登录。 原站大量小说未上传封面，网页使用颜色与书名占位；无图片时 App 同样保留书名占位。"}]}
// LumeRuntime: javascript
//
// 站点：月亮小说（yueliangxiaoshuo.com，PHP 渲染的静态 HTML，含 R-18 分区）
// 交付形态：文字小说（mediaType:'novel'，content 返回 kind:'text'），归漫画板块「小说」。
//
// 结构（2026-11-04 逐页实测）：
//   · 新书        /novel/new?p=N            30 条/页，实测能到 p=100
//   · 榜单        /novel/ranking?mode=daily|weekly|monthly|rookie|total
//                 + r18=0（普通，22 条）/ 1（全部，50 条）/ 2（R-18，25 条），三档首条互不相同
//                 + date=YYYY-MM-DD（榜单日期，缺省就是今天）
//   · 系列（书）  /novel/series/{id}         h1 = 书名，目录是 novel-card 列表（30 章/页，?p=N）
//   · 单章        /novel/show/{id}           <div class="novel-body" id="novel-body"> 里是 <p> 段落
//   · 搜索        /search/novels?q={词}&p=N  30 条/页
//   · 卡片        <article class="novel-card[ has-rank]" data-novel-id="…">
//                   <h3 class="novel-card-title"><a href="/novel/(show|series)/{id}">标题</a>
//                 列表里的条目有两种落点：series = 一部书（有目录），show = 单章/短篇。
//
// 限制：`r18` 只对榜单生效（/novel/new?r18=2 与不传完全一样），所以本源只在榜单通道里用它。
// 系列目录按 30 章/页翻，一本 1400 章的书要 47 页（源里 6 路并发，最多支持 400 页，超出时明确提示而不是截断目录）。

var BASE_URL = 'https://yueliangxiaoshuo.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 30;
var MAX_TOC_PAGES = 400;
var seriesPage = null;
var seriesDirectory = null;

var MODES = [
  { id: 'daily', title: '今日榜' },
  { id: 'weekly', title: '周榜' },
  { id: 'monthly', title: '月榜' },
  { id: 'rookie', title: '新书榜' },
  { id: 'total', title: '总榜' }
];

var RATINGS = [
  { id: 'all', title: '全部' },
  { id: 'normal', title: '普通' },
  { id: 'r18', title: 'R-18' }
];

var R18_VALUE = { all: '1', normal: '0', r18: '2' };

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
    .replace(/&hellip;/g, '…')
    .replace(/&mdash;/g, '—')
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

async function fetchHtml(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: referer || base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：月亮小说触发了人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

// id 形如 "series:361" / "show:297"
function parseRef(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /^(series|show):(\d+)$/.exec(text) || /\/(series|show)\/(\d+)/.exec(text);
  if (!matched) return null;
  return { kind: matched[1], id: matched[2] };
}

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var cardRe = /<article class="novel-card[^"]*"([\s\S]*?)<\/article>/g;
  var card;
  while ((card = cardRe.exec(text)) !== null) {
    var block = card[1];
    var titleHit = /<h3 class="novel-card-title">[\s\S]{0,240}?<a href="\/novel\/(show|series)\/(\d+)">([\s\S]*?)<\/a>/i.exec(block);
    if (!titleHit) continue;
    var key = titleHit[1] + ':' + titleHit[2];
    if (seen[key]) continue;
    var title = oneLine(titleHit[3]);
    if (!title) continue;
    var cover = /<img[^>]*src="([^"]+)"/i.exec(block);
    var coverPlaceholder = /<span[^>]*class="cover-placeholder"/.test(block);
    var author = /class="novel-card-author"[\s\S]{0,160}?<a[^>]*>([\s\S]*?)<\/a>/i.exec(block);
    var words = /([0-9,]+)\s*字/.exec(block);
    var rank = /class="rank-badge">(\d+)</i.exec(block);
    var latest = /class="novel-card-latest"[\s\S]{0,200}?<a[^>]*>([\s\S]*?)<\/a>/i.exec(block);
    seen[key] = true;
    items.push({
      id: key,
      title: title,
      cover: cover && !coverPlaceholder ? absolute(cover[1]) : '',
      coverHeaders: { Referer: base() + '/', 'User-Agent': UA },
      subtitle: [
        rank ? '第 ' + rank[1] + ' 名' : '',
        author ? oneLine(author[1]) : '',
        words ? words[1] + ' 字' : '',
        latest ? oneLine(latest[1]) : ''
      ].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return items;
}

function channelPath(page, categoryId, rating) {
  var id = categoryId || 'new';
  if (/^rank-/.test(id)) {
    var mode = id.slice(5);
    var r18 = R18_VALUE[rating] || '1';
    return '/novel/ranking?mode=' + mode + '&r18=' + r18 + (page > 1 ? '&p=' + page : '');
  }
  return '/novel/new?p=' + page;
}

function maxPageOf(html, marker) {
  var text = String(html || '');
  var re = new RegExp(marker + '(\\d+)', 'g');
  var max = 1;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var n = Number(hit[1]);
    if (n > max) max = n;
  }
  return max;
}

async function poolMap(list, limit, worker) {
  var out = new Array(list.length);
  var cursor = 0;
  var run = async function () {
    while (cursor < list.length) {
      var index = cursor;
      cursor += 1;
      try {
        out[index] = await worker(list[index]);
      } catch (error) {
        throw new Error('目录第 ' + list[index] + ' 页加载失败，请重试：' + String(error));
      }
    }
  };
  var runners = [];
  var width = Math.min(limit, list.length);
  for (var i = 0; i < width; i++) runners.push(run());
  await Promise.all(runners);
  return out;
}

function novelBodyText(html) {
  var text = String(html || '');
  var start = text.indexOf('id="novel-body"');
  if (start < 0) start = text.indexOf('novel-body');
  if (start < 0) return '';
  var open = text.indexOf('>', start);
  var end = text.indexOf('</div>', open);
  var seg = open >= 0 ? text.slice(open + 1, end > open ? end : text.length) : '';
  seg = seg
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  var lines = decodeEntities(seg).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
    if (!line) continue;
    out.push(line);
  }
  return out.join('\n');
}

var LumeSource = {
  id: 'yueliang_comic',
  name: '月亮小说',
  version: '1.0.3',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://yueliangxiaoshuo.com/favicon.ico',
  mirrors: ['https://yueliangxiaoshuo.com'],

  async categories() {
    var list = [{ id: 'new', title: '新书' }];
    for (var i = 0; i < MODES.length; i++) list.push({ id: 'rank-' + MODES[i].id, title: MODES[i].title });
    return list;
  },

  async filters() {
    return {
      groups: [
        {
          id: 'rating',
          title: '分级（仅榜单）',
          options: RATINGS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    var fresh = parseCards(await fetchHtml('/novel/new?p=1')).slice(0, 12);
    if (fresh.length) boards.push({ title: '最新入库', moreUrl: 'new', items: fresh });
    try {
      var daily = parseCards(await fetchHtml('/novel/ranking?mode=daily&r18=1')).slice(0, 12);
      if (daily.length) boards.push({ title: '今日榜', moreUrl: 'rank-daily', items: daily });
    } catch (error) {
      /* 榜单失败不影响首页 */
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var rating = String(filters.rating || 'all').trim();
    if (rating.indexOf(',') >= 0) rating = rating.split(',')[0].trim();

    var path;
    if (keyword) {
      path = '/search/novels?q=' + encodeURIComponent(keyword) + (page > 1 ? '&p=' + page : '');
    } else {
      path = channelPath(page, categoryId, rating);
    }

    var html = await fetchHtml(path);
    var items = parseCards(html);
    if (!items.length) {
      if (keyword) return { items: [], hasMore: false };
      if (page === 1) throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    }
    var hasMore;
    if (keyword) {
      hasMore = items.length >= PAGE_SIZE;
    } else if (/^rank-/.test(categoryId || '')) {
      hasMore = false; // 榜单固定一页
    } else {
      hasMore = items.length >= PAGE_SIZE;
    }
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var ref = parseRef(argument && argument.id);
    if (!ref) return null;
    var path = ref.kind === 'series' ? '/novel/series/' + ref.id : '/novel/show/' + ref.id;
    var html = await fetchHtml(path);
    if (!html) return null;
    if (ref.kind === 'series') seriesPage = { id: ref.id, html: html };
    var pageTitle = /<title>([^<]*)<\/title>/i.exec(html);
    var h1 = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(html);
    var title = '';
    if (ref.kind === 'series') {
      title = oneLine(h1 ? h1[1] : '');
      if (!title && pageTitle) title = oneLine(String(pageTitle[1]).split(' - ')[0]);
    } else {
      title = oneLine(pageTitle ? String(pageTitle[1]).split(' - ')[0] : '');
      if (!title && h1) title = oneLine(h1[1]);
    }
    if (!title) return null;

    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html)
      || /<img[^>]*class="[^"]*cover[^"]*"[^>]*src="([^"]+)"/i.exec(html);
    var coverUrl = cover ? absolute(cover[1]) : '';
    // 站点没有真封面时给的是统一占位图，别当封面用
    if (/og-default\.png|placeholder/i.test(coverUrl)) coverUrl = '';
    var author = /<a[^>]*href="\/users\/[^"]*"[^>]*>([\s\S]{0,60}?)<\/a>/i.exec(html);
    var isR18 = /R-18|R18/.test(html);
    var seriesLink = ref.kind === 'show' ? /href="\/novel\/series\/(\d+)"/i.exec(html) : null;
    var words = /([0-9,]+)\s*字/.exec(html);

    var lines = [];
    if (author) lines.push('作者：' + oneLine(author[1]));
    lines.push('分区：' + (isR18 ? 'R-18' : '普通'));
    if (ref.kind === 'show' && seriesLink) lines.push('所属系列：series:' + seriesLink[1]);
    if (words) lines.push('字数：' + words[1]);
    var intro = /<div class="series-desc[^"]*">([\s\S]*?)<\/div>/i.exec(html)
      || /<meta\s+name="description"\s+content="([^"]*)"/i.exec(html);
    var introText = intro ? clean(intro[1]) : '';
    if (introText) lines.push('', introText);

    return {
      id: ref.kind + ':' + ref.id,
      title: title,
      cover: coverUrl,
      subtitle: [author ? oneLine(author[1]) : '', isR18 ? 'R-18' : '普通'].filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  // 新宿主每次最多读取6个目录分页，避免整本长篇超过单次沙箱时限。
  async chapters(argument) {
    var all = [], page = 1;
    do {
      var batch = await LumeSource.chapterPage({ id: argument && argument.id, page: page });
      all = all.concat(batch.items);
      page = batch.nextPage;
    } while (page);
    return all;
  },

  async chapterPage(argument) {
    var ref = parseRef(argument && argument.id);
    if (!ref) return { items: [], nextPage: null };
    if (ref.kind === 'show') {
      return { items: [{ id: 'show:' + ref.id, title: '正文' }], nextPage: null };
    }
    var startPage = Math.max(1, Number(argument.page) || 1);
    var chapters = [], maxPage;
    if (startPage === 1) {
      var first = seriesPage && seriesPage.id === ref.id
        ? seriesPage.html : await fetchHtml('/novel/series/' + ref.id);
      seriesPage = null;
      chapters = parseCards(first);
      maxPage = maxPageOf(first, '/novel/series/' + ref.id + '\\?p=');
      if (maxPage > MAX_TOC_PAGES) throw new Error('目录超过 ' + MAX_TOC_PAGES + ' 页，请在网页查看完整目录');
      seriesDirectory = { id: ref.id, maxPage: maxPage };
    } else {
      if (!seriesDirectory || seriesDirectory.id !== ref.id) throw new Error('目录会话已失效，请重试');
      maxPage = seriesDirectory.maxPage;
    }
    var endPage = Math.min(startPage + 5, maxPage);
    var rest = [];
    for (var p = startPage === 1 ? 2 : startPage; p <= endPage; p++) rest.push(p);
    var pages = await poolMap(rest, 6, function (pageNo) {
      return fetchHtml('/novel/series/' + ref.id + '?p=' + pageNo);
    });
    for (var i = 0; i < pages.length; i++) {
      var more = parseCards(pages[i] || '');
      for (var k = 0; k < more.length; k++) {
        if (more[k].id.indexOf('show:') === 0) chapters.push(more[k]);
      }
    }
    var out = [];
    var seen = {};
    for (var j = 0; j < chapters.length; j++) {
      var item = chapters[j];
      if (item.id.indexOf('show:') !== 0) continue;
      if (seen[item.id]) continue;
      seen[item.id] = true;
      out.push({ id: item.id, title: item.title });
    }
    // 目录里还有其它 series 卡片（推荐位），只保留 show 章节
    if (!out.length) throw new Error('目录里没有章节（series:' + ref.id + '）');
    return { items: out, nextPage: endPage < maxPage ? endPage + 1 : null };
  },

  async content(argument) {
    var args = argument || {};
    var ref = parseRef(args.chapterId) || parseRef(args.id);
    if (!ref) throw new Error('缺少章节 ID（应形如 show:123）');
    var kind = ref.kind;
    var id = ref.id;
    if (kind === 'series') {
      // 传进来的是书而不是章：取第一章
      var toc = await LumeSource.chapters({ id: 'series:' + id });
      var firstRef = parseRef(toc.length ? toc[0].id : '');
      if (!firstRef) throw new Error('这本书没有章节');
      kind = firstRef.kind;
      id = firstRef.id;
    }
    var html = await fetchHtml('/novel/show/' + id);
    var text = novelBodyText(html);
    if (!text.trim()) throw new Error('这一章没有正文（show:' + id + '）');
    var pageTitle = /<title>([^<]*)<\/title>/i.exec(html);
    var title = pageTitle ? oneLine(String(pageTitle[1]).split(' - ')[0]) : '';
    return { kind: 'text', title: title || undefined, text: text };
  }
};
