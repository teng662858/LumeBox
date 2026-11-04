// LumeSource: {"id":"uaa_video","name":"有爱爱 UAA","version":"1.0.2","category":"video","contentCategory":"adult","mirrors":["https://www.uaa002.com","https://www.uaa001.com","https://www.uaa003.com","https://www.uaa004.com","https://www.uaa005.com","https://www.uaa006.com","https://www.uaa007.com","https://www.uaa008.com","https://www.uaa009.com","https://www.uaa010.com","https://www.uaa2601.com","https://www.uaa2602.com","https://www.uaa2603.com","https://www.uaa2604.com","https://www.uaa2605.com","https://www.uaa2606.com","https://www.uaa2607.com","https://www.uaa2608.com","https://www.uaa2609.com","https://www.uaa2610.com"],"network":"direct","icon":"https://www.uaa002.com/api/web/image/logo.webp","settings":[{"key":"note","type":"info","title":"站点说明","description":"有爱爱 UAA（uaa.com 站群，uaa001–uaa010 / uaa2601–uaa2610 同内容）：视频 / 有声 / 漫画 / 小说 四大库一个源全包，全部匿名可看。网页版被 Cloudflare 人机校验挡着，但 /api/web/* 这条服务端渲染路径不过校验，本源全程走它（列表、详情、章节页），视频/有声的取流走 /api/video|audio/app/*。站点的 VIP / U币 只在前端拦：视频 60 秒试看、每天 10 部/话免费额度、付费章节提示，接口照样下发完整 m3u8 / mp3 / 图片 / 正文（实测见 docs/2026-11-02_UAA有爱爱综合源-VIP绕行.md）。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页","url":"https://www.uaadizhi.com","description":"站点换域名时先看这里（官方永久域名 uaa.com）"}],"contentTypes":["video","audio","comic","novel"]}
// LumeRuntime: javascript
//
// 站点：有爱爱 UAA（www.uaa002.com 等站群；官方永久域名 uaa.com，发布页 uaadizhi.com）
// 形态：Spring Boot 服务端渲染（Thymeleaf）+ 独立 JSON 接口，一个站四个内容库：
//   视频 /api/web/video/*、有声 /api/web/audio/*、漫画 /api/web/comic/*、小说 /api/web/novel/*
//
// ★ 关键通路（2026-11-02 实测）
//   站点根路径被 Cloudflare managed challenge 挡着（curl 直连 403「Just a moment…」，
//   cf-mitigated: challenge，连 /js/、/image/ 都挡），但 **/api/ 前缀不在校验规则里**：
//   · /api/web/<站内路径>  → 直接拿到同一份 SSR HTML（首页/列表/详情/章节/静态资源全通）
//   · /api/video/app/... 、/api/audio/app/... → JSON 接口
//   所以本源不需要网页视图过校验，全程 HTTP 直取。App 自带 UA 实测 200。
//
// ★ VIP / U币 挡在前端（已实测，非绕过登录）
//   · 视频：intro JSON 里 code=1（游客受限，前端 60 秒试看）但 model.url 就是整片 m3u8；
//     实测 xc2026103109 的清单 794 段 / #EXTINF 合计 2381.3 秒，等于详情里的 duration 2381，
//     分片 206 image/jpeg（1,006,364 B）。额度记账是前端到点 POST /video/free/consume，
//     源里**不调**它 + 每次请求现生成 viewId ⇒ 无额度、无试看。
//   · 有声：chapter JSON code=1 + msg「请先登录」，model.url 照样给 mp3（实测 13191.mp3）。
//   · 漫画：章节页内联 var chapter={…}，price 0.3 也把整话 images 全给（实测 26 张 / 48 张）。
//   · 小说：正文就是 SSR 的 div.line，页面标注「字数：N」，实测交付字符数**完全等于** N
//     （4886 / 111），即付费提示只是模板，正文没截断。
//
// ★ 站内搜索
//   网页 SSR 的 ?keyword= 不生效（服务端忽略，仍回默认列表），真搜索只有 JSON：
//   /api/video/app/video/search?keyword=&page=（20 条/页，带 totalPage）。
//   占位：有声/漫画/小说 的 /app/<svc>/search 一律 500，本源搜索只覆盖视频库（其余仍可按分类浏览）。
//
// ★ 失效预案
//   403/521 或 body 出现 cf-chl-/Just a moment ⇒ 站点把 /api/ 也纳进校验了，改走网页视图；
//   m3u8 403 ⇒ 在 headers() 里补 Referer: base() + '/'；CDN 换域 ⇒ 地址都在接口响应里，不用改脚本；
//   站点换域名 ⇒ 源设置切 mirrors，或用发布页 uaadizhi.com。

var BASE_FALLBACK = 'https://www.uaa002.com';
var MIRRORS = ['https://www.uaa002.com', 'https://www.uaa001.com', 'https://www.uaa003.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var PAGE_LIMIT = 48;   // /video|comic|novel|audio/list 每页 48 条
var RANK_LIMIT = 100;  // 排行页固定 100 条且不吃 page 参数
var SEARCH_LIMIT = 20; // JSON 搜索每页 20 条

// 视频：排序 + 地区（origin）。站点 origin=4「正规」与默认列表完全一致、category=AI生成 为 0 条，
// category=日韩片/国产片/欧美片/H动漫 与 origin=2/1/5/3 结果逐条相同，所以只保留 origin 一组。
var VIDEO_CATEGORIES = [
  { id: 'v:new', title: '视频 · 最新', sort: 1 },
  { id: 'v:view', title: '视频 · 最多观看', sort: 3 },
  { id: 'v:collect', title: '视频 · 最多收藏', sort: 4 },
  { id: 'v:o1', title: '视频 · 国产视频', origin: 1 },
  { id: 'v:o2', title: '视频 · 日本AV', origin: 2 },
  { id: 'v:o3', title: '视频 · H动漫', origin: 3 },
  { id: 'v:o5', title: '视频 · 欧美', origin: 5 }
];

var AUDIO_CATEGORIES = [
  { id: 'a:new', title: '有声 · 最新', sort: 2 },
  { id: 'a:hot', title: '有声 · 最多收听', sort: 3 },
  { id: 'a:c:淫词艳曲', title: '有声 · 淫词艳曲', category: '淫词艳曲' },
  { id: 'a:c:激情骚麦', title: '有声 · 激情骚麦', category: '激情骚麦' },
  { id: 'a:c:寸止训练', title: '有声 · 寸止训练', category: '寸止训练' },
  { id: 'a:c:ASMR', title: '有声 · ASMR', category: 'ASMR' },
  { id: 'a:rank', title: '有声 · 收藏榜', path: '/audio/rank' }
];

var COMIC_CATEGORIES = [
  { id: 'c:new', title: '漫画 · 更新', sort: -2 },
  { id: 'c:view', title: '漫画 · 最多观看', sort: 3 },
  { id: 'c:o1', title: '漫画 · 日本H漫', origin: 1 },
  { id: 'c:o2', title: '漫画 · 韩国H漫', origin: 2 },
  { id: 'c:rank', title: '漫画 · 收藏榜', path: '/comic/rank' },
  { id: 'c:rank:new', title: '漫画 · 新作榜', path: '/comic/rank?type=1' }
];

var NOVEL_CATEGORIES = [
  { id: 'n:new', title: '小说 · 更新', sort: 2 },
  { id: 'n:score', title: '小说 · 评分', sort: 5 },
  { id: 'n:meat', title: '小说 · 肉量', sort: 6 },
  { id: 'n:c:都市', title: '小说 · 都市', category: '都市' },
  { id: 'n:c:校园', title: '小说 · 校园', category: '校园' },
  { id: 'n:c:玄幻', title: '小说 · 玄幻', category: '玄幻' },
  { id: 'n:c:系统', title: '小说 · 系统', category: '系统' },
  { id: 'n:c:穿越', title: '小说 · 穿越', category: '穿越' },
  { id: 'n:rank', title: '小说 · 收藏榜', path: '/novel/rank' }
];

var HOME_BOARDS = [
  { title: '最新视频', category: 'v:new' },
  { title: '热门视频', category: 'v:view' },
  { title: '热门漫画', category: 'c:rank' },
  { title: '小说排行', category: 'n:rank' },
  { title: '有声最新', category: 'a:new' }
];

var CACHE = {};

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var host = (domain || BASE_FALLBACK).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(host)) host = 'https://' + host;
  return host.replace(/\/api$/i, '');
}

function headers() {
  return {
    'User-Agent': UA,
    'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Referer': base() + '/'
  };
}

// /api/web 前缀：绕过站点的 Cloudflare 人机校验（实测 /api/ 不在校验规则里）
async function fetchPage(path) {
  var reply = await LumeSource.http.get(base() + '/api/web' + path, { headers: headers() });
  var status = reply ? reply.status : 0;
  var body = reply && reply.body ? String(reply.body) : '';
  if (status === 403 || status === 521 || /Just a moment|cf-chl-|__cf_chl_opt/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：有爱爱把 /api/ 也纳进 Cloudflare 校验了（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return body;
}

function newViewId() {
  // 服务端按 viewId 记账；每次请求现生成一串，等价于「没领过额度」
  return String(Date.now()) + String(1000 + Math.floor(Math.random() * 9000));
}

async function fetchApi(query) {
  var url = base() + '/api' + query + (query.indexOf('?') >= 0 ? '&' : '?') + 'viewId=' + newViewId();
  var h = headers();
  h['token'] = '';
  var reply = await LumeSource.http.get(url, { headers: h });
  var status = reply ? reply.status : 0;
  var body = reply && reply.body ? String(reply.body) : '';
  if (status === 403 || status === 521 || /Just a moment|cf-chl-/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：接口被 Cloudflare 挡住（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('接口打不开：HTTP ' + status + ' ' + query);
  var data = null;
  try { data = JSON.parse(body); } catch (error) { throw new Error('接口返回不是 JSON：' + query); }
  return data;
}

function clean(text) {
  return String(text == null ? '' : text)
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
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

function parseQuery(url) {
  var out = {};
  var idx = String(url || '').indexOf('?');
  if (idx < 0) return out;
  var parts = String(url).slice(idx + 1).split('&');
  for (var i = 0; i < parts.length; i++) {
    var kv = parts[i].split('=');
    if (!kv[0]) continue;
    out[decodeURIComponent(kv[0])] = decodeURIComponent((kv[1] || '').replace(/\+/g, ' '));
  }
  return out;
}

/* ───────────── 列表解析 ───────────── */

// 卡片按 <li class="video_li"> / "comic_li" / "audio_li" / "novel_li_2" 切块
function splitCards(html) {
  var parts = String(html || '').split(/<li class="[a-z_]*(?:video|comic|audio|novel)_li[^"]*">/);
  return parts.length > 1 ? parts.slice(1) : [];
}

// 视频列表卡片：封面 <a href="/video/intro?id=…"> + <div class="title"><a …>标题</a>
function parseVideoCards(html) {
  var blocks = splitCards(html);
  var items = [];
  var seen = {};
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    var idMatch = /\/video\/intro\?id=(\d+)/.exec(block);
    if (!idMatch) continue;
    var id = idMatch[1];
    if (seen[id]) continue;
    var titleMatch = /<div class="title">\s*<a[^>]*>([\s\S]{0,300}?)<\/a>/.exec(block);
    var title = titleMatch ? clean(titleMatch[1]) : '';
    if (!title) {
      var alt = /<a[^>]*title="([^"]{0,300})"/.exec(block);
      if (alt) title = clean(alt[1]);
    }
    if (!title) continue;
    var coverMatch = /<img class="cover"[^>]*src="([^"]+)"/.exec(block);
    var timeMatch = /time\.svg"[^>]*\/>\s*<span>([^<]{0,24})<\/span>/.exec(block);
    var viewMatch = /view\.svg"[^>]*\/>\s*<span>([^<]{0,24})<\/span>/.exec(block);
    var bits = [];
    if (timeMatch) bits.push(clean(timeMatch[1]));
    if (viewMatch) bits.push('播放 ' + clean(viewMatch[1]));
    seen[id] = true;
    items.push({
      id: 'v' + id,
      title: title,
      cover: coverMatch ? absUrl(coverMatch[1]) : '',
      subtitle: bits.join(' · '),
      mediaType: 'video'
    });
  }
  return items;
}

// 漫画/有声/小说卡片：<a href="/comic/intro?id=…" title="…"> 封面 + <div class="title">…
function parseMediaCards(html, kind) {
  var blocks = splitCards(html);
  var items = [];
  var seen = {};
  var idRe = new RegExp('\\/' + kind + '\\/intro\\?id=(\\d+)');
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    var idMatch = idRe.exec(block);
    if (!idMatch) continue;
    var id = idMatch[1];
    if (seen[id]) continue;
    var titleMatch = /<div class="title">\s*(?:<span[^>]*>[^<]*<\/span>\s*)?<a[^>]*>([\s\S]{0,300}?)<\/a>/.exec(block);
    var title = titleMatch ? clean(titleMatch[1]) : '';
    if (!title) {
      var alt = /<a[^>]*title="([^"]{0,300})"/.exec(block);
      if (alt) title = clean(alt[1]);
    }
    if (!title) continue;
    var coverMatch = /<img class="cover"[^>]*src="([^"]+)"/.exec(block);
    var authorMatch = /<div class="author">([\s\S]{0,40}?)<\/div>/.exec(block);
    var tagMatch = /<div class="view">\s*<span>([^<]{0,24})<\/span>/.exec(block);
    var stateMatch = /<div class="state">\s*([^<]{0,16}?)\s*<\/div>/.exec(block);
    var bits = [];
    if (stateMatch) bits.push(clean(stateMatch[1]));
    if (authorMatch) bits.push(clean(authorMatch[1]));
    if (tagMatch) bits.push(clean(tagMatch[1]));
    seen[id] = true;
    var item = { id: prefixOf(kind) + id, title: title, cover: coverMatch ? absUrl(coverMatch[1]) : '', subtitle: bits.join(' · ') };
    if (kind === 'comic') item.mediaType = 'comic';
    else if (kind === 'novel') item.mediaType = 'novel';
    else item.mediaType = 'audio';
    items.push(item);
  }
  return items;
}

function prefixOf(kind) {
  if (kind === 'comic') return 'c';
  if (kind === 'novel') return 'n';
  if (kind === 'audio') return 's';
  return 'v';
}

function hasNextPage(html, page) {
  var next = Number(page) + 1;
  return new RegExp('(?:page=|page =)' + next + '(?!\\d)').test(String(html || ''));
}

/* ───────────── 详情/章节解析 ───────────── */

function parseDetail(html, kind) {
  var text = String(html || '');
  var h1 = /<h1[^>]*>([\s\S]{0,300}?)<\/h1>/.exec(text);
  var title = h1 ? clean(h1[1]) : '';
  if (!title) {
    var t = /<title>([^<]{0,200})/.exec(text);
    title = t ? clean(t[1]) : '';
  }
  var coverMatch = /<img class="cover"[^>]*src="([^"]+)"/.exec(text);
  if (!coverMatch) coverMatch = /poster="([^"]+)"/.exec(text);
  var cover = coverMatch ? absUrl(coverMatch[1]) : '';
  var descMatch = /<meta name="description" content="([\s\S]{0,800}?)"/.exec(text);
  var description = descMatch ? clean(descMatch[1]) : '';
  var tags = [];
  var tagBox = /<ul class="tag_box">([\s\S]*?)<\/ul>/.exec(text);
  if (tagBox) {
    var tagRe = /<a[^>]*>([^<]{1,24})<\/a>/g;
    var m;
    while ((m = tagRe.exec(tagBox[1])) !== null) {
      var tag = clean(m[1]).replace(/^#/, '');
      if (tag && tags.indexOf(tag) < 0) tags.push(tag);
    }
  }
  // 视频详情页的番号/片商/类型/价格
  var flat = clean(text);
  var info = {};
  var keys = ['番号', '片商', '类型', '价格', '时长'];
  for (var i = 0; i < keys.length; i++) {
    var r = new RegExp(keys[i] + '：\\s*([^\\s]{1,40})').exec(flat);
    if (r) info[keys[i]] = r[1];
  }
  return { title: title, cover: cover, description: description, tags: tags, info: info, html: text };
}

// 有声音轨/视频分集：<li class="menu" onclick="choosePlay(0, '<id>')"><div id="<id>" ...> 标题
function parseMenuChapters(html) {
  var text = String(html || '');
  var list = [];
  var seen = {};
  var re = /<li class="menu"[^>]*onclick="choosePlay\([^,]*,\s*'(\d+)'\)"[^>]*>([\s\S]{0,1200}?)<\/li>/g;
  var m;
  while ((m = re.exec(text)) !== null) {
    var id = m[1];
    if (seen[id]) continue;
    var block = m[2];
    var titleMatch = /<div[^>]*data-id="\d+"[^>]*>([\s\S]*?)<\/div>/.exec(block);
    var title = titleMatch ? clean(titleMatch[1]) : '';
    if (!title) title = '第 ' + (list.length + 1) + ' 集';
    seen[id] = true;
    list.push({ id: id, title: title });
  }
  return list;
}

function parseChapterLinks(html, kind) {
  var text = String(html || '');
  var list = [];
  var seen = {};
  var re = new RegExp('\\/' + kind + '\\/chapter\\?id=(\\d+)("[^>]*)?>([\\s\\S]{0,240}?)<\\/a>', 'g');
  var m;
  while ((m = re.exec(text)) !== null) {
    var id = m[1];
    if (seen[id]) continue;
    var title = clean(m[3]);
    // 详情页里的「开始阅读」按钮和翻页按钮不是章节条目
    if (/^开始阅读$|^下一话$|^上一话$|^下一章$|^上一章$|^返回书目$/.test(title)) continue;
    if (!title) title = (kind === 'novel' ? '第 ' : '第 ') + (list.length + 1) + (kind === 'novel' ? ' 章' : ' 话');
    seen[id] = true;
    list.push({ id: id, title: title });
  }
  return list;
}

function splitId(raw) {
  var text = String(raw == null ? '' : raw).trim();
  var head = text.charAt(0);
  var rest = text.slice(1);
  if (/^\d+$/.test(rest)) {
    if (head === 'c') return { kind: 'comic', id: rest };
    if (head === 'n') return { kind: 'novel', id: rest };
    if (head === 's') return { kind: 'audio', id: rest };
    if (head === 'v') return { kind: 'video', id: rest };
  }
  return { kind: 'video', id: text.replace(/\D+$/, '') };
}

async function loadIntro(kind, id) {
  var key = kind + ':' + id;
  if (CACHE[key] && Date.now() - CACHE[key].at < 5 * 60 * 1000) return CACHE[key].value;
  var path = '/' + kind + '/intro?id=' + encodeURIComponent(id);
  var html = await fetchPage(path);
  var parsed = parseDetail(html, kind);
  var chapters = [];
  if (kind === 'comic' || kind === 'novel') chapters = parseChapterLinks(html, kind);
  else chapters = parseMenuChapters(html);
  var value = { parsed: parsed, chapters: chapters, html: html };
  CACHE[key] = { at: Date.now(), value: value };
  return value;
}

/* ───────────── 列表路由 ───────────── */

function videoListPath(category, page) {
  var cat = '';
  var origin = '';
  var sort = 1;
  var cfg = null;
  for (var i = 0; i < VIDEO_CATEGORIES.length; i++) if (VIDEO_CATEGORIES[i].id === category) cfg = VIDEO_CATEGORIES[i];
  if (cfg) {
    if (cfg.category) cat = cfg.category;
    if (cfg.origin) origin = String(cfg.origin);
    if (cfg.sort) sort = cfg.sort;
  }
  return '/video/list?keyword=&searchType=1&category=' + encodeURIComponent(cat) +
    '&origin=' + encodeURIComponent(origin) + '&tag=&sort=' + sort + '&page=' + page;
}

function mediaListPath(kind, category, page) {
  var table = kind === 'audio' ? AUDIO_CATEGORIES : (kind === 'comic' ? COMIC_CATEGORIES : NOVEL_CATEGORIES);
  var cfg = null;
  for (var i = 0; i < table.length; i++) if (table[i].id === category) cfg = table[i];
  if (cfg && cfg.path) return cfg.path;
  var sort = 2;
  var cat = '';
  var origin = '';
  if (cfg) {
    if (cfg.sort) sort = cfg.sort;
    if (cfg.category) cat = cfg.category;
    if (cfg.origin) origin = String(cfg.origin);
  }
  if (kind === 'audio') {
    return '/audio/list?keyword=&searchType=1&category=' + encodeURIComponent(cat) + '&author=&sort=' + sort + '&page=' + page;
  }
  if (kind === 'comic') {
    return '/comic/list?keyword=&searchType=1&author=&origin=' + encodeURIComponent(origin) +
      '&category=' + encodeURIComponent(cat) + '&tag=&sort=' + sort + '&page=' + page;
  }
  return '/novel/list?keyword=&searchType=1&author=&category=' + encodeURIComponent(cat) +
    '&finished=&space=&source=&tag=&sort=' + sort + '&page=' + page;
}

/* ───────────── 源对象 ───────────── */

var LumeSource = {
  id: 'uaa_video',
  name: '有爱爱 UAA',
  version: '1.0.2',
  category: 'video',
  contentCategory: 'adult',
  mirrors: MIRRORS,

  async categories() {
    var list = [];
    var groups = [VIDEO_CATEGORIES, AUDIO_CATEGORIES, COMIC_CATEGORIES, NOVEL_CATEGORIES];
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length; i++) list.push({ id: groups[g][i].id, title: groups[g][i].title });
    }
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

    // 站内搜索：只有 JSON 接口真的按关键词过滤（SSR 的 ?keyword= 会被忽略）
    if (keyword) {
      var data = await fetchApi('/video/app/video/search?keyword=' + encodeURIComponent(keyword) + '&page=' + page);
      if (!data || data.result !== 'success' || !data.model) return { items: [], hasMore: false };
      var model = data.model;
      var rows = model.data || [];
      var items = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (!row || !row.id) continue;
        var bits = [];
        if (row.categories) bits.push(row.categories);
        if (row.durationFormat) bits.push(row.durationFormat);
        if (row.authors) bits.push(row.authors);
        items.push({
          id: 'v' + row.id,
          title: clean(row.title) || String(row.id),
          cover: absUrl(row.coverUrl || row.cover || ''),
          subtitle: bits.join(' · '),
          mediaType: 'video'
        });
      }
      var more = Number(model.currentPage || page) < Number(model.totalPage || 1);
      return { items: items, hasMore: more };
    }

    if (!categoryId) categoryId = 'v:new';
    var kind = categoryId.charAt(0) === 'a' ? 'audio'
      : categoryId.charAt(0) === 'c' ? 'comic'
        : categoryId.charAt(0) === 'n' ? 'novel'
          : 'video';

    var path = kind === 'video' ? videoListPath(categoryId, page) : mediaListPath(kind, categoryId, page);
    var html = await fetchPage(path);

    if (kind === 'video') {
      var videoItems = parseVideoCards(html);
      return { items: videoItems, hasMore: videoItems.length >= PAGE_LIMIT || hasNextPage(html, page) };
    }
    var mediaItems = parseMediaCards(html, kind);
    // 排行页固定 100 条且不吃 page 参数
    var ranked = path.indexOf('/rank') >= 0;
    return {
      items: mediaItems,
      hasMore: ranked ? false : (mediaItems.length >= PAGE_LIMIT || hasNextPage(html, page))
    };
  },

  async detail(argument) {
    var raw = String((argument && argument.id) || '').trim();
    if (!raw) return null;
    var ref = splitId(raw);
    var data;
    try {
      data = await loadIntro(ref.kind, ref.id);
    } catch (error) {
      throw error;
    }
    if (!data.parsed.title) return null;
    var kindLabel = ref.kind === 'video' ? '视频' : (ref.kind === 'audio' ? '有声' : (ref.kind === 'comic' ? '漫画' : '小说'));
    var bits = [];
    if (data.parsed.info['类型']) bits.push(data.parsed.info['类型']);
    if (data.parsed.info['时长']) bits.push(data.parsed.info['时长']);
    if (data.chapters.length) bits.push((ref.kind === 'comic' ? '共 ' : '共 ') + data.chapters.length + (ref.kind === 'novel' ? ' 章' : (ref.kind === 'comic' ? ' 话' : ' 集')));
    var lines = ['有爱爱 UAA · ' + kindLabel + '（' + base() + '）'];
    if (data.parsed.info['番号']) lines.push('番号：' + data.parsed.info['番号']);
    if (data.parsed.info['片商']) lines.push('片商：' + data.parsed.info['片商']);
    if (data.parsed.info['价格']) lines.push('站点标价：' + data.parsed.info['价格'] + '（接口照样下发完整内容）');
    if (data.parsed.description) lines.push(data.parsed.description);
    return {
      id: prefixOf(ref.kind) + ref.id,
      title: data.parsed.title,
      cover: data.parsed.cover,
      subtitle: bits.join(' · '),
      tags: data.parsed.tags.slice(0, 12),
      mediaType: ref.kind === 'audio' ? 'audio' : ref.kind,
      description: lines.join('\n')
    };
  },

  async chapters(argument) {
    var raw = String((argument && argument.id) || '').trim();
    if (!raw) return [];
    var ref = splitId(raw);
    var data = await loadIntro(ref.kind, ref.id);
    if (data.chapters.length) {
      var out = [];
      for (var i = 0; i < data.chapters.length; i++) out.push({ id: data.chapters[i].id, title: data.chapters[i].title });
      return out;
    }
    if (ref.kind === 'video') return [{ id: '0', title: '正片' }];
    if (ref.kind === 'audio') return [{ id: '0', title: '第 1 集' }];
    return [];
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.id || '').trim();
    if (!raw) throw new Error('缺少条目 ID');
    var ref = splitId(raw);
    var chapterId = String(args.chapterId == null ? '' : args.chapterId).trim();

    if (ref.kind === 'video') {
      var data = chapterId && chapterId !== '0'
        ? await fetchApi('/video/app/video/chapter?id=' + encodeURIComponent(chapterId) + '&offset=0&force=false')
        : await fetchApi('/video/app/video/intro?id=' + encodeURIComponent(ref.id));
      var model = data && data.model;
      if (!model || !model.url) {
        throw new Error('站点没给播放地址：' + (data && (data.msg || data.result) ? data.msg || data.result : '未知原因'));
      }
      return { kind: 'video', url: model.url, headers: { 'User-Agent': UA, 'Referer': base() + '/' } };
    }

    if (ref.kind === 'audio') {
      var cid = chapterId && chapterId !== '0' ? chapterId : '';
      if (!cid) {
        var intro = await loadIntro('audio', ref.id);
        if (intro.chapters.length) cid = intro.chapters[0].id;
      }
      if (!cid) throw new Error('这条有声没有取到分集 ID');
      var audio = await fetchApi('/audio/app/audio/chapter?id=' + encodeURIComponent(cid) + '&offset=0&force=false');
      var am = audio && audio.model;
      if (!am || !am.url) throw new Error('站点没给音轨地址：' + (audio && (audio.msg || audio.result) ? audio.msg || audio.result : '未知原因'));
      return { kind: 'audio', url: am.url, title: am.title || '', headers: { 'User-Agent': UA, 'Referer': base() + '/' } };
    }

    if (ref.kind === 'comic') {
      var targetComic = chapterId && chapterId !== '0' ? chapterId : '';
      if (!targetComic) {
        var cIntro = await loadIntro('comic', ref.id);
        if (cIntro.chapters.length) targetComic = cIntro.chapters[0].id;
      }
      if (!targetComic) throw new Error('这条漫画没有取到章节 ID');
      var page = await fetchPage('/comic/chapter?id=' + encodeURIComponent(targetComic));
      var chapter = extractChapterJson(page);
      var images = [];
      if (chapter && chapter.images && chapter.images.length) {
        for (var i = 0; i < chapter.images.length; i++) images.push(absUrl(chapter.images[i]));
      } else {
        var imgRe = /<img[^>]+class="unlazyload"[^>]+src="([^"]+)"/g;
        var im;
        while ((im = imgRe.exec(page)) !== null) images.push(absUrl(im[1]));
      }
      if (!images.length) throw new Error('漫画章节里没解析到图片（站点改版了？）');
      return { kind: 'images', images: images };
    }

    // 小说：正文就是 SSR 的 div.line
    var targetNovel = chapterId && chapterId !== '0' ? chapterId : '';
    if (!targetNovel) {
      var nIntro = await loadIntro('novel', ref.id);
      if (nIntro.chapters.length) targetNovel = nIntro.chapters[0].id;
    }
    if (!targetNovel) throw new Error('这本小说没有取到章节 ID');
    var nPage = await fetchPage('/novel/chapter?id=' + encodeURIComponent(targetNovel));
    var paragraphs = [];
    var lineRe = /<div class="line"[^>]*>\s*([\s\S]*?)\s*<\/div>/g;
    var lm;
    while ((lm = lineRe.exec(nPage)) !== null) {
      var para = clean(lm[1]);
      if (para) paragraphs.push(para);
    }
    if (!paragraphs.length) {
      var notice = /此章节为付费章节[\s\S]{0,80}?/.exec(nPage);
      throw new Error('这一章没解析到正文' + (notice ? '（站点提示：' + clean(notice[0]) + '）' : '（站点改版了？）'));
    }
    return { kind: 'text', text: paragraphs.join('\n\n') };
  }
};

// 从章节页里抠出 `var chapter = {…}`（按花括号配对，避免正则贪婪）
function extractChapterJson(html) {
  var text = String(html || '');
  var at = text.indexOf('var chapter = ');
  if (at < 0) at = text.indexOf('var chapter=');
  if (at < 0) return null;
  var start = text.indexOf('{', at);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var quote = '';
  var escapeNext = false;
  for (var i = start; i < text.length; i++) {
    var ch = text.charAt(i);
    if (inString) {
      if (escapeNext) { escapeNext = false; continue; }
      if (ch === '\\') { escapeNext = true; continue; }
      if (ch === quote) inString = false;
      continue;
    }
    if (ch === '"' || ch === "'") { inString = true; quote = ch; continue; }
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) {
        var raw = text.slice(start, i + 1);
        try { return JSON.parse(raw); } catch (error) { return null; }
      }
    }
  }
  return null;
}
