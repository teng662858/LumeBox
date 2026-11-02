// LumeSource: {"id":"hsckzy_video","name":"黄色仓库","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://hsckzy.vip","https://hsckzy.com","https://hsckzy888.com","https://hsckzy.xyz","https://hsckzy001.com"],"network":"direct","icon":"https://hsckzy.vip/template/ziyuan2/css/style.css","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（hsckzy.com）","url":"https://hsckzy.com/","description":"官方地址发布页：hsckzy.vip / hsckzy888.com / hsckzy.xyz / hsckzy001.com / hszyckapi.vip"},{"key":"note","type":"info","title":"站点说明","description":"黄色仓库资源站（hsckzy.vip，苹果CMS + ziyuan2 模板）：国产区/AV区/欧美区/动漫区/其他区共 36 个分类、6.9 万部。列表/详情/搜索都是匿名 GET；详情页按来源分组内联播放地址（「正片$https://…」），其中「黄色仓库资源m3u8」那条是 m3u8 直链（实测 200 + #EXTM3U，master 里 2000kb/hls/index.m3u8 子列表可取），「黄色仓库云」是 share 网页（走内嵌网页播放）。"}]}
// LumeRuntime: javascript
//
// 站点：黄色仓库资源站（https://hsckzy.vip）—— 苹果CMS（maccms）+ ziyuan2 模板。
// 发布页 hsckzy.com 给出的地址池：hsckzy.vip / hsckzy888.com / hsckzy.xyz / hsckzy001.com / hszyckapi.vip。
// 站内公告写「本站不提供在线正版播放，复制地址到浏览器观看」，但详情页的 m3u8 那条实测能直接播。
//
// 页面结构（2026-11-02 实测，全部匿名 GET、无签名、无登录）：
//   分类列表  /index.php/vod/type/id/<cid>.html        第 N 页 /index.php/vod/type/id/<cid>/page/<N>.html （50 条/页）
//   详情      /index.php/vod/detail/id/<id>.html
//             标题在 <title>（带「剧情介绍--黄色仓库资源站」后缀），封面是第一张 img.uyjthen.com
//             播放地址按来源分组：<h3>来源：黄色仓库m3u8</h3><ul><li>正片$https://…/index.m3u8</li></ul>
//   搜索      /index.php/vod/search.html?wd=<词>&page=<N>                    （50 条/页）
//   播放页    /index.php/vod/play/id/<id>/sid/<sid>/nid/<nid>.html（本源不用，详情页已足够）
//
// 形态：详情页有 .m3u8 的线路 → kind:'video'（原生播放）；只有 share 网页 → kind:'webplayer'。
// 列表页没有封面（纯文字列表），封面统一在详情页取。
//
// 失效预案：换域名时改 BASE_FALLBACK / MIRRORS；m3u8 403 时补 Referer；
// 详情页不再内联地址时，去 /index.php/vod/play/id/<id>/sid/1/nid/1.html 里找。

var BASE_FALLBACK = 'https://hsckzy.vip';
var MIRRORS = ['https://hsckzy.vip', 'https://hsckzy.com', 'https://hsckzy888.com', 'https://hsckzy.xyz', 'https://hsckzy001.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 50;

var CATEGORIES = [
  { id: '1', title: '国产区' },
  { id: '6', title: '国产 · 网红主播' },
  { id: '7', title: '国产 · 国产传媒' },
  { id: '8', title: '国产 · 探花系列' },
  { id: '37', title: '国产 · 国产自拍' },
  { id: '2', title: 'AV区' },
  { id: '9', title: 'AV · 人妻熟女' },
  { id: '10', title: 'AV · 日本无码' },
  { id: '11', title: 'AV · 美乳巨乳' },
  { id: '12', title: 'AV · 强制侵犯' },
  { id: '13', title: 'AV · 制服诱惑' },
  { id: '14', title: 'AV · 绝色佳人' },
  { id: '15', title: 'AV · 风俗泡泡浴' },
  { id: '16', title: 'AV · 家庭乱伦' },
  { id: '20', title: 'AV · 少女萝莉' },
  { id: '21', title: 'AV · SM调教' },
  { id: '22', title: 'AV · 绝顶潮吹' },
  { id: '23', title: 'AV · 魔镜系列' },
  { id: '24', title: 'AV · 时间停止' },
  { id: '25', title: 'AV · 催眠洗脑' },
  { id: '26', title: 'AV · 漫改系列' },
  { id: '27', title: 'AV · 电车痴汉' },
  { id: '28', title: 'AV · 淫欲痴女' },
  { id: '3', title: '欧美区' },
  { id: '36', title: '欧美 · 欧美精品' },
  { id: '5', title: '动漫区' },
  { id: '38', title: '动漫 · 日本动漫' },
  { id: '39', title: '动漫 · 3D动漫' },
  { id: '43', title: '动漫 · AI短剧' },
  { id: '30', title: '其他区' },
  { id: '17', title: '其他 · AV解说' },
  { id: '18', title: '其他 · 三级电影' },
  { id: '29', title: '其他 · AI换脸' },
  { id: '31', title: '其他 · 网曝门' },
  { id: '32', title: '其他 · TS专区' },
  { id: '33', title: '其他 · 女性向系列' },
  { id: '34', title: '其他 · 女同性恋' },
  { id: '35', title: '其他 · 男同性恋' },
  { id: '40', title: '其他 · 韩国主播' },
  { id: '41', title: '其他 · 泰国风情' },
  { id: '42', title: '其他 · OnlyFans' }
];

var HOME_BOARDS = [
  { title: '网红主播', category: '6' },
  { title: '人妻熟女', category: '9' },
  { title: 'AV解说', category: '17' }
];

var DETAIL_CACHE = {};

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
    throw new Error('NEED_WEBVIEW_VERIFY：黄色仓库被 Cloudflare 挡住（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (/cf-chl-|Just a moment|cf-turnstile/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：黄色仓库需要网页验证');
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
  // 列表是纯文字表格：<li><span class="xing_vb4"><a href="…/detail/id/88805.html">标题<em>[高清]</em></a></span>
  //                 <span class="xing_vb5">网红主播</span><span class="xing_vb6">2026-11-02 14:58:25</span></li>
  var re = /<li>[\s\S]{0,400}?<a href="\/index\.php\/vod\/detail\/id\/(\d+)\.html"[^>]*>([\s\S]{0,300}?)<\/a>[\s\S]{0,400}?<\/li>/g;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    var block = matched[0];
    var title = clean(matched[2].replace(/<em[\s\S]*?<\/em>/gi, ''));
    if (!title) continue;
    var catMatch = /class="xing_vb5"[^>]*>([\s\S]{0,40}?)<\/span>/.exec(block);
    var timeMatch = /class="xing_vb6"[^>]*>([\s\S]{0,80}?)<\/span>/.exec(block);
    var bits = [];
    if (catMatch) bits.push(clean(catMatch[1]));
    if (timeMatch) bits.push(clean(timeMatch[1]).replace(/\s+/g, ' ').slice(0, 16));
    seen[id] = true;
    items.push({ id: id, title: title, cover: '', subtitle: bits.join(' · ') });
  }
  return items;
}

function hasNextPage(html, page) {
  var next = Number(page) + 1;
  return new RegExp('/page/' + next + '\\.html').test(String(html || ''));
}

/* ───────────── 详情 ───────────── */

function parseDetail(html, id) {
  var text = String(html || '');
  var titleMatch = /<title>([^<]{0,220})/.exec(text);
  var title = titleMatch ? clean(titleMatch[1]).replace(/剧情介绍\s*-+\s*黄色仓库资源站\s*$/, '').replace(/-+黄色仓库资源站\s*$/, '').trim() : '';
  var coverMatch = /<img[^>]+(?:data-original|data-src|src)="(https?:\/\/[^"]+\.(?:jpg|jpeg|png|webp))"/i.exec(text);
  var cover = coverMatch ? coverMatch[1] : '';
  var flat = clean(text);
  var catMatch = /当前位置\s*([^\/\s]{2,12})\s*\//.exec(flat);
  var classify = catMatch ? catMatch[1] : '';
  var introMatch = /<div class="vodplayinfo">([\s\S]{0,600}?)<\/div>/.exec(text);
  var intro = introMatch ? clean(introMatch[1]) : '';

  // 按来源分组：<h3>来源：黄色仓库m3u8</h3>…<li>正片$https://…</li>…
  var groups = [];
  var groupRe = /<h3>\s*来源：([^<]{1,40})<\/h3>([\s\S]{0,4000}?)<\/ul>/g;
  var gm;
  while ((gm = groupRe.exec(text)) !== null) {
    var label = clean(gm[1]) || '线路';
    var urls = [];
    var pairRe = /([^<>$\s"]{1,20})\$((?:https?:)?\/\/[^\s<>"']+)/g;
    var pm;
    while ((pm = pairRe.exec(gm[2])) !== null) {
      var url = absUrl(pm[2]);
      if (!url || urls.indexOf(url) >= 0) continue;
      urls.push(url);
    }
    if (urls.length) groups.push({ label: label, urls: urls });
  }
  // 兜底：没有 h3 分组时直接抓所有「名称$地址」
  if (!groups.length) {
    var loose = [];
    var looseRe = /([^<>\s$"]{1,20})\$((?:https?:)?\/\/[^\s<>"']+)/g;
    var lm;
    while ((lm = looseRe.exec(text)) !== null) {
      var u2 = absUrl(lm[2]);
      if (u2 && loose.indexOf(u2) < 0 && !/\/(?:template|static)\//i.test(u2)) loose.push(u2);
    }
    if (loose.length) groups.push({ label: '默认线路', urls: loose });
  }
  return {
    id: String(id),
    title: title || String(id),
    cover: cover,
    classify: classify,
    intro: intro,
    groups: groups
  };
}

async function loadDetail(id) {
  var key = String(id);
  if (DETAIL_CACHE[key] && Date.now() - DETAIL_CACHE[key].at < 5 * 60 * 1000) return DETAIL_CACHE[key].value;
  var value = parseDetail(await fetchHtml('/index.php/vod/detail/id/' + encodeURIComponent(id) + '.html'), id);
  DETAIL_CACHE[key] = { at: Date.now(), value: value };
  return value;
}

/* ───────────── 源对象 ───────────── */

var LumeSource = {
  id: 'hsckzy_video',
  name: '黄色仓库',
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
    if (!boards.length) throw new Error('首页板块都没取到：站点可能换了域名或被 Cloudflare 挡住（看发布页 hsckzy.com）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var searchPath = '/index.php/vod/search.html?wd=' + encodeURIComponent(keyword) + '&page=' + page;
      var searchHtml = await fetchHtml(searchPath);
      var hits = parseCards(searchHtml);
      return { items: hits, hasMore: hits.length >= PAGE_SIZE };
    }

    var cid = Number(categoryId) || 6;
    var path = page > 1
      ? '/index.php/vod/type/id/' + cid + '/page/' + page + '.html'
      : '/index.php/vod/type/id/' + cid + '.html';
    var html = await fetchHtml(path);
    var items = parseCards(html);
    return { items: items, hasMore: items.length >= PAGE_SIZE || hasNextPage(html, page) };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return null;
    var info = await loadDetail(id);
    if (!info.title) return null;
    var bits = [];
    if (info.classify) bits.push(info.classify);
    if (info.groups.length) bits.push(info.groups.length + ' 条线路');
    return {
      id: info.id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      tags: info.classify ? [info.classify] : [],
      description: '黄色仓库资源站（' + base() + '）\n' +
        '分类：' + (info.classify || '-') + '｜线路：' + info.groups.map(function (g) { return g.label; }).join(' / ') + '\n' +
        (info.intro || '')
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var info = await loadDetail(id);
    var list = [];
    for (var i = 0; i < info.groups.length; i++) {
      var group = info.groups[i];
      for (var j = 0; j < group.urls.length; j++) {
        list.push({
          id: i + '|' + j,
          title: group.label + (group.urls.length > 1 ? ' ' + (j + 1) : '')
        });
      }
    }
    if (!list.length) list.push({ id: '0|0', title: '正片' });
    return list;
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || '').trim();
    if (!id) throw new Error('缺少条目 ID');
    var info = await loadDetail(id);
    var raw = String(args.chapterId || '0|0');
    var parts = raw.split('|');
    var gi = Number(parts[0]) || 0;
    var ui = Number(parts[1]) || 0;
    var group = info.groups[gi];
    if (!group || !group.urls[ui]) {
      group = info.groups[0];
      ui = 0;
    }
    if (!group || !group.urls[ui]) throw new Error('这条没有解析到播放地址（详情页结构可能变了）');
    var url = group.urls[ui];
    if (/\.m3u8(\?|$)/i.test(url)) {
      return {
        kind: 'video',
        url: url,
        headers: { 'User-Agent': UA, 'Referer': base() + '/' }
      };
    }
    // share 网页 / 其它非直链：交给 App 内嵌网页播放
    return { kind: 'webplayer', pageUrl: url, headers: headers() };
  }
};
