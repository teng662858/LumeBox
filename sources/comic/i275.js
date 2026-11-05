// LumeSource: {"id":"i275_audiobook","name":"275听书","version":"1.0.0","category":"audiobook","contentCategory":"movie","mediaType":"audio","settingsApiVersion":2,"network":"direct","mirrors":["https://www.i275.com","https://m.i275.com"],"icon":"https://www.i275.com/logo192.png","settings":[{"key":"note","type":"info","title":"站点说明","description":"275听书（i275.com）是中文有声小说站：首页只有「最近上架」，没有分类页；本源把站内搜索做成「题材」分类（站方搜索最多回 50 条、不分页，所以每个题材一页到底）。音频接口要一个网页会话（脚本自己领、自己复用）。注意：站方已把音频 CDN 收紧成「只给官方 App」，网页/第三方播放器请求会回 HTTP 403 Access Denied（站点首页自己也写着「本站无法正常收听，请到小程序拾音盘」）；源里会把这件事如实报出来，而不是给一个播不响的地址。"}]}

// 275听书网（https://www.i275.com）· 有声小说源
//
// 站点形态：PHP + Tailwind 服务端渲染，**没有分类页**，可用结构就四块
//   GET  /                         首页：只是「最近上架」12 部 + 热门搜索 5 部
//   GET  /search.php?q=<词>         站内搜索：命中书名/作者/演播/简介，**服务端 LIMIT 50、不吃 page**
//   GET  /book/{书号}.html          详情：书名/封面/作者/演播/状态/热度/简介 + **完整目录**
//                                   （目录条目 id="chapter-pos-N"，href=/play/{书号}/{章节号}.html）
//   GET  /api_chapter.php?book_id=&chapter_id=   → {url,title,book_title,cover}
//        · **必须带网页会话 Cookie**（先 GET / 拿 PHPSESSID），否则回 {"error":"非法访问"}
//        · url 有三种形态（都是站点数据库的真实状态）：
//            1. http(s)://2025.tingshijie.com/… 或 audio.tingshijie.com/…（自建音频）
//            2. "lrts$<专辑号>#<音轨号>#…#<手机号>.txt" —— 只存了懒人畅听的编号，本站没有音频
//            3. null —— 新书还没上传音频
//
// ⚠ 播放链路的现状（2026-11-05 实测，写在源里免得以后误判成「源写错了」）：
//    形态 1 的地址本身是对的（api 原样下发），但 *.tingshijie.com 对所有非官方 App 的请求
//    一律回 403「Access Denied: Please use the official App.」：
//      · http / https、带不带 Range、带不带 PHPSESSID、带各种 Referer 都一样；
//      · 换 UA（浏览器 / Dalvik / okhttp / 微信 / 各种 App 猜名）只有 okhttp、ExoPlayer 会走成
//        普通 404，其余全 403；加 ?sign= / ?token= / ?e=&st= 等签名参数也不改变结果；
//      · 境外多节点复测（check-host.net 的 at/de/ir/rs/ru 节点）同样 403，
//        说明不是本机出口 IP 的问题，是站方按客户端凭据收紧的。
//    所以 content() 会先探一下这条地址：能取到字节就正常交给播放器；回 403 就抛出
//    「站方只给官方 App」的可读错误（不伪造可播地址，也不静默返回空）。
//
// 没有的东西就不声明：站点没有排序、没有筛选、没有分页、没有会员体系；
// 分类是本源用站内搜索词拼出来的（站方无分类页，这是唯一能真出内容的浏览轴）。

var BASE_URL = 'https://www.i275.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

var SESSION_KEY = 'i275/session.json';
var BOOK_KEY = 'i275/book_';
var SESSION_TTL = 6 * 3600 * 1000;
var BOOK_TTL = 30 * 60 * 1000;
var CHAPTER_PAGE_LIMIT = 9000; // 实测最长一本书 8027 章，超过就截断到目录页能承载的范围

// 题材「分类」：站点没有分类页，这些是站内搜索词（每个都实测有真实结果，首条互不相同）。
// 站方搜索上限 50 条且不分页，所以每个题材就是一个满 50 条（或更少）的列表。
var KW_CATEGORIES = [
  { key: '玄幻', title: '题材 · 玄幻' },
  { key: '都市', title: '题材 · 都市' },
  { key: '悬疑', title: '题材 · 悬疑' },
  { key: '恐怖', title: '题材 · 恐怖' },
  { key: '历史', title: '题材 · 历史' },
  { key: '修仙', title: '题材 · 修仙' },
  { key: '仙侠', title: '题材 · 仙侠' },
  { key: '武侠', title: '题材 · 武侠' },
  { key: '盗墓', title: '题材 · 盗墓' },
  { key: '灵异', title: '题材 · 灵异' },
  { key: '推理', title: '题材 · 推理' },
  { key: '言情', title: '题材 · 言情' },
  { key: '科幻', title: '题材 · 科幻' },
  { key: '校园', title: '题材 · 校园' },
  { key: '官场', title: '题材 · 官场' },
  { key: '评书', title: '题材 · 评书' },
  { key: '相声', title: '题材 · 相声' },
  { key: '广播剧', title: '题材 · 广播剧' },
  { key: '儿童', title: '题材 · 儿童' }
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

function decode(text) {
  return String(text == null ? '' : text)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&ldquo;|&rdquo;/g, '"')
    .replace(/&#(\d+);/g, function (whole, code) {
      var value = parseInt(code, 10);
      return value > 0 ? String.fromCharCode(value) : whole;
    })
    .replace(/\s+/g, ' ')
    .trim();
}

function headerValue(response, name) {
  var headers = response && response.headers ? response.headers : null;
  if (!headers) return '';
  var wanted = String(name).toLowerCase();
  var keys = Object.keys(headers);
  for (var i = 0; i < keys.length; i++) {
    if (String(keys[i]).toLowerCase() === wanted) {
      var value = headers[keys[i]];
      return Array.isArray(value) ? value.join(', ') : String(value == null ? '' : value);
    }
  }
  return '';
}

async function readJson(key) {
  try {
    if (!(await LumeSource.fs.exists(key))) return null;
    var text = await LumeSource.fs.readText(key);
    if (!text) return null;
    return JSON.parse(text);
  } catch (error) {
    return null;
  }
}

async function writeJson(key, value) {
  try {
    await LumeSource.fs.writeText(key, JSON.stringify(value));
  } catch (error) {
    /* 缓存写不进去不影响主流程 */
  }
}

// ------------------------------------------------------------------ 会话（api_chapter 的门票）
async function sessionCookie(force) {
  var cached = force ? null : await readJson(SESSION_KEY);
  if (cached && cached.cookie && Date.now() - Number(cached.t || 0) < SESSION_TTL) {
    return cached.cookie;
  }
  var response = await LumeSource.http.get(base() + '/', {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
    }
  });
  if (!response || response.status !== 200) {
    throw new Error('275听书首页打不开：HTTP ' + (response ? response.status : 0) + '（站点换域名时请在源设置里改镜像）');
  }
  var raw = headerValue(response, 'set-cookie');
  var pairs = [];
  var parts = String(raw).split(',');
  for (var i = 0; i < parts.length; i++) {
    var piece = parts[i].split(';')[0].trim();
    if (piece && piece.indexOf('=') > 0) pairs.push(piece);
  }
  var cookie = pairs.join('; ');
  if (!cookie || cookie.indexOf('PHPSESSID=') < 0) {
    // 宿主已经替我们维持了 Cookie 罐（Set-Cookie 不在 headers 里）时，
    // 仍然按「没有会话」处理会更稳：显式给一个 PHPSESSID，让 PHP 自己开一个会话再试。
    cookie = 'PHPSESSID=' + randomSessionId();
  }
  await writeJson(SESSION_KEY, { cookie: cookie, t: Date.now() });
  return cookie;
}

function randomSessionId() {
  var chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  var out = '';
  for (var i = 0; i < 26; i++) out += chars.charAt(Math.floor(Math.random() * chars.length));
  return out;
}

// ------------------------------------------------------------------ 抓页面
async function fetchPage(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var cookie = '';
  try {
    cookie = await sessionCookie(false);
  } catch (error) {
    cookie = '';
  }
  var headers = {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    Referer: referer || base() + '/'
  };
  if (cookie) headers.Cookie = cookie;
  var response = await LumeSource.http.get(url, { headers: headers });
  var status = response ? response.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：275听书返回 HTTP ' + status + '（站点触发了网页校验），请在源设置里走网页视图');
  }
  if (status !== 200) {
    throw new Error('275听书页面打不开：HTTP ' + status + ' ' + path);
  }
  return { html: response.body || '', url: url };
}

// ------------------------------------------------------------------ 列表解析
// 首页卡片：<a href="/book/ID.html" class="bg-white rounded-lg …">
//   <img src="封面" alt="标题"><div class="p-2"><div class="font-medium …">标题</div>
//   <div class="text-xs …">某某 演播</div></div></a>
function parseHomeNewest(html) {
  var items = [];
  var seen = {};
  var pattern = /<a href="\/book\/(\d+)\.html"[^>]*class="bg-white[\s\S]{0,1200}?<\/a>/g;
  var matched;
  while ((matched = pattern.exec(html)) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    var block = matched[0];
    var titleMatch = /class="font-medium[^"]*"[^>]*>([\s\S]*?)<\/div>/.exec(block) ||
      /<img[^>]*alt="([^"]*)"/.exec(block);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) continue;
    var coverMatch = /<img[^>]*src="([^"]+)"/.exec(block);
    var narratorMatch = /class="text-xs[^"]*"[^>]*>([\s\S]*?)<\/div>/.exec(block);
    var narrator = decode(narratorMatch ? narratorMatch[1] : '');
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: absolute(coverMatch ? coverMatch[1] : ''),
      subtitle: narrator,
      mediaType: 'audio'
    });
  }
  return items;
}

// 首页「热门搜索」：<a href='/book/58.html' class='ml-2 underline …'>剑来（上下部）</a>
function parseHot(html) {
  var start = html.indexOf('热门搜索');
  if (start < 0) return [];
  var block = html.slice(start, start + 4000);
  var items = [];
  var seen = {};
  var pattern = /<a href='\/book\/(\d+)\.html'[^>]*>([\s\S]*?)<\/a>/g;
  var matched;
  while ((matched = pattern.exec(block)) !== null) {
    var id = matched[1];
    var title = decode(matched[2]);
    if (!id || !title || seen[id]) continue;
    seen[id] = true;
    items.push({ id: id, title: title, subtitle: '站点热门', mediaType: 'audio' });
  }
  return items;
}

// 搜索结果卡片：<a href="/book/ID.html" class="flex p-4 gap-4 …">
//   <img src="封面" alt="…"><h3>标题</h3><p>演播 XXX</p><p>作者 YYY</p><p>简介…</p></a>
function parseSearch(html) {
  var items = [];
  var seen = {};
  var pattern = /<a href="\/book\/(\d+)\.html"[^>]*class="flex p-4[\s\S]{0,2600}?<\/a>/g;
  var matched;
  while ((matched = pattern.exec(html)) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    var block = matched[0];
    var titleMatch = /<h3[^>]*>([\s\S]*?)<\/h3>/.exec(block);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) continue;
    var coverMatch = /<img[^>]*src="([^"]+)"/.exec(block);
    var narrator = '';
    var narratorMatch = /演播<\/span>([\s\S]*?)<\/p>/.exec(block);
    if (narratorMatch) narrator = decode(narratorMatch[1]);
    var authorMatch = /作者<\/span>([\s\S]*?)<\/p>/.exec(block);
    var author = authorMatch ? decode(authorMatch[1]) : '';
    var subtitleParts = [];
    if (narrator) subtitleParts.push('演播 ' + narrator);
    if (author) subtitleParts.push('作者 ' + author);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: absolute(coverMatch ? coverMatch[1] : ''),
      subtitle: subtitleParts.join(' · '),
      mediaType: 'audio'
    });
  }
  return items;
}

async function search(keyword) {
  var word = String(keyword == null ? '' : keyword).trim();
  if (!word) return { items: [], hasMore: false };
  var page = await fetchPage('/search.php?q=' + encodeURIComponent(word));
  var items = parseSearch(page.html);
  if (!items.length) {
    // 站方搜索只认书名/作者/演播的正常写法，全站搜不到就是真的没有
    return { items: [], hasMore: false };
  }
  return { items: items, hasMore: false };
}

// ------------------------------------------------------------------ 书本页（详情 + 目录共用一次请求）
function parseBookMeta(html, id) {
  // 书本页顶部还带着和首页一样的搜索大标题（h1 是「275听书-海量免费有声小说」），
  // 真正的书本信息在「书籍详情」标题之后、目录之前，先切出这一段再解析。
  var start = html.indexOf('书籍详情');
  var end = html.indexOf('chapter-pos-');
  var block = start >= 0 ? html.slice(start, end > start ? end : Math.min(html.length, start + 8000)) : html;
  if (!block) block = html;
  var titleMatch = /<h1 class="text-2xl[^"]*"[^>]*>([\s\S]*?)<\/h1>/.exec(block) ||
    /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(block);
  var title = decode(titleMatch ? titleMatch[1] : '');
  if (!title) {
    var docTitle = /<title>([\s\S]*?)<\/title>/.exec(html);
    title = decode(docTitle ? String(docTitle[1]).split(' - ')[0] : '');
  }
  var coverMatch = /<img[^>]*src="((?:https?:\/\/|\/uploads\/)[^"]+)"/.exec(block);
  var authorMatch = /作者：<span[^>]*>([\s\S]*?)<\/span>/.exec(block);
  var narratorMatch = /演播：<span[^>]*>([\s\S]*?)<\/span>/.exec(block);
  var statusMatch = /状态：<span[^>]*>([\s\S]*?)<\/span>/.exec(block);
  var heatMatch = /热度：<span[^>]*>([\s\S]*?)<\/span>/.exec(block);
  var descMatch = /class="text-gray-600[^"]*line-clamp-3[^"]*"[^>]*>([\s\S]*?)<\/p>/.exec(block);
  var author = decode(authorMatch ? authorMatch[1] : '');
  var narrator = decode(narratorMatch ? narratorMatch[1] : '');
  var status = decode(statusMatch ? statusMatch[1] : '');
  var heat = decode(heatMatch ? heatMatch[1] : '');
  var subtitleParts = [];
  if (narrator) subtitleParts.push('演播 ' + narrator);
  if (status) subtitleParts.push(status);
  if (heat) subtitleParts.push(heat);
  return {
    id: String(id),
    title: title,
    cover: absolute(coverMatch ? coverMatch[1] : ''),
    author: author,
    subtitle: subtitleParts.join(' · '),
    status: status,
    description: decode(descMatch ? descMatch[1] : ''),
    mediaType: 'audio'
  };
}

// 目录：<a id="chapter-pos-1" href="/play/39454/23581985.html" …>
//         <span class="text-xs …">1.</span><span class="text-sm …">章节名</span></a>
function parseChapters(html) {
  var chapters = [];
  var seen = {};
  var pattern = /<a id="chapter-pos-\d+"[^>]*href="\/play\/\d+\/(\d+)\.html"[^>]*>([\s\S]*?)<\/a>/g;
  var matched;
  while ((matched = pattern.exec(html)) !== null) {
    var chapterId = matched[1];
    if (!chapterId || seen[chapterId]) continue;
    var block = matched[2];
    var titleMatch = /class="text-sm[^"]*"[^>]*>([\s\S]*?)<\/span>/.exec(block);
    var title = decode(titleMatch ? titleMatch[1] : '');
    if (!title) title = '第 ' + (chapters.length + 1) + ' 集';
    seen[chapterId] = true;
    chapters.push({ id: chapterId, title: title });
    if (chapters.length >= CHAPTER_PAGE_LIMIT) break;
  }
  return chapters;
}

async function bookPage(id) {
  var key = BOOK_KEY + id + '.json';
  var cached = await readJson(key);
  if (cached && Date.now() - Number(cached.t || 0) < BOOK_TTL && cached.meta) {
    return cached;
  }
  var page = await fetchPage('/book/' + encodeURIComponent(id) + '.html', base() + '/');
  var html = page.html;
  // 书被删/没上架：站点回 200 + 极短正文（实测 10~200 字节）
  if (html.length < 2000) {
    var empty = { meta: null, chapters: [], t: Date.now() };
    await writeJson(key, empty);
    return empty;
  }
  var record = {
    meta: parseBookMeta(html, id),
    chapters: parseChapters(html),
    t: Date.now()
  };
  await writeJson(key, record);
  return record;
}

// ------------------------------------------------------------------ 音频地址
async function chapterAudio(bookId, chapterId, force) {
  var cookie = await sessionCookie(!!force);
  var referer = base() + '/book/' + bookId + '.html';
  var response = await LumeSource.http.get(
    base() + '/api_chapter.php?book_id=' + encodeURIComponent(bookId) + '&chapter_id=' + encodeURIComponent(chapterId),
    { headers: { 'User-Agent': UA, Referer: referer, Cookie: cookie, Accept: 'application/json,*/*' } }
  );
  var status = response ? response.status : 0;
  if (status !== 200) {
    throw new Error('275听书取集失败：HTTP ' + status);
  }
  var text = response.body || '';
  var data = null;
  try {
    data = JSON.parse(text);
  } catch (error) {
    data = null;
  }
  if (!data) throw new Error('275听书接口返回的不是 JSON：' + String(text).slice(0, 80));
  if (data.error && !data.url) {
    // 会话过期/被站点判成「不是从网页来的」时，重领一次会话再试
    if (!force && String(data.error).indexOf('非法访问') >= 0) {
      return chapterAudio(bookId, chapterId, true);
    }
    throw new Error('275听书接口拒绝了这次请求：' + String(data.error));
  }
  return data;
}

// 探一下音频地址到底能不能取到字节：能取到就放行，403 就如实说是站方的限制
async function probeAudio(url) {
  try {
    var attempt = LumeSource.http.get(url, {
      headers: { 'User-Agent': UA, Range: 'bytes=0-2047', Referer: base() + '/' }
    });
    var raced = await Promise.race([
      attempt,
      new Promise(function (resolve) {
        setTimeout(function () {
          resolve(null);
        }, 2600);
      })
    ]);
    if (!raced) return { ok: true, unknown: true };
    var status = raced.status || 0;
    if (status === 403) {
      return { ok: false, status: 403, body: String(raced.body || '').slice(0, 60) };
    }
    return { ok: true, status: status };
  } catch (error) {
    // 超时/网络抖动不当作「站方拦住了」，照常把地址交给播放器
    return { ok: true, unknown: true };
  }
}

// ------------------------------------------------------------------ 入口
async function homeBoard() {
  var page = await fetchPage('/', base() + '/');
  var newest = parseHomeNewest(page.html);
  var hot = parseHot(page.html);
  var boards = [];
  if (hot.length) boards.push({ title: '热门收听', items: hot });
  if (newest.length) boards.push({ title: '最近上架', items: newest });
  if (!boards.length) {
    throw new Error('275听书首页没有解析到任何书目（站点改版了？）');
  }
  return boards;
}

async function categoryList() {
  var list = [
    // 首页「热门搜索」那 5 部是站点人工挑的常青书，实测都还有音频；
    // 「最近上架」的新书大多还没上传音频（接口 url 为 null），所以排在后面。
    { id: 'hot', title: '热门收听' },
    { id: 'new', title: '最近上架' }
  ];
  for (var i = 0; i < KW_CATEGORIES.length; i++) {
    list.push({ id: 'kw:' + KW_CATEGORIES[i].key, title: KW_CATEGORIES[i].title });
  }
  return list;
}

async function listItems(input) {
  var args = input || {};
  var page = Number(args.page || 1);
  var categoryId = String(args.categoryId || '').trim();
  var keyword = String(args.keyword || '').trim();

  if (keyword) {
    if (page > 1) return { items: [], hasMore: false };
    return search(keyword);
  }
  if (!categoryId || categoryId === 'new' || categoryId === 'hot') {
    if (page > 1) return { items: [], hasMore: false };
    var pageData = await fetchPage('/', base() + '/');
    if (categoryId === 'hot') {
      var hot = parseHot(pageData.html);
      if (!hot.length) throw new Error('275听书首页没有「热门搜索」块了');
      return { items: hot, hasMore: false };
    }
    var newest = parseHomeNewest(pageData.html);
    if (!newest.length) throw new Error('275听书首页没有解析到「最近上架」');
    return { items: newest, hasMore: false };
  }
  if (categoryId.indexOf('kw:') === 0) {
    if (page > 1) return { items: [], hasMore: false };
    return search(categoryId.slice(3));
  }
  throw new Error('未知分类：' + categoryId + '（站点没有分类页，本源只提供最近上架 / 热门 / 题材搜索）');
}

async function detailOf(input) {
  var id = String((input && input.id) || '').trim();
  if (!id) return null;
  var record = await bookPage(id);
  if (!record || !record.meta) return null;
  return record.meta;
}

async function chaptersOf(input) {
  var id = String((input && input.id) || '').trim();
  if (!id) throw new Error('缺少书号');
  var record = await bookPage(id);
  if (!record || !record.meta) {
    throw new Error('这本书在 275听书上没有内容（书号 ' + id + ' 是空书或已下架），换一本试试');
  }
  var rows = record.chapters || [];
  if (!rows.length) {
    throw new Error('这本书在 275听书上没有目录（书号 ' + id + '），换一本试试');
  }
  return rows;
}

async function contentOf(input) {
  var args = input || {};
  var bookId = String(args.id || '').trim();
  var chapterId = String(args.chapterId || '').trim();
  // 兼容把「书号/章节号」一起塞进 chapterId 的写法
  if (chapterId.indexOf('/') > 0) {
    var parts = chapterId.split('/');
    if (!bookId) bookId = parts[0];
    chapterId = parts[parts.length - 1];
  }
  if (!bookId || !chapterId) throw new Error('缺少书本或章节编号');
  var data = await chapterAudio(bookId, chapterId, false);
  var url = String(data.url == null ? '' : data.url).trim();
  if (/^lrts\$/.test(url)) {
    throw new Error('这一集 275听书只存了懒人畅听的编号（' + url.split('#')[0] + '），本站没有音频文件，换别的书试试');
  }
  if (!/^https?:\/\//i.test(url)) {
    throw new Error('这一集站方没有给音频（接口 url 为空）：新书常常还没上传，换别的书试试');
  }
  var probe = await probeAudio(url);
  if (!probe.ok) {
    throw new Error('站方音频主机拒绝非官方 App 的请求（HTTP 403「' + (probe.body || 'Access Denied') + '」）：' +
      '275听书的音频 CDN 现在只给官方 App 放行，网页/第三方播放器取不到字节，本源不伪造可播地址');
  }
  return {
    kind: 'audio',
    url: url,
    headers: { 'User-Agent': UA, Referer: base() + '/' }
  };
}

var LumeSource = {
  id: 'i275_audiobook',
  name: '275听书',
  version: '1.0.0',
  category: 'audiobook',
  contentCategory: 'movie',
  mediaType: 'audio',
  network: 'direct',
  mirrors: ['https://www.i275.com', 'https://m.i275.com'],
  icon: 'https://www.i275.com/logo192.png',
  settingsApiVersion: 2,
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '275听书（i275.com）是中文有声小说站：首页只有「最近上架」，站点没有分类页，' +
        '本源把站内搜索词做成「题材」分类（站方搜索最多回 50 条、不分页，每个题材一页到底）。' +
        '音频接口需要网页会话，脚本会自己领一次并复用。注意：站方把音频 CDN 收紧成只给官方 App，' +
        '网页/第三方播放器请求会回 403，源里会如实报出来，不给播不响的地址。'
    },
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开站点首页（含 APP 下载）',
      url: 'https://www.i275.com/',
      description: '站点换域名时先看这里；首页右下角是官方 APK/PWA 入口'
    }
  ],

  home: homeBoard,
  categories: categoryList,
  list: listItems,
  detail: detailOf,
  chapters: chaptersOf,
  content: contentOf
};

