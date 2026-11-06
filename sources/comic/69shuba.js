// LumeSource: {"id":"shuba_novel","name":"69书吧","version":"1.0.1","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.69shuba.com"],"network":"direct","icon":"https://www.69shuba.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"69书吧（69shuba.com，jieqi 模板的小说站）：全站页面在 Cloudflare managed challenge 后面——本机首次访问一律 403「Just a moment...」，用真实浏览器过完校验、拿到 cf_clearance 之后才正常。源里照约定抛 NEED_WEBVIEW_VERIFY，请用 App 的网页视图过一次校验（Cookie 会按站点保存复用）。页面编码是 GBK，App 侧走 gb18030 解码通道（iOS 原生解码）；在其它平台跑测会看到乱码，属工具限制。分类 /novels/class/{0-12}.htm（13 个：全部分类/玄幻魔法/修真武侠/言情小说/历史军事/游戏竞技/科幻空间/悬疑惊悚/同人小说/都市小说/官场职场/青春校园/穿越时空）；榜单 /novels/hot、/novels/male、/novels/female、/novels/full、/last.html；详情 /book/{id}.htm；目录 /book/{id}/；正文 /txt/{书号}/{章节号}；搜索 POST /modules/article/search.php（searchkey）。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开站点首页","url":"https://www.69shuba.com/","description":"站点会换域名，打不开时先从这里找当前地址"}]}
// LumeRuntime: javascript
//
// 站点：69书吧（www.69shuba.com，jieqi 小说站，GBK 编码，全站 CF managed challenge）
//
// 实测（2026-11-04，用真实 Chrome 过完 CF 后取得 HTML）：
//   · 分类导航  /novels/class/{0..12}.htm —— 0 全部分类 / 1 玄幻魔法 / 2 修真武侠 / 3 言情小说 /
//               4 历史军事 / 5 游戏竞技 / 6 科幻空间 / 7 悬疑惊悚 / 8 同人小说 / 9 都市小说 /
//               10 官场职场 / 11 穿越时空 / 12 青春校园
//   · 列表      <div class="newbox"><ul id="article_list_content"><li>
//                 <a href="https://www.69shuba.com/book/{id}.htm" class="imgbox"><img src="…/files/article/image/…jpg"></a>
//                 <h3><a href="…/book/{id}.htm">标题</a></h3> … </li>…</ul></div>
//   · 详情      /book/{id}.htm：<h1>书名</h1>、封面 img[src*=files/article/image]、简介，
//               以及 JS 里的 bookinfo = { articleid, articlename, author, sortName, tags }
//   · 目录      /book/{id}/：<div class="catalog" id="catalog"><ul><li data-num="1">
//                 <a href="https://www.69shuba.com/txt/{书号}/{章节号}">第1章 …</a></li>…（一次给全）
//   · 正文      /txt/{书号}/{章节号}：<div class="txtnav"> 里 <h1>章节名</h1> + .txtinfo + #txtright(广告)
//                之后就是正文（`<br><br>` 分行），正文以 <div class="contentadv">(广告) 结束
//   · 搜索      POST /modules/article/search.php 表单字段 searchkey（+ submit=Search）
//
// 关键前提：**所有页面都在 CF 挑战后面**，第一次请求必然 403；源里抛 NEED_WEBVIEW_VERIFY，
// 由 App 打开网页视图让用户本人过一次校验，之后同源 Cookie（cf_clearance）自动复用。

var BASE_URL = 'https://www.69shuba.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var CLASSES = [
  { id: '0', title: '全部分类' },
  { id: '1', title: '玄幻魔法' },
  { id: '2', title: '修真武侠' },
  { id: '3', title: '言情小说' },
  { id: '4', title: '历史军事' },
  { id: '5', title: '游戏竞技' },
  { id: '6', title: '科幻空间' },
  { id: '7', title: '悬疑惊悚' },
  { id: '8', title: '同人小说' },
  { id: '9', title: '都市小说' },
  { id: '10', title: '官场职场' },
  { id: '11', title: '穿越时空' },
  { id: '12', title: '青春校园' }
];

var RANKS = [
  { id: 'hot', title: '排行榜', path: '/novels/hot' },
  { id: 'male', title: '男生小说', path: '/novels/male' },
  { id: 'female', title: '女生小说', path: '/novels/female' },
  { id: 'full', title: '完本小说', path: '/novels/full' },
  { id: 'last', title: '最近更新', path: '/last.html' }
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
    .replace(/&amp;(?=(?:emsp|ensp|thinsp|nbsp|#(?:x[0-9a-f]+|[0-9]+));)/gi, '&')
    .replace(/&(?:nbsp|emsp|ensp|thinsp);/gi, ' ')
    .replace(/&#x([0-9a-f]+);/gi, function (_, n) { var c = parseInt(n, 16); return c <= 0x10ffff ? String.fromCodePoint(c) : ''; })
    .replace(/&#([0-9]+);/g, function (_, n) { var c = Number(n); return c <= 0x10ffff ? String.fromCodePoint(c) : ''; })
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
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
  var body = reply && reply.body ? String(reply.body) : '';
  if (status === 403 || status === 503 || status === 521 || /Just a moment|cf-chl-|请稍候/.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：69书吧在 Cloudflare 人机校验后面（HTTP ' + status + '），请在网页视图里过一次校验');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return body;
}

async function postForm(path, fields, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var body = Object.keys(fields).map(function (key) {
    return encodeURIComponent(key) + '=' + encodeURIComponent(fields[key]);
  }).join('&');
  var reply = await LumeSource.http.post(url, body, {
    headers: {
      'User-Agent': UA,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'text/html,*/*;q=0.8',
      Referer: referer || base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  var text = reply && reply.body ? String(reply.body) : '';
  if (status === 403 || status === 503 || status === 521 || /Just a moment|cf-chl-|请稍候/.test(text)) {
    throw new Error('NEED_WEBVIEW_VERIFY：69书吧的搜索也在 Cloudflare 人机校验后面（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('搜索失败：HTTP ' + status);
  return text;
}

function bookIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/book\/(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 列表：#article_list_content 里每个 li 一本书
function parseItems(html) {
  var text = String(html || '');
  var start = text.indexOf('article_list_content');
  var scope = start >= 0 ? text.slice(start) : text;
  var items = [];
  var seen = {};
  var blocks = scope.split('<a href="https://www.69shuba.com/book/');
  if (blocks.length < 2) blocks = scope.split('<a href="/book/');
  for (var i = 1; i < blocks.length; i++) {
    var seg = blocks[i].slice(0, 900);
    var idHit = /^(\d+)\.htm/.exec(seg);
    if (!idHit) continue;
    var id = idHit[1];
    if (seen[id]) continue;
    var img = /<img[^>]*src="([^"]+)"/i.exec(seg);
    var titleHit = /<h3>[\s\S]{0,200}?<a[^>]*>([\s\S]{1,80}?)<\/a>/i.exec(seg);
    var title = oneLine(titleHit ? titleHit[1] : '');
    if (!title) {
      var alt = /<img[^>]*alt="([^"]+)"/i.exec(seg);
      title = oneLine(alt ? alt[1] : '');
    }
    if (!title) continue;
    var author = /作者：\s*<a[^>]*>([\s\S]{0,40}?)<\/a>/i.exec(seg);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: img ? absolute(img[1]) : '',
      subtitle: author ? '作者：' + oneLine(author[1]) : '',
      mediaType: 'novel'
    });
  }
  return items;
}

function channelPath(categoryId) {
  var id = categoryId || '';
  if (/^rank-/.test(id)) {
    var key = id.slice(5);
    for (var i = 0; i < RANKS.length; i++) {
      if (RANKS[i].id === key) return RANKS[i].path;
    }
  }
  if (/^class-/.test(id)) return '/novels/class/' + id.slice(6) + '.htm';
  return '/novels/class/0.htm';
}

var LumeSource = {
  id: 'shuba_novel',
  name: '69书吧',
  version: '1.0.1',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://www.69shuba.com/favicon.ico',
  mirrors: ['https://www.69shuba.com'],

  async categories() {
    var list = [];
    for (var i = 0; i < CLASSES.length; i++) {
      list.push({ id: 'class-' + CLASSES[i].id, title: CLASSES[i].title });
    }
    for (var k = 0; k < RANKS.length; k++) {
      list.push({ id: 'rank-' + RANKS[k].id, title: RANKS[k].title });
    }
    return list;
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var boards = [];
    try {
      var latest = parseItems(await fetchHtml('/novels/class/0.htm')).slice(0, 12);
      if (latest.length) boards.push({ title: '全部分类', moreUrl: 'class-0', items: latest });
    } catch (error) {
      throw error;
    }
    try {
      var hot = parseItems(await fetchHtml('/novels/hot')).slice(0, 12);
      if (hot.length) boards.push({ title: '排行榜', moreUrl: 'rank-hot', items: hot });
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

    var html;
    if (keyword) {
      html = await postForm('/modules/article/search.php', { searchkey: keyword, submit: 'Search' });
    } else {
      html = await fetchHtml(channelPath(categoryId));
    }
    var items = parseItems(html);
    if (!items.length) {
      if (keyword) return { items: [], hasMore: false };
      if (page === 1) throw new Error('这个分类没有取到条目（' + channelPath(categoryId) + '，站点模板可能改了）');
    }
    // 分类/榜单页都是单页铺完（没有翻页控件）
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/book/' + id + '.htm');
    if (!html) return null;
    var h1 = /<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html);
    var title = oneLine(h1 ? h1[1] : '');
    if (!title) return null;
    var info = /bookinfo\s*=\s*\{([\s\S]{0,1200}?)\}/.exec(html);
    var fields = {};
    if (info) {
      var re = /(\w+)\s*:\s*'([^']*)'/g;
      var hit;
      while ((hit = re.exec(info[1])) !== null) fields[hit[1]] = hit[2];
    }
    var cover = /<img[^>]*src="([^"]*\/files\/article\/image\/[^"]+)"/i.exec(html);
    var intro = /<div class="intro">([\s\S]*?)<\/div>/i.exec(html) || /<meta\s+name="description"\s+content="([^"]*)"/i.exec(html);
    var lines = [];
    if (fields.author) lines.push('作者：' + fields.author);
    if (fields.sortName) lines.push('分类：' + fields.sortName);
    if (fields.tags) lines.push('标签：' + fields.tags.replace(/\|/g, ' ').trim());
    var introText = intro ? clean(intro[1]) : '';
    if (introText) lines.push('', introText);
    return {
      id: id,
      title: fields.articlename || title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: [fields.author || '', fields.sortName || ''].filter(Boolean).join(' · ') || '69书吧',
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return [];
    var html = await fetchHtml('/book/' + id + '/');
    var start = html.indexOf('id="catalog"');
    var scope = start >= 0 ? html.slice(start) : html;
    var out = [];
    var seen = {};
    var re = /href="(?:https?:\/\/[^"\/]*)?\/txt\/(\d+)\/(\d+)"[^>]*>([\s\S]{1,80}?)<\/a>/g;
    var hit;
    while ((hit = re.exec(scope)) !== null) {
      var cid = hit[2];
      if (seen[cid]) continue;
      seen[cid] = true;
      out.push({ id: hit[1] + '/' + cid, title: oneLine(hit[3]) || '第 ' + (out.length + 1) + ' 章' });
    }
    if (!out.length) throw new Error('目录里没有章节（书号 ' + id + '，可能要先过网页校验）');
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /(\d+)\/(\d+)/.exec(raw);
    var bookId = matched ? matched[1] : bookIdOf(args.id);
    var chapterId = matched ? matched[2] : '';
    if (!bookId || !chapterId) throw new Error('缺少章节 ID（应形如 书号/章节号）');

    var path = '/txt/' + bookId + '/' + chapterId;
    var html = await fetchHtml(path);
    var text = chapterText(html);
    if (!text) throw new Error('这一章没解析到正文（' + path + '）');
    var heading = /<div class="txtnav"[\s\S]{0,200}?<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html);
    return {
      kind: 'text',
      title: heading ? oneLine(heading[1]) : undefined,
      text: text
    };
  }
};

// 正文：.txtnav 里、#txtright 广告之后到 .contentadv（广告块）之前
function chapterText(html) {
  var text = String(html || '');
  var start = text.indexOf('class="txtnav"');
  if (start < 0) return '';
  var seg = text.slice(start);
  var right = seg.indexOf('id="txtright"');
  if (right >= 0) {
    var close = seg.indexOf('</div>', right);
    if (close > 0) seg = seg.slice(close + 6);
  }
  var end = seg.indexOf('<div class="contentadv"');
  if (end < 0) end = seg.indexOf('<div');
  if (end > 0) seg = seg.slice(0, end);
  seg = seg
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  var lines = decodeEntities(seg).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '').trim();
    if (!line) continue;
    out.push(line);
  }
  return out.join('\n');
}
