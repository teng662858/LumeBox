// LumeSource: {"id":"diyibanzhu_novel","name":"第一版主","version":"1.0.2","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.01bzw.us","https://www.111bz.cc","https://www.bz1111111.net"],"network":"direct","icon":"https://www.01bzw.us/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"第一版主（qula 模板小说站）。用户给的 bz1111111.net 与 diyibanzhu.app 在 Cloudflare 后面：bz1111111.net 是 managed challenge（本机所在网络连 challenges.cloudflare.com 都被断，浏览器也过不去），diyibanzhu.app 是 WAF 直接返回「Sorry, you have been blocked」。所以本源默认走可直连的同站镜像 01bzw.us（UTF-8，实测 200），另两个镜像 111bz.cc（GBK）与 bz1111111.net 按顺序备用。分类 /sort/{1-10}/{页码}/（玄幻/武侠/都市/历史/侦探/网游/科幻/恐怖/散文/辣文）；详情 /bookcv/{id}/ 的 og:novel:* 里有书名/作者/类别/状态；章节 /html/{p}/{书号}/{章节号}.html；正文在 div#content，站点把部分汉字换成 <img class=zi data-word=字> 做防采集，源里会还原。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（diyibanzhu.app）","url":"https://diyibanzhu.app/","description":"官方发布页；本机网络被 Cloudflare 拦住，手机数据网络通常能开"}]}
// LumeRuntime: javascript
//
// 站点：第一版主（qula 小说模板），主用镜像 https://www.01bzw.us
//
// 实测（2026-11-04）：
//   · bz1111111.net → Cloudflare managed challenge（「请稍候…」）；本机网络连
//     challenges.cloudflare.com 都被断开（Chrome 报 ERR_CONNECTION_CLOSED），过不去。
//   · diyibanzhu.app → Cloudflare WAF 直接回「Sorry, you have been blocked」（Ray a55486b5…-HKG）。
//   · 01bzw.us / 111bz.cc → 可直连 200，内容同站，所以源默认用 01bzw.us（UTF-8）。
//   · 分类  /sort/{1..10}/{page}/      玄幻小说/武侠小说/都市小说/历史小说/侦探小说/
//                                      网游小说/科幻小说/恐怖小说/散文小说/辣文小说
//          列表卡片 <div class="item"> → <a href="/bookcv/{id}/"><img … alt="书名"></a><dl><dt>…
//   · 详情  /bookcv/{id}/              <h1>书名</h1> + 作者/类别/状态 + 封面 + og:novel:* meta
//   · 目录  同一页的 /html/{p}/{书号}/{章节号}.html 链接（一本书 60+ 章，一次给全）
//   · 正文  /html/{p}/{书号}/{章节号}.html → <div class="content" id="content"><p>…
//          防采集：部分汉字被换成 <img class="zi" … data-word="交">，源里用 data-word/alt 还原
//   · 搜索  /search/?… 各种参数都回 0 条（站点搜索是前端脚本调的），所以关键字暂不实现

var MIRRORS = ['https://www.01bzw.us', 'https://www.111bz.cc', 'https://www.bz1111111.net'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

var SORTS = [
  { id: '1', title: '玄幻小说' },
  { id: '2', title: '武侠小说' },
  { id: '3', title: '都市小说' },
  { id: '4', title: '历史小说' },
  { id: '5', title: '侦探小说' },
  { id: '6', title: '网游小说' },
  { id: '7', title: '科幻小说' },
  { id: '8', title: '恐怖小说' },
  { id: '9', title: '散文小说' },
  { id: '10', title: '辣文小说' }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
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
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
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
  if (status === 403 || status === 503 || status === 521 || /Just a moment|cf-chl-|请稍候|Sorry, you have been blocked/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：第一版主当前镜像被 Cloudflare 挡了（HTTP ' + status + '），可在源设置里换成 01bzw.us');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return body;
}

function imageHeaders() { return { Referer: base() + '/', 'User-Agent': UA }; }
function coverUrl(value, id) {
  if (value) return absolute(value).replace(/^http:/i, 'https:');
  // Same canonical image layout as the site's own image cards.
  return 'https://www.dybzw.me/images/' + Math.floor(Number(id) / 1000) + '/' + id + '/' + id + 's.jpg';
}

function parseItems(html) {
  var text = String(html || '');
  var out = [];
  var seen = {};

  function push(id, title, cover, subtitle) {
    if (!id || !title || seen[id]) return;
    seen[id] = true;
    out.push({ id: id, title: title, cover: coverUrl(cover, id), coverHeaders: imageHeaders(), subtitle: subtitle || '', mediaType: 'novel' });
  }

  // 1) 大卡片：<div class="item"><div class="image"><a href="/bookcv/{id}/"><img …></a></div>
  //             <dl><dt><span>作者</span><a href="/bookcv/{id}/">书名</a></dt>…
  var cards = text.split('<div class="item">');
  for (var c = 1; c < cards.length; c++) {
    var card = cards[c].slice(0, 2000);
    var idHit = /\/bookcv\/(\d+)\//.exec(card);
    if (!idHit) continue;
    var img = /<img[^>]*src="([^"]+)"/i.exec(card);
    var dtHit = /<dt>([\s\S]{0,200}?)<\/dt>/i.exec(card);
    var dt = dtHit ? dtHit[1] : '';
    var nameHit = /<a[^>]*>([^<]{1,80})<\/a>/i.exec(dt);
    var title = clean(nameHit ? nameHit[1] : '') || clean(/<img[^>]*alt="([^"]*)"/i.exec(card) ? /<img[^>]*alt="([^"]*)"/i.exec(card)[1] : '');
    var authorHit = /<span>([^<]{1,24})<\/span>/i.exec(dt);
    push(idHit[1], title, img ? absolute(img[1]) : '', authorHit ? '作者：' + clean(authorHit[1]) : '');
  }

  // 2) 文字列表：<li><span class="s1">[分类]</span><span class="s2"><a href="/bookcv/{id}/">书名</a></span>…
  var rowRe = /<li[^>]*>[\s\S]{0,200}?<a href="\/bookcv\/(\d+)\/"[^>]*>([^<]{1,80})<\/a>/g;
  var row;
  while ((row = rowRe.exec(text)) !== null) {
    push(row[1], clean(row[2]), '', '');
  }

  return out;
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
  if (status === 403 || /Just a moment|cf-chl-|请稍候/i.test(text)) {
    throw new Error('NEED_WEBVIEW_VERIFY：第一版主的搜索接口被 Cloudflare 挡了（HTTP ' + status + '）');
  }
  return text;
}

// 搜索：qula 模板只认真宿主上的 POST /search/（01bzw.us 会 301 到 www.dybzw.me，GET 一律 0 条）
function parseSearch(html) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var re = /<li[^>]*>[\s\S]{0,300}?<span class="s1">([\s\S]{0,40}?)<\/span>[\s\S]{0,200}?<a href="\/bookcv\/(\d+)\/"[^>]*>([\s\S]{0,80}?)<\/a>[\s\S]{0,300}?<span class="s4">([\s\S]{0,40}?)<\/span>/g;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var id = hit[2];
    if (seen[id]) continue;
    var title = clean(hit[3]);
    if (!title) continue;
    seen[id] = true;
    out.push({
      id: id,
      title: title,
      cover: coverUrl('', id),
      coverHeaders: imageHeaders(),
      subtitle: [clean(hit[1]).replace(/^\[|\]$/g, ''), hit[4] ? '作者：' + clean(hit[4]) : ''].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return out;
}

var LumeSource = {
  id: 'diyibanzhu_novel',
  name: '第一版主',
  version: '1.0.2',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://www.01bzw.us/favicon.ico',
  mirrors: MIRRORS,

  async categories() {
    return SORTS.map(function (item) {
      return { id: 'sort-' + item.id, title: item.title };
    });
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var boards = [];
    for (var i = 0; i < SORTS.length && boards.length < 3; i++) {
      var items = parseItems(await fetchHtml('/sort/' + SORTS[i].id + '/1/')).slice(0, 12);
      if (items.length) boards.push({ title: SORTS[i].title, moreUrl: 'sort-' + SORTS[i].id, items: items });
    }
    if (!boards.length) throw new Error('首页没解析出条目（站点结构可能变了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    if (keyword) {
      var html = await postForm('https://www.dybzw.me/search/', { searchkey: keyword, Submit: '搜索' }, base() + '/');
      var found = parseSearch(html);
      return { items: found, hasMore: false };
    }
    var sortId = /^sort-(\d+)/.exec(categoryId);
    var sid = sortId ? sortId[1] : '1';
    var html = await fetchHtml('/sort/' + sid + '/' + page + '/');
    var items = parseItems(html);
    if (!items.length && page === 1) throw new Error('这个分类没有取到条目（sort ' + sid + '）');
    var hasMore = new RegExp('/sort/' + sid + '/' + (page + 1) + '/').test(html);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return null;
    var html = await fetchHtml('/bookcv/' + id + '/');
    var meta = function (name) {
      var re = new RegExp('<meta\\s+property="og:novel:' + name + '"\\s+content="([^"]*)"', 'i');
      var hit = re.exec(html) || new RegExp('<meta\\s+content="([^"]*)"\\s+property="og:novel:' + name + '"', 'i').exec(html);
      return hit ? decodeEntities(hit[1]) : '';
    };
    var h1 = /<div class="info"[\s\S]{0,400}?<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html) || /<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html);
    var title = meta('book_name') || clean(h1 ? h1[1] : '');
    if (!title) return null;
    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html);
    var desc = /<meta\s+property="og:description"\s+content="([^"]*)"/i.exec(html);
    var lines = [];
    if (meta('author')) lines.push('作者：' + meta('author'));
    if (meta('category')) lines.push('分类：' + meta('category'));
    if (meta('status')) lines.push('状态：' + meta('status'));
    if (meta('update_time')) lines.push('更新：' + meta('update_time'));
    if (meta('lastest_chapter_name')) lines.push('最新：' + meta('lastest_chapter_name'));
    var intro = desc ? clean(desc[1]) : '';
    if (intro) lines.push('', intro);
    return {
      id: id,
      title: title,
      cover: coverUrl(cover ? cover[1] : '', id),
      coverHeaders: imageHeaders(),
      subtitle: [meta('author'), meta('category')].filter(Boolean).join(' · ') || '第一版主',
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return [];
    var html = await fetchHtml('/bookcv/' + id + '/');
    var out = [];
    var seen = {};
    var re = /<a[^>]+href="(\/html\/\d+\/\d+\/(\d+)\.html)"[^>]*>([\s\S]{0,90}?)<\/a>/g;
    var hit;
    while ((hit = re.exec(html)) !== null) {
      var path = hit[1];
      var cid = Number(hit[2]);
      if (seen[path]) continue;
      var name = clean(hit[3]);
      if (!name) continue;
      // 「开始阅读」「加入书架」这类按钮不是章节
      if (/开始阅读|加入书架|直达底部|投推荐票|章节目录/.test(name)) continue;
      seen[path] = true;
      out.push({ id: path, title: name, sort: cid });
    }
    if (!out.length) throw new Error('目录里没有章节（书号 ' + id + '）');
    out.sort(function (a, b) { return a.sort - b.sort; });
    return out.map(function (row) { return { id: row.id, title: row.title }; });
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /\/html\/(\d+)\/(\d+)\/(\d+)\.html/.exec(path);
    if (!matched) throw new Error('缺少章节路径（应形如 /html/p/书号/章节号.html）');
    var url = '/html/' + matched[1] + '/' + matched[2] + '/' + matched[3] + '.html';
    var html = await fetchHtml(url);
    var text = chapterText(html);
    if (!text) throw new Error('这一章没解析到正文（' + url + '）');
    var heading = /<div class="bookname"[^>]*>[\s\S]{0,120}?<h1[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html) ||
      /<h1[^>]*class="[^"]*(?:title|bookname)[^"]*"[^>]*>([\s\S]{0,120}?)<\/h1>/i.exec(html);
    var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/i.exec(html);
    var title = heading ? clean(heading[1]) : (ogTitle ? clean(ogTitle[1]).replace(/[_-].*$/, '') : '');
    return { kind: 'text', title: title || undefined, text: text };
  }
};

// 正文：div#content 里，<p> 分段；防采集的 <img class="zi" data-word="字"> 用 data-word/alt 还原
function chapterText(html) {
  var text = String(html || '');
  var start = text.indexOf('id="content"');
  if (start < 0) start = text.indexOf("id='content'");
  if (start < 0) return '';
  var seg = text.slice(text.indexOf('>', start) + 1);
  var end = seg.indexOf('<div class="bottem');
  if (end < 0) end = seg.indexOf('<div class="footer');
  if (end > 0) seg = seg.slice(0, end);

  seg = seg
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    // 防采集字图：data-word / alt 就是被换掉的汉字
    .replace(/<img[^>]*class="[^"]*\bzi\b[^"]*"[^>]*>/gi, function (tag) {
      var word = /data-word="([^"]*)"/i.exec(tag) || /alt="([^"]*)"/i.exec(tag);
      return word ? word[1] : '';
    })
    .replace(/<img[^>]*>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<\/div>/gi, '\n')
    .replace(/<[^>]+>/g, '');

  var lines = decodeEntities(seg).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
    if (!line) continue;
    // 站点在正文里插的广告（如「笔趣Ω 『 阁ΔＢＱgXsw．ＣoM」「发布邮箱…地址发布页…」）
    if (/笔趣|ＢＱ|bqgxsw|阁Δ/i.test(line) && line.length < 40) continue;
    if (/发布邮箱|地址发布页|ＧＭＡＩＬ|Ｌｔｘ|Ltxsd/i.test(line)) continue;
    out.push(line);
  }
  return out.join('\n');
}
