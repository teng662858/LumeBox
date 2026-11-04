// LumeSource: {"id":"lcm_video","name":"乐成漫画 · 短剧","version":"1.0.0","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.lcmhx.cc"],"network":"direct","icon":"https://www.lcmhx.cc/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"乐成漫画（lcmhx.cc，Nuxt SSR 的成人站：漫画 + AI 成人短剧）。本源只做**已验证的短剧频道**：分类 /mctype/5/（AI成人短剧，28 条/页），条目 /lcmh-{id}/，页内 <video data-hls-src=\"https://s.chigua.media/hls/{id}/index.m3u8\">。⚠ s.chigua.media 有防盗链（直连 403 referer blocked），本源统一改写走站点自己的代理 /media.php?url=…（实测 200 + #EXTM3U）。⚠ 站上的漫画分类（/mctype/6|17|18…）图片走 img5.qy0.ru，本机出口被拒（403「链接已失效」），没法验证，因此没做进本源。"}]}
// LumeRuntime: javascript
//
// 站点：乐成漫画（www.lcmhx.cc，Nuxt2 SSR + hanime 模板，成人漫画 + AI 成人短剧）
//
// 来源结构（2026-11-04 实测）：
//   · 导航分类 /mctype/{5,6,7,8,10..18,21..24}/（5 = AI成人短剧，其余是漫画/图集）
//   · 列表     /mctype/{n}/            每页 28 条：
//                <a href="/lcmh-{id}/" alt="标题"><img data-src="https://t4.qy0.ru/…webp">
//   · 详情     /lcmh-{id}/             <title>「标题 - 乐成漫画」；短剧页里有
//                <video data-hls-src="https://s.chigua.media/hls/{id}/index.m3u8" data-fallback-src="…mp4">
//   · 取流     s.chigua.media 直连 → 403「The referer has been blocked」；
//              改走站点代理 /media.php?url={encodeURIComponent(m3u8)} → 200 + #EXTM3U（2302 B），
//              清单里的分片地址也是 www.lcmhx.cc/media.php…（App 会把 http 升到 https）。
//   · 漫画图   img5.qy0.ru 在本机出口一律 403「链接已失效」（封面域 t4.qy0.ru 正常），无法验证 → 不做。

var BASE_URL = 'https://www.lcmhx.cc';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var CATS = [
  { id: '5', title: 'AI成人短剧' }
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
    throw new Error('NEED_WEBVIEW_VERIFY：乐成漫画触发了人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

function itemIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/lcmh-(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 防盗链：统一改写成站点自己的 media.php 代理
function proxied(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (text.indexOf('/media.php?') >= 0 || text.indexOf('http://www.lcmhx.cc/media.php') >= 0 || text.indexOf('https://www.lcmhx.cc/media.php') >= 0) {
    return text.replace(/^http:\/\//i, 'https://');
  }
  return base() + '/media.php?url=' + encodeURIComponent(absolute(text));
}

function parseItems(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  // 卡片两种版式：图片卡 <a href="/lcmh-{id}/">…<img title="标题"> + .hv-title；
  // 图文卡 <a href="/lcmh-{id}/" alt="标题">…<img data-src="…">。统一按 id 抓块再找标题。
  var blocks = text.split('<a href="/lcmh-');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var idHit = /^(\d+)\//.exec(block);
    if (!idHit) continue;
    var id = idHit[1];
    if (seen[id]) continue;
    var seg = block.slice(0, 2600);
    var altHit = /alt="([^"]*)"/i.exec(seg);
    var titleHit = /<div class="hv-title">\s*([\s\S]{0,160}?)\s*<\/div>/i.exec(seg);
    var imgTitle = /<img[^>]*title="([^"]*)"/i.exec(seg);
    var title = oneLine(
      (altHit && altHit[1]) || (titleHit && titleHit[1]) || (imgTitle && imgTitle[1]) || ''
    );
    if (!title) continue;
    var img = /<img[^>]*(?:data-bg2|data-src|src)="([^"]+)"/i.exec(seg);
    var views = /hv-subtitle">[\s\S]{0,120}?([0-9]+)/i.exec(seg);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: img ? absolute(img[1]) : '',
      subtitle: views ? views[1] + ' 浏览' : 'AI 成人短剧',
      mediaType: 'video'
    });
  }
  return items;
}

function pageTitleOf(html) {
  var title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(String(html || ''));
  var text = oneLine(title ? title[1] : '');
  return text.replace(/\s*[-–_|]\s*乐成漫画\s*$/, '').trim();
}

var LumeSource = {
  id: 'lcm_video',
  name: '乐成漫画 · 短剧',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  network: 'direct',
  icon: 'https://www.lcmhx.cc/favicon.ico',
  mirrors: ['https://www.lcmhx.cc'],

  async categories() {
    return CATS.map(function (item) {
      return { id: item.id, title: item.title };
    });
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var boards = [];
    for (var i = 0; i < CATS.length; i++) {
      try {
        var cards = parseItems(await fetchHtml('/mctype/' + CATS[i].id + '/')).slice(0, 12);
        if (cards.length) boards.push({ title: CATS[i].title, moreUrl: CATS[i].id, items: cards });
      } catch (error) {
        /* 单频道失败不影响首页 */
      }
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    if (!categoryId) categoryId = '5';

    var path = keyword
      ? '/index.php/vod/search.html?wd=' + encodeURIComponent(keyword)
      : '/mctype/' + categoryId + '/';
    var html = await fetchHtml(path);
    var items = parseItems(html);
    if (!items.length && keyword) return { items: [], hasMore: false };
    if (!items.length && page === 1) {
      throw new Error('这个分类没有取到条目（' + path + '，站点模板可能改了）');
    }
    // 站点分类页没有翻页控件（每页 28 条）
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var id = itemIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/lcmh-' + id + '/');
    if (!html) return null;
    var title = pageTitleOf(html);
    if (!title) return null;
    var poster = /poster="([^"]+)"/i.exec(html);
    var desc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(html);
    var lines = [];
    lines.push('类型：AI 成人短剧');
    var descText = desc ? oneLine(desc[1]) : '';
    if (descText) lines.push('', descText);
    return {
      id: id,
      title: title,
      cover: poster ? absolute(poster[1]) : '',
      subtitle: 'AI 成人短剧',
      description: lines.join('\n'),
      mediaType: 'video'
    };
  },

  async chapters(argument) {
    var id = itemIdOf(argument && argument.id);
    if (!id) return [];
    return [{ id: id + ':1', title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var id = itemIdOf(raw) || itemIdOf(args.id);
    if (!id) throw new Error('缺少剧集 ID');

    var pagePath = '/lcmh-' + id + '/';
    var html = await fetchHtml(pagePath);
    var hls = /data-hls-src="([^"]+)"/i.exec(html);
    var fallback = /data-fallback-src="([^"]+)"/i.exec(html);
    var target = hls ? hls[1] : (fallback ? fallback[1] : '');
    if (!target) throw new Error('这一集没有解析到播放地址（data-hls-src 缺失）');
    return {
      kind: 'video',
      url: proxied(target),
      headers: { Referer: base() + pagePath, 'User-Agent': UA }
    };
  }
};
