// LumeSource: {"id":"8csk_comic","name":"八叉书库","version":"1.0.1","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://8csk.org","https://8csk.net","https://8csk.cc","https://bxsk.net","https://bxsk.org","https://bcshuku.com","https://bcsk8.com","https://baxsk.com","https://8xsk.net","https://8xsk.info"],"network":"direct","icon":"https://8csk.org/favicon.ico","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（8csk.xyz）","url":"https://8csk.xyz/","description":"官方地址发布页：发布页域名 8xsk.top / 8csk.xyz，站点域名 8csk.net/org/cc、bxsk.net/org/cc、bcshuku.com/cc/net、bcsk8.com/net/cc/xyz、bacsk.com/cc、baxsk.com/cc、8xsk.net/info/xyz"},{"key":"note","type":"info","title":"站点说明","description":"八叉书库（8xsk 字站，全站 18+ 成人小说）：分类 /booklist1-9；最新更新 /latest、最新入库 /release、热门排行 /popular、完本 /completed（分页 /xxx/index_N.html，分类分页 /booklistN/{页-1}.html）；题材 /genre/{slug}/index_N.html；详情 /novel{id}/，章节列表 /novel{id}/?p=N（每页 51 章）；正文不在 HTML 里——章节页内嵌一次性令牌，POST /conapi.php 取纯文本（本源已复刻）。站内搜索 /e/search/index.php?keyboard=&show=title,writer,byr&searchget=1，翻页带 searchid。 部分原站封面文件自身返回 404；这些作品保留书名占位，不使用其它书籍图片。"}]}
// LumeRuntime: javascript
//
// 站点：八叉书库（8csk.org，WordPress + 「truyen」小说主题，全站 18+ 成人小说）
// 发布页：https://8csk.xyz/（发布页给 18 个域名：8csk.net/org/cc、bxsk.net/org/cc、bcshuku.com/cc/net、
//   bcsk8.com/net/cc/xyz、bacsk.com/cc、baxsk.com/cc、8xsk.net/info/xyz —— 全部实测 200 且同内容，
//   镜像里放前 10 个）
//
// 结构（2026-11-04 逐页实测）：
//   · 分类        /booklist1 … /booklist9（长篇/综合/武侠/历史/都市/玄幻/女生/其他/现代）
//                 分页是「页号-1」：/booklist1/1.html = 第 2 页，末尾有 Last 链接（例：/booklist1/322.html）
//   · 榜单        /latest（最新更新）、/release（最新入库）、/popular（热门排行）、/completed（完本）
//                 分页 /latest/index_2.html、/popular/index_3.html …
//   · 题材        /genre/{slug}/、/genre/{slug}/index_2.html（站点没有题材索引页，slug 从书页的
//                 <a href="/genre/xx/" title="中文"> 反查，本源固定放 30 个高频题材）
//   · 搜索        GET /e/search/index.php?keyboard={词}&show=title,writer,byr&searchget=1
//                 翻页 /e/search/result/index.php?page={页-1}&searchid={searchid}（searchid 随结果页下发）
//   · 列表卡片    <div class="col-md-3 col-sm-6 col-xs-6 home-truyendecu"> 里：
//                 <a href="/novel{id}/" title="书名"> + <img src="https://img.8xsk.top/..."> +
//                 <h3 itemprop="name"> + 观看数 + 作者（.chuyen-muc）+ 连载/完本角标 + 最新章 + 日期
//   · 详情        /novel{id}/：h1 / .single_title、封面 img[itemprop=image]、作者 a[itemprop=author]、
//                 分类与 #标签、观看数、更新时间、简介 .desc-text
//   · 章节目录    /novel{id}/?p=N（每页 51 章，第 1 页不带 ?p）
//                 ⚠ 目录里掺了隐藏诱饵 <li style="position:absolute;left:-99999px…">（假章节），必须跳过
//   · 正文        **不在 HTML 里**。章节页内嵌一次性令牌，前端 POST /conapi.php：
//                 {url(密文串), mobile:1, isk:1, novel, chapter, t(时间戳), n, sign(sha256)}
//                 → {"success":"1","content":"……纯文本……"}。本源从章节页抓这 7 个参数立刻回放
//                 同一个请求（令牌按页生成、带 t，没法跨章复用），拿到纯文本正文。
//                 实测 book 50252 chapter0 / chapter500 各 2295 / 2204 字，无图片字、无付费墙。

var BASE_URL = 'https://8csk.org';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 24;
var MAX_CHAPTER_PAGES = 40;
var BOOK_TTL_MS = 5 * 60 * 1000;

var LISTS = [
  { id: 'latest', title: '最新更新', path: '/latest' },
  { id: 'release', title: '最新入库', path: '/release' },
  { id: 'popular', title: '热门排行', path: '/popular' },
  { id: 'completed', title: '完本小说', path: '/completed' }
];

var CATS = [
  { id: 'bl1', title: '长篇小说' },
  { id: 'bl2', title: '综合小说' },
  { id: 'bl3', title: '武侠小说' },
  { id: 'bl4', title: '历史小说' },
  { id: 'bl5', title: '都市小说' },
  { id: 'bl6', title: '玄幻小说' },
  { id: 'bl7', title: '女生小说' },
  { id: 'bl8', title: '其他小说' },
  { id: 'bl9', title: '现代小说' }
];

// slug 全部来自书页 /genre/{slug}/ 反查，标题是站点自己写的中文
var GENRES = [
  { id: 'xiaoyuan', title: '校园' },
  { id: 'jiaoshi', title: '教师' },
  { id: 'renqi', title: '人妻' },
  { id: 'shunv', title: '熟女' },
  { id: 'yujie', title: '御姐' },
  { id: 'luoli', title: '萝莉' },
  { id: 'nvshen', title: '女神' },
  { id: 'hougong', title: '后宫' },
  { id: 'dushi', title: '都市' },
  { id: 'juqing', title: '剧情' },
  { id: 'shuangwen', title: '爽文' },
  { id: 'diaojiao', title: '调教' },
  { id: 'daoju', title: '道具' },
  { id: 'zhifu', title: '制服' },
  { id: 'heisi', title: '黑丝' },
  { id: 'juru', title: '巨乳' },
  { id: 'koujiao', title: '口交' },
  { id: 'zujiao', title: '足交' },
  { id: 'rujiao', title: '乳交' },
  { id: 'qunjiao', title: '群交' },
  { id: 'luanlun', title: '乱伦' },
  { id: 'muzi', title: '母子' },
  { id: 'xiongmei', title: '兄妹' },
  { id: 'munv', title: '母女' },
  { id: 'chugui', title: '出轨' },
  { id: 'yinqi', title: '淫妻' },
  { id: 'jiaohuanbanlv', title: '交换伴侣' },
  { id: 'luchu', title: '露出' },
  { id: 'lingru', title: '凌辱' },
  { id: 'kunbang', title: '捆绑' }
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
    .replace(/&middot;/g, '·')
    .replace(/&hellip;/g, '…')
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
    throw new Error('NEED_WEBVIEW_VERIFY：八叉书库触发了人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

function bookIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/novel(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 书籍页 60 KB 左右，detail 与 chapters 都会用；缓存 5 分钟少发一次请求
async function readBook(id) {
  var file = 'b-' + id + '.json';
  try {
    var raw = await LumeSource.fs.readText(file);
    if (raw) {
      var cached = JSON.parse(raw);
      if (cached && cached.h && Date.now() - Number(cached.at || 0) < BOOK_TTL_MS) return String(cached.h);
    }
  } catch (error) {
    /* 缓存读不到就现抓 */
  }
  var html = await fetchHtml('/novel' + id + '/');
  try {
    await LumeSource.fs.writeText(file, JSON.stringify({ at: Date.now(), h: html }));
  } catch (error) {
    /* 写不进缓存不影响主流程 */
  }
  return html;
}

// 列表卡片：每个 home-truyendecu 一块
function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split(/(?:home-truyendecu|<div class="normal-image1\b)/);
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var link = /<a\s+href="\/novel(\d+)\/"[^>]*title="([^"]*)"/.exec(block);
    if (!link) continue;
    var id = link[1];
    if (!id || seen[id]) continue;
    var title = oneLine(link[2]);
    if (!title) {
      var h3 = /<h3 itemprop="name">([\s\S]*?)<\/h3>/.exec(block);
      title = oneLine(h3 ? h3[1] : '');
    }
    if (!title) continue;
    var cover = /src="(https:\/\/img\.8xsk\.top\/[^"]+)"/.exec(block)
      || /srcset="(https:\/\/img\.8xsk\.top\/[^"\s]+)/.exec(block);
    var author = /class="chi-tiet chuyen-muc"[\s\S]{0,240}?<a[^>]*>([^<]*)<\/a>/.exec(block);
    var status = /hoan-thanh-mau">([^<]*)</.exec(block);
    var date = /([0-9]{4}-[0-9]{2}-[0-9]{2})/.exec(block);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      coverHeaders: { Referer: base() + '/', 'User-Agent': UA },
      subtitle: [
        status ? oneLine(status[1]) : '',
        author ? oneLine(author[1]) : '',
        date ? date[1] : ''
      ].filter(Boolean).join(' · '),
      mediaType: 'novel'
    });
  }
  return items;
}

// 首页「最近更新」这类纯文字行
function parseRows(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('truyenhot_li_customcol');
  for (var i = 1; i < blocks.length; i++) {
    var link = /<a\s+href="\/novel(\d+)\/"[^>]*title="([^"]*)"/.exec(blocks[i]);
    if (!link) continue;
    var id = link[1];
    var title = oneLine(link[2]);
    if (!id || !title || seen[id]) continue;
    seen[id] = true;
    items.push({ id: id, title: title, cover: base() + '/novel' + id + '/',
      coverHeaders: { Referer: base() + '/', 'User-Agent': UA, 'x-lume-image-page-selector': 'img[itemprop=image]' }, mediaType: 'novel' });
  }
  return items;
}

// 总页数：靠分页条里的 Last 链接反推（各版块编号规则不同）
function totalPages(html) {
  var text = String(html || '');
  var block = /<ul class="pagination[^"]*">([\s\S]*?)<\/ul>/.exec(text);
  var scope = block ? block[1] : text;
  var last = /<a href="([^"]+)"[^>]*>\s*(?:Last|尾页)\s*<\/a>/.exec(scope);
  if (!last) return 1;
  var href = decodeEntities(last[1]);
  var indexHit = /index_(\d+)\.html/.exec(href);
  if (indexHit) return Number(indexHit[1]);
  var listHit = /\/booklist\d+\/(\d+)\.html/.exec(href);
  if (listHit) return Number(listHit[1]) + 1;
  var searchHit = /page=(\d+)/.exec(href);
  if (searchHit) return Number(searchHit[1]) + 1;
  return 1;
}

function listPath(page, categoryId) {
  for (var i = 0; i < LISTS.length; i++) {
    if (LISTS[i].id === categoryId) {
      return LISTS[i].path + (page > 1 ? '/index_' + page + '.html' : '');
    }
  }
  var cat = 'bl1';
  for (var k = 0; k < CATS.length; k++) {
    if (CATS[k].id === categoryId) cat = CATS[k].id;
  }
  var n = cat.replace('bl', '');
  return '/booklist' + n + (page > 1 ? '/' + (page - 1) + '.html' : '');
}

function genrePath(page, slug) {
  return '/genre/' + slug + '/' + (page > 1 ? 'index_' + page + '.html' : '');
}

// 章节页里的正文令牌（POST /conapi.php 的 7 个字段）
function contentToken(html) {
  var text = String(html || '');
  var body = /\$\.post\(\s*["']\/conapi\.php["']([\s\S]*?),\s*function/.exec(text);
  var scope = body ? body[1] : text;
  var pick = function (key) {
    var hit = new RegExp('"' + key + '"\\s*:\\s*"?([^",\\s]+)"?').exec(scope);
    return hit ? hit[1] : '';
  };
  return {
    url: pick('url'),
    novel: pick('novel'),
    chapter: pick('chapter'),
    t: pick('t'),
    n: pick('n'),
    sign: pick('sign')
  };
}

function bodyText(raw) {
  var text = String(raw == null ? '' : raw).replace(/\r\n/g, '\n');
  var lines = text.split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
    if (!line) continue;
    out.push(line);
  }
  return out.join('\n');
}

async function searchList(keyword, page) {
  var searchId = '';
  try {
    var cached = await LumeSource.fs.readText('search-' + encodeURIComponent(keyword) + '.json');
    if (cached) {
      var saved = JSON.parse(cached);
      if (saved && saved.id && Date.now() - Number(saved.at || 0) < 30 * 60 * 1000) searchId = String(saved.id);
    }
  } catch (error) {
    searchId = '';
  }

  // 没有 searchid（首次搜或缓存过期）就先走一次搜索页拿 id；翻页一律走 result 页
  var html = '';
  if (!searchId) {
    html = await fetchHtml(
      '/e/search/index.php?keyboard=' + encodeURIComponent(keyword) + '&show=title,writer,byr&searchget=1'
    );
    var idHit = /searchid=(\d+)/.exec(html);
    if (idHit) {
      searchId = idHit[1];
      try {
        await LumeSource.fs.writeText(
          'search-' + encodeURIComponent(keyword) + '.json',
          JSON.stringify({ id: searchId, at: Date.now() })
        );
      } catch (error) {
        /* 搜索 id 存不下来就每次重搜 */
      }
    }
  }
  if (searchId && page > 1) {
    html = await fetchHtml('/e/search/result/index.php?page=' + (page - 1) + '&searchid=' + searchId);
  }

  var items = parseCards(html);
  if (!items.length) items = parseRows(html);
  var total = totalPages(html);
  return { items: items, hasMore: page < total };
}

// 分批并发（章节目录动辄 20+ 页，串行会超时）
async function poolMap(list, limit, worker) {
  var out = new Array(list.length);
  var cursor = 0;
  var runners = [];
  var run = async function () {
    while (cursor < list.length) {
      var index = cursor;
      cursor += 1;
      try {
        out[index] = await worker(list[index], index);
      } catch (error) {
        out[index] = '';
      }
    }
  };
  var width = Math.min(limit, list.length);
  for (var i = 0; i < width; i++) runners.push(run());
  await Promise.all(runners);
  return out;
}

var LumeSource = {
  id: '8csk_comic',
  name: '八叉书库',
  version: '1.0.1',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://8csk.org/favicon.ico',
  mirrors: [
    'https://8csk.org',
    'https://8csk.net',
    'https://8csk.cc',
    'https://bxsk.net',
    'https://bxsk.org',
    'https://bcshuku.com',
    'https://bcsk8.com',
    'https://baxsk.com',
    'https://8xsk.net',
    'https://8xsk.info'
  ],

  async categories() {
    var list = [];
    for (var i = 0; i < LISTS.length; i++) list.push({ id: LISTS[i].id, title: LISTS[i].title });
    for (var k = 0; k < CATS.length; k++) list.push({ id: CATS[k].id, title: CATS[k].title });
    return list;
  },

  async filters() {
    return {
      groups: [
        {
          id: 'genre',
          title: '题材',
          options: GENRES.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var html = await fetchHtml('/');
    var boards = [];
    var rows = parseRows(html).slice(0, 12);
    if (rows.length) boards.push({ title: '最近更新', moreUrl: 'latest', items: rows });
    var hot = [];
    try {
      hot = parseCards(await fetchHtml('/popular')).slice(0, 12);
    } catch (error) {
      hot = parseCards(html).slice(0, 12);
    }
    if (hot.length) boards.push({ title: '热门排行', moreUrl: 'popular', items: hot });
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var genre = String(filters.genre || '').trim();
    if (genre.indexOf(',') >= 0) genre = genre.split(',')[0].trim();

    if (keyword) return await searchList(keyword, page);

    // 题材页是独立栏目（站点没有「分类 + 题材」的组合参数），选了题材就按题材浏览
    var path = genre ? genrePath(page, genre) : listPath(page, categoryId);
    var html = await fetchHtml(path);
    var items = parseCards(html);
    if (!items.length) items = parseRows(html);
    var total = totalPages(html);
    if (!items.length && page === 1) {
      throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    }
    return { items: items, hasMore: page < total };
  },

  async detail(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return null;
    var html = await readBook(id);
    if (!html) return null;
    var titleHit = /<h1>[\s\S]{0,240}?<a[^>]*title="([^"]*)"[\s\S]{0,160}?<span itemprop="name">([\s\S]*?)<\/span>/.exec(html);
    var title = oneLine(titleHit ? (titleHit[2] || titleHit[1] || '') : '');
    if (!title) {
      var single = /<h2 class="single_title">([\s\S]*?)<\/h2>/.exec(html);
      title = oneLine(single ? single[1] : '');
    }
    if (!title) {
      var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/.exec(html);
      title = oneLine(ogTitle ? ogTitle[1] : '');
    }
    if (!title) return null;

    var cover = /<img[^>]*itemprop="image"[^>]*src="([^"]+)"/.exec(html)
      || /<img[^>]*src="(https:\/\/img\.8xsk\.top\/[^"]+)"/.exec(html);
    var author = /<a\s+href="\/e\/search\/[^"]*"[^>]*itemprop="author"[^>]*>([\s\S]*?)<\/a>/.exec(html)
      || /itemprop="author"[^>]*>([\s\S]*?)<\/a>/.exec(html);
    var genres = [];
    var gRe = /<a\s+href="\/genre\/([^"\/]+)\/"[^>]*title="([^"]*)"/g;
    var gMatch;
    while ((gMatch = gRe.exec(html)) !== null) {
      var tag = oneLine(gMatch[2]);
      if (tag && genres.indexOf('#' + tag) < 0) genres.push('#' + tag);
    }
    var views = /glyphicon-eye-open[\s\S]{0,140}?<\/h3>\s*<span>(\d+)<\/span>/.exec(html);
    var update = /glyphicon-time[\s\S]{0,180}?<span[^>]*>([0-9]{4}-[0-9]{2}-[0-9]{2}[^<]*)<\/span>/.exec(html);
    var intro = /<div class="desc-text"[^>]*>([\s\S]*?)<\/div>\s*(?:<div class="showmore">|<\/div>)/.exec(html)
      || /<div class="desc-text"[^>]*>([\s\S]*?)<\/div>/.exec(html);
    var introText = intro ? clean(intro[1]) : '';
    introText = introText.replace(/小说介绍/g, '').replace(/^[\s·]+/, '').trim();

    var lines = [];
    if (author) lines.push('作者：' + oneLine(author[1]));
    if (genres.length) lines.push('题材：' + genres.join(' '));
    if (views) lines.push('观看：' + views[1]);
    if (update) lines.push('更新：' + oneLine(update[1]));
    if (introText) lines.push('', introText);

    return {
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      coverHeaders: { Referer: base() + '/', 'User-Agent': UA },
      subtitle: [author ? oneLine(author[1]) : '', genres.slice(0, 3).join(' ')].filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var id = bookIdOf(argument && argument.id);
    if (!id) return [];
    var first = await readBook(id);
    var maxPage = 1;
    var pRe = /\/novel\d+\/\?p=(\d+)/g;
    var pMatch;
    while ((pMatch = pRe.exec(first)) !== null) {
      var n = Number(pMatch[1]);
      if (n > maxPage) maxPage = n;
    }
    maxPage = Math.min(maxPage, MAX_CHAPTER_PAGES);

    // 第 1 页已经有 HTML；其余页分批并发抓（串行 20+ 页会超 5 秒预算）
    var rest = [];
    for (var p = 2; p <= maxPage; p++) rest.push(p);
    var restHtml = await poolMap(rest, 6, function (pageNo) {
      return fetchHtml('/novel' + id + '/?p=' + pageNo);
    });
    var pages = [first].concat(restHtml);

    var out = [];
    var seen = {};
    for (var i = 0; i < pages.length; i++) {
      var raw = pages[i] || '';
      if (!raw) continue;
      // 书页顶部还有一块「最新章节」（最新 2 条，会重复且顺序相反），只认 #list-chapter 里的完整目录
      var start = raw.indexOf('id="list-chapter"');
      var html = start >= 0 ? raw.slice(start) : raw;
      var blocks = html.split('<li class="chap-');
      for (var k = 1; k < blocks.length; k++) {
        var block = blocks[k];
        // 目录里掺了 position:absolute;left:-99999px 的假章节，跳过
        if (block.indexOf('left:-99999px') >= 0) continue;
        var link = /<a href="\/novel\d+\/(chapter\d+\.html)"[^>]*title="([^"]*)"/.exec(block);
        if (!link) continue;
        var file = link[1];
        if (seen[file]) continue;
        seen[file] = true;
        var name = oneLine(link[2]);
        if (!name) {
          var span = /<span class="chapter-text">([\s\S]*?)<\/span>/.exec(block);
          name = oneLine(span ? span[1] : '');
        }
        out.push({ id: id + '/' + file.replace('.html', ''), title: name });
      }
    }
    if (!out.length) throw new Error('目录里没有章节节点（' + id + '，站点模板可能改了）');
    // 站点目录本来就从第 1 章往后排，不用翻序；缺标题的按序补
    for (var j = 0; j < out.length; j++) {
      if (!out[j].title) out[j].title = '第 ' + (j + 1) + ' 章';
    }
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /(\d+)\/(chapter\d+)/.exec(raw);
    var novel = matched ? matched[1] : bookIdOf(args.id);
    var chapter = matched ? matched[2] : '';
    if (!novel || !chapter) throw new Error('缺少章节 ID（应形如 书号/chapterN）');

    var chapterPath = '/novel' + novel + '/' + chapter + '.html';
    var html = await fetchHtml(chapterPath);
    var title = oneLine((/<h2[^>]*class="[^"]*chapter[^"]*"[^>]*>([\s\S]*?)<\/h2>/.exec(html) || [])[1] || '');
    if (!title) {
      var t2 = /<title>([^<]*)<\/title>/.exec(html);
      title = oneLine(t2 ? String(t2[1]).split(/[-_|]/)[0] : '');
    }

    var token = contentToken(html);
    if (!token.url || !token.sign) {
      throw new Error('这一章没找到正文令牌（' + chapterPath + '，站点模板可能改了）');
    }
    var form = [
      'url=' + encodeURIComponent(token.url),
      'mobile=1',
      'isk=1',
      'novel=' + encodeURIComponent(token.novel || novel),
      'chapter=' + encodeURIComponent(token.chapter),
      't=' + encodeURIComponent(token.t),
      'n=' + encodeURIComponent(token.n),
      'sign=' + encodeURIComponent(token.sign)
    ].join('&');

    var reply = await LumeSource.http.post(base() + '/conapi.php', form, {
      headers: {
        'User-Agent': UA,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'XMLHttpRequest',
        Origin: base(),
        Referer: base() + chapterPath
      }
    });
    var status = reply ? reply.status : 0;
    if (status !== 200) throw new Error('正文接口打不开：HTTP ' + status);
    var payload = null;
    try {
      payload = JSON.parse(String(reply.body || ''));
    } catch (error) {
      payload = null;
    }
    if (!payload || String(payload.success) !== '1' || !payload.content) {
      throw new Error('正文接口没给内容（令牌可能已过期，重试一次）');
    }
    var text = bodyText(payload.content);
    if (!text) throw new Error('这一章是空的');
    return { kind: 'text', title: title || undefined, text: text };
  }
};
