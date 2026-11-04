// LumeSource: {"id":"jmcomic_novel","name":"禁漫天堂 · JM文庫","version":"1.0.0","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://18comic.ink","https://18comic.vip","https://jmcomic.me"],"network":"direct","icon":"https://18comic.ink/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"禁漫天堂的 JM文庫 → 禁漫小說 频道（18comic.ink 实测可直连，18comic.vip / jmcomic.me 走 Cloudflare 挑战，源里抛 NEED_WEBVIEW_VERIFY 时换镜像即可）。列表 /novels?o={mr|mv|mp|tf}&t={a|t|w|m}（单页 78 部，站点没有翻页控件）；搜索 /search/novels?search_query=；详情 /novel/{id}/；章节 /novelchapters/{n}；正文在 #ncc1 与 #ncc2 两个 .novel-content 里（纯 <p>/<br> 段落，实测无付费墙；个别章节页有「金幣購買」弹窗，但正文仍照常下发）。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（jmcomictt.site）","url":"https://jmcomictt.site/","description":"官方发布页：给当前域名与 APP 下载"}]}
// LumeRuntime: javascript
//
// 站点：禁漫天堂（18comic）JM文庫 → 禁漫小說。交付形态：文字小说（mediaType:'novel'，content 返回 kind:'text'）。
//
// 结构（2026-11-04 用 18comic.ink 实测，.vip/.me 均被 CF 挑战）：
//   · 列表   /novels?o=mr|mv|mp|tf（排序）+ &t=a|t|w|m（时间）；单页 78 部，没有 ?page=
//   · 卡片   <div class="thumb-overlay-albums"><a href="/novel/{id}/{slug}">
//            <img data-original=".../media/novels/{id}_tmb.jpg" title="[作者] 标题 | 原名">
//   · 详情   /novel/{id}/   h1 = 「[作者] 标题 | 原名」，og:image = 封面
//   · 章节   /novelchapters/{n}（详情页里列出；正文页有上一章/下一章）
//   · 正文   <div id="ncc1" class="novel-content"> … </div><div id="ncc2" class="novel-content"> … </div>
//            （分两栏塞正文，`<br />` 分行；实测第 1 章两栏合计 4000+ 字，未登录可读）

var BASE_URL = 'https://18comic.ink';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var SORTS = [
  { id: 'mr', title: '最新' },
  { id: 'mv', title: '人气' },
  { id: 'mp', title: '最多图片' },
  { id: 'tf', title: '最多点赞' }
];

var TIMES = [
  { id: 'all', title: '全部' },
  { id: 'a', title: '全部时间' },
  { id: 't', title: '今日' },
  { id: 'w', title: '本周' },
  { id: 'm', title: '本月' }
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
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：禁漫天堂触发了 Cloudflare 人机校验（HTTP ' + status + '），可在源设置里换 18comic.ink 镜像');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (/cf-chl-|Just a moment|cf-turnstile/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：禁漫天堂需要网页验证，可在源设置里换 18comic.ink 镜像');
  }
  return body;
}

// 书籍 id 直接用 /novel/{id}/{slug} 这段路径（详情/搜索都靠它）
function novelPathOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/novel\/(\d+)(?:\/[^"?#]*)?/.exec(text);
  if (matched) return { id: matched[1], path: '/novel/' + matched[1] + '/' };
  var num = /^(\d+)$/.exec(text);
  if (num) return { id: num[1], path: '/novel/' + num[1] + '/' };
  return null;
}

function parseItems(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('href="/novel/');
  for (var i = 1; i < blocks.length; i++) {
    var seg = blocks[i].slice(0, 2500);
    var idHit = /^(\d+)\//.exec(seg);
    if (!idHit) continue;
    var id = idHit[1];
    if (seen[id]) continue;
    var img = /<img[^>]*data-original="([^"]+)"/i.exec(seg) || /<img[^>]*data-src="([^"]+)"/i.exec(seg);
    var titleHit = /<img[^>]*title="([^"]*)"/i.exec(seg);
    var title = oneLine(titleHit ? titleHit[1] : '');
    if (!title) continue;
    seen[id] = true;
    items.push({
      id: '/novel/' + id + '/',
      title: title,
      cover: img ? absolute(img[1]) : '',
      subtitle: '禁漫小說',
      mediaType: 'novel'
    });
  }
  return items;
}

var LumeSource = {
  id: 'jmcomic_novel',
  name: '禁漫天堂 · JM文庫',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://18comic.ink/favicon.ico',
  mirrors: ['https://18comic.ink', 'https://18comic.vip', 'https://jmcomic.me'],

  async categories() {
    return SORTS.map(function (item) {
      return { id: 'sort-' + item.id, title: '禁漫小說 · ' + item.title };
    });
  },

  async filters() {
    // 站点的小说列表只认 ?o=（排序）；?t=（时间范围）实测回 0 条，所以不声明时间组
    return {
      groups: [
        {
          id: 'sort',
          title: '排序',
          options: SORTS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    var latest = parseItems(await fetchHtml('/novels?o=mr')).slice(0, 12);
    if (latest.length) boards.push({ title: '禁漫小說 · 最新', moreUrl: 'sort-mr', items: latest });
    try {
      var hot = parseItems(await fetchHtml('/novels?o=mv')).slice(0, 12);
      if (hot.length) boards.push({ title: '禁漫小說 · 人气', moreUrl: 'sort-mv', items: hot });
    } catch (error) {
      /* 人气榜失败不影响首页 */
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    var sort = String(filters.sort || '').trim();
    if (!sort && /^sort-/.test(categoryId)) sort = categoryId.slice(5);
    if (!sort) sort = 'mr';
    var time = String(filters.time || '').trim();
    if (time === 'all' || time.indexOf(',') >= 0) time = time === 'all' ? '' : time.split(',')[0].trim();

    var path;
    if (keyword) {
      path = '/search/novels?search_query=' + encodeURIComponent(keyword);
    } else {
      path = '/novels?o=' + sort + (time ? '&t=' + time : '');
    }

    var html = await fetchHtml(path);
    var items = parseItems(html);
    if (!items.length && keyword) return { items: [], hasMore: false };
    if (!items.length) throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    // 站点的小说列表是单页（没有 ?page= 控件），换排序/时间才有新内容
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var ref = novelPathOf(argument && argument.id);
    if (!ref) return null;
    var html = await fetchHtml(ref.path);
    if (!html) return null;
    var h1 = /<h1[^>]*>([\s\S]{0,400}?)<\/h1>/i.exec(html);
    var title = oneLine(h1 ? h1[1] : '');
    if (!title) {
      var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/i.exec(html);
      title = oneLine(ogTitle ? ogTitle[1] : '');
    }
    if (!title) return null;
    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html);
    var coverUrl = cover ? absolute(cover[1]) : '';
    // og:image 是站点 logo；真封面在 /media/novels/{id}_tmb.jpg
    if (!coverUrl || /new_logo|blank\.jpg/i.test(coverUrl)) {
      coverUrl = 'https://cdn-msp2.18comic.ink/media/novels/' + ref.id + '_tmb.jpg';
    }
    var imgCover = /<img[^>]*data-original="([^"]*\/media\/novels\/[^"]+)"/i.exec(html);
    if (imgCover) coverUrl = absolute(imgCover[1]);
    var author = /^\[([^\]]+)\]/.exec(title);
    var chapters = chapterLinks(html);
    var lines = [];
    if (author) lines.push('作者：' + author[1]);
    lines.push('分类：禁漫小說');
    if (chapters.length) lines.push('章节：' + chapters.length);
    return {
      id: ref.path,
      title: title,
      cover: coverUrl,
      subtitle: [author ? author[1] : '', chapters.length + ' 章'].filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var ref = novelPathOf(argument && argument.id);
    if (!ref) return [];
    var html = await fetchHtml(ref.path);
    var rows = chapterLinks(html);
    if (!rows.length) throw new Error('这本书没有解析到章节（' + ref.path + '，可能需要网页验证）');
    return rows;
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /\/novelchapters\/(\d+)/.exec(raw);
    var chapterId = matched ? matched[1] : '';
    if (!chapterId) throw new Error('缺少章节 ID（应形如 /novelchapters/1234）');

    var path = '/novelchapters/' + chapterId;
    var html = await fetchHtml(path);
    var text = novelText(html);
    if (!text) throw new Error('这一章没有解析到正文（' + path + '）');
    var heading = /<h4[^>]*class="[^"]*novel-content[^"]*"[^>]*>([\s\S]{0,120}?)<\/h4>/i.exec(html);
    return {
      kind: 'text',
      title: heading ? oneLine(heading[1]) : undefined,
      text: text
    };
  }
};

// 详情页里的章节链接（/novelchapters/{n}）：
//   <a href="/novelchapters/1851" data-album="1851" data-index="2"> <li>2. 第1.2話 <span>…</span>
function chapterLinks(html) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var blocks = text.split('href="/novelchapters/');
  for (var i = 1; i < blocks.length; i++) {
    var seg = blocks[i].slice(0, 700);
    var idHit = /^(\d+)/.exec(seg);
    if (!idHit) continue;
    var id = idHit[1];
    if (seen[id]) continue;
    seen[id] = true;
    var liHit = /<li[^>]*>([\s\S]{0,160}?)(?:<span|<\/li>)/i.exec(seg);
    var name = liHit ? oneLine(liHit[1]) : '';
    name = name.replace(/^\d+[.、,]\s*/, '').trim();
    out.push({ id: '/novelchapters/' + id, title: name || '第 ' + out.length + ' 話' });
  }
  out.sort(function (a, b) {
    return Number(a.id.replace(/\D/g, '')) - Number(b.id.replace(/\D/g, ''));
  });
  return out;
}

// 正文：#ncc1 与 #ncc2 两栏 .novel-content，<br /> 分行
function novelText(html) {
  var text = String(html || '');
  var parts = [];
  var re = /<div[^>]*id="ncc(\d)"[^>]*>([\s\S]*?)<\/div>/g;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    parts.push(hit[2]);
  }
  if (!parts.length) return '';
  var joined = parts
    .join('\n')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  var lines = decodeEntities(joined).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '').trim();
    if (!line || line === '>' || line === '/>') continue;
    out.push(line);
  }
  return out.join('\n');
}
