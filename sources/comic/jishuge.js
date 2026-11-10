// LumeSource: {"id":"jishuge_novel","name":"集书阁","version":"1.0.1","category":"comic","contentCategory":"adult","network":"direct","mirrors":["https://xn--x-ny6ap04bvzfcy2d.com","https://www.xn--1jqvh729avzfcy2d8ummib.com","https://xn--x-081b421a.com","https://xchengren.com"],"icon":"https://xn--x-ny6ap04bvzfcy2d.com/assets/build/favicon.ae6ab38e3ee5dc0c.svg","settingsApiVersion":2,"settings":[{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 成人小说站（短篇 10400 部 + 长篇 203 部，免登录、无封面）。站点 2026-11 已升级成「X小说 / x文学」新前端：旧 集书阁.com 的阅读页会 301 到新站，本源直接走新站域名（x成人小说.com / 集书阁成人小说.com / x文学.com / xchengren.com，都是站内「收藏回家」公布的永久域名）。"}],"mediaType":"novel"}
// LumeRuntime: javascript
//
// 站点：集书阁（集书阁.com）。2026-11-10 实测：旧域的首页/列表还是旧模板，
// 但**阅读页会 301 到新站**（X小说 / x文学 前端），旧域 canonical 也指向
// www.集书阁成人小说.com。所以本源直接按新站做，避免旧模板 + 跳转混用。
//
// 实测（2026-11-10，新站 x成人小说.com，旧站跳转后同内容）：
//   · 列表   /books、/books/page/N（20 部/页，共 10603 部）
//            /category/{1..52}、/category/{id}/page/N
//            分类：短篇情色小说 10400 部（520 页）、长篇情色小说 203 部 + 50 个题材
//   · 搜索   /search?q=<词>&page=N（实测「母子」57 部 3 页、「白洁」2 条）
//   · 卡片   <li class="book-item">：h2>a 标题（短篇直链 /read/<hash>/<章页id>，
//            长篇链 /book/<hash>）+ 分类 + 「N 章」+ 摘要；**全站没有封面**
//   · 详情   /book/<hash>：h1.book-heading + 「分类 · 章节目录」+ chapter-grid 全目录
//   · 正文   /read/<hash>/<章页id>：#bookcontent 的 <p> 段落。正文里偶尔夹一处
//            <span class="brand-mark">更多阅读内容请见x文学.com…</span>，源里整段丢掉
//   · 站点无排序/筛选、免登录；页面直连 200（Cloudflare 只注入脚本，不拦请求）
//
// 站内 ID：b:<书 hash>；章节 ID 用站方章页 id（数字）。两个域名的列表/详情/正文
// 实测同一套 hash 与内容。

var MIRRORS = [
  'https://www.xn--1jqvh729avzfcy2d8ummib.com',
  'https://xn--x-ny6ap04bvzfcy2d.com',
  'https://xn--x-081b421a.com',
  'https://xchengren.com',
];

var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

// 站方分类导航（/books 页面里 53 个链接，id 与站内 /category/<id> 一致）
var CATEGORIES = [
  { id: 'all', title: '全部', path: '/books' },
  { id: '1', title: '短篇情色小说', path: '/category/1' },
  { id: '2', title: '长篇情色小说', path: '/category/2' },
  { id: '3', title: '情色文学', path: '/category/3' },
  { id: '4', title: '短篇小说', path: '/category/4' },
  { id: '5', title: '通俗小说', path: '/category/5' },
  { id: '6', title: '校园小说', path: '/category/6' },
  { id: '7', title: '乡村小说', path: '/category/7' },
  { id: '8', title: '都市小说', path: '/category/8' },
  { id: '9', title: '医生小说', path: '/category/9' },
  { id: '10', title: '武侠小说', path: '/category/10' },
  { id: '11', title: '奇幻小说', path: '/category/11' },
  { id: '12', title: '穿越小说', path: '/category/12' },
  { id: '13', title: '黑暗小说', path: '/category/13' },
  { id: '14', title: '日本小说', path: '/category/14' },
  { id: '15', title: '现代情色', path: '/category/15' },
  { id: '16', title: '日本情色', path: '/category/16' },
  { id: '17', title: '西洋情色', path: '/category/17' },
  { id: '18', title: '伴侣交换', path: '/category/18' },
  { id: '19', title: '武侠情色', path: '/category/19' },
  { id: '20', title: '奇幻科幻', path: '/category/20' },
  { id: '21', title: '家庭乱伦', path: '/category/21' },
  { id: '22', title: '性爱调教', path: '/category/22' },
  { id: '23', title: '粗野性交', path: '/category/23' },
  { id: '24', title: '多人群交', path: '/category/24' },
  { id: '25', title: '教师学生', path: '/category/25' },
  { id: '26', title: '古典情色', path: '/category/26' },
  { id: '27', title: '历史情色', path: '/category/27' },
  { id: '28', title: '同性情色', path: '/category/28' },
  { id: '29', title: '都市生活', path: '/category/29' },
  { id: '30', title: '乡间记趣', path: '/category/30' },
  { id: '31', title: '疯狂暴露', path: '/category/31' },
  { id: '32', title: '午夜怪谈', path: '/category/32' },
  { id: '33', title: '游戏乐园', path: '/category/33' },
  { id: '34', title: '医生护士', path: '/category/34' },
  { id: '35', title: '奇遇物语', path: '/category/35' },
  { id: '36', title: '左邻右舍', path: '/category/36' },
  { id: '37', title: '同事之间', path: '/category/37' },
  { id: '38', title: '旅游纪事', path: '/category/38' },
  { id: '39', title: '纯洁恋情', path: '/category/39' },
  { id: '40', title: '明星系列', path: '/category/40' },
  { id: '41', title: '意外收获', path: '/category/41' },
  { id: '42', title: '忘年之乐', path: '/category/42' },
  { id: '43', title: '另类其他', path: '/category/43' },
  { id: '44', title: '知识技巧', path: '/category/44' },
  { id: '45', title: '情欲性爱', path: '/category/45' },
  { id: '46', title: '经典激情', path: '/category/46' },
  { id: '47', title: '近亲乱伦', path: '/category/47' },
  { id: '48', title: '人妻美妇', path: '/category/48' },
  { id: '49', title: '学生校园', path: '/category/49' },
  { id: '50', title: '职业制服', path: '/category/50' },
  { id: '51', title: '粗暴性爱', path: '/category/51' },
  { id: '52', title: '情色武侠', path: '/category/52' },
];

function jgBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
}

function jgHeaders(extra) {
  var headers = { 'User-Agent': UA, Referer: jgBase() + '/' };
  if (extra) {
    for (var key in extra) headers[key] = extra[key];
  }
  return headers;
}

async function jgGet(path) {
  var response = await LumeSource.http.get(jgBase() + path, {
    headers: jgHeaders({ Accept: 'text/html,application/xhtml+xml' }),
  });
  if (response.status === 403 || response.status === 503 || response.status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：集书阁返回人机校验（HTTP ' + response.status + '），可在网页视图里过一次校验');
  }
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('集书阁暂不可用（HTTP ' + response.status + '）');
  return response.body;
}

function jgText(value) {
  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  return String(value == null ? '' : value)
    .replace(/<[^>]*>/g, '')
    .replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, function (raw, key) {
      if (key.charAt(0) !== '#') return entities[key.toLowerCase()] || raw;
      var code = key.charAt(1).toLowerCase() === 'x'
        ? parseInt(key.slice(2), 16)
        : Number(key.slice(1));
      return code <= 0x10ffff ? String.fromCodePoint(code) : raw;
    })
    .replace(/\s+/g, ' ')
    .trim();
}

function jgParseId(raw) {
  var match = /^b:([0-9a-f]{32})$/i.exec(String(raw == null ? '' : raw).trim());
  return match ? { hash: match[1].toLowerCase() } : null;
}

function jgCategoryOf(categoryId) {
  var id = String(categoryId || 'all');
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i];
  }
  return CATEGORIES[0];
}

function jgHasNext(html) {
  // 末页的「下一页」是 <span aria-disabled="true">，只有还能翻时才是 <a>
  return /<a[^>]*>\s*下一页\s*<\/a>/.test(String(html || ''));
}

// 首页板块用的是紧凑链接（不是 book-item 卡片）：
// <li><a href="/read/<hash>/<章页id>"><span class="book-category">[分类]</span> 标题</a></li>
function jgHomeLinks(html) {
  var text = String(html || '');
  var pattern = /<li>\s*<a href="\/(?:read|book)\/([0-9a-f]{32})(?:\/(\d+))?">([\s\S]*?)<\/a>\s*<\/li>/g;
  var items = [];
  var seen = {};
  var matched;
  while ((matched = pattern.exec(text)) !== null) {
    var hash = matched[1].toLowerCase();
    if (seen[hash]) continue;
    seen[hash] = true;
    var inner = matched[3];
    var category = /<span class="book-category">\s*\[?([^\]]*?)\]?\s*<\/span>/.exec(inner);
    var title = jgText(inner.replace(/<span class="book-category">[\s\S]*?<\/span>/g, ''));
    if (!title) continue;
    items.push({
      id: 'b:' + hash,
      title: title,
      subtitle: category ? jgText(category[1]) : undefined,
      mediaType: 'novel',
    });
  }
  return items;
}

// 列表卡片：短篇直链 /read/<hash>/<章页id>，长篇链 /book/<hash>，统一收成 b:<hash>。
function jgCards(html) {
  var text = String(html || '');
  var blocks = text.split('<li class="book-item">').slice(1);
  var items = [];
  var seen = {};
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i].split('</li>')[0];
    var href = /<h2>\s*<a href="\/(?:read|book)\/([0-9a-f]{32})(?:\/(\d+))?">([\s\S]*?)<\/a>/.exec(block);
    if (!href) continue;
    var hash = href[1].toLowerCase();
    if (seen[hash]) continue;
    seen[hash] = true;
    var title = jgText(href[3]);
    if (!title) continue;
    var meta = /<p class="book-meta">\s*<a[^>]*>([\s\S]*?)<\/a>\s*<span>([\s\S]*?)<\/span>/.exec(block);
    var category = meta ? jgText(meta[1]) : '';
    var chapters = meta ? jgText(meta[2]) : '';
    var subtitle = category && chapters ? category + ' · ' + chapters : (category || chapters);
    items.push({
      id: 'b:' + hash,
      title: title,
      subtitle: subtitle || undefined,
      mediaType: 'novel',
    });
  }
  return items;
}

function jgBookInfo(html) {
  var text = String(html || '');
  var heading = /<h1 class="book-heading">([\s\S]*?)<\/h1>/.exec(text);
  var title = jgText(heading ? heading[1] : '');
  if (!title) return null;
  var desc = /<p class="book-description">([\s\S]*?)<\/p>/.exec(text);
  var label = jgText(desc ? desc[1] : '').replace(/·\s*章节目录\s*$/, '').trim();
  var count = /<span class="muted">\s*(\d+)\s*章\s*<\/span>/.exec(text);
  return {
    title: title,
    category: label,
    chapters: count ? Number(count[1]) : 0,
  };
}

function jgChapters(html, bookTitle) {
  var text = String(html || '');
  var grid = /<ul class="chapter-grid">([\s\S]*?)<\/ul>/.exec(text);
  if (!grid) return [];
  var pattern = /<a href="\/read\/[0-9a-f]{32}\/(\d+)">([\s\S]*?)<\/a>/g;
  var items = [];
  var seen = {};
  var matched;
  while ((matched = pattern.exec(grid[1])) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    seen[id] = true;
    var title = jgText(matched[2]);
    if (bookTitle && title.indexOf(bookTitle) === 0) {
      title = title.slice(bookTitle.length).replace(/^[\s·:：-]+/, '').trim();
    }
    if (!title || title === bookTitle) title = '正文';
    items.push({ id: id, title: title });
  }
  return items;
}

// 正文：#bookcontent 里的 <p>；去掉品牌水印 span 与残留的「x文学.com」提示。
function jgContentText(html) {
  var text = String(html || '');
  var at = text.search(/id="bookcontent"/);
  if (at < 0) return '';
  var start = text.indexOf('>', at);
  if (start < 0) return '';
  start += 1;
  var end = text.indexOf('</div>', start);
  var block = end > start ? text.slice(start, end) : text.slice(start);

  block = block.replace(/<span[^>]*class="[^"]*brand-mark[^"]*"[^>]*>[\s\S]*?<\/span>/gi, '');
  block = block.replace(/<br\s*\/?>/gi, '\n');
  block = block.replace(/<\/p\s*>/gi, '\n');
  block = block.replace(/<[^>]*>/g, '');

  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  block = block.replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, function (raw, key) {
    if (key.charAt(0) !== '#') return entities[key.toLowerCase()] || raw;
    var code = key.charAt(1).toLowerCase() === 'x'
      ? parseInt(key.slice(2), 16)
      : Number(key.slice(1));
    return code <= 0x10ffff ? String.fromCodePoint(code) : raw;
  });

  block = block.replace(/更多阅读内容请见[^\s。，]*[。，]?[^\n]*/g, '');
  block = block.replace(/[ \t\u3000]+/g, ' ');
  block = block.replace(/\n[ \t]+/g, '\n');
  block = block.replace(/\n{3,}/g, '\n\n');
  return block.trim();
}

var LumeSource = {
  categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) {
      list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    }
    return list;
  },

  async home() {
    var html = await jgGet('/');
    if (html == null) throw new Error('集书阁首页打不开');
    var text = String(html);
    var sections = [];
    var pattern = /<section class="panel">([\s\S]*?)<\/section>/g;
    var matched;
    while ((matched = pattern.exec(text)) !== null) {
      var block = matched[1];
      var heading = /<h[12][^>]*class="section-title"[^>]*>([\s\S]*?)<\/h[12]>/.exec(block);
      var title = jgText(heading ? heading[1] : '');
      if (!title) continue;
      var items = jgCards(block);
      if (!items.length) items = jgHomeLinks(block);
      if (!items.length) continue;
      var moreUrl;
      if (title.indexOf('短篇') === 0) moreUrl = '1';
      else if (title.indexOf('长篇') === 0) moreUrl = '2';
      sections.push({ title: title, moreUrl: moreUrl, items: items });
    }
    if (!sections.length) throw new Error('集书阁首页没解析出内容（站方可能改版）');
    return sections;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Math.floor(Number(args.page) || 1));
    var keyword = String(args.keyword || '').trim();
    var path;

    if (keyword) {
      path = '/search?q=' + encodeURIComponent(keyword) + (page > 1 ? '&page=' + page : '');
    } else {
      var category = jgCategoryOf(args.categoryId);
      path = category.path + (page > 1 ? '/page/' + page : '');
    }

    var html = await jgGet(path);
    if (html == null) return { items: [], hasMore: false };
    var items = jgCards(html);
    if (!items.length && page === 1 && !keyword) {
      throw new Error('这个分类没解析出条目（' + jgCategoryOf(args.categoryId).title + '），站方可能改版');
    }
    return { items: items, hasMore: items.length > 0 ? jgHasNext(html) : false };
  },

  async detail(argument) {
    var target = jgParseId(argument && argument.id);
    if (!target) return null;
    var html = await jgGet('/book/' + target.hash);
    if (html == null) return null;
    var info = jgBookInfo(html);
    if (!info) return null;

    var lines = [];
    if (info.category) lines.push('分类：' + info.category);
    lines.push('共 ' + (info.chapters || '若干') + ' 章');
    lines.push('站点：X小说 / x文学（集书阁新前端）');
    return {
      id: 'b:' + target.hash,
      title: info.title,
      subtitle: (info.category ? info.category + ' · ' : '') + '共 ' + (info.chapters || '若干') + ' 章',
      description: lines.join('\n'),
      mediaType: 'novel',
    };
  },

  async chapters(argument) {
    var target = jgParseId(argument && argument.id);
    if (!target) return [];
    var html = await jgGet('/book/' + target.hash);
    if (html == null) return [];
    var info = jgBookInfo(html);
    var list = jgChapters(html, info ? info.title : '');
    if (list.length) return list;

    var start = /<a class="button"[^>]*href="\/read\/[0-9a-f]{32}\/(\d+)"/.exec(html);
    return start ? [{ id: start[1], title: '正文' }] : [];
  },

  async content(argument) {
    var args = argument || {};
    var target = jgParseId(args.id);
    if (!target) throw new Error('缺少书籍 ID（应形如 b:<hash>）');

    var chapterId = /^\d+$/.test(String(args.chapterId == null ? '' : args.chapterId))
      ? String(args.chapterId)
      : '';

    if (!chapterId) {
      var bookHtml = await jgGet('/book/' + target.hash);
      if (bookHtml == null) throw new Error('这本书不存在或已下架');
      var info = jgBookInfo(bookHtml);
      var list = jgChapters(bookHtml, info ? info.title : '');
      if (!list.length) throw new Error('这本书没有章节');
      chapterId = list[0].id;
    }

    var html = await jgGet('/read/' + target.hash + '/' + chapterId);
    if (html == null) throw new Error('这一章不存在或已下架');
    var text = jgContentText(html);
    if (!text || text.length < 20) {
      throw new Error('这一章没解析出正文（可能被站方改了结构）');
    }
    return { kind: 'text', text: text };
  },
};
