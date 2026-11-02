// LumeSource: {"id":"yeshezy_video","name":"夜社资源","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://yeshezy1.com"],"network":"direct","icon":"https://yeshezy1.com/template/panghu/images/ico/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"夜社资源（yeshezy1.com，苹果CMS + panghu 模板）是综合成人资源站：视频 / 有声 / 写真 / 漫画 / 小说 / 夜生活 / 影视 七大类。列表与详情页都是匿名 GET，视频与有声在详情页直接内联 m3u8（实测 200 + #EXTM3U，分片可取），写真与漫画内联图片直链，小说章节是正文页。本源把七大类都收进来：视频/有声走原生播放，写真/漫画与小说走内嵌网页阅读（App 视频板块不渲染图片与文本）。站点给站长采集用的 /api.php/provide/vod 需要授权域名，本源不用它。"}]}
// LumeRuntime: javascript
//
// 站点：夜社资源（https://yeshezy1.com）—— 苹果CMS（maccms）+ panghu 模板的**综合**成人资源站。
// 统计口径（首页）：15.9w 视频 / 2.1w 有声 / 10.7w 写真 / 3.2w 漫画 / 2.5w 小说 / 12.7w 影视。
//
// 页面结构（2026-11-02 实测，全部匿名 GET、无签名、无登录）：
//   分类      /vodtype/<cid>.html     第 N 页 /vodtype/<cid>-<N>.html   （30 条/页）
//   视频详情  /voddetail/<vodId>.html → 「第1集$https://…/play.m3u8」逐集内联
//   视频播放  /vodplay/<vodId>-<线路>-<集>.html
//   图集详情  /voddetail/<vodId>.html → 「1P$https://…/001.jpg」逐页内联（写真/漫画同构）
//   小说分类  /arttype/<aid>.html     第 N 页 /arttype/<aid>-<N>.html
//   小说详情  /artdetail-<artId>.html → 章节 /artrss-<artId>/nid/<n>.html（正文页）
//   搜索      /vodsearch/<词>----------<N>---.html                  （20 条/页）
//
// 采集 API /api.php/provide/vod/ 返回「域名未授权」——那是给站长绑域名用的，本源全程走页面解析。
//
// 形态分派（App 的视频板块只渲染 video/audio，图片与文本会走内嵌网页）：
//   · 详情页里有 .m3u8 → kind:'video'；分类属于有声三组（11/12/13）→ kind:'audio'
//   · 详情页里是图片直链（写真 14/15/16/17/18/44、漫画 19/20/21）→ kind:'webplayer'，pageUrl 指站点播放页
//   · 小说（art）→ kind:'webplayer'，pageUrl 指章节正文页
//
// 失效预案：站点换域名时改 MIRRORS / BASE_FALLBACK；m3u8 403 时补 Referer；
// 详情页不再内联地址时，去 /vodplay/<id>-1-<集>.html 里找（播放页结构同理）。

var BASE_FALLBACK = 'https://yeshezy1.com';
var MIRRORS = ['https://yeshezy1.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

// 有声三组：这几个分类的 m3u8 是音频 HLS，交给 App 的音频通路
var AUDIO_TYPES = { 11: true, 12: true, 13: true };

var CATEGORIES = [
  { id: 't1', title: '全部视频' },
  { id: 't28', title: '视频 · AI短剧' },
  { id: 't10', title: '视频 · 擦边短剧' },
  { id: 't6', title: '视频 · 国产视频' },
  { id: 't7', title: '视频 · 日本AV' },
  { id: 't9', title: '视频 · 欧美情色' },
  { id: 't43', title: '视频 · 韩国BJ' },
  { id: 't8', title: '视频 · H动漫' },
  { id: 't11', title: '有声 · 有声小说' },
  { id: 't12', title: '有声 · 淫词艳曲' },
  { id: 't13', title: '有声 · 激情骚麦' },
  { id: 't14', title: '写真 · 秀人系列' },
  { id: 't16', title: '写真 · 网红COS' },
  { id: 't18', title: '写真 · 各国套图' },
  { id: 't44', title: '写真 · AI绘图' },
  { id: 't17', title: '写真 · 内购私拍' },
  { id: 't15', title: '写真 · 机构套图' },
  { id: 't19', title: '漫画 · 韩国H漫' },
  { id: 't20', title: '漫画 · 日本H漫' },
  { id: 't21', title: '漫画 · 3D漫画' },
  { id: 't46', title: '影视 · 精彩电影' },
  { id: 't47', title: '影视 · 热门网剧' },
  { id: 't48', title: '影视 · 热门综艺' },
  { id: 't49', title: '影视 · 热血动漫' },
  { id: 't50', title: '影视 · 精彩短剧' },
  { id: 't53', title: '影视 · 电影解说' },
  { id: 't51', title: '影视 · 红果短剧' },
  { id: 't52', title: '影视 · 海外短剧' },
  { id: 'a22', title: '小说 · 都市生活' },
  { id: 'a23', title: '小说 · 学生校园' },
  { id: 'a24', title: '小说 · 家庭乱伦' },
  { id: 'a25', title: '小说 · 玄幻武侠' },
  { id: 'a26', title: '小说 · 系统穿越' },
  { id: 'a27', title: '小说 · 同人改编' },
  { id: 'a55', title: '小说 · 泰国夜生活' }
];

var HOME_BOARDS = [
  { title: '最新视频', category: 't1' },
  { title: '有声小说', category: 't11' },
  { title: '写真套图', category: 't14' }
];

var ITEM_CACHE = {};

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var host = (domain || BASE_FALLBACK).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(host)) host = 'https://' + host;
  return host;
}

function headers() {
  return {
    'User-Agent': UA,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': base() + '/'
  };
}

async function fetchHtml(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, { headers: headers() });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：夜社资源被 Cloudflare 挡住（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (/cf-chl-|Just a moment|cf-turnstile/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：夜社资源需要网页验证');
  }
  return body;
}

function clean(text) {
  return String(text == null ? '' : text)
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function absUrl(url) {
  var u = String(url == null ? '' : url).trim();
  if (!u) return '';
  if (u.indexOf('//') === 0) return 'https:' + u;
  if (/^https?:\/\//i.test(u)) return u;
  if (u.charAt(0) === '/') return base() + u;
  return base() + '/' + u;
}

/* ───────────── 列表 ───────────── */

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  // 卡片：<a href="/voddetail/711967.html" title="标题" class="pic">封面 + span.type + span.time</a>
  //       <a href="/voddetail/711967.html" title="标题" class="info"><div class="title">标题</div>…
  var re = /<a[^>]+href="\/voddetail\/(\d+)\.html"[^>]*title="([^"]{0,200})"[^>]*>/g;
  var marks = [];
  var matched;
  while ((matched = re.exec(text)) !== null) {
    marks.push({ at: matched.index, id: matched[1], title: matched[2] });
  }
  for (var i = 0; i < marks.length; i++) {
    var id = marks[i].id;
    if (seen[id]) continue;
    var stop = i + 1 < marks.length ? marks[i + 1].at : Math.min(text.length, marks[i].at + 1200);
    var block = text.slice(marks[i].at, stop);
    var title = clean(marks[i].title);
    if (!title) {
      var titleMatch = /<div class="title"[^>]*>([\s\S]{0,160}?)<\/div>/.exec(block);
      if (titleMatch) title = clean(titleMatch[1]);
    }
    if (!title) continue;
    var coverMatch = /<img[^>]+(?:data-original|data-src|src)="([^"]+)"/i.exec(block);
    var typeMatch = /<span class="type"[^>]*>([\s\S]{0,40}?)<\/span>/.exec(block);
    var timeMatch = /<span class="time"[^>]*>([\s\S]{0,40}?)<\/span>/.exec(block);
    var bits = [];
    if (typeMatch) bits.push(clean(typeMatch[1]));
    if (timeMatch) bits.push(clean(timeMatch[1]));
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: coverMatch ? absUrl(coverMatch[1]) : '',
      subtitle: bits.join(' · ')
    });
  }
  return items;
}

function parseArtCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var re = /<a[^>]+href="\/artdetail-(\d+)\.html"[^>]*title="([^"]{0,200})"[^>]*>/g;
  var marks = [];
  var matched;
  while ((matched = re.exec(text)) !== null) marks.push({ at: matched.index, id: matched[1], title: matched[2] });
  for (var i = 0; i < marks.length; i++) {
    var id = marks[i].id;
    if (seen[id]) continue;
    var stop = i + 1 < marks.length ? marks[i + 1].at : Math.min(text.length, marks[i].at + 1200);
    var block = text.slice(marks[i].at, stop);
    var title = clean(marks[i].title);
    if (!title) {
      var titleMatch = /<div class="title"[^>]*>([\s\S]{0,160}?)<\/div>/.exec(block);
      if (titleMatch) title = clean(titleMatch[1]);
    }
    if (!title) continue;
    var coverMatch = /<img[^>]+(?:data-original|data-src|src)="([^"]+)"/i.exec(block);
    var typeMatch = /<span class="type"[^>]*>([\s\S]{0,40}?)<\/span>/.exec(block);
    seen[id] = true;
    items.push({
      id: 'a' + id,
      title: title,
      cover: coverMatch ? absUrl(coverMatch[1]) : '',
      subtitle: typeMatch ? clean(typeMatch[1]) : '小说'
    });
  }
  return items;
}

function hasNextPage(html, page) {
  var next = Number(page) + 1;
  var text = String(html || '');
  return new RegExp('(?:/vodtype/\\d+-' + next + '\\.html|/arttype/\\d+-' + next + '\\.html|' + next + '---\\.html|class="[^"]*next)').test(text);
}

/* ───────────── 详情 ───────────── */

function parseVodDetail(html, id) {
  var text = String(html || '');
  var titleMatch = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/.exec(text);
  var title = titleMatch ? clean(titleMatch[1]) : '';
  if (!title) {
    var t = /<title>([^<]{0,160})/.exec(text);
    title = t ? clean(t[1]).replace(/详情\s*-\s*夜社资源.*$/, '').trim() : '';
  }
  var coverMatch = /<img[^>]+(?:data-original|data-src|src)="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i.exec(text);
  var cover = coverMatch ? coverMatch[1] : '';
  var flat = clean(text);
  var classify = '';
  var cMatch = /分类：\s*([^\s]{1,16})/.exec(flat);
  if (cMatch) classify = cMatch[1];
  var epsMatch = /集数：\s*(\d+)/.exec(flat);
  var episodes = epsMatch ? Number(epsMatch[1]) : 0;
  var durMatch = /时长：\s*([\d:]{4,12})/.exec(flat);
  var duration = durMatch ? durMatch[1] : '';
  var introsMatch = /(?:视频简介|有声简介|写真简介|漫画简介|简介)[\s\S]{0,30}?<div[^>]*>([\s\S]{0,600}?)<\/div>/.exec(text);
  var intro = introsMatch ? clean(introsMatch[1]) : '';

  // 资源对：第N集$https://…m3u8  或  1P$https://…jpg
  var pairs = [];
  var pairRe = /([^<>\s$"]{1,24})\$((?:https?:)?\/\/[^\s<>"']+)/g;
  var matched;
  while ((matched = pairRe.exec(text)) !== null) {
    var label = matched[1].trim();
    var link = absUrl(matched[2]);
    if (!link) continue;
    if (/\/(?:template|static)\//i.test(link)) continue;
    pairs.push({ label: label, url: link });
  }
  var hasVideo = false;
  var hasImage = false;
  for (var i = 0; i < pairs.length; i++) {
    if (/\.m3u8(\?|$)/i.test(pairs[i].url)) hasVideo = true;
    else if (/\.(jpg|jpeg|png|webp)(\?|$)/i.test(pairs[i].url)) hasImage = true;
  }
  return {
    id: String(id),
    kind: 'vod',
    title: title || String(id),
    cover: cover,
    classify: classify,
    episodes: episodes,
    duration: duration,
    intro: intro,
    pairs: pairs,
    hasVideo: hasVideo,
    hasImage: hasImage
  };
}

function parseArtDetail(html, id) {
  var text = String(html || '');
  var titleMatch = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/.exec(text);
  var title = titleMatch ? clean(titleMatch[1]) : '';
  if (!title) {
    var t = /<title>([^<]{0,160})/.exec(text);
    title = t ? clean(t[1]).replace(/详情\s*-\s*夜社资源.*$/, '').trim() : '';
  }
  var coverMatch = /<img[^>]+(?:data-original|data-src|src)="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i.exec(text);
  var flat = clean(text);
  var classify = '';
  var cMatch = /分类：\s*([^\s]{1,16})/.exec(flat);
  if (cMatch) classify = cMatch[1];
  var introsMatch = /小说简介[\s\S]{0,40}?<div[^>]*>([\s\S]{0,600}?)<\/div>/.exec(text);
  var intro = introsMatch ? clean(introsMatch[1]) : '';
  var chapters = [];
  var chRe = /href="\/artrss-(\d+)\/nid\/(\d+)\.html"[^>]*>([^<]{0,80})</g;
  var matched;
  var seen = {};
  while ((matched = chRe.exec(text)) !== null) {
    var key = matched[2];
    if (seen[key]) continue;
    seen[key] = true;
    chapters.push({ id: matched[2], title: clean(matched[3]) || ('第 ' + matched[2] + ' 章'), artId: matched[1] });
  }
  return {
    id: 'a' + id,
    artId: String(id),
    kind: 'art',
    title: title || String(id),
    cover: coverMatch ? coverMatch[1] : '',
    classify: classify,
    intro: intro,
    chapters: chapters
  };
}

async function loadVod(id) {
  var key = 'v' + id;
  if (ITEM_CACHE[key] && Date.now() - ITEM_CACHE[key].at < 5 * 60 * 1000) return ITEM_CACHE[key].value;
  var value = parseVodDetail(await fetchHtml('/voddetail/' + encodeURIComponent(id) + '.html'), id);
  ITEM_CACHE[key] = { at: Date.now(), value: value };
  return value;
}

async function loadArt(id) {
  var key = 'a' + id;
  if (ITEM_CACHE[key] && Date.now() - ITEM_CACHE[key].at < 5 * 60 * 1000) return ITEM_CACHE[key].value;
  var value = parseArtDetail(await fetchHtml('/artdetail-' + encodeURIComponent(id) + '.html'), id);
  ITEM_CACHE[key] = { at: Date.now(), value: value };
  return value;
}

function splitId(raw) {
  var text = String(raw == null ? '' : raw).trim();
  if (text.charAt(0) === 'a' && /^a\d+$/.test(text)) return { kind: 'art', id: text.slice(1) };
  return { kind: 'vod', id: text.replace(/^v/, '') };
}

/* ───────────── 源对象 ───────────── */

var LumeSource = {
  id: 'yeshezy_video',
  name: '夜社资源',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: MIRRORS,

  async categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    return list;
  },

  async home() {
    var boards = [];
    for (var i = 0; i < HOME_BOARDS.length; i++) {
      var board = HOME_BOARDS[i];
      try {
        var page = await this.list({ page: 1, categoryId: board.category });
        if (page.items.length) boards.push({ title: board.title, moreUrl: board.category, items: page.items.slice(0, 12) });
      } catch (error) { /* 单板块失败不影响其它 */ }
    }
    if (!boards.length) throw new Error('首页板块都没取到：站点可能换了域名或被 Cloudflare 挡住');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var searchPath = '/vodsearch/' + encodeURIComponent(keyword) + '----------' + page + '---.html';
      var searchHtml = await fetchHtml(searchPath);
      var hits = parseCards(searchHtml);
      return { items: hits, hasMore: hits.length >= 20 };
    }

    if (!categoryId) categoryId = 't1';
    if (categoryId.charAt(0) === 'a') {
      var aid = Number(categoryId.slice(1)) || 0;
      var artPath = page > 1 ? '/arttype/' + aid + '-' + page + '.html' : '/arttype/' + aid + '.html';
      var artHtml = await fetchHtml(artPath);
      var artItems = parseArtCards(artHtml);
      return { items: artItems, hasMore: artItems.length >= 30 || hasNextPage(artHtml, page) };
    }
    var cid = Number(categoryId.replace(/^t/, '')) || 1;
    var vodPath = page > 1 ? '/vodtype/' + cid + '-' + page + '.html' : '/vodtype/' + cid + '.html';
    var html = await fetchHtml(vodPath);
    var items = parseCards(html);
    return { items: items, hasMore: items.length >= 30 || hasNextPage(html, page) };
  },

  async detail(argument) {
    var raw = String((argument && argument.id) || '').trim();
    if (!raw) return null;
    var ref = splitId(raw);
    if (ref.kind === 'art') {
      var art = await loadArt(ref.id);
      if (!art.title) return null;
      var artBits = [];
      if (art.classify) artBits.push(art.classify);
      if (art.chapters.length) artBits.push('共 ' + art.chapters.length + ' 章');
      return {
        id: art.id,
        title: art.title,
        cover: art.cover,
        subtitle: artBits.join(' · '),
        tags: art.classify ? [art.classify] : [],
        description: '夜社资源 · 小说（' + base() + '）\n' + (art.intro || '')
      };
    }
    var vod = await loadVod(ref.id);
    if (!vod.title) return null;
    var bits = [];
    if (vod.classify) bits.push(vod.classify);
    if (vod.episodes) bits.push(vod.episodes + ' 集');
    if (vod.duration) bits.push(vod.duration);
    return {
      id: vod.id,
      title: vod.title,
      cover: vod.cover,
      subtitle: bits.join(' · '),
      tags: vod.classify ? [vod.classify] : [],
      description: '夜社资源（' + base() + '）\n' +
        '分类：' + (vod.classify || '-') + '｜集数：' + (vod.episodes || '-') + '｜时长：' + (vod.duration || '-') + '\n' +
        (vod.intro || '')
    };
  },

  async chapters(argument) {
    var raw = String((argument && argument.id) || '').trim();
    if (!raw) return [];
    var ref = splitId(raw);
    if (ref.kind === 'art') {
      var art = await loadArt(ref.id);
      return art.chapters.map(function (ch) { return { id: ch.id, title: ch.title }; });
    }
    var vod = await loadVod(ref.id);
    if (!vod.pairs.length) return [{ id: '0', title: '正片' }];
    var list = [];
    for (var i = 0; i < vod.pairs.length; i++) {
      list.push({ id: String(i), title: vod.pairs[i].label || ('第 ' + (i + 1) + ' 集') });
    }
    return list;
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.id || '').trim();
    if (!raw) throw new Error('缺少条目 ID');
    var ref = splitId(raw);

    if (ref.kind === 'art') {
      var art = await loadArt(ref.id);
      var nid = String(args.chapterId || (art.chapters[0] && art.chapters[0].id) || '1');
      var pageUrl = base() + '/artrss-' + encodeURIComponent(art.artId) + '/nid/' + encodeURIComponent(nid) + '.html';
      return { kind: 'webplayer', pageUrl: pageUrl, headers: headers() };
    }

    var vod = await loadVod(ref.id);
    if (!vod.pairs.length) throw new Error('这条没有解析到播放地址（详情页结构可能变了）');
    var index = Number(args.chapterId || 0);
    if (!isFinite(index) || index < 0) index = 0;
    if (index >= vod.pairs.length) index = 0;
    var pair = vod.pairs[index];

    if (/\.m3u8(\?|$)/i.test(pair.url)) {
      var audio = !!AUDIO_TYPES[Number(vod.classifyId || 0)];
      if (!audio) {
        // 用分类名兜底判断（详情页能拿到的是名称）
        audio = /有声|骚麦|艳曲/.test(String(vod.classify || ''));
      }
      return {
        kind: audio ? 'audio' : 'video',
        url: pair.url,
        headers: { 'User-Agent': UA, 'Referer': base() + '/' }
      };
    }

    // 图集/漫画：App 视频板块不渲染图片，交给内嵌网页阅读
    var playUrl = base() + '/vodplay/' + encodeURIComponent(vod.id) + '-1-' + (index + 1) + '.html';
    return { kind: 'webplayer', pageUrl: playUrl, headers: headers() };
  }
};
