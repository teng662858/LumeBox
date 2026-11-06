// LumeSource: {"id":"gmh_comic","name":"G社漫画","version":"1.1.1","category":"comic","mirrors":["https://g-mh.org","https://m.g-mh.org","https://godamanga.com"],"network":"direct","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"note","type":"info","title":"站点说明","description":"G社漫画。正文图片必须使用站点页面 Referer；使用图床自身 Referer 会收到 HTTP 200 的“请到本网站阅读”提示图。本源按实际站点地址传递图片请求头。遇到 Cloudflare 校验时请在网页视图完成校验后重试。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开地址发布页","url":"https://n.telltome.net/","description":"站点导航提供的永久地址发布页。"}],"icon":"https://g-mh.org/favicon.ico"}

// 站点：https://g-mh.org （Astro 静态前端 + 自建 JSON API；简繁同站）
//
// ## 结构（每条都对着**实时页面/接口**核过，快照见 snapshots/gmh_*.html）
//
//   列表  GET /manga/page/{N}   全部漫画（第 1 页是 /manga），18 张卡/页，实测共 100 页；
//         GET /hots 人气推荐、/dayup 热门更新、/newss 最新上架 —— **整表页，只有第 1 页**
//         （实测三页各 18 条、没有分页器）；
//         GET /manga-tag/{tag}/page/{N}、/manga-genre/{genre}/page/{N}  标签 / 题材分类。
//   卡片  `<a href="/manga/{slug}">`（作品 id 就是 slug）：
//           `<img class="card" alt="{slug}" src="https://c-nc-1.6wm.top/manga/{slug}/{hash}.webp">`
//           `<h3 class="cardtitle">{标题}</h3>`
//   详情  GET /manga/{slug}  页面本身**不渲染章节**（Astro 静态壳），但带 `data-mid`：
//           `<div id="mangachapters" data-mid="4418">`
//         章节与详情数据都在自建 API 上（页面自己的 JS 也是这么取的）：
//           GET https://v2.apikk.top/api/v2/manga/get?mid={mid}
//             → {code, status, data: {id, title, slug, cover, desc, status, chapters: [
//                  {id, attributes: {title, slug, order, updatedAt}}, … ]}}
//         实测：接口不需要 Referer/额外头，直连可用；chapters 数组是**旧→新**升序
//         （第一项就是第 01 话），直接按站点顺序交给 App。
//   正文  GET https://v2.apikk.top/api/v2/chapter/getinfo?m={mid}&c={章节id}
//             → {data: {info: {images: {images: "{一串加密文本}", line: 2}, title, slug,
//                        nextslug, prevslug, …}}}
//         **`images.images` 是加过密的**，站点由前端自己的解码器还原：
//           · 前端会加载 /assets/runtime/chapter-decoder.js，然后调 `window.__cimg.r(串)`；
//           · 解码结果 = [{order, url}]，url 是**相对路径**，拼上图片域才是完整地址；
//           · 图片域按 `line` 选：line===2 → https://c-nd2-1.6wm.top，否则 → https://c-nd3-1.6wm.top
//             （站点自己的路由表就是这么映射的；两台上游实测都能取到同一张图）。
//         本源的做法是**把站点自己的解码器拿过来在本源上下文里跑**（不做逆向、不改写它的
//         算法）：取一次源码缓存在沙盒存储里，配一套最小浏览器垫片后 eval，再调它的 r()。
//         实测：解码 38 张图 ≈ 0.9 秒（含解码器加载），在沙箱 10 秒预算内。
//
// ## 站点自己的现实（如实说明）
//
//   · **没有搜索**：导航里的搜索框（`name="q"`）在服务端没有实现——实测 `?q=naruto`
//     返回的还是普通首页、0 条结果；API 也没有搜索端点（/manga/search 等一律 404）。
//     因此本源的关键词搜索**如实拒绝**（抛出可读原因），不返回一份假的「没找到」。
//   · 图片域与 API 都在同一套 CDN/接口上：站点换域名（g-mh.org / godamh.com 同站）时
//     资源地址也会跟着变（封面里就是各自的 c-nc-1.6wm.top）。

var BASE_URL = 'https://g-mh.org';
var API_URL = 'https://v2.apikk.top/api/v2';
var DECODER_URL = '/assets/runtime/chapter-decoder.js';
var DECODER_KEY = 'gmh/decoder.js';

// 同站镜域（g-mh.org 是主域；godamh.com 实测是同一套前端与同一套 API）。
var HOSTS = ['https://g-mh.org', 'https://m.g-mh.org', 'https://godamanga.com'];
var HOST_KEY = 'gmh/host';

// 图片域（站点自己的路由表：line 2 走 nd2，其余走 nd3）。
var IMAGE_HOST_LINE2 = 'https://c-nd2-1.6wm.top';
var IMAGE_HOST_DEFAULT = 'https://c-nd3-1.6wm.top';

var ITEM_WINDOW = 1500;   // 单张卡往后看的窗口
var MAX_ITEMS = 200;      // 单次列表最多产出
var MAX_CHAPTERS = 5000;  // 目录最多解析多少话
var MAX_IMAGES = 800;     // 正文最多收多少张图（实测一话 38 张，留足余量）

var LumeSource = {
  id: 'gmh_comic',
  name: 'G社漫画',
  version: '1.1.1',
  category: 'comic',
  network: 'direct',
  icon: 'https://g-mh.org/favicon.ico',

  // ---------------------------------------------------------------- 契约方法

  /// 分类：四个「整表页」栏目的固定 id + 站点自己的题材/标签（从 /manga 页实时抓）。
  async categories() {
    var result = [
      { id: 'all', title: '全部' },
      { id: 'hots', title: '人气推荐' },
      { id: 'dayup', title: '热门更新' },
      { id: 'newss', title: '最新上架' }
    ];
    try {
      var html = await this.__get('/manga');
      var genres = this.__labels(html, 'manga-genre');
      for (var i = 0; i < genres.length; i++) result.push(genres[i]);
      var tags = this.__labels(html, 'manga-tag');
      for (var j = 0; j < tags.length; j++) result.push(tags[j]);
    } catch (error) {
      console.warn('[gmh] 取题材/标签失败（只用四个栏目）：' + error);
    }
    return result;
  },

  /// 首页：三个整表页各出一块（各 12 条）。逐块 try/catch，站点侧挂了也只丢那一块。
  async home() {
    var boards = [
      { id: 'hots', title: '人气推荐' },
      { id: 'dayup', title: '热门更新' },
      { id: 'newss', title: '最新上架' }
    ];
    var result = [];
    for (var i = 0; i < boards.length; i++) {
      try {
        var payload = await this.list({ categoryId: boards[i].id, page: 1 });
        var items = payload && payload.items ? payload.items : [];
        if (!items.length) continue;
        result.push({
          title: boards[i].title,
          moreUrl: boards[i].id,
          items: items.slice(0, 12)
        });
      } catch (error) {
        console.warn('[gmh] 首页「' + boards[i].title + '」失败：' + error);
      }
    }
    return result;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId).trim() : '';

    // 站点没有搜索（见文件头）：**如实拒绝**，不返回一份假的空结果。
    if (keyword) {
      throw new Error('G社漫画没有搜索入口：站点的搜索框（?q=）在服务端没有实现'
        + '（实测返回的是普通首页），API 也没有搜索端点。请用分类/标签浏览。');
    }

    var url;
    if (!category || category === 'all') {
      url = '/manga' + (page > 1 ? '/page/' + page : '');
    } else if (category === 'hots' || category === 'dayup' || category === 'newss') {
      // 三个整表页：站点没有分页器，第 2 页不去请求一个不存在的地址。
      if (page > 1) return { items: [], hasMore: false };
      url = '/' + category;
    } else if (category.indexOf('tag:') === 0) {
      url = '/manga-tag/' + encodeURIComponent(category.slice(4))
        + (page > 1 ? '/page/' + page : '');
    } else if (category.indexOf('genre:') === 0) {
      url = '/manga-genre/' + encodeURIComponent(category.slice(6))
        + (page > 1 ? '/page/' + page : '');
    } else {
      url = '/manga' + (page > 1 ? '/page/' + page : '');
    }

    var html = await this.__get(url);
    var items = this.__items(html);
    return { items: items, hasMore: this.__hasNextPage(html) };
  },

  async detail(argument) {
    var slug = this.__slug(argument);
    // 作品页一次拿全：data-mid（章节接口要用）+ 标题/封面/简介/作者/题材/标签。
    var page = await this.__pageInfo(slug);
    var info = null;
    try {
      info = await this.__manga(page.mid);
    } catch (error) {
      console.warn('[gmh] 详情接口失败（用页面上的信息继续）：' + error);
    }
    var chapters = this.__chapterList(info);
    var title = page.title || (info ? String(info.title || '') : '');
    if (!title) {
      console.warn('[gmh] 作品页没认出标题：' + slug);
      return null;
    }
    var parts = [];
    if (page.status) parts.push(page.status);
    if (chapters.length) parts.push('共 ' + chapters.length + ' 话');
    if (page.author) parts.push('作者：' + page.author);
    return {
      id: slug,
      title: title,
      cover: page.cover || (info ? String(info.cover || '') : ''),
      subtitle: parts.join(' · '),
      description: page.description || (info ? this.__clean(String(info.desc || '')) : ''),
      tags: page.tags,
      extra: {
        mid: page.mid,
        author: page.author,
        genre: page.genre,
        status: page.status,
        chapters: chapters.length
      }
    };
  },

  async chapters(argument) {
    var slug = this.__slug(argument);
    var page = await this.__pageInfo(slug);
    var info = await this.__manga(page.mid);
    var chapters = this.__chapterList(info);
    if (!chapters.length) {
      throw new Error('G社漫画：这一部没有章节（' + slug + '）——站点可能把章节挪到了别处');
    }
    return chapters;
  },

  async content(argument) {
    var slug = this.__slug(argument);
    var chapterId = argument && argument.chapterId ? String(argument.chapterId).trim() : '';
    if (!chapterId) throw new Error('G社漫画：缺少章节 id（请重新进一次目录）');
    var page = await this.__pageInfo(slug);
    var mid = page.mid;

    var response = await this.__api('/chapter/getinfo?m=' + encodeURIComponent(mid)
      + '&c=' + encodeURIComponent(chapterId));
    var info = response && response.data ? response.data.info : null;
    if (!info || !info.images) {
      throw new Error('G社漫画：这一话拿不到图片数据（' + slug + '/' + chapterId + '）');
    }
    var packed = info.images;
    var host = Number(packed.line) === 2 ? IMAGE_HOST_LINE2 : IMAGE_HOST_DEFAULT;
    var decoded = await this.__decode(String(packed.images || ''));
    var images = [];
    for (var i = 0; i < decoded.length && images.length < MAX_IMAGES; i++) {
      var entry = decoded[i] || {};
      var path = String(entry.url || '');
      if (!path) continue;
      images.push(path.indexOf('http') === 0 ? path : host + path);
    }
    if (!images.length) {
      throw new Error('G社漫画：解码后没有图片（' + slug + '/' + chapterId + '）');
    }
    // The CDN returns a valid 200 warning image for its own origin Referer.
    // ImageContent uses per-URL imageHeaders, not the video-only headers field.
    var imageHeaders = {};
    var requestHeaders = {
      Referer: (await this.__host()).replace(/\/+$/, '') + '/',
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
    };
    for (var j = 0; j < images.length; j++) imageHeaders[images[j]] = requestHeaders;
    return { kind: 'images', images: images, imageHeaders: imageHeaders };
  },

  // ---------------------------------------------------------------- 站点解码器

  /// 用**站点自己的解码器**把加密串还原成 [{order, url}]。
  ///
  /// 步骤：取源码（优先沙盒缓存）→ 配最小浏览器垫片 → eval → 调 `window.__cimg.r(串)`。
  /// 垫片只需要 `location`（实测：去掉它会报错，其余都是防御性补齐）；
  /// TextDecoder/TextEncoder 是 Comic 板块没有的环境垫片（猫源才有），这里自带一份。
  async __decode(packed) {
    var source = '';
    try {
      // 解码器是混淆过的：**不能**用 `__cimg` 之类字面量判断内容对不对（标识符在
      // 字符串表里拼出来），只做体积兜底，真正的校验在 eval 之后（拿不到 __cimg.r 就抛）。
      var cached = await LumeSource.fs.readText(DECODER_KEY);
      if (cached && cached.length > 5000) source = cached;
    } catch (error) { /* 没缓存就现取 */ }
    if (!source) {
      source = await this.__raw(DECODER_URL);
      if (source.length < 5000) {
        throw new Error('G社漫画：站点解码器内容不对（只有 ' + source.length
          + ' 字节）——站点可能换了解码器');
      }
      try { await LumeSource.fs.writeText(DECODER_KEY, source); } catch (error) { /* 存不下也能用 */ }
    }

    this.__shimBrowser(await this.__host());
    var global_ = (function () { return this; })();
    if (!(global_.window && global_.window.__cimg && global_.window.__cimg.r)) {
      // 间接 eval：解码器是 IIFE，挂在全局 window 上。
      var evaluate = eval;
      evaluate(source);
    }
    var decoder = global_.window && global_.window.__cimg ? global_.window.__cimg.r : null;
    if (typeof decoder !== 'function') {
      throw new Error('G社漫画：解码器没有就绪（站点改了加载方式）');
    }
    var result = await decoder(packed);
    return Array.isArray(result) ? result : [];
  },

  /// 最小浏览器环境（幂等）。只做「让解码器跑起来」这一件事。
  __shimBrowser(host) {
    var g = (function () { return this; })();
    if (g.window && g.window.__gmhShim) return;
    var origin = host || BASE_URL;
    var location_ = {
      href: origin + '/manga/x/y', origin: origin, protocol: 'https:',
      host: origin.replace(/^https?:\/\//, ''), hostname: origin.replace(/^https?:\/\//, ''),
      pathname: '/manga/x/y', search: '', hash: ''
    };
    var element = {
      style: {}, dataset: {},
      addEventListener: function () {}, appendChild: function () {},
      setAttribute: function () {}, removeAttribute: function () {},
      getAttribute: function () { return null; },
      classList: { add: function () {}, remove: function () {}, contains: function () { return false; } },
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      getContext: function () { return null; }
    };
    var document_ = {
      createElement: function () { return element; },
      createElementNS: function () { return element; },
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      getElementById: function () { return null; },
      addEventListener: function () {},
      cookie: '', URL: location_.href, referrer: location_.href, readyState: 'complete',
      head: element, body: element, documentElement: element
    };
    var storage = {
      getItem: function () { return null; },
      setItem: function () {}, removeItem: function () {}, clear: function () {}
    };
    g.window = g;
    g.self = g;
    g.document = document_;
    g.location = location_;
    g.localStorage = storage;
    g.sessionStorage = storage;
    g.navigator = {
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        + 'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      platform: 'iPhone', language: 'zh-CN', hardwareConcurrency: 8
    };
    g.screen = { width: 390, height: 844, colorDepth: 32 };
    g.history = { pushState: function () {}, replaceState: function () {} };
    g.performance = { now: function () { return new Date().getTime(); } };
    g.Image = function () {};
    g.XMLHttpRequest = function () {
      this.open = function () {}; this.send = function () {}; this.setRequestHeader = function () {};
    };
    g.window.__gmhShim = true;

    // atob/btoa：QuickJS 自带，这里补一份纯 JS 实现，保证任何引擎/测试环境下都能跑。
    if (typeof g.atob === 'undefined') {
      g.atob = function (text) {
        var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        var clean = String(text || '').replace(/[^A-Za-z0-9+/=]/g, '');
        var out = '';
        var buffer = 0;
        var bits = 0;
        for (var i = 0; i < clean.length; i++) {
          var ch = clean.charAt(i);
          if (ch === '=') break;
          var value = alphabet.indexOf(ch);
          if (value < 0) continue;
          buffer = (buffer << 6) | value;
          bits += 6;
          if (bits >= 8) {
            bits -= 8;
            out += String.fromCharCode((buffer >> bits) & 0xff);
          }
        }
        return out;
      };
    }
    if (typeof g.btoa === 'undefined') {
      g.btoa = function (text) {
        var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        var input = String(text == null ? '' : text);
        var out = '';
        var i = 0;
        while (i < input.length) {
          var c1 = input.charCodeAt(i++) & 0xff;
          var c2 = i < input.length ? input.charCodeAt(i++) & 0xff : NaN;
          var c3 = i < input.length ? input.charCodeAt(i++) & 0xff : NaN;
          out += alphabet.charAt(c1 >> 2);
          out += alphabet.charAt(((c1 & 3) << 4) | (isNaN(c2) ? 0 : c2 >> 4));
          out += isNaN(c2) ? '=' : alphabet.charAt(((c2 & 15) << 2) | (isNaN(c3) ? 0 : c3 >> 6));
          out += isNaN(c3) ? '=' : alphabet.charAt(c3 & 63);
        }
        return out;
      };
    }

    // Comic 板块没有 TextDecoder/TextEncoder（猫源垫片才有），这里补一份最小实现。
    if (typeof g.TextDecoder === 'undefined') {
      var Decoder = function (label) { this.encoding = label || 'utf-8'; };
      Decoder.prototype.decode = function (bytes) {
        var view = bytes;
        if (view && view.buffer && view.length === undefined) view = new Uint8Array(view.buffer);
        if (!view || view.length === undefined) return '';
        var out = '';
        var i = 0;
        while (i < view.length) {
          var b = view[i++];
          var code;
          if (b < 0x80) code = b;
          else if (b >= 0xc0 && b < 0xe0) code = ((b & 0x1f) << 6) | (view[i++] & 0x3f);
          else if (b >= 0xe0 && b < 0xf0) {
            code = ((b & 0x0f) << 12) | ((view[i++] & 0x3f) << 6) | (view[i++] & 0x3f);
          } else {
            code = ((b & 0x07) << 18) | ((view[i++] & 0x3f) << 12)
              | ((view[i++] & 0x3f) << 6) | (view[i++] & 0x3f);
          }
          if (code > 0xffff) {
            code -= 0x10000;
            out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
          } else {
            out += String.fromCharCode(code);
          }
        }
        return out;
      };
      g.TextDecoder = Decoder;
    }
    if (typeof g.TextEncoder === 'undefined') {
      var Encoder = function () {};
      Encoder.prototype.encode = function (input) {
        var text = String(input == null ? '' : input);
        var bytes = [];
        for (var i = 0; i < text.length; i++) {
          var code = text.charCodeAt(i);
          if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
            var next = text.charCodeAt(i + 1);
            if (next >= 0xdc00 && next <= 0xdfff) {
              code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
              i++;
            }
          }
          if (code < 0x80) bytes.push(code);
          else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
          else if (code < 0x10000) {
            bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
          } else {
            bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
              0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
          }
        }
        return new Uint8Array(bytes);
      };
      g.TextEncoder = Encoder;
    }
  },

  // ---------------------------------------------------------------- 内部工具

  __slug(argument) {
    // 传参口径兼容 `id` / `itemId` / `url`：契约是 id，但存量的自检脚本用 itemId。
    var id = '';
    var keys = ['id', 'itemId', 'url'];
    for (var k = 0; argument && k < keys.length && !id; k++) {
      if (argument[keys[k]] != null) id = String(argument[keys[k]]).trim();
    }
    if (!id) throw new Error('G社漫画：缺少作品 slug（请从列表重新打开）');
    // 容错：只留 slug 段（传进来的是完整地址也能用）。
    var marker = id.indexOf('/manga/');
    if (marker >= 0) id = id.slice(marker + '/manga/'.length);
    return id.replace(/^\/+|\/+$/g, '');
  },

  /// 作品页一次拿全：数字 id（章节接口要它）+ 页面上渲染的元信息。
  async __pageInfo(slug) {
    var html = await this.__get('/manga/' + encodeURIComponent(slug));
    var midMatch = /id="mangachapters"\s+data-mid="(\d+)"/.exec(html)
      || /data-mid="(\d+)"/.exec(html);
    if (!midMatch) {
      throw new Error('G社漫画：作品页没读出 data-mid（' + slug + '）——站点可能改了标记');
    }
    // 标题：<h1> 里除标题外还挂着状态徽章（連載中/已完結）。
    var titleMatch = /<h1[^>]*>([\s\S]{0,300}?)<\/h1>/.exec(html);
    var status = '';
    var title = '';
    if (titleMatch) {
      var h1 = titleMatch[1];
      var statusMatch = />\s*(連載中|连载中|已完結|已完结|休載中)\s*</.exec(h1);
      if (statusMatch) status = statusMatch[1];
      title = this.__clean(h1);
    }
    // 封面：og:image 是**本作**的封面；页面里的 img.card 是「推荐位」卡片
    // （实测第一张属于别的作品），只能当兜底。
    var coverMatch = /<meta property="og:image" content="([^"]+)"/.exec(html)
      || /<img[^>]+class="card"[^>]+src="([^"]+)"/.exec(html)
      || /"thumbnailUrl":\["([^"]+)"/.exec(html);
    var descMatch = /<p class="text-medium[^"]*">([\s\S]{0,4000}?)<\/p>/.exec(html);
    var authorMatch = /href="\/manga-author\/([^"]+)"[^>]*>\s*<span>\s*([^<]*?)<\/span>/.exec(html);
    var genreMatch = /href="\/manga-genre\/([^"]+)"[^>]*>\s*<span>\s*([^<]*?)<\/span>/.exec(html);
    var tags = [];
    var tagPattern = /href="\/manga-tag\/([^"]+)"[^>]*>\s*<span[^>]*>\s*#?([^<]{1,20})<\/span>/g;
    var tagMatch;
    while ((tagMatch = tagPattern.exec(html)) !== null) {
      var label = this.__clean(tagMatch[2]).replace(/^#/, '');
      if (label && tags.indexOf(label) < 0 && tags.length < 12) tags.push(label);
    }
    return {
      mid: midMatch[1],
      title: title.replace(status, '').trim() || this.__clean(titleMatch ? titleMatch[1] : ''),
      status: status,
      cover: coverMatch ? this.__absolute(coverMatch[1]) : '',
      description: this.__clean(descMatch ? descMatch[1] : '').replace(/^[:：]/, ''),
      author: this.__clean(authorMatch ? authorMatch[2] : ''),
      genre: this.__clean(genreMatch ? genreMatch[2] : ''),
      tags: tags
    };
  },

  async __manga(mid) {
    var response = await this.__api('/manga/get?mid=' + encodeURIComponent(mid));
    return response && response.data ? response.data : null;
  },

  /// 章节：用接口里的 chapters 数组（站点顺序＝旧→新，直接给 App）。
  __chapterList(info) {
    var raw = info && info.chapters && info.chapters.length ? info.chapters : [];
    var chapters = [];
    for (var i = 0; i < raw.length && chapters.length < MAX_CHAPTERS; i++) {
      var entry = raw[i] || {};
      var attributes = entry.attributes || {};
      if (entry.id == null) continue;
      var title = this.__clean(String(attributes.title || ''));
      chapters.push({
        id: String(entry.id),
        title: title || ('第 ' + (i + 1) + ' 话')
      });
    }
    return chapters;
  },

  /// 列表页的条目（`a[href=/manga/{slug}]` + `img.card` + `h3.cardtitle`）。
  __items(html) {
    var items = [];
    var seen = {};
    var pattern = /<a href="\/manga\/([^"\/]+)"[^>]*>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      if (items.length >= MAX_ITEMS) break;
      var slug = match[1];
      if (seen[slug]) continue;
      seen[slug] = true;
      var block = html.slice(match.index, match.index + ITEM_WINDOW);
      var coverMatch = /<img[^>]+class="card"[^>]+src="([^"]+)"/.exec(block)
        || /<img[^>]+src="([^"]+)"[^>]*class="card"/.exec(block);
      var titleMatch = /class="cardtitle"[^>]*>([^<]*)</.exec(block);
      var title = this.__clean(titleMatch ? titleMatch[1] : '');
      items.push({
        id: slug,
        title: title || slug,
        cover: coverMatch ? this.__absolute(coverMatch[1]) : '',
        subtitle: ''
      });
    }
    return items;
  },

  /// 题材/标签：`href="/manga-{kind}/{slug}"`，标题取链接文本（去掉 # 与按钮壳）。
  __labels(html, kind) {
    var pattern = new RegExp('<a href="/' + kind + '/([^"\\/]+)"[^>]*>([\\s\\S]{0,200}?)<\\/a>', 'g');
    var result = [];
    var seen = {};
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var slug = match[1];
      if (seen[slug]) continue;
      var title = this.__clean(match[2]).replace(/^#/, '').replace(/[#>]/g, '').trim();
      if (!title) continue;
      seen[slug] = true;
      result.push({
        id: (kind.indexOf('genre') >= 0 ? 'genre:' : 'tag:') + slug,
        title: title
      });
    }
    return result;
  },

  __hasNextPage(html) {
    return /href="[^"]*\/page\/\d+"/.test(html);
  },

  __absolute(url) {
    var value = String(url || '').trim();
    if (!value) return '';
    if (value.indexOf('http') === 0) return value;
    if (value.indexOf('//') === 0) return 'https:' + value;
    return BASE_URL + (value.charAt(0) === '/' ? '' : '/') + value;
  },

  __clean(text) {
    return String(text || '')
      .replace(/<[^>]*>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/\s+/g, ' ')
      .trim();
  },

  // ---------------------------------------------------------------- 网络

  /// 前端页面（自动换镜域）。
  async __get(path) {
    var hosts = await this.__hostList();
    var lastFailure = '';
    var blocked = '';
    for (var i = 0; i < hosts.length; i++) {
      var url = hosts[i] + (path.indexOf('http') === 0 ? '' : path);
      var target = path.indexOf('http') === 0 ? path : url;
      var response = null;
      try {
        response = await LumeSource.http.get(target, { headers: { 'Referer': hosts[i] + '/' } });
      } catch (error) {
        // 连不上（域名被重置 / DNS 失败）：换下一个域，别当成站点错误。
        lastFailure = String(error);
        await this.__forgetHost(hosts[i]);
        continue;
      }
      var status = response ? Number(response.status) : 0;
      var body = response && response.body ? String(response.body) : '';
      if (status === 200) {
        await this.__rememberHost(hosts[i]);
        if (/just a moment|checking your browser|attention required|__cf_chl|cf-chl-/.test(body.slice(0, 4000))) {
          throw new Error('NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP '
            + status + ' ' + target + '）');
        }
        return body;
      }
      if (status === 403 || status === 429 || status === 503) {
        // 站点防护拦下（网页视图有机会救回来）：先换域，全都不行时给网页视图。
        blocked = 'HTTP ' + status + ' ' + target;
        await this.__forgetHost(hosts[i]);
        continue;
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + target);
    }
    if (blocked) {
      throw new Error('NEED_WEBVIEW_VERIFY：G社漫画的候选域都被站点防护拦下（'
        + blocked + '）——可在网页视图里过一次校验再重试');
    }
    throw new Error('连不上 G社漫画（候选域：' + hosts.join('、') + '；最后一次失败：'
      + lastFailure + '）');
  },

  /// 取原始文本（解码器源码用；不走 __get 的自动换域，直接指到可用域）。
  async __raw(path) {
    var host = await this.__host();
    var response = await LumeSource.http.get(host + path);
    if (!response || Number(response.status) !== 200) {
      throw new Error('G社漫画：取站点解码器失败（HTTP '
        + (response ? response.status : 0) + '）');
    }
    return String(response.body || '');
  },

  /// 自建 API（v2.apikk.top，不走镜域切换）。
  async __api(path) {
    var response = await LumeSource.http.get(API_URL + path, {
      headers: { 'Accept': 'application/json, text/plain, */*' }
    });
    var status = response ? Number(response.status) : 0;
    var body = response && response.body ? String(response.body) : '';
    if (status !== 200) {
      throw new Error('G社漫画接口失败：HTTP ' + status + ' ' + API_URL + path);
    }
    var parsed;
    try {
      parsed = JSON.parse(body);
    } catch (error) {
      throw new Error('G社漫画接口返回的不是 JSON：' + path);
    }
    if (parsed && parsed.code != null && Number(parsed.code) !== 200
      && !(parsed.status === true || parsed.status === 1)) {
      throw new Error('G社漫画接口错误：' + (parsed.msg || parsed.code) + ' ' + path);
    }
    return parsed;
  },

  async __hostList() {
    var hosts = [];
    // App 注入的域名（自定义域名 > 选中镜像）权重最高：注入发生在脚本加载之后，
    // 所以每次取列表都现读 config，而不是在模块顶层算一次。
    try {
      var injected = (typeof LumeSource !== 'undefined' && LumeSource.config)
        ? String(LumeSource.config.domain || '').replace(/\/+$/, '') : '';
      if (injected) hosts.push(injected);
    } catch (error) { /* 老版本 App 没有 config */ }
    try {
      var saved = await LumeSource.fs.readText(HOST_KEY);
      if (saved && saved.indexOf('http') === 0) hosts.push(saved);
    } catch (error) { /* 读不到就按默认顺序 */ }
    for (var i = 0; i < HOSTS.length; i++) {
      if (hosts.indexOf(HOSTS[i]) < 0) hosts.push(HOSTS[i]);
    }
    return hosts;
  },

  async __host() {
    var list = await this.__hostList();
    return list[0];
  },

  async __rememberHost(host) {
    try {
      var saved = await LumeSource.fs.readText(HOST_KEY);
      if (saved !== host) await LumeSource.fs.writeText(HOST_KEY, host);
    } catch (error) { /* 存不下也能用 */ }
  },

  async __forgetHost(host) {
    try {
      var saved = await LumeSource.fs.readText(HOST_KEY);
      if (saved === host) await LumeSource.fs.remove(HOST_KEY);
    } catch (error) { /* 删不掉也不影响本次 */ }
  }
};
