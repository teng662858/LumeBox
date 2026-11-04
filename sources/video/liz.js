// LumeSource: {"id":"liz_video","name":"荔枝短剧","version":"1.0.0","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://liz01.com"],"network":"direct","icon":"https://liz01.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"荔枝短剧（liz01.com，Nuxt SPA + SSR 首屏）：AI 成人短剧站。频道 /category/（48 部）、/original/（荔枝原创 37 部）、/featured/（荔枝精选 48 部）、题材 /en/tag/{slug}/（30 个题材）；剧集 /en/drama/{id}/、单集 /en/drama/{id}/ep-{n}/。播放地址在单集页的 JSON-LD 里：contentUrl = /api/v1/cdn/video/{uuid}/manifest.m3u8?t=&sign=（SSR 现签，实测 200 + #EXTM3U 22 KB）。排序按钮是前端 JS（Latest/Hottest/Most Saved/Most Liked），URL 参数实测不生效，所以本源不做排序；封面由前端异步解密加载（配置里有 imageAesKeyHex），SSR HTML 里没有封面地址，列表封面留空。"}]}
// LumeRuntime: javascript
//
// 站点：荔枝短剧（liz01.com，Nuxt3 + SSR 首屏，AI 成人短剧）
//
// 结构（2026-11-04 实测）：
//   · 频道      /category/（48 部） /original/（37 部） /featured/（48 部）
//   · 题材      /en/tag/{slug}/（hougong/yingluan/chuanyue/chongsheng/…，站上 30 个）
//   · 卡片      <article class="vcard"><a href="/en/drama/{id}/ep-1/" class="vcard__link">
//                 <img class="cover-art__img" alt="《标题》 English 剧照">
//   · 详情      /en/drama/{id}/   h1 = 中文标题，og:description = 简介，页内 ep-{n} 链接 = 集数
//   · 单集      /en/drama/{id}/ep-{n}/   页内 JSON-LD VideoObject.contentUrl：
//                 /api/v1/cdn/video/{uuid}/manifest.m3u8?t={时间戳}&sign={sha…}
//               实测直接 GET → 200 + #EXTM3U（22,969 B master），不需要 Referer、不需要登录。
//               签名带 t，所以每次取流都要现开单集页（不能缓存地址）。
//
// 限制：
//   · 排序（Latest/Hottest/Most Saved/Most Liked）是前端按钮，`?sort=` 实测不生效 → 不声明排序组；
//   · 封面由前端异步解密（config.imageAesKeyHex），SSR HTML 里没有图片地址 → 列表封面留空；
//   · 频道单页 37–48 部，站上没有翻页控件。

var BASE_URL = 'https://liz01.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

var CHANNELS = [
  { id: 'all', title: '全部分类', path: '/category/' },
  { id: 'original', title: '荔枝原创', path: '/original/' },
  { id: 'featured', title: '荔枝精选', path: '/featured/' }
];

var TAGS = [
  { id: 'hougong', title: '后宫' },
  { id: 'yingluan', title: '淫乱' },
  { id: 'chuanyue', title: '穿越' },
  { id: 'chongsheng', title: '重生' },
  { id: 'tianchong', title: '甜宠' },
  { id: 'lianai', title: '恋爱' },
  { id: 'dushi', title: '都市' },
  { id: 'nixi', title: '逆袭' },
  { id: 'luanlun', title: '乱伦' },
  { id: 'nantong', title: '耽美' },
  { id: 'tongxing', title: '同性' },
  { id: 'shunv', title: '熟女' },
  { id: 'xianyan', title: '现言' },
  { id: 'quanmou', title: '权谋' },
  { id: 'renqi', title: '人妻' },
  { id: 'zhichang', title: '职场' },
  { id: 'fanzui', title: '犯罪' },
  { id: 'nuelian', title: '虐恋' },
  { id: 'lingyi', title: '灵异' },
  { id: 'xianxia', title: '仙侠' },
  { id: 'guzhuang', title: '古装' },
  { id: 'gufeng', title: '古风' },
  { id: 'qingchun', title: '青春' },
  { id: 'xiangcun', title: '乡村' }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim().replace(/\\u002F/g, '/');
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
    .replace(/&hellip;/g, '…')
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
    throw new Error('NEED_WEBVIEW_VERIFY：荔枝短剧触发了人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

// 封面走 CDN：media.lizdj009.com/{uuid}，**内容是 AES-128-CBC 密文**（站点 config 里的
// imageAesKeyHex/imageAesIvHex），本机用 node crypto 解出真 JPEG（ffd8ffe0）。
// 交给 App 原生解密：lume-enc://aes-cbc/<base64url(key)>/<base64url(iv)>/<url>
var COVER_KEY = '6hnCHoXXaNpBZfWWSriGsg';
var COVER_IV = '9NU-y8JzkB4NnNeEgjPHAg';

function encryptedCover(url) {
  if (!url) return '';
  if (!/^https?:\/\//i.test(url)) return '';
  return 'lume-enc://aes-cbc/' + COVER_KEY + '/' + COVER_IV + '/' + url;
}

function dramaIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/drama\/(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

// 卡片标题：alt="《无限尾行》 Harem Lewdness 剧照" → 无限尾行
function titleFromAlt(alt) {
  var text = oneLine(alt);
  var book = /《([^》]+)》/.exec(text);
  if (book) return oneLine(book[1]);
  return text.replace(/\s*(剧照|海报|poster|still)\s*$/i, '').trim();
}

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  // 页面头部的 JSON-LD ItemList 给「标题 + 封面 + 剧集地址」，比卡片可靠（有封面）
  var ld = /<script type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g;
  var block;
  while ((block = ld.exec(text)) !== null) {
    if (block[1].indexOf('"ItemList"') < 0) continue;
    var itemRe = /\{"@type":"ListItem","position":\d+,"url":"([^"]+)","name":"([^"]*)","image":"?([^",}]*)"?/g;
    var hit;
    while ((hit = itemRe.exec(block[1])) !== null) {
      var idHit = /\/drama\/(\d+)/.exec(String(hit[1]).replace(/\\\//g, '/'));
      if (!idHit) continue;
      var id = idHit[1];
      if (seen[id]) continue;
      var title = oneLine(String(hit[2]).replace(/\\u([0-9a-fA-F]{4})/g, ''));
      if (!title) continue;
      seen[id] = true;
      items.push({
        id: id,
        title: title,
        cover: encryptedCover(hit[3] ? String(hit[3]).replace(/\\\//g, '/') : ''),
        subtitle: '',
        mediaType: 'video'
      });
    }
  }

  var re = /<article class="vcard[^"]*"[\s\S]*?<\/article>/g;
  var card;
  while ((card = re.exec(text)) !== null) {
    var cardHtml = card[0];
    var link = /href="\/en\/drama\/(\d+)\/ep-\d+\/"/i.exec(cardHtml);
    if (!link) continue;
    var cid = link[1];
    var alt = /alt="([^"]*)"/i.exec(cardHtml);
    var cardTitle = alt ? titleFromAlt(alt[1]) : '';
    if (!cardTitle) continue;
    var plays = /vcard__plays-label"[^>]*>([^<]*)</i.exec(cardHtml);
    var eps = /vcard__eps"[^>]*>([^<]*)</i.exec(cardHtml);
    var badge = /vcard__cover-badge"[^>]*>([^<]*)</i.exec(cardHtml);
    var subtitle = [
      badge ? oneLine(badge[1]) : '',
      plays ? oneLine(plays[1]) + ' 播放' : '',
      eps ? oneLine(eps[1]) : ''
    ].filter(Boolean).join(' · ');
    if (seen[cid]) {
      // JSON-LD 已经放了标题与封面，这里补副标题
      for (var i = 0; i < items.length; i++) {
        if (items[i].id === cid && !items[i].subtitle) items[i].subtitle = subtitle;
      }
      continue;
    }
    seen[cid] = true;
    items.push({
      id: cid,
      title: cardTitle,
      cover: '',
      subtitle: subtitle,
      mediaType: 'video'
    });
  }
  return items;
}

function channelPath(categoryId, tag) {
  if (tag) return '/en/tag/' + tag + '/';
  for (var i = 0; i < CHANNELS.length; i++) {
    if (CHANNELS[i].id === categoryId) return CHANNELS[i].path;
  }
  return '/category/';
}

function episodeNumbers(html, dramaId) {
  var text = String(html || '');
  var re = new RegExp('/en/drama/' + dramaId + '/ep-(\\d+)/', 'g');
  var numbers = [];
  var seen = {};
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var n = Number(hit[1]);
    if (!n || seen[n]) continue;
    seen[n] = true;
    numbers.push(n);
  }
  numbers.sort(function (a, b) { return a - b; });
  return numbers;
}

var LumeSource = {
  id: 'liz_video',
  name: '荔枝短剧',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  network: 'direct',
  icon: 'https://liz01.com/favicon.ico',
  mirrors: ['https://liz01.com'],

  async categories() {
    return CHANNELS.map(function (item) {
      return { id: item.id, title: item.title };
    });
  },

  async filters() {
    return {
      groups: [
        {
          id: 'tag',
          title: '题材',
          options: TAGS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    for (var i = 0; i < CHANNELS.length; i++) {
      try {
        var cards = parseCards(await fetchHtml(CHANNELS[i].path)).slice(0, 12);
        if (cards.length) boards.push({ title: CHANNELS[i].title, moreUrl: CHANNELS[i].id, items: cards });
      } catch (error) {
        /* 单个频道失败不影响首页 */
      }
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var tag = String(filters.tag || '').trim();
    if (tag.indexOf(',') >= 0) tag = tag.split(',')[0].trim();

    var path = keyword ? '/search/' + encodeURIComponent(keyword) : channelPath(categoryId, tag);
    var html = await fetchHtml(path);
    var items = parseCards(html);
    if (!items.length && keyword) return { items: [], hasMore: false };
    if (!items.length) throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    // 站点各频道都是单页，没有翻页控件
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var id = dramaIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/en/drama/' + id + '/');
    if (!html) return null;
    var h1 = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(html);
    var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/i.exec(html);
    var title = oneLine(h1 ? h1[1] : '');
    if (!title && ogTitle) title = oneLine(String(ogTitle[1]).split('_')[0]);
    if (!title) return null;
    var desc = /<meta\s+(?:property|name)="(?:og:)?description"\s+content="([^"]*)"/i.exec(html);
    var episodes = episodeNumbers(html, id);
    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html);
    var coverUrl = cover ? absolute(cover[1]) : '';
    // og:image 是站点 logo，不是剧集封面；封面由前端解密加载，SSR 里没有
    if (/litchi-logo|og-default|placeholder/i.test(coverUrl)) coverUrl = '';
    var lines = [];
    lines.push('类型：AI 成人短剧');
    if (episodes.length) lines.push('集数：' + episodes.length);
    if (desc && oneLine(desc[1])) lines.push('', oneLine(desc[1]));
    return {
      id: id,
      title: title,
      cover: coverUrl,
      subtitle: episodes.length ? episodes.length + ' 集' : '短剧',
      description: lines.join('\n'),
      mediaType: 'video'
    };
  },

  async chapters(argument) {
    var id = dramaIdOf(argument && argument.id);
    if (!id) return [];
    var html = await fetchHtml('/en/drama/' + id + '/');
    var episodes = episodeNumbers(html, id);
    if (!episodes.length) throw new Error('这部剧没有解析到集数（drama ' + id + '）');
    return episodes.map(function (n) {
      return { id: id + ':' + n, title: '第 ' + n + ' 集' };
    });
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /^(\d+):(\d+)$/.exec(raw);
    var id = matched ? matched[1] : dramaIdOf(args.id);
    var episode = matched ? Number(matched[2]) : 1;
    if (!id) throw new Error('缺少剧集 ID（应形如 853:1）');

    var pagePath = '/en/drama/' + id + '/ep-' + episode + '/';
    var html = await fetchHtml(pagePath);
    var contentUrl = /"contentUrl":"([^"]+)"/i.exec(html) || /"contentUrl":\s*"([^"]+)"/i.exec(html);
    if (!contentUrl) throw new Error('单集页没有 contentUrl（签名播放地址缺失）');
    var url = absolute(contentUrl[1]);
    if (!url) throw new Error('播放地址解析失败');
    return {
      kind: 'video',
      url: url,
      headers: { Referer: base() + pagePath, 'User-Agent': UA }
    };
  }
};
