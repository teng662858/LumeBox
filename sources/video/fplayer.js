// LumeSource: {"id":"fplayer_video","name":"飞播","version":"1.0.1","category":"video","contentCategory":"adult","mirrors":["https://fplayer.cc"],"network":"proxy","icon":"https://fplayer.cc/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"飞播 FPlayer（fplayer.cc）：国产原创/自拍短视频。榜单页 /rankings/latest|trending|most-liked/?page=N，搜索 /search/?keyword=<词>&page=N（注意有斜杠）。详情 /video/<id>/，播放走 /embed/<id>/ 内的 m3u8（播放域 cdnawsgoogle.456311.xyz）。国内直连不通，需要代理。"}]}
// LumeRuntime: javascript
//
// 站点：飞播 FPlayer（https://fplayer.cc）
//
// 结构（2026-10-30 实测）：
//   榜单   /rankings/latest/、/rankings/trending/、/rankings/most-liked/，翻页 ?page=N
//   搜索   /search/?keyword=<词>&page=N（/search 会 301 到 /search/）
//   详情   /video/<id>/
//   播放   /embed/<id>/ 内 <video src="https://cdnawsgoogle.456311.xyz/<hash>/pl.m3u8">
//   卡片   <a href="/video/<id>/" aria-label="播放 标题"><img src="https://cdn-image.fplayer.cc/images/<id>.webp" alt="标题">
//
// 网络：国内直连 000，需要代理；封面在 cdn-image.fplayer.cc。

var DEFAULT_DOMAIN = 'https://fplayer.cc';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

var RANKINGS = [
  ['latest', '最新'],
  ['trending', '正在热播'],
  ['most-liked', '最多点赞']
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (domain || DEFAULT_DOMAIN).replace(/\/+$/, '');
}

function headers(referer) {
  return {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
    Referer: referer || base() + '/'
  };
}

function entity(text) {
  return String(text == null ? '' : text).replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, function (all, code) {
    var map = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
    if (map[code] !== undefined) return map[code];
    if (code.charAt(0) === '#') {
      var n = code.charAt(1) === 'x' || code.charAt(1) === 'X' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      if (isFinite(n) && n > 0 && n < 0x110000) return String.fromCharCode(n);
    }
    return all;
  });
}

function clean(text) {
  return entity(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function absolute(url) {
  var value = entity(String(url == null ? '' : url)).trim();
  if (!value || /^data:/i.test(value)) return '';
  if (/^https?:\/\//i.test(value)) return value;
  if (value.charAt(0) === '/') return base() + value;
  return base() + '/' + value;
}

async function get(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, { headers: headers() });
  var status = Number((reply && reply.status) || 0);
  var body = String((reply && reply.body) || '');
  if (!status) throw new Error('飞播：连不上（' + url + '，国内需代理）');
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：站点要求网页验证（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('飞播：请求失败（HTTP ' + status + ' ' + path + '）');
  return body;
}

function parseCards(html) {
  var re = /<a href="\/video\/(\d+)\/"[^>]*aria-label="(?:播放\s*)?([^"]*)"[\s\S]{0,400}?<img src="([^"]+)"/g;
  var out = [];
  var seen = {};
  var m;
  while ((m = re.exec(String(html || ''))) !== null) {
    if (seen[m[1]]) continue;
    seen[m[1]] = 1;
    out.push({
      id: m[1],
      title: clean(m[2]) || ('视频 ' + m[1]),
      cover: absolute(m[3]) || ('https://cdn-image.fplayer.cc/images/' + m[1] + '.webp'),
      subtitle: ''
    });
  }
  return out;
}

var LumeSource = {
  id: 'fplayer_video',
  name: '飞播',
  version: '1.0.1',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://fplayer.cc'],

  async home() {
    var sections = [];
    for (var i = 0; i < RANKINGS.length; i++) {
      try {
        var html = await get('/rankings/' + RANKINGS[i][0] + '/');
        var items = parseCards(html);
        if (items.length) sections.push({ title: RANKINGS[i][1], moreUrl: RANKINGS[i][0], items: items.slice(0, 24) });
      } catch (error) {
        console.warn('[fplayer] 首页抓取失败 ' + RANKINGS[i][1] + '：' + error);
      }
    }
    if (!sections.length) throw new Error('飞播：首页没有条目（站点可能改版或需要代理）');
    return sections;
  },

  async categories() {
    var out = [];
    for (var i = 0; i < RANKINGS.length; i++) out.push({ id: RANKINGS[i][0], title: RANKINGS[i][1] });
    return out;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1) || 1;
    if (page < 1) page = 1;
    var keyword = clean(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    var path;
    if (keyword) {
      path = '/search/?keyword=' + encodeURIComponent(keyword) + (page > 1 ? '&page=' + page : '');
    } else {
      var key = categoryId || 'latest';
      var known = false;
      for (var i = 0; i < RANKINGS.length; i++) if (RANKINGS[i][0] === key) known = true;
      if (!known) throw new Error('飞播：认不出这个分类（' + categoryId + '）');
      path = '/rankings/' + key + '/' + (page > 1 ? '?page=' + page : '');
    }
    var html = await get(path);
    var items = parseCards(html);
    if (!items.length) console.warn('[fplayer] 列表没解析出条目：' + path);
    // 站点每页 20 条；解析不足 12 条就认为到底
    return { items: items, hasMore: items.length >= 12 };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var html = await get('/video/' + id + '/');
    var title = clean((/property="og:title"[^>]+content="([^"]+)"/i.exec(html) || [])[1]);
    if (!title) title = clean((/<title[^>]*>([\s\S]*?)<\/title>/.exec(html) || [])[1]).replace(/\s*[-|]\s*飞播.*$/, '');
    var cover = ([/property="og:image"[^>]+content="([^"]+)"/i.exec(html) || []])[1] || '';
    if (!cover) cover = 'https://cdn-image.fplayer.cc/images/' + id + '.webp';
    var desc = clean((/name="description"[^>]+content="([^"]*)"/.exec(html) || [])[1]);
    return {
      id: id,
      title: title || ('视频 ' + id),
      cover: absolute(cover) || null,
      subtitle: '',
      description: (desc ? desc + '\n' : '') + '源站：' + base() + '/video/' + id + '/'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    return [{ id: 'play', title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.itemId || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('飞播：缺少视频 id');
    var pageUrl = base() + '/video/' + id + '/';
    var embedUrl = base() + '/embed/' + id + '/';
    var html = await get('/embed/' + id + '/');
    var url = (/<video[^>]+src="(https?:\/\/[^"]+\.m3u8[^"]*)"/.exec(html) || [])[1] || '';
    if (!url) url = (/"(?:file|source|url)"\s*:\s*"(https?:\/\/[^"]+\.m3u8[^"]*)"/.exec(html) || [])[1] || '';
    if (!url) url = (/(https?:\/\/[^"'\s]+\.m3u8[^"'\s]*)/.exec(html) || [])[1] || '';
    if (!url) {
      return { kind: 'webplayer', pageUrl: embedUrl, headers: headers(pageUrl) };
    }
    url = entity(url).replace(/\\\//g, '/');
    // 注意：不要给播放器带 Range 头——播放器拿它去请求每一条分片，只会拿到前 1KB，画面停在 0:00。
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: embedUrl }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
