// LumeSource: {"id":"jmcomic_video","name":"禁漫天堂 · H動漫","version":"1.0.0","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://18comic.ink","https://18comic.vip","https://jmcomic.me"],"network":"direct","icon":"https://18comic.ink/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"禁漫天堂的 H動漫 频道（18comic.ink 实测可直连；18comic.vip / jmcomic.me 走 Cloudflare 挑战，源里会抛 NEED_WEBVIEW_VERIFY，换镜像即可）。列表 /videos?o={mr|mv|mp|tr|md|tf}&t={a|t|w|m}&page=N；条目 /video/{id}/；播放页直接内联 <source type='application/x-mpegURL'> 的签名 m3u8（e/st 参数），实测 200 + #EXTM3U。签名有时效，所以每次取流都现开播放页。分类/筛选都实测换内容（?o=mv 热门、?t=w 本周、page=2 都不同）。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（jmcomictt.site）","url":"https://jmcomictt.site/","description":"官方发布页：给当前域名与 APP 下载"}]}
// LumeRuntime: javascript
//
// 站点：禁漫天堂（18comic）的 H動漫 频道。用户给的 18comic.vip 走 Cloudflare managed challenge
// （本机 403「Just a moment...」），但镜像 18comic.ink 实测直连 200，所以本源默认用 .ink，
// .vip / jmcomic.me 留在 mirrors 里供切换。
//
// 结构（2026-11-04 用 18comic.ink 实测）：
//   · 列表   /videos              每页 40 条左右；?o=mr 最新 / o=mv 热门 / o=mp·tr·md·tf；?t=a|t|w|m 时间范围
//            ?page=N 真翻页（第 2 页首条与第 1 页不同）
//   · 卡片   <div class="thumb-overlay"><img data-original="…/media/videos/tmb/{id}/10.jpg" title="标题">
//            外加 .video-factory（片商）/ .video-view（👁️ 播放数）/ .video-added（日期）
//   · 详情   /video/{id}/  h1 = 标题，og:image = 封面(/media/videos/tmb/{id}/default.jpg)
//   · 播放   <video id="vplayer"><source src="https://ms18comic-2.iiooxx.rocks/…/hls/{iphone|hd|…}/{id}.mp4/index.m3u8?e=…&st=…"
//             type='application/x-mpegURL'> —— 签名带时效，且不同清晰度不一定都存在（实测 hd 可能 404）
//             所以 content() 依次试前 3 条源，命中 200 + #EXTM3U 就用它。

var BASE_URL = 'https://18comic.ink';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var SORTS = [
  { id: 'mr', title: '最新' },
  { id: 'mv', title: '人气' },
  { id: 'mp', title: '最多图片' },
  { id: 'tr', title: ' trending' },
  { id: 'md', title: '最多收藏' },
  { id: 'tf', title: '最多点赞' }
];

var TIMES = [
  { id: '', title: '全部' },
  { id: 'a', title: '全部时间' },
  { id: 't', title: '今日' },
  { id: 'w', title: '本周' },
  { id: 'm', title: '本月' }
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
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：禁漫天堂触发了 Cloudflare 人机校验（HTTP ' + status + '），可在源设置里换 18comic.ink 镜像');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (/cf-chl-|Just a moment|cf-turnstile/i.test(body)) {
    throw new Error('NEED_WEBVIEW_VERIFY：禁漫天堂需要网页验证，可在源设置里换 18comic.ink 镜像');
  }
  return body;
}

function videoIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/video\/(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 列表卡片：<a href="/video/{id}/{slug}"> 里面是 .thumb-overlay + img，后面跟 .video-factory/.video-view/.video-added
function parseItems(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('href="/video/');
  for (var i = 1; i < blocks.length; i++) {
    var seg = blocks[i].slice(0, 3200);
    var idHit = /^(\d+)\//.exec(seg);
    if (!idHit) continue;
    var id = idHit[1];
    if (seen[id]) continue;
    var img = /<img[^>]*data-original="([^"]+)"/i.exec(seg) || /<img[^>]*data-src="([^"]+)"/i.exec(seg);
    var title = /<img[^>]*title="([^"]*)"/i.exec(seg);
    var name = oneLine(title ? title[1] : '');
    if (!name) {
      var spanTitle = /<span class="video-title[^"]*">([\s\S]*?)<\/span>/i.exec(seg);
      name = oneLine(spanTitle ? spanTitle[1] : '');
    }
    if (!name) continue;
    var factory = /class="video-factory"[^>]*>([\s\S]*?)<\/div>/i.exec(seg);
    var views = /class="video-view"[^>]*>([\s\S]*?)<\/div>/i.exec(seg);
    var added = /class="video-added"[^>]*>([\s\S]*?)<\/div>/i.exec(seg);
    seen[id] = true;
    items.push({
      id: id,
      title: name,
      cover: img ? absolute(img[1]) : '',
      subtitle: [
        factory ? oneLine(factory[1]) : '',
        views ? oneLine(views[1]) : '',
        added ? oneLine(added[1]) : ''
      ].filter(Boolean).join(' · '),
      mediaType: 'video'
    });
  }
  return items;
}

function pagerOf(html, page) {
  var text = String(html || '');
  var nextHref = new RegExp('href="[^"]*[?&]page=' + (page + 1) + '(?:[^"]*)"');
  if (nextHref.test(text)) return true;
  return /class="pagination"/.test(text) && new RegExp('page=' + (page + 1)).test(text);
}

var LumeSource = {
  id: 'jmcomic_video',
  name: '禁漫天堂 · H動漫',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  network: 'direct',
  icon: 'https://18comic.ink/favicon.ico',
  mirrors: ['https://18comic.ink', 'https://18comic.vip', 'https://jmcomic.me'],

  async categories() {
    var list = [];
    for (var i = 0; i < SORTS.length; i++) {
      list.push({ id: 'sort-' + SORTS[i].id, title: SORTS[i].title });
    }
    return list;
  },

  async filters() {
    return {
      groups: [
        {
          id: 'sort',
          title: '排序',
          options: SORTS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        },
        {
          id: 'time',
          title: '时间',
          options: TIMES.map(function (item) {
            return { id: item.id || 'all', title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    var latest = parseItems(await fetchHtml('/videos')).slice(0, 12);
    if (latest.length) boards.push({ title: '最新', moreUrl: 'sort-mr', items: latest });
    try {
      var hot = parseItems(await fetchHtml('/videos?o=mv')).slice(0, 12);
      if (hot.length) boards.push({ title: '热门', moreUrl: 'sort-mv', items: hot });
    } catch (error) {
      /* 热门失败不影响首页 */
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    var sort = String(filters.sort || '').trim();
    if (!sort && /^sort-/.test(categoryId)) sort = categoryId.slice(5);
    if (!sort) sort = 'mr';
    var time = String(filters.time || '').trim();
    if (time === 'all' || time.indexOf(',') >= 0) time = time === 'all' ? '' : time.split(',')[0].trim();

    var path;
    if (keyword) {
      path = '/search/videos?search_query=' + encodeURIComponent(keyword) + '&page=' + page;
    } else {
      path = '/videos?o=' + sort + (time ? '&t=' + time : '') + '&page=' + page;
    }

    var html = await fetchHtml(path);
    var items = parseItems(html);
    if (!items.length && keyword) return { items: [], hasMore: false };
    if (!items.length && page === 1) throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    return { items: items, hasMore: pagerOf(html, page) };
  },

  async detail(argument) {
    var id = videoIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/video/' + id + '/');
    if (!html) return null;
    var h1 = /<h1[^>]*>([\s\S]{0,300}?)<\/h1>/i.exec(html);
    var title = oneLine(h1 ? h1[1] : '');
    if (!title) return null;
    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html);
    var views = /class="video-view"[^>]*>([\s\S]*?)<\/div>/i.exec(html);
    var factory = /class="video-factory"[^>]*>([\s\S]*?)<\/div>/i.exec(html);
    var lines = [];
    lines.push('类型：H動漫');
    if (factory) lines.push('片商：' + oneLine(factory[1]));
    if (views) lines.push('播放：' + oneLine(views[1]));
    return {
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: factory ? oneLine(factory[1]) : 'H動漫',
      description: lines.join('\n'),
      mediaType: 'video'
    };
  },

  async chapters(argument) {
    var id = videoIdOf(argument && argument.id);
    if (!id) return [];
    return [{ id: id + ':video', title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var id = videoIdOf(raw) || videoIdOf(args.id);
    if (!id) throw new Error('缺少视频 ID');

    var pagePath = '/video/' + id + '/';
    var html = await fetchHtml(pagePath);
    var sources = [];
    var re = /<source\s+src="([^"]+)"\s+type=['"]application\/x-mpegURL['"]/gi;
    var hit;
    while ((hit = re.exec(html)) !== null) {
      var url = decodeEntities(hit[1]);
      if (url) sources.push(url);
    }
    if (!sources.length) throw new Error('播放页没有解析到 m3u8（站点模板可能改了）');

    var picked = '';
    var qualities = [];
    for (var i = 0; i < sources.length && i < 4; i++) {
      var probe = await LumeSource.http.get(sources[i], {
        headers: {
          'User-Agent': UA,
          Accept: '*/*',
          Referer: base() + pagePath,
          Origin: base()
        }
      });
      var status = probe ? probe.status : 0;
      var body = probe && probe.body ? String(probe.body) : '';
      if (status === 200 && body.indexOf('#EXTM3U') >= 0) {
        var label = /\/hls\/([^/]+)\//i.exec(sources[i]);
        var tag = label ? label[1] : '源' + (i + 1);
        qualities.push({ url: sources[i], label: tag, headers: { Referer: base() + pagePath } });
        if (!picked) picked = sources[i];
      }
    }
    if (!picked) throw new Error('这条视频的 m3u8 都打不开（签名过期？重试一次）');
    return {
      kind: 'video',
      url: picked,
      qualities: qualities,
      headers: { Referer: base() + pagePath, 'User-Agent': UA }
    };
  }
};
