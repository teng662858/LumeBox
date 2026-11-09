// LumeSource: {"id":"jifangge_video","name":"集芳阁云搜","version":"1.0.0","category":"video","contentCategory":"adult","network":"direct","mirrors":["https://xn--24d-jbaitao-com-p120ak61d.jfgwww.com"],"icon":"https://xn--24d-jbaitao-com-p120ak61d.jfgwww.com/static/logo.svg","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开地址发布页","url":"https://jifangge.com/","description":"官方地址发布页（jifangge.com）；站点换域名时先看这里"},{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 国产/AV 云搜聚合。搜索词要按站方规则做 AES 加密才能进站方搜索页（源里已内置）；播放是站方直链 m3u8，可原生播放。今日热播/今日更新只有首页 20 条（站方把 ?p= 分页做了 CDN 整页缓存，翻不动），要往下逛用标签或关键词。"}]}
// LumeRuntime: javascript
//
// 站点：集芳阁云搜（punycode 主域见 mirrors），一个只做聚合的成人视频云搜。
//
// 实测（2026-11-09）：
//   · 首页 / 只有导航 + 热门搜索词，没有内容列表；内容是三个入口：
//       /toplist.html         今日热播 Top100（20 条/页，页脚写 5 页）
//       /newlist.html         今日更新 Top100（同上）
//       /search-0-<排序>-<词>-<页>.html   搜索/标签结果（实测「偷情」519 页）
//   · 搜索词必须在 URL 里带 AES 密文：AES-128-CBC、key/iv 是站方前端常量、
//     **零填充**（正好 16 字节时不额外补块），再 encodeURIComponent(base64)。
//     用 tools.aes 走宿主原生加密，源里不塞纯 JS 加密。
//   · 列表卡片：<li><a href="content/<32位>.html"> + .cover 的 background-image
//     + <span class="vodtime">时长</span> + <div class="ctitle"><p>标题</p>
//   · 详情 /content/<hash>.html：og:title / og:image + <a playdata="…m3u8"> 通道
//     （实测只有一个通道；m3u8 是 master，变体指向 …/index.m3u8，分片 200 video/mp2t）
//   · 封面、m3u8、分片都**不需要** Referer/Cookie，直连可取。
//   · 页脚 /toplist.php?p=N、/newlist.php?p=N 会被站方 CDN 整页缓存（cf-cache-status
//     HIT，查询串不进缓存键），p 取任何值都是同一页，所以这两个榜只做第 1 页。
//
// 已知坑：站方对搜索页的缓存按路径分键，因此**翻页必须换路径**（…-<页>.html），
// 这也正是它能翻 519 页的原因。

var MIRRORS = ['https://xn--24d-jbaitao-com-p120ak61d.jfgwww.com'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';

// 站方前端常量（首页 jskeys.php 里的 encrypt()）
var AES_KEY = '2d4ebb7cb767dab1';
var AES_IV = '7563ca4af41bd0fb';

// 排序：0 相关度、2 播放量、3 时长、4 收录时间（站方 <select> 的取值）
var SORTS = { rel: '0', hits: '2', length: '3', newest: '4' };

// 首页 recommandlist 的首批标签；取不到就退回这份（站方「换一批」里的常用词）
var FALLBACK_TAGS = ['中文', '偷情', '自拍', '国产', '人妻', '巨乳', '丝袜', '按摩', '学生', '模特'];

function jfgBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
}

function jfgHeaders(extra) {
  var headers = { 'User-Agent': UA, Referer: jfgBase() + '/' };
  if (extra) {
    for (var key in extra) headers[key] = extra[key];
  }
  return headers;
}

async function jfgGet(path) {
  var response = await LumeSource.http.get(jfgBase() + path, {
    headers: jfgHeaders({ Accept: 'text/html,application/xhtml+xml' }),
  });
  if (response.status === 403 || response.status === 503) {
    throw new Error('集芳阁返回人机校验（HTTP ' + response.status + '），稍后重试或换个网络');
  }
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('集芳阁暂不可用（HTTP ' + response.status + '）');
  return response.body;
}

function jfgLatin1(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 0xff);
  return out;
}

// 关键词 → UTF-8 字节（沙箱没有 TextEncoder，这里自己转）
function jfgUtf8(text) {
  var bytes = [];
  var chars = Array.from(String(text));
  for (var i = 0; i < chars.length; i++) {
    var cp = chars[i].codePointAt(0);
    if (cp < 0x80) {
      bytes.push(cp);
    } else if (cp < 0x800) {
      bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
    } else if (cp < 0x10000) {
      bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    } else {
      bytes.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 63),
        0x80 | ((cp >> 6) & 63),
        0x80 | (cp & 63),
      );
    }
  }
  return bytes;
}

// 站方 encrypt()：AES-128-CBC + 零填充（已对齐时不补块）→ encodeURIComponent(base64)
async function jfgEncrypt(text) {
  var bytes = jfgUtf8(text);
  var pad = (16 - (bytes.length % 16)) % 16;
  for (var i = 0; i < pad; i++) bytes.push(0);
  var cipher = await LumeSource.tools.aes({
    key: btoa(AES_KEY),
    iv: btoa(AES_IV),
    data: btoa(jfgLatin1(bytes)),
    mode: 'CBC',
    encrypt: true,
    padding: 'none',
  });
  return encodeURIComponent(String(cipher).trim());
}

function jfgText(value) {
  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  return String(value || '')
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

function jfgDuration(text) {
  var match = /^(\d+):(\d+):(\d+)$/.exec(String(text || '').trim());
  if (!match) return undefined;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

function jfgPager(html) {
  var num = /<span class="num">(\d+)\s*\/\s*(\d+)<\/span>/.exec(html);
  if (!num) return null;
  return { page: Number(num[1]), total: Number(num[2]) };
}

function jfgItems(html) {
  var blocks = String(html || '').split(/<li[ >]/).slice(1);
  var items = [];
  var seen = {};
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    // 热播榜的链接带 ?f=top 后缀，这里只取 hash 本身（详情页按 hash 请求）
    var href = /href="content\/([0-9a-f]{16,})\.html(?:\?[^"]*)?"/.exec(block);
    if (!href) continue;
    if (seen[href[1]]) continue;
    seen[href[1]] = true;
    var title = /<div class="ctitle">\s*<p>([\s\S]*?)<\/p>/.exec(block);
    var cover = /background-image:url\('([^']+)'\)/.exec(block);
    var time = /class="vodtime">([^<]*)</.exec(block);
    var name = jfgText(title ? title[1] : '');
    if (!name) continue;
    items.push({
      id: href[1],
      title: name,
      cover: cover ? cover[1] : undefined,
      subtitle: time ? String(time[1]).trim() : undefined,
      duration: jfgDuration(time ? time[1] : ''),
    });
  }
  return items;
}

async function jfgSearchPage(keyword, sort, page) {
  var token = await jfgEncrypt(keyword);
  var path = '/search-0-' + (SORTS[sort] || SORTS.rel) + '-' + token +
    (page > 1 ? '-' + page : '') + '.html';
  var html = await jfgGet(path);
  if (html == null) return { items: [], hasMore: false };
  var pager = jfgPager(html);
  return {
    items: jfgItems(html),
    hasMore: pager ? pager.page < pager.total : false,
  };
}

async function jfgDetailPage(id) {
  if (!/^[0-9a-f]{16,}$/i.test(String(id || ''))) return null;
  var html = await jfgGet('/content/' + id + '.html');
  if (html == null) return null;
  var title = /<meta\s+property="og:title"\s+content="([^"]*)"/i.exec(html);
  var cover = /<meta\s+property="og:image"\s+content="([^"]*)"/i.exec(html);
  var sources = [];
  var link = /<a[^>]*playdata="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  var match;
  while ((match = link.exec(html))) {
    var url = match[1].trim();
    if (!/^https?:\/\//.test(url)) continue;
    if (sources.indexOf(url) < 0) sources.push(url);
  }
  return {
    title: jfgText(title ? title[1] : ''),
    cover: cover ? jfgText(cover[1]) : undefined,
    sources: sources,
  };
}

async function jfgHomeTags() {
  try {
    var html = await jfgGet('/');
    var list = /var\s+recommandlist\s*=\s*(\[[\s\S]*?\]);/.exec(html || '');
    if (!list) return FALLBACK_TAGS;
    var tags = JSON.parse(list[1]).filter(function (tag) {
      return typeof tag === 'string' && tag.trim();
    });
    return tags.length ? tags.slice(0, 10) : FALLBACK_TAGS;
  } catch (error) {
    return FALLBACK_TAGS;
  }
}

var LumeSource = {
  async categories() {
    var tags = await jfgHomeTags();
    var list = [
      { id: 'top', title: '今日热播' },
      { id: 'new', title: '今日更新' },
    ];
    for (var i = 0; i < tags.length; i++) {
      list.push({ id: 'tag_' + tags[i], title: '标签 · ' + tags[i] });
    }
    return list;
  },

  async list({ categoryId, page, keyword } = {}) {
    var currentPage = Math.max(1, Math.floor(Number(page) || 1));
    var query = String(keyword || '').trim();
    if (query) return jfgSearchPage(query, 'rel', currentPage);

    var id = String(categoryId || 'new');
    if (id.indexOf('tag_') === 0) {
      return jfgSearchPage(id.slice(4), 'rel', currentPage);
    }
    // 两个榜的 ?p= 被 CDN 整页缓存覆盖，只能给首页；再深就是重复内容。
    if (currentPage > 1) return { items: [], hasMore: false };
    var html = await jfgGet(id === 'top' ? '/toplist.html' : '/newlist.html');
    if (html == null) return { items: [], hasMore: false };
    return { items: jfgItems(html), hasMore: false };
  },

  async detail({ id } = {}) {
    var page = await jfgDetailPage(id);
    if (!page || !page.title) return null;
    return {
      id: id,
      title: page.title,
      cover: page.cover,
      description: page.sources.length
        ? '集芳阁云搜收录 · 站方直链 m3u8（' + page.sources.length + ' 个通道）'
        : '集芳阁云搜收录',
    };
  },

  async chapters({ id } = {}) {
    var page = await jfgDetailPage(id);
    if (!page || !page.sources.length) return [];
    if (page.sources.length === 1) return [{ id: 'main', title: '正片' }];
    return page.sources.map(function (url, index) {
      return { id: 'ch' + index, title: '通道 ' + (index + 1) };
    });
  },

  async content({ id, chapterId } = {}) {
    var page = await jfgDetailPage(id);
    if (!page || !page.sources.length) throw new Error('这条视频没有可播放的直链');
    var index = 0;
    var match = /^ch(\d+)$/.exec(String(chapterId || 'main'));
    if (match) index = Math.min(Number(match[1]), page.sources.length - 1);
    return {
      kind: 'video',
      url: page.sources[index],
      headers: jfgHeaders(),
    };
  },
};
