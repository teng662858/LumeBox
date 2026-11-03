// LumeSource: {"id":"antbyw_comic","name":"蚂蚁搬运","version":"1.0.1","category":"comic","mirrors":["http://www.antbyw.com"],"icon":"https://www.antbyw.com/favicon.ico"}
//
// 站点：蚂蚁搬运网 / ant搬运网（Discuz! X + jameson_manhua 插件，服务端渲染，全程免登录，2026-10-25 实测）
//
// 入口域：源码里写的是 http://www.antbyw.com，但站点 301 到 https://www.antbyw.com，
// 所以 base() 会把 http:// 升成 https://，省掉每次请求一次跳转（页内 <base href> 也是 https）。
// 编码：页面 meta charset=utf-8，curl 拿到的字节 UTF-8 解码零替换符（用 GBK 解会烂），
// 所以直接 response.body 当 UTF-8 字符串用，不需要 TextDecoder。
//
// 路由（plugin.php?id=jameson_manhua，页面里 c=index 有时省略，两种都能开）：
//   · 首页      &c=index&a=index                     多块「最新更新 / 日本 / 少年 / 少女 /
//                                                     已完结 / 连载中」的 uk-card 卡片墙
//   · 库        &c=index&a=ku[&region=1|&shouzhong=46|&jindu=96|&category_id=13]&page=N
//                                                     1240 页，60 条/页
//   · 详情      &c=index&a=bofang&kuid={kuid}         作品信息 + 目录（单行本 / 单话 / 番外篇）
//   · 阅读      &a=read&kuid={kuid}&zjid={zjid}&page=N  每页 5 张图，靠 &page= 翻页
//   · 搜索      &c=index&a=search&keyword={kw}&page=N  服务端渲染，同样 60 条/页
//   · rootcategory / a=store 之类：&a=rootcategory&category_id=1 直接回 "no visit"（要登录态），
//     本源不用它，分类走 a=ku 的筛选参数。
//
// 卡片形状（ku / 首页 / 搜索结果同一套，只有最后一段 <p> 的 class 略有差别）：
//   <div class="uk-card mbm uk-text-center">
//     <div class="uk-card-media-top uk-inline">
//       <a href="./plugin.php?id=jameson_manhua&amp;c=index&amp;a=bofang&amp;kuid=200605">
//         <img loading="lazy" src="https://imgmhc.antbyw.com/mh_cover/62017.jpg" alt="">
//         <div class="uk-overlay …"><a class="xs1" href="…">第02话 / 连载中</a></div></a></div>
//     <div class=""><p class="mt5 mb5 uk-text-truncate uk-text-center xs2">
//       <a href="./plugin.php?…&amp;kuid=200605">拜田同学想看我的窝囊样</a></p></div>
//   </div>
//   所以按 <div class="uk-card 切片，每片里取 kuid / img src / .xs1 或 .uk-overlay 文本 /
//   <p class="mt5…"> 里的 a 文本（标题）。
//
// 章节形状：&a=bofang 页按 <h3 class="uk-alert-warning">单行本</h3> / 单话 / 番外篇 分三段，
// 每段：<a href="…&a=read&kuid=N&zjid=M" class="uk-button uk-button-default zj-container">第20卷</a>
//   HTML 里的顺序是「新→旧」（第205话 … 第01话、第20卷 … 第01卷），本源按段倒序还原成
//   「旧→新」，并把「单话」排在「单行本」前面——单行本一卷 196 张图／40 页，放前面会拖慢首读。
//
// 播放页：&a=read 的 HTML 里直接内联
//   <script> jQuery(function(){ let urls = ["https://imgmhc.antbyw.com/ps4/…/第01话/01.jpg.webp", …]; … })
//   只有 5 张，靠分页 <a href="…&page=2"> 补；页尾有 <span title="共 11 页">，本源据此并发抓完
//   （上限 40 页 = 200 张，防止单行本那种 196 图把调用时间拖爆）。
//   图在 imgmhc.antbyw.com，实测裸访问就 206，带不带 Referer 都行；这里仍统一带站点 Referer。
//
// App 侧：需要能出外网（本源走宿主 http，用户自备代理时 App 侧要配好）。

var DEFAULT_BASE = 'https://www.antbyw.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
var MAX_PAGES = 40;      // 单章最多翻 40 页（约 200 张图）
var PAGE_CONCURRENCY = 4;

// 分类：直接就是 a=ku 的筛选参数，id 里带的值原样拼回 URL
var CATEGORIES = [
  { id: 'all', title: '全部漫画' },
  { id: 'region=1', title: '日本' },
  { id: 'shouzhong=46', title: '少年' },
  { id: 'shouzhong=45', title: '少女' },
  { id: 'jindu=96', title: '连载中' },
  { id: 'jindu=97', title: '已完结' }
];

var lastPage = { url: '', html: '' };

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var value = (domain || DEFAULT_BASE).replace(/\/+$/, '');
  // 站点强制 https，先升掉，省一次 301
  return value.replace(/^http:\/\//i, 'https://');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim().replace(/&amp;/g, '&');
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text.replace(/^\.\//, '');
}

function headers(extra) {
  var result = {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
  };
  for (var key in extra || {}) if (extra[key] != null) result[key] = extra[key];
  return result;
}

function decode(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#(\d+);/g, function (all, code) {
      return String.fromCharCode(Number(code));
    })
    .replace(/&nbsp;/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function looksBlocked(status, body) {
  return (status === 403 || status === 503) && /Just a moment|cf-chl-|challenge-platform/i.test(String(body || ''));
}

function wait(ms) {
  return new Promise(function (resolve) {
    setTimeout(resolve, ms);
  });
}

async function get(target) {
  var url = absolute(target);
  if (lastPage.url === url && lastPage.html) return lastPage.html;
  var status = 0;
  for (var attempt = 0; attempt < 3; attempt++) {
    var response = await LumeSource.http.request({
      url: url,
      method: 'GET',
      headers: headers({ Referer: base() + '/' })
    });
    status = response ? response.status : 0;
    var text = String((response && response.body) || '');
    if (looksBlocked(status, text)) {
      throw new Error('NEED_WEBVIEW_VERIFY：蚂蚁搬运 被 Cloudflare 挑战页拦住（HTTP ' + status + '），请给本源配代理或走网页视图');
    }
    if (status === 200) {
      if (text.length > 4000) lastPage = { url: url, html: text };
      return text;
    }
    // 520/521/522/524：Cloudflare 说源站没正常回包，等一会儿再试
    if (status >= 500) {
      await wait(250 + attempt * 350);
      continue;
    }
    throw new Error('蚂蚁搬运 页面打不开：HTTP ' + status + ' ' + url);
  }
  throw new Error('蚂蚁搬运 页面打不开：HTTP ' + status + '（源站抖动，已重试 3 次）' + url);
}

// ------------------------------------------------------------------ 解析
// 按 <div class="uk-card 切片，每片取 kuid / 封面 / 副标题 / 标题
function parseCards(pageHtml) {
  var items = [];
  var seen = {};
  var chunks = String(pageHtml).split('<div class="uk-card');
  for (var i = 1; i < chunks.length; i++) {
    var chunk = chunks[i].slice(0, 3000).replace(/&amp;/g, '&');
    var idMatch = /a=bofang&kuid=(\d+)/.exec(chunk);
    if (!idMatch) continue;
    var kuid = idMatch[1];
    if (seen[kuid]) continue;
    var coverMatch = /<img[^>]*src="([^"]+)"/i.exec(chunk);
    var cover = coverMatch ? decode(coverMatch[1]) : '';
    if (/loading\.gif|blank\.|default\.jpg/i.test(cover)) cover = '';
    var titleMatch = /<p[^>]*class="[^"]*mt5[^"]*"[^>]*>\s*<a[^>]*>([^<]*)<\/a>/i.exec(chunk);
    if (!titleMatch) {
      var anchors = chunk.match(/<a\b[^>]*>[^<]+<\/a>/g) || [];
      for (var k = anchors.length - 1; k >= 0 && !titleMatch; k--) {
        var textMatch = /<a\b[^>]*>([^<]+)<\/a>/.exec(anchors[k]);
        if (textMatch && decode(textMatch[1]) && !/^javascript/.test(anchors[k])) titleMatch = textMatch;
      }
    }
    var title = titleMatch ? decode(titleMatch[1]) : '';
    if (!title) continue;
    var subMatch = /<div class="uk-overlay[^"]*"[^>]*>([\s\S]*?)<\/div>/i.exec(chunk) ||
      /<div class="uk-text-truncate[^"]*"[^>]*>([\s\S]*?)<\/div>/i.exec(chunk);
    seen[kuid] = true;
    items.push({
      id: absolute('/plugin.php?id=jameson_manhua&c=index&a=bofang&kuid=' + kuid),
      title: title,
      cover: cover ? absolute(cover) : '',
      subtitle: subMatch ? decode(subMatch[1]) : ''
    });
  }
  return items;
}

function pageCount(pageHtml) {
  var matched = /共\s*(\d+)\s*页/.exec(pageHtml);
  return matched ? Number(matched[1]) : 0;
}

// 目录按段解析：单行本 / 单话 / 番外篇
function parseChapters(pageHtml) {
  var text = String(pageHtml);
  var marks = [];
  var splitter = /<h3[^>]*class="uk-alert-warning"[^>]*>([\s\S]*?)<\/h3>/g;
  var matched;
  while ((matched = splitter.exec(text)) !== null) {
    marks.push({ title: decode(matched[1]), start: splitter.lastIndex });
  }
  if (!marks.length) marks.push({ title: '', start: 0 });

  var groups = [];
  for (var i = 0; i < marks.length; i++) {
    var end = i + 1 < marks.length ? marks[i + 1].start : text.length;
    var chunk = text.slice(marks[i].start, end).replace(/&amp;/g, '&');
    var rows = [];
    var seen = {};
    var anchor = /<a\b([^>]*)>([^<]*)<\/a>/g;
    var hit;
    while ((hit = anchor.exec(chunk)) !== null) {
      if (hit[1].indexOf('zj-container') < 0) continue;
      var hrefMatch = /href="([^"]+)"/i.exec(hit[1]);
      if (!hrefMatch) continue;
      var url = absolute(hrefMatch[1]);
      if (!url || seen[url]) continue;
      seen[url] = true;
      rows.push({ id: url, title: decode(hit[2]) || ('第 ' + (rows.length + 1) + ' 话') });
    }
    if (rows.length) groups.push({ title: marks[i].title, rows: rows.reverse() });
  }

  // 阅读顺序：单话 → 番外篇 → 单行本（单行本一卷图太多，排最后）
  function rank(title) {
    if (/单话|連載|连载/.test(title)) return 0;
    if (/番外/.test(title)) return 1;
    if (/单行本|單行本/.test(title)) return 2;
    return 1.5;
  }
  groups.sort(function (left, right) {
    return rank(left.title) - rank(right.title);
  });
  var chapters = [];
  var used = {};
  for (var g = 0; g < groups.length; g++) {
    for (var r = 0; r < groups[g].rows.length; r++) {
      var row = groups[g].rows[r];
      if (used[row.id]) continue;
      used[row.id] = true;
      chapters.push(row);
    }
  }
  return chapters;
}

// 阅读页：let urls = ["…","…"]; + <span title="共 N 页">
function parseReader(pageHtml) {
  var urls = [];
  var seen = {};
  var block = /let\s+urls\s*=\s*(\[[\s\S]*?\])\s*;/.exec(pageHtml);
  if (block) {
    var pattern = /"([^"]+)"/g;
    var matched;
    while ((matched = pattern.exec(block[1])) !== null) {
      var url = matched[1].replace(/\\\//g, '/');
      if (!/^https?:\/\//i.test(url) || seen[url]) continue;
      seen[url] = true;
      urls.push(url);
    }
  }
  var pageMatch = /共\s*(\d+)\s*页/.exec(pageHtml);
  return { urls: urls, pages: pageMatch ? Number(pageMatch[1]) : 1 };
}

function imageHeaders() {
  return {
    Referer: base() + '/',
    'User-Agent': UA,
    Accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
  };
}

function idOf(argument) {
  return argument && argument.id ? String(argument.id).trim() : '';
}

// 顺序无关的并发映射：结果按输入顺序落位
async function mapLimit(list, limit, worker) {
  var results = new Array(list.length);
  var cursor = 0;
  async function run() {
    while (cursor < list.length) {
      var index = cursor++;
      results[index] = await worker(list[index], index);
    }
  }
  var workers = [];
  for (var i = 0; i < limit && i < list.length; i++) workers.push(run());
  await Promise.all(workers);
  return results;
}

var LumeSource = {
  id: 'antbyw_comic',
  name: '蚂蚁搬运',
  version: '1.0.1',
  icon: 'https://www.antbyw.com/favicon.ico',
  category: 'comic',
  mirrors: ['http://www.antbyw.com'],

  async categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    return list;
  },

  async home() {
    var pageHtml = await get('/plugin.php?id=jameson_manhua&c=index&a=index');
    // 首页是「最新更新 / 日本 / 少年 / 少女 / 已完结 / 连载中」几堵卡片墙，
    // 每堵墙前面有一个 24px 的分区大标题（后面几个还带自己的 a=ku 筛选链接）。
    var marks = [];
    var markRe = /<a class="" href="([^"]*a=ku[^"]*)" style="font-size:\s*24px[^>]*>([^<]+)<\/a>/g;
    var matched;
    while ((matched = markRe.exec(pageHtml)) !== null) {
      var filter = /a=ku&((?:region|shouzhong|jindu|category_id|search_age)=\d+)/.exec(matched[1]);
      marks.push({ title: decode(matched[2]), start: matched.index, more: filter ? filter[1] : 'all' });
    }
    var bounds = [{ title: '最新更新', start: 0, more: 'all' }].concat(marks);
    var boards = [];
    for (var i = 0; i < bounds.length; i++) {
      var end = i + 1 < bounds.length ? bounds[i + 1].start : pageHtml.length;
      var items = parseCards(pageHtml.slice(bounds[i].start, end));
      if (!items.length) continue;
      boards.push({ title: bounds[i].title, moreUrl: bounds[i].more, items: items.slice(0, 18) });
    }
    if (!boards.length) throw new Error('蚂蚁搬运：首页没认出条目（插件可能改版）');
    return boards;
  },

  async list(argument) {
    var settings = argument || {};
    var pageNo = Number(settings.page || 1);
    if (!pageNo || pageNo < 1) pageNo = 1;
    var keyword = settings.keyword ? String(settings.keyword).trim() : '';

    if (keyword) {
      var searchHtml = await get('/plugin.php?id=jameson_manhua&c=index&a=search&keyword=' +
        encodeURIComponent(keyword) + '&page=' + pageNo);
      var hits = parseCards(searchHtml);
      var searchPages = pageCount(searchHtml);
      return { items: hits, hasMore: searchPages ? pageNo < searchPages : hits.length >= 20 };
    }

    var filter = settings.categoryId ? String(settings.categoryId).trim() : 'all';
    var query = /^(region|shouzhong|jindu|category_id|search_age)=\d+$/.test(filter) ? '&' + filter : '';
    var pageHtml = await get('/plugin.php?id=jameson_manhua&c=index&a=ku' + query + '&page=' + pageNo);
    var items = parseCards(pageHtml);
    var pages = pageCount(pageHtml);
    return { items: items, hasMore: pages ? pageNo < pages : items.length >= 20 };
  },

  async detail(argument) {
    var id = idOf(argument);
    if (!id) return null;
    var pageHtml = await get(id);
    var titleMatch = /<h3 class="uk-heading-line mt10 m10 mbn">([\s\S]*?)<\/h3>/i.exec(pageHtml) ||
      /<h3[^>]*class="uk-heading-line[^"]*"[^>]*>([\s\S]*?)<\/h3>/i.exec(pageHtml) ||
      /<meta property="og:title" content="([^"]*)"/i.exec(pageHtml) ||
      /<title>([\s\S]*?)<\/title>/i.exec(pageHtml);
    var title = titleMatch ? decode(titleMatch[1]) : '';
    if (!title) return null;
    title = title.replace(/\s*-\s*tapmanga[\s\S]*$/, '').trim();

    var coverMatch = /<div uk-grid class="bofangwrap[\s\S]{0,900}?<img[^>]*src="([^"]+)"/i.exec(pageHtml) ||
      /<meta property="og:image" content="([^"]*)"/i.exec(pageHtml);
    var cover = coverMatch ? absolute(decode(coverMatch[1])) : '';

    var parts = [];
    var upto = /更新到:\s*([^<\s]+)/.exec(pageHtml);
    if (upto) parts.push(decode(upto[1]));
    var author = /漫畫作者:\s*([\s\S]{0,80}?)<\/div>/i.exec(pageHtml);
    if (author) {
      var authorText = decode(author[1]);
      if (authorText) parts.push(authorText);
    }
    var alias = /别名:\s*([\s\S]{0,120}?)<\/div>/i.exec(pageHtml);
    if (alias) {
      var aliasText = decode(alias[1]);
      if (aliasText) parts.push(aliasText);
    }

    var descMatch = /<div class="uk-alert xs2 mt5 mb5 pt5 pb5"[^>]*>([\s\S]*?)<\/div>/i.exec(pageHtml) ||
      /<meta name="description" content="([^"]*)"/i.exec(pageHtml);
    var description = descMatch ? decode(descMatch[1]) : '';
    description = description.replace(/\s*tapmanga[\s\S]*$/, '').trim();

    return {
      id: absolute(id),
      title: title,
      cover: cover,
      subtitle: parts.join(' · '),
      description: description
    };
  },

  async chapters(argument) {
    var id = idOf(argument);
    if (!id) return [];
    if (/a=read\b/.test(id)) return [{ id: absolute(id), title: '本章' }];
    var pageHtml = await get(id);
    return parseChapters(pageHtml);
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId).trim() : '';
    var target = chapterId || idOf(argument);
    if (!target) throw new Error('蚂蚁搬运：缺少阅读页地址');

    // 传进来的是作品页/章节 id 时，先找到该作品的第一个「阅读」链接
    if (!/a=read\b/.test(target)) {
      var detailHtml = await get(target);
      var chapters = parseChapters(detailHtml);
      if (!chapters.length) throw new Error('蚂蚁搬运：该条目没有章节');
      target = chapters[0].id;
    }

    var firstHtml = await get(target);
    var first = parseReader(firstHtml);
    if (!first.urls.length) {
      throw new Error('蚂蚁搬运：阅读页没解析出图片（可能是会员章或站点改版）' + absolute(target));
    }

    var images = first.urls.slice();
    var total = Math.min(first.pages || 1, MAX_PAGES);
    if (total > 1) {
      var rest = [];
      for (var pageNo = 2; pageNo <= total; pageNo++) rest.push(pageNo);
      var baseUrl = absolute(target).replace(/([?&])page=\d+/, '$1').replace(/[?&]$/, '');
      var joiner = baseUrl.indexOf('?') >= 0 ? '&' : '?';
      var fetched = await mapLimit(rest, PAGE_CONCURRENCY, async function (pageNo) {
        try {
          var html = await get(baseUrl + joiner + 'page=' + pageNo);
          return parseReader(html).urls;
        } catch (error) {
          return [];
        }
      });
      for (var i = 0; i < fetched.length; i++) {
        var rows = fetched[i] || [];
        for (var j = 0; j < rows.length; j++) images.push(rows[j]);
      }
    }

    var unique = [];
    var seen = {};
    for (var k = 0; k < images.length; k++) {
      if (seen[images[k]]) continue;
      seen[images[k]] = true;
      unique.push(images[k]);
    }
    return { kind: 'images', images: unique, headers: imageHeaders() };
  }
};
