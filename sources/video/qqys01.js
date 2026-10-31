// LumeSource: {"id":"qqys01_movie","name":"千千影视","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.qqys01.com"],"network":"direct","icon":"https://www.qqys01.com/favicon.ico"}
//
// 站点页面是公开的 MacCMS 风格 HTML。此源提供公开分类、列表、搜索、详情和分集；
// 仅读取公开播放页内的免费媒体配置；官方分享页交回原网站。
// 遇到页面标注 VIP / 付费 / 积分限制时拒绝播放，不调用第三方解析服务或绕过授权。
var ORIGIN = 'https://www.qqys01.com';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var CATEGORY_ROWS = [
  { id: 'home', title: '首页推荐' },
  { id: '1', title: '电影' },
  { id: '2', title: '连续剧' },
  { id: '3', title: '综艺' },
  { id: '4', title: '动漫' }
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return (domain || ORIGIN).replace(/\/+$/, '');
}

function absolute(path) {
  var value = String(path || '').trim();
  if (!value) return '';
  if (/^https?:\/\//i.test(value)) return value;
  if (value.indexOf('//') === 0) return 'https:' + value;
  return base() + (value.charAt(0) === '/' ? value : '/' + value);
}

async function page(path, missingOk) {
  var response = await LumeSource.http.get(absolute(path), {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      Referer: base() + '/'
    }
  });
  if (missingOk && response && response.status === 404) return '';
  if (response && (response.status === 403 || response.status === 503) && /cf-chl-|challenge-platform|just a moment/i.test(response.body || '')) {
    throw new Error('NEED_WEBVIEW_VERIFY：千千影视触发人机校验，请在网页视图完成验证');
  }
  if (!response || response.status !== 200) {
    throw new Error('千千影视页面请求失败：HTTP ' + (response ? response.status : 0) + ' ' + path);
  }
  return response.body || '';
}

function decode(text) {
  return String(text || '')
    .replace(/&nbsp;|&#160;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, function (_, value) { return String.fromCharCode(Number(value)); })
    .replace(/&#x([\da-f]+);/gi, function (_, value) { return String.fromCharCode(parseInt(value, 16)); });
}

function clean(text) {
  return decode(String(text || '').replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function restricted(text) {
  return /(?:\bVIP\b|会员专享|付费观看|需付费|积分播放|金币播放)/i.test(String(text || ''));
}

function featuredItems(html) {
  var heading = html.indexOf('正在热映');
  if (heading < 0) throw new Error('千千影视首页推荐结构已变化');
  var end = html.indexOf('class="module-heading"', heading + 5);
  return parseItems(html.slice(heading, end < 0 ? html.length : end));
}

function routePriority(chapter) {
  var name = chapter.title.split(' · ')[0];
  var priorities = { 'JS线路': 0, 'BF线路': 1, 'DB线路': 2, 'MY线路': 3, 'Ry线路': 4, 'LZ线路': 6, 'FF线路': 7 };
  return Object.prototype.hasOwnProperty.call(priorities, name) ? priorities[name] : 5;
}

function parseItems(html) {
  var items = [];
  var seen = {};
  var cards = /<a\b(?=[^>]*class=["'][^"']*\bmodule-(?:poster-item|card-item-poster)(?:\s|["']))([^>]*)>([\s\S]*?)<\/a>/gi;
  var match;
  while ((match = cards.exec(String(html))) !== null) {
    var attrs = match[1];
    var body = match[2];
    var href = /\bhref=["']([^"']+)["']/i.exec(attrs);
    var id = href && /\/voddetail(\d+)\.html(?:[?#]|$)/i.exec(href[1]);
    if (!id || seen[id[1]] || restricted(body + ' ' + attrs)) continue;
    var titleAttr = /\btitle=["']([^"']+)["']/i.exec(attrs);
    var titleMatch = /class=["'][^"']*module-poster-item-title[^"']*["'][^>]*>([\s\S]*?)<\//i.exec(body);
    var alt = /\balt=["']([^"']*)["']/i.exec(body);
    var cover = /\bdata-original=["']([^"']+)["']/i.exec(body) || /\bsrc=["']([^"']+)["']/i.exec(body);
    var note = /class=["'][^"']*module-item-note[^"']*["'][^>]*>([\s\S]*?)<\//i.exec(body);
    var title = clean(titleAttr ? titleAttr[1] : titleMatch ? titleMatch[1] : alt ? alt[1] : '');
    if (!title) continue;
    seen[id[1]] = true;
    items.push({
      id: id[1],
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: note ? clean(note[1]) : ''
    });
  }
  return items;
}

function first(value) { return String(value || '').split(',')[0]; }

// 站点单个维度不支持多选；App 多选时取第一项。类型采用站点子分类 id，
// 它会切换到该子类（例如动作片 6），其余维度可组合，不在本地假过滤。
function listPath(categoryId, pageNumber, filters) {
  var category = /^\d+$/.test(String(categoryId || '')) ? String(categoryId) : '1';
  filters = filters || {};
  var type = first(filters.type);
  var slots = [type && /^\d+$/.test(type) ? type : category,
    first(filters.area), '', first(filters.genre), first(filters.lang), '', '', '',
    String(pageNumber), '', '', first(filters.year)];
  return '/vodshow/' + slots.map(encodeURIComponent).join('-') + '.html';
}

function detailPath(value) {
  var text = String(value || '');
  var match = /^\d+$/.test(text) ? [text, text] : /\/voddetail(\d+)\.html(?:[?#]|$)/.exec(text);
  return match ? '/voddetail' + match[1] + '.html' : '';
}

function filterGroups(html) {
  var groups = [];
  var known = { '类型': ['type', 0], '剧情': ['genre', 3], '地区': ['area', 1], '语言': ['lang', 4], '年份': ['year', 11] };
  var chunks = String(html).split(/<div\b[^>]*class=["']module-class-items\b[^"']*["'][^>]*>/i);
  for (var i = 1; i < chunks.length; i++) {
    var heading = /class=["']module-item-title["'][^>]*>([\s\S]*?)<\/div>/i.exec(chunks[i]);
    var title = heading ? clean(heading[1]) : '';
    var key = known[title];
    if (!key) continue;
    var options = [];
    var seen = {};
    var links = /<a\b[^>]*href=["']\/vodshow\/([^"']+)\.html["'][^>]*>([\s\S]*?)<\/a>/gi;
    var match;
    while ((match = links.exec(chunks[i])) !== null) {
      var label = clean(match[2]);
      if (label === '全部') continue;
      var slots = match[1].split('-');
      var id = slots[key[1]] || '';
      try { id = decodeURIComponent(id); } catch (_) { continue; }
      if (!id || seen[id]) continue;
      seen[id] = true;
      options.push({ id: id, title: label });
    }
    if (options.length) groups.push({ id: key[0], title: title, options: options });
  }
  return groups;
}

function playerData(html) {
  var match = /\bvar\s+player_data\s*=\s*(\{[^<]*?\})\s*;?\s*<\/script>/i.exec(html);
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch (_) { throw new Error('千千影视播放配置格式已变化'); }
}

// 与网页的 base64decode + unescape 一致，不依赖 App 沙箱里没有的 atob/Buffer。
function mediaUrl(player) {
  var value = String(player.url || '');
  if (Number(player.encrypt) === 2) {
    var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var buffer = 0, bits = 0, result = '';
    for (var i = 0; i < value.length; i++) {
      var ch = value.charAt(i);
      if (ch === '=') break;
      var index = alphabet.indexOf(ch);
      if (index < 0) continue;
      buffer = (buffer << 6) | index;
      bits += 6;
      if (bits >= 8) { bits -= 8; result += String.fromCharCode((buffer >>> bits) & 255); }
    }
    value = result;
  }
  if (Number(player.encrypt) === 1 || Number(player.encrypt) === 2) {
    value = value.replace(/%u([\da-f]{4})|%([\da-f]{2})/gi, function (_, unicode, byte) {
      return String.fromCharCode(parseInt(unicode || byte, 16));
    });
  } else if (Number(player.encrypt || 0) !== 0) {
    throw new Error('千千影视使用了尚未支持的播放编码');
  }
  return value;
}

function hasNext(html, pageNumber) {
  var pattern = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
  var match;
  while ((match = pattern.exec(String(html))) !== null) {
    if (!/\bclass=["'][^"']*page-next[^"']*["']/i.test(match[1])) continue;
    if (!/下一页|下页/.test(clean(match[2]))) continue;
    var href = /\bhref=["']([^"']+)["']/i.exec(match[1]);
    return !!href && new RegExp('(?:^|[-/])' + (pageNumber + 1) + '(?:[-./]|$)').test(href[1]);
  }
  return false;
}

var LumeSource = {
  id: 'qqys01_movie',
  name: '千千影视',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  mirrors: ['https://www.qqys01.com'],

  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开站点主页',
      url: 'https://www.qqys01.com/',
      description: '站点首页会公布当前可用地址。'
    },
    {
      key: 'playbackNote',
      type: 'info',
      title: '播放说明',
      description: '仅支持公开免费媒体；部分原站线路会失效，可切换 JS / BF 等线路。官方分享页交回官网。未发现独立镜像；qqys01.com 仅为主站跳转别名。类型会切换子分类，筛选多选取首项；旧版 App 的筛选默认按电影库展示。VIP、付费与积分限制不会绕过。'
    }
  ],

  async categories() {
    return CATEGORY_ROWS;
  },

  async filters(argument) {
    // filtersFor() 会传分类；旧版 filters() 无参数时按电影库展示。
    var category = argument && argument.categoryId || '1';
    return { groups: filterGroups(await page(listPath(category, 1))) };
  },

  async home() {
    var items = featuredItems(await page('/'));
    return items.length
      ? [{ title: '正在热映', moreUrl: 'home', items: items }]
      : [];
  },

  async list(argument) {
    var input = argument || {};
    var pageNumber = Math.max(1, Math.floor(Number(input.page) || 1));
    var keyword = String(input.keyword || '').trim();
    if (!keyword && (!input.categoryId || input.categoryId === 'home') && !Object.keys(input.filters || {}).some(function (key) { return !!input.filters[key]; })) {
      // 首页推荐是原站固定板块；没有下一页，不假接电影库冒充推荐分页。
      return { items: pageNumber === 1 ? featuredItems(await page('/')) : [], hasMore: false };
    }
    var path;
    if (keyword) {
      path = pageNumber > 1
        ? '/vodsearch/page/' + pageNumber + '/wd/' + encodeURIComponent(keyword) + '.html'
        : '/vodsearch.html?wd=' + encodeURIComponent(keyword);
    } else {
      path = listPath(input.categoryId, pageNumber, input.filters);
    }
    var html = await page(path);
    return { items: parseItems(html), hasMore: hasNext(html, pageNumber) };
  },

  async detail(argument) {
    var id = detailPath(argument && argument.id);
    if (!id) return null;
    var html = await page(id, true);
    var heading = /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(html);
    if (!heading) return null;
    var cover = /class=["'][^"']*module-info-poster[^"']*["'][\s\S]{0,1800}?data-original=["']([^"']+)["']/i.exec(html);
    var description = /class=["'][^"']*module-info-introduction-content[^"']*["'][^>]*>([\s\S]*?)<\//i.exec(html);
    var status = /class=["']module-info-item-title["'][^>]*>\s*集数[：:]\s*<\/span>\s*<div\b[^>]*class=["']module-info-item-content["'][^>]*>([\s\S]*?)<\//i.exec(html);
    return {
      id: /voddetail(\d+)/.exec(id)[1],
      title: clean(heading[1]),
      cover: cover ? absolute(cover[1]) : '',
      subtitle: status ? clean(status[1]) : '',
      description: description ? clean(description[1]) : ''
    };
  },

  async chapters(argument) {
    var id = detailPath(argument && argument.id);
    if (!id) return [];
    var html = await page(id);
    var chapters = [];
    var seen = {};
    var names = [], nameMatch;
    var namePattern = /\bdata-dropdown-value=["']([^"']+)["']/gi;
    while ((nameMatch = namePattern.exec(html)) !== null) names.push(clean(nameMatch[1]));
    var blocks = html.split(/<div\b[^>]*class=["'][^"']*\bmodule-play-list-content\b[^"']*["'][^>]*>/i);
    for (var i = 1; i < blocks.length; i++) {
      var links = /<a\b([^>]*class=["'][^"']*module-play-list-link[^"']*["'][^>]*)>([\s\S]*?)<\/a>/gi;
      var block = blocks[i].split('</div>')[0];
      var match;
      while ((match = links.exec(block)) !== null) {
        var href = /\bhref=["']([^"']+)["']/i.exec(match[1]);
        if (!href || !/\/vodplay\/[^"']+\.html(?:[?#]|$)/i.test(href[1])) continue;
        var title = clean(match[2]);
        if (!title || restricted(title) || seen[href[1]]) continue;
        seen[href[1]] = true;
        chapters.push({ id: href[1], title: (names[i - 1] ? names[i - 1] + ' · ' : '') + title });
      }
    }
    if (!chapters.length) {
      var firstPlay = /<a\b([^>]*href=["']([^"']*\/vodplay\/[^"']+\.html)["'][^>]*)>([\s\S]*?)<\/a>/i.exec(html);
      if (firstPlay) {
        var title = clean(firstPlay[3]) || '正片';
        if (!restricted(title)) chapters.push({ id: firstPlay[2], title: title });
      }
    }
    // 保留每条原站线路及其集序，优先显示本次实测较稳定的 JS/BF/DB。
    return chapters.sort(function (a, b) { return routePriority(a) - routePriority(b); });
  },

  async content(argument) {
    var chapterId = String(argument && argument.chapterId || '');
    if (!chapterId) throw new Error('缺少公开播放页地址');
    var path = /(?:^|\/)vodplay\/(\d+-\d+-\d+)\.html(?:[?#]|$)/.exec(chapterId);
    if (!path) {
      throw new Error('不是千千影视的公开播放页');
    }
    chapterId = absolute('/vodplay/' + path[1] + '.html');
    var html = await page(chapterId);
    if (restricted(html)) throw new Error('该分集标注为 VIP 或付费内容，源不会绕过站点限制');
    var player = playerData(html);
    if (!player) throw new Error('千千影视未返回公开播放配置，请在站点查看是否需要登录');
    if (Number(player.points || 0) > 0) throw new Error('该分集需要积分或付费授权，请在原站访问');
    var media = mediaUrl(player);
    if (/^https?:\/\//i.test(media) && /\.(?:m3u8|mp4|flv|mpd)(?:[?#]|$)/i.test(media)) {
      return { kind: 'video', url: media, headers: { Referer: chapterId, 'User-Agent': UA } };
    }
    if (!/^https?:\/\//i.test(media)) throw new Error('千千影视没有可用的公开媒体地址');
    // 页面配置指向腾讯/爱奇艺等官方分享页时，只打开该页，遵守官方访问限制。
    return {
      kind: 'webplayer',
      pageUrl: media,
      headers: { Referer: base() + '/', 'User-Agent': UA }
    };
  }
};
