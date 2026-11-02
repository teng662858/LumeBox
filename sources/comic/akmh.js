// LumeSource: {"id":"akmh_comic","name":"18ak漫画","version":"1.0.0","category":"comic","contentCategory":"adult","mirrors":["https://www.18akmanhua.com"],"network":"direct","icon":"https://www.18akmanhua.com/logo.png"}
// LumeRuntime: javascript
//
// 站点：18ak漫画 / 爱看漫画（https://www.18akmanhua.com，全站 18+，Vue3 SPA）
// 来源：从「暮色」App（com.look.mbox）的内置站 akmh 挖出来的漫画板块（同站的视频在 akmh.js）。
//
// 一、协议（与视频源共用）
//   sign = md5(timestamp + "api" + path + "GET" + "6F7A4DF7000C045C636B9123B11E4EC7")
//   响应 {"code":200,"data":{"suffix","data"}}，AES-256-CBC：
//     key = "9a2d65b4a693ad0e40e5b156df25e406"，iv = "9a62e6977b" + suffix
//   （2026-11-03 用 Tabbit 打开站点、点进一本书抓真实请求核对的参数名）
//
// 二、接口
//   GET /api/stacksCategories                          → [{id,name}] 13 个分类
//   GET /api/stacks?page=&size=&type=1[&category=]     → {totalSize, list:[{id,title,author,desc,keyword}]}
//        type=1 是漫画库（实测 6599 部）；category 传分类 id（剧情 604 部）
//   GET /api/bookDetails?book_id=                      → {bookDetail:{id,title,author,desc,keyword,image,view,...}}
//   GET /api/chaptersDirectories?book_id=&sort=0&page=1&size=N
//        → {totalSize, list:[{id,title,image,sort,is_free,price,...}]}
//   GET /api/books?type=1&kind=N                       → 首页分区（新作/推荐…，本源未用）
//
// 三、阅读图片（关键）
//   章节里的 image 是**缩略图**：/toptoon/newtop/content/81213/63041/a.jpg（260x360）
//   正文页是同一目录下的 **数字命名**：1.jpg / 2.jpg / 3.jpg …（实测某章 25 页全在，
//   单页 100–390 KB）。所以 content() 从 image 的目录出发，按 1,2,3… 顺序探，
//   遇到第一个 404 停（上限 60 页，防止异常章节把调用拖长）。
//
// 四、限制
//   · 没有画廊式分页器，只能按数字顺序探；某章中间缺页会被提前截断（实测没见过）。
//   · 付费章（is_free=0 / price>0）图片同样 200——接口层不鉴权。
//   · 无站内搜索接口（/searchBooks 参数未定），本源不做搜索。

var SITE = 'https://www.18akmanhua.com';
var SIGN_SECRET = '6F7A4DF7000C045C636B9123B11E4EC7';
var AES_KEY = '9a2d65b4a693ad0e40e5b156df25e406';
var AES_IV_PREFIX = '9a62e6977b';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 24;
var MAX_PAGES = 60;

function siteBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || SITE).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function media(path) {
  var raw = String(path == null ? '' : path).trim();
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return siteBase() + (raw.charAt(0) === '/' ? '' : '/') + raw;
}

async function api(path, query) {
  var root = siteBase();
  var ts = Math.floor(Date.now() / 1000);
  var sign = await LumeSource.tools.digest('md5', ts + 'api' + path + 'GET' + SIGN_SECRET);
  var url = root + '/api' + path + (query ? '?' + query : '');
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'application/json, text/plain, */*',
      timestamp: String(ts),
      sign: String(sign).toLowerCase(),
      Referer: root + '/',
      Origin: root,
    },
  });
  if (!reply || reply.status !== 200) {
    throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  }
  var wallet;
  try {
    wallet = JSON.parse(String(reply.body || ''));
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  var envelope = wallet && wallet.data;
  if (!envelope || !envelope.data || !envelope.suffix) {
    throw new Error('接口结构变了：' + path + (wallet && wallet.message ? '（' + wallet.message + '）' : ''));
  }
  var plainB64 = await LumeSource.tools.aes({
    key: btoa(AES_KEY),
    iv: btoa(AES_IV_PREFIX + String(envelope.suffix)),
    data: String(envelope.data),
    mode: 'CBC',
    encrypt: false,
  });
  var plain = await LumeSource.tools.base64Decode(plainB64);
  try {
    return JSON.parse(plain);
  } catch (error) {
    throw new Error('响应解不开（站点换密钥了？）：' + path);
  }
}

var CATEGORIES = [
  { id: 'c0', title: '全部', category: '' },
  { id: 'c8', title: '剧情', category: '8' },
  { id: 'c4', title: '爱情', category: '4' },
  { id: 'c12', title: 'BL(无码)', category: '12' },
  { id: 'c5', title: 'BL/GL', category: '5' },
  { id: 'c10', title: '日漫', category: '10' },
  { id: 'c9', title: '真人', category: '9' },
  { id: 'c1', title: '恐/疑', category: '1' },
  { id: 'c11', title: '3D', category: '11' },
  { id: 'c2', title: '搞笑', category: '2' },
  { id: 'c3', title: '小品集', category: '3' },
  { id: 'c6', title: '动作', category: '6' },
  { id: 'c7', title: '奇幻', category: '7' },
];

function categoryOf(id) {
  var key = String(id == null || id === '' ? 'c0' : id);
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === key) return CATEGORIES[i];
  return CATEGORIES[0];
}

function rowOf(v) {
  if (!v) return null;
  var id = String(v.id == null ? '' : v.id);
  if (!id) return null;
  var title = clean(v.title);
  if (!title) return null;
  var bits = [];
  if (v.author) bits.push(clean(v.author));
  if (v.keyword) bits.push(String(v.keyword).replace(/#/g, '').split(',').slice(0, 2).join(' '));
  return { id: id, title: title, cover: media(v.image), subtitle: bits.join(' · ') };
}

var RECENT = {};
function remember(rows) {
  for (var i = 0; i < rows.length; i++) RECENT[rows[i].id] = rows[i];
}

// ---------------- 入口 ----------------
var LumeSource = {
  id: 'akmh_comic',
  name: '18ak漫画',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',
  mirrors: ['https://www.18akmanhua.com'],

  async categories() {
    return CATEGORIES.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async home() {
    var boards = [];
    var plans = [CATEGORIES[0], CATEGORIES[1], CATEGORIES[2]];
    for (var i = 0; i < plans.length; i++) {
      var cat = plans[i];
      try {
        var data = await api('/stacks', 'page=1&size=12&type=1' + (cat.category ? '&category=' + cat.category : ''));
        var list = (data && data.list) || [];
        var rows = [];
        for (var k = 0; k < list.length; k++) {
          var row = rowOf(list[k]);
          if (row) rows.push(row);
        }
        if (rows.length) {
          remember(rows);
          boards.push({ title: cat.title, moreUrl: cat.id, items: rows.slice(0, 12) });
        }
      } catch (error) {
        if (i === 0) throw error;
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口签名或密钥可能变了');
    return boards;
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    if (clean(a.keyword)) throw new Error('这个站没有可用的站内搜索接口');
    var cat = categoryOf(a.categoryId);
    var data = await api('/stacks', 'page=' + page + '&size=' + PAGE_SIZE + '&type=1' + (cat.category ? '&category=' + cat.category : ''));
    var list = (data && data.list) || [];
    var rows = [];
    for (var i = 0; i < list.length; i++) {
      var row = rowOf(list[i]);
      if (row) rows.push(row);
    }
    remember(rows);
    var totalPage = Number(data && data.totalPage) || Math.ceil((Number(data && data.totalSize) || 0) / PAGE_SIZE);
    return { items: rows, hasMore: totalPage ? page < totalPage : rows.length >= PAGE_SIZE };
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var data = await api('/bookDetails', 'book_id=' + id);
    var d = (data && data.bookDetail) || null;
    if (!d) return null;
    var row = { id: id, title: clean(d.title), cover: media(d.image) };
    remember([row]);
    var desc = [];
    if (d.author) desc.push('作者 ' + clean(d.author));
    if (d.keyword) desc.push('标签 ' + String(d.keyword).replace(/#/g, '').split(',').filter(Boolean).join('・'));
    if (d.view) desc.push('阅读 ' + d.view);
    if (d.desc) desc.push('', clean(d.desc));
    return {
      id: id,
      title: clean(d.title) || id,
      cover: media(d.image),
      subtitle: clean(d.author),
      description: desc.join('\n'),
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    var data = await api('/chaptersDirectories', 'book_id=' + id + '&sort=0&page=1&size=500');
    var list = (data && data.list) || [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (!c || c.id == null) continue;
      out.push({ id: String(c.id) + '@' + String(c.image || ''), title: clean(c.title) || ('第 ' + (i + 1) + ' 话') });
    }
    if (!out.length) throw new Error('这本书没有章节（可能已下架）');
    return out;
  },

  async content(args) {
    var chapterId = String((args && (args.chapterId || args.id)) || '');
    if (!chapterId) throw new Error('缺少章节 ID');
    var at = chapterId.indexOf('@');
    var thumb = at >= 0 ? chapterId.slice(at + 1) : '';
    var root = siteBase();
    // 章节图的目录来自缩略图：/toptoon/newtop/content/81213/63041/a.jpg → 去掉文件名得到目录
    var dir = '';
    var raw = thumb.replace(/^https?:\/\/[^/]+/i, '');
    var cut = raw.lastIndexOf('/');
    if (cut > 0) dir = raw.slice(0, cut + 1);
    if (!dir) throw new Error('章节图目录拿不到（章节信息过期，回目录重进一次）');

    var images = [];
    // 并发探：一批 10 张，遇到第一张不存在的就停。
    // 串行探 60 页要 11 秒（超 App 单次 5 秒预算），并发后约 1–2 秒。
    var batch = 10;
    var stopped = false;
    for (var start = 1; start <= MAX_PAGES && !stopped; start += batch) {
      var jobs = [];
      for (var i = start; i < start + batch && i <= MAX_PAGES; i++) {
        jobs.push((function (index) {
          var target = root + dir + index + '.jpg';
          return LumeSource.http
            .get(target, { headers: { 'User-Agent': UA, Referer: root + '/', Range: 'bytes=0-1023' } })
            .then(function (head) {
              return { url: target, ok: !!head && (head.status === 200 || head.status === 206) };
            })
            .catch(function () {
              return { url: target, ok: false };
            });
        })(i));
      }
      var results = await Promise.all(jobs);
      for (var k = 0; k < results.length; k++) {
        if (!results[k].ok) {
          stopped = true;
          break;
        }
        images.push(results[k].url);
      }
    }
    if (!images.length) throw new Error('这一章没探到图片（站点可能换了图片命名）');
    return {
      kind: 'images',
      images: images,
      headers: { 'User-Agent': UA, Referer: siteBase() + '/' },
    };
  },
};
