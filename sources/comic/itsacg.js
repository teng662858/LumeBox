// LumeSource: {"id":"itsacg_comic","name":"ITsACG 漫画","version":"1.0.0","category":"comic","contentCategory":"adult","mirrors":["https://www.itsacg.com","https://www.itsacgaa123.space"],"network":"direct","icon":"https://www.itsacg.com/source/plugin/jameson_manhua/images/myjs/logo/newlogo.jpg","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（itsacg.top）","url":"https://itsacg.top/","description":"官方地址发布页：主站 www.itsacg.com、备用 www.itsacgaa123.space，另有邮箱索取最新地址"},{"key":"note","type":"info","title":"站点说明","description":"ITsACG（Discuz + jameson_manhua 插件）：绅士向同人本/单行本/杂志短篇/韩漫/3D 漫，全部单话整本，阅读页 nopage=1 一次给出整本图片（实测 132 张）。列表/详情/阅读/搜索都是匿名 GET，不需要登录也不需要会员；主站在大陆被屏蔽，需要代理或改走备用站。"}]}
// LumeRuntime: javascript
//
// 站点：ITsACG（漫画中心）—— Discuz! + 插件 jameson_manhua，全部是绅士向漫画。
// 主站 https://www.itsacg.com ｜ 备用 https://www.itsacgaa123.space ｜ 发布页 https://itsacg.top
// （发布页上写明「主站在大陆被屏蔽，科学上网能访问主站」，大陆打不开时换备用站）。
//
// 接口（2026-11-02 实测，全部匿名 GET、无签名、无需登录）：
//   分类列表  /plugin.php?id=jameson_manhua&a=ku&category_id=<cid>&page=<n>
//             cid：1 同人誌 / 2 單行本 / 3 雜誌&短篇 / 4 韓漫 / 19 3D&漫畫（每页 30 本）
//   排行榜    /plugin.php?id=jameson_manhua&a=rank&page=<n>         （每页 20 本，分页极深）
//   最近更新  /plugin.php?id=jameson_manhua&a=updatelist            （10 本，单页）
//   编辑推荐  /plugin.php?id=jameson_manhua&a=new_tj                （10 本，单页）
//   详情      /plugin.php?id=jameson_manhua&c=index&a=bofang&kuid=<kuid>
//             标题在 <h3 class="mt0">，第一张 <img> 就是封面，标签在 a=search_tags&tag_name=…
//   阅读      /plugin.php?id=jameson_manhua&c=index&a=read&zjid=<zjid>&nopage=1
//             页面里内联 `let urls = [...]`，nopage=1 = 整本图片（实测 132 张，与分页 7×40 合并一致）
//   搜索      /plugin.php?id=jameson_manhua&c=index&a=search&keyword=<词>
//             直接用 GET，**不需要 formhash**（实测「巨乳」→ 30 条）
//   图片 CDN  https://image2.imgspace.co.uk/data/...、/hacg_cover/...（直连 200，只认 Referer）
//
// 结构要点：一个 kuid 就是一本（一个 zjid），没有多章节；所以 chapters() 给一话全集，
// content() 用 nopage=1 一页拿全，图片链接直接返回（沙箱没有 atob/Buffer，这里也不需要解密）。
//
// 失效预案：站点换域名看发布页 itsacg.top；图片 403 时补 Referer；列表解析不到时
// 先看 a=bofang&kuid= 的 href 是否改成了别的 action。

var BASE_FALLBACK = 'https://www.itsacg.com';
var MIRRORS = ['https://www.itsacg.com', 'https://www.itsacgaa123.space'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PLUGIN = '/plugin.php?id=jameson_manhua';
var PAGE_SIZE = 30;

var CATEGORIES = [
  { id: 'rank', title: '排行榜' },
  { id: 'update', title: '最近更新' },
  { id: 'tj', title: '编辑推荐' },
  { id: 'c1', title: '同人誌' },
  { id: 'c2', title: '單行本' },
  { id: 'c3', title: '雜誌&短篇' },
  { id: 'c4', title: '韓漫' },
  { id: 'c19', title: '3D&漫畫' }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var host = (domain || BASE_FALLBACK).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(host)) host = 'https://' + host;
  return host;
}

function headers(referer) {
  return {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,ja;q=0.8',
    'Referer': referer || base() + '/'
  };
}

async function fetchHtml(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, { headers: headers() });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：ITsACG 被 Cloudflare 挡住（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (/cf-chl-|Just a moment|cf-turnstile/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：ITsACG 需要网页验证');
  }
  return body;
}

function clean(text) {
  return String(text == null ? '' : text)
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function absUrl(url) {
  var u = String(url == null ? '' : url).trim();
  if (!u) return '';
  if (/^https?:\/\//i.test(u)) return u;
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (u.charAt(0) === '/') return base() + u;
  return base() + '/' + u.replace(/^\.\//, '');
}

/* ───────────── 列表解析 ───────────── */

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  // 两种卡片布局：
  //   分类/搜索页  <div class="image-fm"><img></div><div class="image-title">标题</div>
  //   排行/更新页  <div class="item-media"><img></div><div class="item-title">标题</div>
  var re = /<a[^>]+a=bofang&amp;kuid=(\d+)[^>]*>([\s\S]{0,1500}?)<\/a>/g;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var kuid = matched[1];
    var block = matched[2];
    if (seen[kuid]) continue;
    var title = '';
    var titleMatch = /class="image-title"[^>]*>([\s\S]{0,300}?)<\/div>/.exec(block) ||
      /class="item-title"[^>]*>([\s\S]{0,300}?)<\/div>/.exec(block);
    if (titleMatch) title = clean(titleMatch[1]);
    if (!title) {
      var altMatch = /<img[^>]+(?:alt|title)="([^"]{2,120})"/.exec(block);
      if (altMatch) title = clean(altMatch[1]);
    }
    if (!title) continue;
    var coverMatch = /<img[^>]+src="([^"]+)"/.exec(block);
    var cover = coverMatch ? absUrl(coverMatch[1]) : '';
    var summaryMatch = /class="image-summary"[^>]*>([\s\S]{0,120}?)<\/div>/.exec(block);
    var summary = summaryMatch ? clean(summaryMatch[1]).replace(/^更新时间[:：]\s*/, '') : '';
    if (!summary) {
      var readMatch = /閱讀量[:：]\s*(\d+)/.exec(block);
      if (readMatch) summary = '阅读 ' + readMatch[1];
    }
    seen[kuid] = true;
    items.push({
      id: kuid,
      title: title,
      cover: cover,
      subtitle: summary
    });
  }
  return items;
}

function hasNextPage(html, page) {
  var next = Number(page) + 1;
  return new RegExp('page=' + next + '(?:&|"|\x27)').test(String(html || ''));
}

/* ───────────── 详情解析 ───────────── */

function parseDetail(html, kuid) {
  var text = String(html || '');
  var titleMatch = /<h3 class="mt0">([\s\S]{0,300}?)<\/h3>/.exec(text);
  var title = titleMatch ? clean(titleMatch[1]) : '';
  var coverMatch = /<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|webp))"/i.exec(text);
  var tags = [];
  var tagRe = /a=search_tags&amp;tag_name=([^"&]+)"/g;
  var tagMatch;
  while ((tagMatch = tagRe.exec(text)) !== null) {
    var tag = clean(decodeURIComponent(tagMatch[1]));
    if (tag && tags.indexOf(tag) < 0) tags.push(tag);
  }
  var zjids = [];
  var zjRe = /a=read&amp;zjid=(\d+)/g;
  var zjMatch;
  while ((zjMatch = zjRe.exec(text)) !== null) {
    if (zjids.indexOf(zjMatch[1]) < 0) zjids.push(zjMatch[1]);
  }
  var readsMatch = /阅读(\d+)/.exec(text);
  return {
    id: String(kuid),
    title: title,
    cover: coverMatch ? absUrl(coverMatch[1]) : '',
    tags: tags,
    zjids: zjids.length ? zjids : [String(kuid)],
    reads: readsMatch ? readsMatch[1] : ''
  };
}

/* ───────────── 阅读页图片 ───────────── */

function parseImages(html) {
  var text = String(html || '');
  var urls = [];
  var seen = {};
  var re = /https:\/\/[^"'\s\\<>]+?\.(?:jpg|jpeg|png|webp)/gi;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var url = matched[0];
    if (/hacg_cover\//.test(url)) continue;
    if (seen[url]) continue;
    seen[url] = true;
    urls.push(url);
  }
  return urls;
}

/* ───────────── 源对象 ───────────── */

var DETAIL_CACHE = { at: 0, id: '', value: null };
var DETAIL_TTL_MS = 5 * 60 * 1000;

async function detailInfo(kuid) {
  if (DETAIL_CACHE.value && DETAIL_CACHE.id === String(kuid) && Date.now() - DETAIL_CACHE.at < DETAIL_TTL_MS) {
    return DETAIL_CACHE.value;
  }
  var info = parseDetail(await fetchHtml(PLUGIN + '&c=index&a=bofang&kuid=' + encodeURIComponent(kuid)), kuid);
  DETAIL_CACHE = { at: Date.now(), id: String(kuid), value: info };
  return info;
}

var LumeSource = {
  id: 'itsacg_comic',
  name: 'ITsACG 漫画',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',
  mirrors: MIRRORS,

  async categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    return list;
  },

  async home() {
    var boards = [];
    try {
      var update = parseCards(await fetchHtml(PLUGIN + '&a=updatelist'));
      if (update.length) boards.push({ title: '最近更新', moreUrl: 'update', items: update.slice(0, 12) });
    } catch (error) { /* 单板块失败不致命 */ }
    try {
      var rank = parseCards(await fetchHtml(PLUGIN + '&a=rank'));
      if (rank.length) boards.push({ title: '排行榜', moreUrl: 'rank', items: rank.slice(0, 12) });
    } catch (error) { /* 同上 */ }
    try {
      var tj = parseCards(await fetchHtml(PLUGIN + '&a=new_tj'));
      if (tj.length) boards.push({ title: '编辑推荐', moreUrl: 'tj', items: tj.slice(0, 12) });
    } catch (error) { /* 同上 */ }
    if (!boards.length) throw new Error('首页板块一个都没取到：站点可能被 Cloudflare 挡住或换了域名（看发布页 itsacg.top）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var searchHtml = await fetchHtml(PLUGIN + '&c=index&a=search&keyword=' + encodeURIComponent(keyword) + '&page=' + page);
      var hits = parseCards(searchHtml);
      return { items: hits, hasMore: hasNextPage(searchHtml, page) && hits.length >= PAGE_SIZE };
    }

    if (!categoryId) categoryId = 'rank';
    var path;
    if (categoryId === 'rank') path = PLUGIN + '&a=rank&page=' + page;
    else if (categoryId === 'update') path = PLUGIN + '&a=updatelist';
    else if (categoryId === 'tj') path = PLUGIN + '&a=new_tj';
    else if (categoryId.charAt(0) === 'c') path = PLUGIN + '&a=ku&category_id=' + Number(categoryId.slice(1)) + '&page=' + page;
    else throw new Error('未知分类：' + categoryId);

    var html = await fetchHtml(path);
    var items = parseCards(html);
    var hasMore;
    if (categoryId === 'update' || categoryId === 'tj') hasMore = false;
    else hasMore = hasNextPage(html, page) && items.length >= 10;
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var kuid = String((argument && argument.id) || '').trim();
    if (!kuid) return null;
    var info = parseDetail(await fetchHtml(PLUGIN + '&c=index&a=bofang&kuid=' + encodeURIComponent(kuid)), kuid);
    if (!info.title) return null;
    var bits = [];
    if (info.reads) bits.push('阅读 ' + info.reads);
    if (info.tags.length) bits.push(info.tags.slice(0, 3).join(' / '));
    return {
      id: info.id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      tags: info.tags,
      description:
        '站点：' + base() + '\n' +
        'ITsACG（绅士向同人本/单行本/杂志短篇/韩漫/3D 漫）\n' +
        (info.tags.length ? '标签：' + info.tags.join('・') + '\n' : '') +
        '阅读页直接内联整本图片地址，不需要登录或会员；站点换域名见发布页 itsacg.top。'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var info = await detailInfo(id);
    var chapters = [];
    for (var i = 0; i < info.zjids.length; i++) {
      chapters.push({
        id: info.zjids[i],
        title: info.zjids.length > 1 ? '第 ' + (i + 1) + ' 话' : '全集（整本阅读）'
      });
    }
    return chapters;
  },

  async content(argument) {
    var args = argument || {};
    var zjid = String(args.chapterId || args.id || '').trim();
    if (!zjid) throw new Error('缺少阅读 ID');
    var html = await fetchHtml(PLUGIN + '&c=index&a=read&zjid=' + encodeURIComponent(zjid) + '&nopage=1');
    var images = parseImages(html);
    if (!images.length) {
      var paged = parseImages(await fetchHtml(PLUGIN + '&c=index&a=read&zjid=' + encodeURIComponent(zjid) + '&page=1'));
      images = paged;
    }
    if (!images.length) throw new Error('这一本没解析到图片：站点阅读页结构可能变了');
    var imageHeaders = {};
    var referer = base() + '/';
    for (var i = 0; i < images.length; i++) imageHeaders[images[i]] = { 'User-Agent': UA, 'Referer': referer };
    return { kind: 'images', images: images, imageHeaders: imageHeaders };
  }
};
