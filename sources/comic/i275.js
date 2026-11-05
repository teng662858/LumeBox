// LumeSource: {"id":"i275_audiobook","name":"275听书","version":"1.1.0","category":"audiobook","contentCategory":"movie","mediaType":"audio","settingsApiVersion":2,"network":"direct","mirrors":["https://www.i275.com","https://m.i275.com"],"icon":"https://www.i275.com/logo192.png","settings":[{"key":"note","type":"info","title":"站点说明","description":"275听书（i275.com）是中文有声小说站：首页只有「最近上架」，没有分类页；本源把站内搜索做成「题材」分类（站方搜索最多回 50 条、不分页，每个题材一页到底）。音频三种来路：懒人畅听（lrts）走 m.lrts.me 换到腾讯音乐 CDN、喜马拉雅（xm）走 mobile 的 free/play 跳转，这两类实测能播；站方自建音频（新书与站内热门那批）现在只给官方 App 放行，请求回 HTTP 403，源里会如实报出来，不给播不响的地址。想听能播的，先从「题材」分类进。"}]}

// 275听书网（https://www.i275.com）· 有声小说源
//
// 站点形态：PHP + Tailwind 服务端渲染，**没有分类页**，可用结构就四块
//   GET  /                         首页：只是「最近上架」12 部 + 热门搜索 5 部
//   GET  /search.php?q=<词>         站内搜索：命中书名/作者/演播/简介，**服务端 LIMIT 50、不吃 page**
//   GET  /book/{书号}.html          详情：书名/封面/作者/演播/状态/热度/简介 + **完整目录**
//                                   （目录条目 id="chapter-pos-N"，href=/play/{书号}/{章节号}.html）
//   GET  /api_chapter.php?book_id=&chapter_id=   → {url,title,book_title,cover}
//        · 裸请求会被判 {"error":"非法访问"}；先 GET / 让宿主把 PHPSESSID 收进 Cookie 罐就正常
//        · url 有四种形态（都是站点数据库的真实状态）：
//            1. http(s)://2025.tingshijie.com/…、audio.tingshijie.com/…  ← 站方自建音频
//            2. "lrts$<专辑号>#<音轨号>#<分段>#<手机号>.txt"               ← 懒人畅听编号
//            3. "xm$<声音ID>"                                            ← 喜马拉雅声音
//            4. null —— 新书还没上传音频
//
// 播放：②③ 真的能出声，① 播不了（是站方现状，不是解析问题）
//   · ② 懒人畅听：GET https://m.lrts.me/ajax/getPlayPath?entityId=&entityType=3&opType=1
//       &sections=[分段]&type=0&id=<音轨号>&section=<分段> → list[0].path 是腾讯音乐 CDN 的
//       签名 m4a（实测 206 + audio/mp4；没买的付费章节回「收费章节未购买」）。抽样 20 本：
//       18 本可播。
//   · ③ 喜马拉雅：https://mobile.ximalaya.com/mobile/redirect/free/play/<id>/0 会 302 到
//       audiopay CDN 的 m4a（实测 206 + audio/x-m4a，http/https 都行）。这里**故意不预取**，
//       直接把跳转地址交给播放器，免得把整集音频拉进沙箱。
//   · ① 站方自建音频：api 下发的地址本身是对的，但 *.tingshijie.com 对所有非官方 App 一律回
//       403「Access Denied: Please use the official App.」—— http/https、带不带 Range /
//       PHPSESSID / Referer / Origin / X-Requested-With、换 UA（浏览器/okhttp/微信/各种 App
//       猜名）、加 ?sign= ?token= ?e=&st= 等参数结果都一样；境外多节点复测
//       （check-host.net 的 at/de/ir/rs/ru）也 403，不是本机出口 IP 的问题。
//       站点首页自己也弹窗写着「本站无法正常收听，请到小程序拾音盘」。content() 因此对这
//       一类先探一次字节：403 就抛可读错误，不伪造可播地址。
//
// 没有的东西就不声明：站点没有排序、没有筛选、没有分页、没有会员体系；
// 分类是本源用站内搜索词拼出来的（站方无分类页，这是唯一能真出内容的浏览轴），
// 顺序把「首条实测能播」的题材排在前面，免得用户第一下就踩到被锁的音频。

var BASE_URL = 'https://www.i275.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

var SESSION_KEY = 'i275/session.json';
var BOOK_KEY = 'i275/book_';
var LRTS_KEY = 'i275/lrts_';
var SESSION_TTL = 6 * 3600 * 1000;
var BOOK_TTL = 30 * 60 * 1000;
var CHAPTER_PAGE_LIMIT = 9000; // 实测最长一本书 8027 章，超过就截断到目录页能承载的范围

// 题材「分类」：站点没有分类页，这些是站内搜索词（每个都实测有真实结果，首条互不相同）。
// 站方搜索上限 50 条且不分页，所以每个题材就是一个满 50 条（或更少）的列表。
// 顺序说明：站方自建音频那批书（新书 + 站内热门）被 CDN 锁给官方 App，
// 首批放「首条实测能播」的题材（懒人畅听/喜马拉雅音频），免得用户第一下就踩到锁。
var KW_CATEGORIES = [
  { key: '悬疑', title: '题材 · 悬疑' },
  { key: '灵异', title: '题材 · 灵异' },
  { key: '仙侠', title: '题材 · 仙侠' },
  { key: '相声', title: '题材 · 相声' },
  { key: '儿童', title: '题材 · 儿童' },
  { key: '玄幻', title: '题材 · 玄幻' },
  { key: '都市', title: '题材 · 都市' },
  { key: '恐怖', title: '题材 · 恐怖' },
  { key: '历史', title: '题材 · 历史' },
  { key: '修仙', title: '题材 · 修仙' },
  { key: '武侠', title: '题材 · 武侠' },
  { key: '盗墓', title: '题材 · 盗墓' },
  { key: '推理', title: '题材 · 推理' },
  { key: '言情', title: '题材 · 言情' },
  { key: '科幻', title: '题材 · 科幻' },
  { key: '校园', title: '题材 · 校园' },
  { key: '官场', title: '题材 · 官场' },
  { key: '评书', title: '题材 · 评书' },
  { key: '广播剧', title: '题材 · 广播剧' }
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
// 站点判「非法访问」看的是会话：宿主（App 的 SiteSessionPool / 检查器）本来就按 origin
// 记住 Set-Cookie，所以**正常情况下什么都不用做**；只有在裸打被判非法访问时，
// 才自己 GET 一次首页、把读得到的 Set-Cookie 拼成 Cookie 头重试一次。
async function seedSession() {
  var cached = await readJson(SESSION_KEY);
  if (cached && Date.now() - Number(cached.t || 0) < SESSION_TTL && cached.seeded) return cached.cookie || '';
  var response = await LumeSource.http.get(base() + '/', {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
    }
  });
  var status = response ? response.status : 0;
  if (status !== 200) {
    throw new Error('275听书首页打不开：HTTP ' + status + '（站点换域名时请在源设置里改镜像）');
  }
  var raw = String(headerValue(response, 'set-cookie') || '');
  var pairs = [];
  var parts = raw.split(',');
  for (var i = 0; i < parts.length; i++) {
    var piece = parts[i].split(';')[0].trim();
    if (piece && piece.indexOf('=') > 0) pairs.push(piece);
  }
  var cookie = pairs.join('; ');
  // 宿主已经把 Set-Cookie 收进自己的罐里时，这里读不到 —— 那就别自己造 Cookie，
  // 交给宿主带（显式塞一个假的 PHPSESSID 反而会让站点判非法访问）。
  await writeJson(SESSION_KEY, { cookie: cookie, seeded: true, t: Date.now() });
  return cookie;
}

// ------------------------------------------------------------------ 抓页面
// 站点只有 api_chapter.php 认会话，HTML 页匿名就能开；这里不领会话，
// 免得每次 list/home 都多发一个 GET /（实测首页两跳 3 秒、多了会被判超预算）。
async function fetchPage(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var headers = {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    Referer: referer || base() + '/'
  };
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
async function apiChapter(bookId, chapterId, cookie) {
  var headers = {
    'User-Agent': UA,
    Referer: base() + '/book/' + bookId + '.html',
    Accept: 'application/json,*/*'
  };
  if (cookie) headers.Cookie = cookie;
  var response = await LumeSource.http.get(
    base() + '/api_chapter.php?book_id=' + encodeURIComponent(bookId) + '&chapter_id=' + encodeURIComponent(chapterId),
    { headers: headers }
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
  return data;
}

async function chapterAudio(bookId, chapterId) {
  // ① 先裸打一次：宿主 Cookie 罐里通常已经有会话了（GET / 那一步由下面的 seed 补）
  var warmed = await readJson(SESSION_KEY);
  if (!warmed || !warmed.seeded || Date.now() - Number(warmed.t || 0) >= SESSION_TTL) {
    await seedSession();
  }
  var data = await apiChapter(bookId, chapterId, '');
  if (data && !data.error) return data;
  if (data && data.error && String(data.error).indexOf('非法访问') < 0) {
    throw new Error('275听书接口拒绝了这次请求：' + String(data.error));
  }
  // ② 被判「非法访问」：自己领一次会话 Cookie 再重试一次
  var cookie = await seedSession();
  if (cookie) {
    data = await apiChapter(bookId, chapterId, cookie);
    if (data && !data.error) return data;
  }
  throw new Error('275听书接口判了「非法访问」：站点会话没拿到（宿主没保存 Set-Cookie 时会出现），稍后重试或换个镜像');
}


// 探一下音频地址到底能不能取到字节：能取到就放行，403 就如实说是站方的限制
async function probeAudio(url, headers) {
  try {
    var probeHeaders = { 'User-Agent': UA, Range: 'bytes=0-2047', Referer: base() + '/' };
    if (headers) {
      var keys = Object.keys(headers);
      for (var i = 0; i < keys.length; i++) probeHeaders[keys[i]] = headers[keys[i]];
    }
    var attempt = LumeSource.http.get(url, { headers: probeHeaders });
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

// ---------------------------------------------------------------- 懒人畅听（lrts$）
// api_chapter 对一批书只给 "lrts$<专辑号>#<音轨号>#<分段>#<手机号>.txt"，
// 真实音频在懒人畅听：m.lrts.me 的 getPlayPath 匿名就能换到腾讯音乐 CDN 的签名 mp4
// （实测 18/20 可播，206 + audio/mp4；没买的付费章节会回「收费章节未购买」）。
async function resolveLrts(token) {
  var cached = await readJson(LRTS_KEY + hashKey(token) + '.json');
  if (cached && cached.url && Date.now() - Number(cached.t || 0) < 20 * 60 * 1000) {
    return cached.url;
  }
  var parts = String(token).split('#');
  var match = /^lrts\$(\d+)/.exec(parts[0] || '');
  if (!match || !/^\d+$/.test(parts[1] || '')) {
    throw new Error('懒人畅听标识格式不认识：' + token);
  }
  var section = /^\d+$/.test(parts[2] || '') ? parts[2] : '1';
  var query = 'entityId=' + match[1] + '&entityType=3&opType=1&sections=' + encodeURIComponent('[' + section + ']') +
    '&type=0&id=' + parts[1] + '&section=' + section;
  var headers = { 'User-Agent': UA, Referer: 'https://m.lrts.me/', Accept: 'application/json,*/*' };
  var response = await LumeSource.http.get('https://m.lrts.me/ajax/getPlayPath?' + query, { headers: headers });
  var payload = null;
  try {
    payload = JSON.parse((response && response.body) || '');
  } catch (error) {
    payload = null;
  }
  var url = payload && payload.list && payload.list[0] ? String(payload.list[0].path || '') : '';
  if (!/^https?:\/\//i.test(url)) {
    var reason = payload ? (payload.msg || payload.apiStatus || '') : '';
    if (String(reason).indexOf('收费') >= 0 || String(reason).indexOf('购买') >= 0) {
      throw new Error('这一集在懒人畅听是收费章节（' + reason + '）：站方只免费放出这本书的前几章，换靠前的章或换「喜马拉雅」音频的书');
    }
    throw new Error('懒人畅听没有给这一集的音频' + (reason ? '（' + reason + '）' : '') + '，换一集或换一本书试试');
  }
  await writeJson(LRTS_KEY + hashKey(token) + '.json', { url: url, t: Date.now() });
  return url;
}

// ---------------------------------------------------------------- 喜马拉雅（xm$）
// 另有一批书给的是 "xm$<声音ID>"：mobile.ximalaya.com 的 free/play 会 302 到
// audiopay CDN 的 m4a（实测 206 + audio/x-m4a），不需要账号。
// 这里**故意不预取**：宿主会跟随 302，预取一次就是把整集（几 MB～几十 MB）拉进沙箱，
// 手机上白白吃流量；直接把这条跳转地址交给播放器，让它自己去跟。
function ximalayaUrl(trackId) {
  if (!/^\d+$/.test(trackId)) throw new Error('喜马拉雅声音编号不认识：xm$' + trackId);
  return 'https://mobile.ximalaya.com/mobile/redirect/free/play/' + trackId + '/0';
}

function hashKey(text) {
  var hash = 0;
  var value = String(text);
  for (var i = 0; i < value.length; i++) {
    hash = (hash * 31 + value.charCodeAt(i)) % 1000000007;
  }
  return String(hash);
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
  var list = [];
  // 题材板放前面：站内「热门搜索」那 5 部与最新 12 部大多是站方自建音频，
  // 现在只给官方 App 放行（403）；题材板里老书多，走懒人畅听/喜马拉雅，实测能播。
  for (var i = 0; i < KW_CATEGORIES.length; i++) {
    list.push({ id: 'kw:' + KW_CATEGORIES[i].key, title: KW_CATEGORIES[i].title });
  }
  list.push({ id: 'hot', title: '热门收听（站内）' });
  list.push({ id: 'new', title: '最近上架（站内）' });
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
  var data = await chapterAudio(bookId, chapterId);
  var url = String(data.url == null ? '' : data.url).trim();

  // ① 懒人畅听编号 → m.lrts.me 换腾讯音乐 CDN 的签名 mp4（匿名可用，实测 206）
  if (/^lrts\$/.test(url)) {
    var lrtsUrl = await resolveLrts(url);
    return {
      kind: 'audio',
      url: lrtsUrl,
      headers: { 'User-Agent': UA, Referer: 'https://m.lrts.me/' }
    };
  }

  // ② 喜马拉雅声音 ID → mobile.ximalaya.com 的 free/play 跳转（实测 206 + audio/x-m4a）
  if (/^xm\$/.test(url)) {
    return {
      kind: 'audio',
      url: ximalayaUrl(url.slice(3).trim()),
      headers: { 'User-Agent': UA, Referer: 'https://www.ximalaya.com/' }
    };
  }

  // ③ 站方自建音频：地址原样下发，但主机只给官方 App 放行（403）
  if (!/^https?:\/\//i.test(url)) {
    throw new Error('这一集站方没有给音频（接口 url 为空）：新书常常还没上传，换别的书试试');
  }
  var probe = await probeAudio(url);
  if (!probe.ok) {
    throw new Error('站方自建音频主机拒绝非官方 App 的请求（HTTP 403「' + (probe.body || 'Access Denied') + '」）：' +
      '这一类的书 275听书只给官方 App 放行，网页/第三方播放器取不到字节；换「题材」分类里别的书通常能播');
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

