// LumeSource: {"id":"book18_novel","name":"色文網","version":"1.0.0","category":"comic","contentCategory":"adult","mediaType":"novel","network":"direct","mirrors":["https://www.book18.org"],"icon":"https://www.book18.org/logo.png","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"note","type":"info","title":"站点说明","description":"18+ 繁体成人小说站（色文網）。正文默认取站方的简体版本 /zh-hans/，源里再统一出处；長篇按「卷」给章节（一卷内含多节，正文很长），短篇一条即一篇。站点没有可用的封面图（og:image 只有站标），列表按标题展示。"}]}
// LumeRuntime: javascript
//
// 站点：色文網 book18.org（Yii2 模板），成人小说站，繁简双语。
//
// 实测（2026-11-09）：
//   · 長篇列表   /?sort=modified|hits|views|score|likes&page=N&per-page=50
//               卡片就是 <li class="list-group-item"><a href="/chapters/<书名>">书名</a>
//   · 分类列表   /category/{id}?page=N     100 条/页，条目是 <a href="/article/{id}">
//               （分类页里全是**短篇**；分類名见 categories，总数上万）
//   · 搜索       /?q=<关键词>&page=N       命中長篇书名（实测「母子」50 条/页、可翻页）
//   · 详情       /chapters/<书名>          页内 <a href="/<数字>">卷名(章节范围)作者</a>
//                —— 一卷 = 一章，正文一次性给全（实测单卷 18 万字量级）
//   · 正文       /zh-hans/<卷号> 或 /zh-hans/article/<id>
//               <div id="content"><p>…</p>…</div>，段尾夹着 <span class="d-none">book18.org</span>
//               防采集水印，源里整段丢掉；正文后面紧跟 <div id="_links"> 广告位，切掉。
//   · 站方没有真实封面（og:image 是 logo.png），列表只用标题，不编造图。
//
// 已知坑：繁简两个 URL 前缀（/zh-hans/）**同一内容**，源统一走简体；如果哪天简体页
// 404，自动退回繁体原文（源里做了兜底）。

var MIRRORS = ['https://www.book18.org'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';
var PAGE_SIZE = 50;

// 長篇排序入口（站方首页的按钮组）
var SORTS = [
  { id: 'latest', title: '最新長篇', query: 'sort=modified' },
  { id: 'hits', title: '最多', query: 'sort=hits' },
  { id: 'views', title: '最火', query: 'sort=views' },
  { id: 'score', title: '推薦', query: 'sort=score' },
];

// 短篇分类（站方侧边栏；均已实测 200 且条目为 /article/<id>）
var CATEGORIES = [
  { id: 'cat_15', title: '都市激情' },
  { id: 'cat_6', title: '家庭亂倫' },
  { id: 'cat_18', title: '人妻交換' },
  { id: 'cat_17', title: '另類小說' },
  { id: 'cat_16', title: '校園春色' },
  { id: 'cat_4', title: '學生校園' },
  { id: 'cat_23', title: '亂倫文學' },
  { id: 'cat_11', title: '人妻熟女' },
  { id: 'cat_24', title: '短篇文學' },
];

function b18Base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
}

function b18Headers(extra) {
  var headers = { 'User-Agent': UA, Referer: b18Base() + '/' };
  if (extra) {
    for (var key in extra) headers[key] = extra[key];
  }
  return headers;
}

async function b18Get(path) {
  var response = await LumeSource.http.get(b18Base() + path, {
    headers: b18Headers({ Accept: 'text/html,application/xhtml+xml' }),
  });
  if (response.status === 403 || response.status === 503) {
    throw new Error('色文網返回人机校验（HTTP ' + response.status + '），稍后重试');
  }
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('色文網暂不可用（HTTP ' + response.status + '）');
  return response.body;
}

function b18Text(value) {
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

// 列表卡片：長篇是 /chapters/<书名>，短篇是 /article/<id>
var ITEM_RE = /<li class="list-group-item[^"]*">\s*<a href="(\/(?:chapters\/[^"]+|article\/\d+))"[^>]*>([\s\S]*?)<\/a>/g;

function b18Items(html) {
  var items = [];
  var seen = {};
  ITEM_RE.lastIndex = 0;
  var match;
  while ((match = ITEM_RE.exec(String(html || '')))) {
    var id = match[1].replace(/^\//, '');
    if (seen[id]) continue;
    var title = b18Text(match[2]);
    if (!title) continue;
    seen[id] = true;
    items.push({ id: id, title: title });
  }
  return items;
}

function b18HasMore(html) {
  return /class="page-item next"(?! disabled)/.test(String(html || ''));
}

async function b18ListPage(path) {
  var html = await b18Get(path);
  if (html == null) return { items: [], hasMore: false };
  return { items: b18Items(html), hasMore: b18HasMore(html) };
}

function b18Query(params) {
  var parts = [];
  for (var key in params) {
    if (params[key] == null || params[key] === '') continue;
    parts.push(key + '=' + encodeURIComponent(params[key]));
  }
  return parts.length ? '?' + parts.join('&') : '';
}

// 正文：切出 id="content" 到广告位 <div id="_links"> 之间，按 <p> 分段
function b18Body(html) {
  var text = String(html || '');
  var start = text.indexOf('id="content"');
  if (start < 0) return '';
  var end = text.indexOf('<div id="_links"', start);
  var segment = end > start ? text.slice(start, end) : text.slice(start);
  segment = segment.replace(/<span class="d-none">[\s\S]*?<\/span>/gi, '');
  var paragraphs = segment.split(/<p[^>]*>/i).slice(1);
  var lines = [];
  for (var i = 0; i < paragraphs.length; i++) {
    var raw = paragraphs[i].split(/<\/p>/i)[0];
    var line = b18Text(raw.replace(/<br\s*\/?>/gi, '\n'));
    if (line) lines.push(line);
  }
  return lines.join('\n\n');
}

// 简体优先，404 时退回繁体
async function b18Page(path) {
  var html = await b18Get('/zh-hans/' + path);
  if (html != null) return html;
  return b18Get('/' + path);
}

var LumeSource = {
  categories() {
    var list = [];
    for (var i = 0; i < SORTS.length; i++) {
      list.push({ id: SORTS[i].id, title: SORTS[i].title });
    }
    for (var j = 0; j < CATEGORIES.length; j++) {
      list.push({ id: CATEGORIES[j].id, title: '短篇 · ' + CATEGORIES[j].title });
    }
    return list;
  },

  async list({ categoryId, page, keyword } = {}) {
    var currentPage = Math.max(1, Math.floor(Number(page) || 1));
    var query = String(keyword || '').trim();
    var paging = { page: currentPage, 'per-page': PAGE_SIZE };
    if (query) {
      paging.q = query;
      return b18ListPage('/' + b18Query(paging));
    }
    var id = String(categoryId || 'latest');
    if (id.indexOf('cat_') === 0) {
      return b18ListPage('/category/' + id.slice(4) + b18Query(paging));
    }
    for (var i = 0; i < SORTS.length; i++) {
      if (SORTS[i].id !== id) continue;
      var params = { page: currentPage, 'per-page': PAGE_SIZE };
      var sortKey = SORTS[i].query.split('=')[0];
      var sortValue = SORTS[i].query.split('=')[1];
      params[sortKey] = sortValue;
      return b18ListPage('/' + b18Query(params));
    }
    return b18ListPage('/' + b18Query(paging));
  },

  async detail({ id } = {}) {
    var path = String(id || '').replace(/^\/+/, '');
    if (!path) return null;
    var html = await b18Page(path);
    if (html == null) return null;
    var title = /<title>([\s\S]*?)<\/title>/i.exec(html);
    var name = b18Text(title ? title[1] : '').replace(/\s*-\s*(情色|成人|色情)[^-]*$/, '').trim();
    if (!name) return null;
    var groups = b18Items(html).filter(function (item) {
      return /^chapters\//.test(item.id) || /^article\//.test(item.id);
    });
    var parts = [];
    if (/^chapters\//.test(path)) parts.push(groups.length ? groups.length + ' 卷' : '長篇');
    else parts.push('短篇');
    return {
      id: id,
      title: name,
      subtitle: parts.join(' · '),
      description: name + ' · 色文網（18+ 成人小说）',
    };
  },

  async chapters({ id } = {}) {
    var path = String(id || '').replace(/^\/+/, '');
    if (!path) return [];
    if (!/^chapters\//.test(path)) {
      // 短篇：一条即一篇
      return [{ id: path, title: '正文' }];
    }
    // 目录只在**繁体**书页里给：/zh-hans/chapters/<书名> 是简体正文入口，
    // 它不渲染卷列表（实测两个书页：繁体 12 条卷链接，简体 0 条）。
    var html = await b18Get('/' + path);
    if (html == null) html = await b18Page(path);
    if (html == null) return [];
    var chapters = [];
    var seen = {};
    var link = /<li class="list-group-item[^"]*">\s*<a href="\/?(\d{4,})"[^>]*>([\s\S]*?)<\/a>/g;
    var match;
    while ((match = link.exec(html))) {
      var chapterId = match[1];
      if (seen[chapterId]) continue;
      seen[chapterId] = true;
      chapters.push({ id: chapterId, title: b18Text(match[2]) || ('第 ' + chapterId + ' 卷') });
    }
    return chapters;
  },

  async content({ id, chapterId } = {}) {
    var path = String(chapterId || id || '').replace(/^\/+/, '');
    if (!path) throw new Error('缺少章节地址');
    var html = await b18Page(path);
    if (html == null) throw new Error('这一章打不开了');
    var text = b18Body(html);
    if (!text) throw new Error('这一章没有正文（站点结构可能变了）');
    var title = /<title>([\s\S]*?)<\/title>/i.exec(html);
    return {
      kind: 'text',
      title: b18Text(title ? title[1] : '').replace(/\s*-\s*(情色|成人|色情)[^-]*$/, '').trim() || undefined,
      text: text,
    };
  },
};
