// LumeSource: {"id":"xyunsou_video","name":"X云搜","version":"1.0.0","category":"video","contentCategory":"adult","network":"direct","mirrors":["https://xn--x-bw6a720euqa.com"],"icon":"https://xn--x-bw6a720euqa.com/favicon.svg","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"note","type":"info","title":"站点说明","description":"18+ 云搜聚合站。**站方把播放器锁在会员里**：视频页 data-content-restricted=1，/api/video-user-state 匿名只回 authenticated:false，播放器 HTML 只发给「已登录且 is_vip 为真」的账号；/hot、/favorite-rankings 匿名直接 401。所以本源只做「最新 + 搜索 + 详情」，播放走站方网页播放器——在网页里登录你自己的站方账号后由站方放行。"},{"key":"login","type":"info","title":"播放说明","description":"点开条目后是站方视频页；需要在该网页里登录（并开通站方会员）才能出画面。没有账号时只能看标题与封面。"}]}
// LumeRuntime: javascript
//
// 站点：X云搜（x云搜.com，punycode 主域见 mirrors），成人视频云搜聚合。
//
// 实测（2026-11-09）：
//   · 列表   /latest 与 /latest/page/{n}（24 条/页，翻页链接「下一页」）
//            /search?q=<词>&page={n}（24 条/页；站方还有 sort=relevance|newest）
//            卡片 <article class="video-card"> → <a class="video-thumb" href="/video/{id}"
//            aria-label="查看 {标题}"> + <img data-source-src|data-poster-src> +
//            <span class="duration-badge">00:05:53</span>
//   · 详情   /video/{id} → <h1>标题</h1> + og:image 封面（data-s3-src 那台 p.xsocdn.com
//            有防盗链，403，只用 data-source-src / data-poster-src）
//   · 播放   **锁会员**：视频页 body 带 data-content-restricted="1"，播放器由
//            /api/video-user-state?video_id=…&include_player=1 下发，匿名回
//            {authenticated:false,is_vip:false}；只有 authenticated && is_vip 才拿到 player.html。
//            /hot、/favorite-rankings/month 匿名 401。所以本源只给列表/详情，
//            播放交给站方网页播放器（用户自己登录会员）。
//
// 结论：这不是「源站防盗链」那种能绕的口子，是站方账号权限；源里不做假线路。

var MIRRORS = ['https://xn--x-bw6a720euqa.com'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';

// 首页「热门搜索」里的常用词（站方 trend 链接），当分类用
var TREND_TAGS = ['偷情', '无码', '熟女', '换妻', '乱伦', '母子', '巨乳', '内射'];

function xyBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
}

function xyHeaders(extra) {
  var headers = { 'User-Agent': UA, Referer: xyBase() + '/' };
  if (extra) {
    for (var key in extra) headers[key] = extra[key];
  }
  return headers;
}

async function xyGet(path) {
  var response = await LumeSource.http.get(xyBase() + path, {
    headers: xyHeaders({ Accept: 'text/html,application/xhtml+xml' }),
  });
  if (response.status === 401) return null;
  if (response.status === 403 || response.status === 503) {
    throw new Error('X云搜返回人机校验（HTTP ' + response.status + '），稍后重试');
  }
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('X云搜暂不可用（HTTP ' + response.status + '）');
  return response.body;
}

function xyText(value) {
  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  return String(value == null ? '' : value)
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

function xyDuration(text) {
  var match = /^(\d+):(\d+):(\d+)$/.exec(String(text || '').trim());
  if (!match) return undefined;
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

function xyItems(html) {
  var blocks = String(html || '').split('<article class="video-card">').slice(1);
  var items = [];
  var seen = {};
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    var href = /href="\/video\/(\d+)"/.exec(block);
    if (!href || seen[href[1]]) continue;
    seen[href[1]] = true;
    var label = /aria-label="查看\s*([^"]*)"/.exec(block);
    var title = xyText(label ? label[1] : '');
    if (!title) continue;
    var cover = /data-source-src="([^"]+)"/.exec(block) || /data-poster-src="([^"]+)"/.exec(block);
    var time = /class="duration-badge"[^>]*>([\s\S]*?)<\/span>/.exec(block);
    var duration = time ? xyText(time[1]).replace(/^\s*/, '') : '';
    items.push({
      id: href[1],
      title: title,
      cover: cover ? cover[1] : undefined,
      subtitle: duration || undefined,
      duration: xyDuration(duration),
    });
  }
  return items;
}

async function xyListPage(path) {
  var html = await xyGet(path);
  if (html == null) return { items: [], hasMore: false };
  return { items: xyItems(html), hasMore: /下一页/.test(html) };
}

var LumeSource = {
  categories() {
    var list = [{ id: 'latest', title: '最新收录' }];
    for (var i = 0; i < TREND_TAGS.length; i++) {
      list.push({ id: 'tag_' + TREND_TAGS[i], title: '热门 · ' + TREND_TAGS[i] });
    }
    return list;
  },

  async list({ categoryId, page, keyword } = {}) {
    var currentPage = Math.max(1, Math.floor(Number(page) || 1));
    var query = String(keyword || '').trim();
    if (query) {
      return xyListPage('/search?q=' + encodeURIComponent(query) + '&page=' + currentPage);
    }
    var id = String(categoryId || 'latest');
    if (id.indexOf('tag_') === 0) {
      return xyListPage('/search?q=' + encodeURIComponent(id.slice(4)) + '&page=' + currentPage);
    }
    return xyListPage(currentPage > 1 ? '/latest/page/' + currentPage : '/latest');
  },

  async detail({ id } = {}) {
    if (!/^\d+$/.test(String(id || ''))) return null;
    var html = await xyGet('/video/' + id);
    if (html == null) return null;
    var heading = /<h1>([\s\S]*?)<\/h1>/.exec(html);
    var title = xyText(heading ? heading[1] : '');
    if (!title) return null;
    var cover = /<meta\s+property="og:image"\s+content="([^"]*)"/i.exec(html);
    var duration = /data-duration-label[^>]*>([^<]*)</.exec(html);
    return {
      id: id,
      title: title,
      cover: cover ? xyText(cover[1]) : undefined,
      subtitle: duration ? xyText(duration[1]) : undefined,
      description: 'X云搜收录 · 播放需在站方网页登录会员账号',
    };
  },

  async chapters({ id } = {}) {
    if (!/^\d+$/.test(String(id || ''))) return [];
    return [{ id: 'web', title: '网页播放（需站方会员）' }];
  },

  async content({ id } = {}) {
    if (!/^\d+$/.test(String(id || ''))) throw new Error('这条视频没有详情页');
    return { kind: 'webplayer', pageUrl: xyBase() + '/video/' + id };
  },
};
