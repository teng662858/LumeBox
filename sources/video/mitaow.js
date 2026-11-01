// LumeSource: {"id":"mitaow_video","name":"蜜桃网","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://admire.mdskbdjb.cc","https://base.mdskbdjb.cc","https://access.mdskbdjb.cc","https://d2l6fc4s7txsb.cloudfront.net"],"network":"direct","settings":[{"key":"note","type":"info","title":"站点说明","description":"蜜桃网（admire/base/access.mdskbdjb.cc 三条线路同一套站，mitaow50.com 只是地址发布页）：吃瓜爆料 + 网红黑料 + 国产厂牌，SSR 页面，列表 60 条/页。列表 /order/today/ 与 /order/hot/ 支持 /page/N/ 翻页；9 个分类（/category/<slug>/）固定首屏 60 条不分页。详情 /archives/<id>/ 的 DPlayer data-config 里直接给签名 m3u8（hls.ohjzmm.cn），带 Referer 可播。搜索 /search/<词>/。"}]}
// LumeRuntime: javascript
//
// 站点：蜜桃网（https://admire.mdskbdjb.cc）—— 服务端渲染的爆料站，页面里直接带播放器配置。
// 结构（2026-11-02 实测，Tabbit 打开真站定位到真实域名后逐页验证）：
//   列表   /order/today/（今日更新）、/order/hot/（热门），分页 /order/<type>/page/<N>/
//          /category/mitaoremen|wanghuang|jian-kong-po-jie|tan-hua-da-shen|cg|
//          ou-mei-xie-lie|ce-pai-chao-di|gaoqingav|chengrendongman/
//   搜索   /search/<encodeURIComponent(词)>/
//   详情   /archives/<id>/  → <div class="videoplayer dplayer" data-config='{...}'>
//          data-config.video.url = https://hls.ohjzmm.cn/videos5/<hash>/<hash>.m3u8?auth_key=…
//   卡片   <a href="/archives/<id>/" title="标题"> … <img z-image-loader-url="`封面`">
// 站点没有加密接口，纯 HTML 解析即可；封面地址两边带反引号，要剥掉。

var DEFAULT_DOMAIN = 'https://admire.mdskbdjb.cc';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

// 列表分页的两种入口 + 9 个分类
var CATS = [
  { id: 'today', title: '今日更新', path: '/order/today/' },
  { id: 'hot', title: '热门', path: '/order/hot/' },
  { id: 'c-mitaoremen', title: '蜜桃热门', path: '/category/mitaoremen/' },
  { id: 'c-wanghuang', title: '蜜桃网黄', path: '/category/wanghuang/' },
  { id: 'c-jian-kong-po-jie', title: 'AI短剧', path: '/category/jian-kong-po-jie/' },
  { id: 'c-tan-hua-da-shen', title: '探花大神', path: '/category/tan-hua-da-shen/' },
  { id: 'c-cg', title: '原创乱伦', path: '/category/cg/' },
  { id: 'c-ou-mei-xie-lie', title: '欧美系列', path: '/category/ou-mei-xie-lie/' },
  { id: 'c-ce-pai-chao-di', title: '偷拍窥视', path: '/category/ce-pai-chao-di/' },
  { id: 'c-gaoqingav', title: '高清AV', path: '/category/gaoqingav/' },
  { id: 'c-chengrendongman', title: '成人动漫', path: '/category/chengrendongman/' }
];
var PAGED = /^\/order\//; // 只有 /order/* 支持 /page/N/

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (domain || DEFAULT_DOMAIN).replace(/\/+$/, '');
}

function site() { return base() + '/'; }

async function fetchPage(url) {
  var res = await LumeSource.http.get(url, { headers: { 'User-Agent': UA, Referer: site() } });
  if (!res || res.status < 200 || res.status >= 300) throw new Error('抓取失败 HTTP ' + (res && res.status) + ' ' + url);
  return res.body || '';
}

function decodeEntities(text) {
  return String(text == null ? '' : text)
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function absUrl(path) {
  var value = String(path == null ? '' : path).trim().replace(/^`+|`+$/g, '');
  if (!value) return '';
  if (/^https?:\/\//i.test(value)) return value;
  if (value.charAt(0) === '/') return base() + value;
  return '';
}

function idOf(href) {
  var m = /\/archives\/(\d+)\//.exec(String(href || ''));
  return m ? m[1] : '';
}

// 列表页：按 /archives/<id>/ 主链接推进，标题取 title 属性或紧随其后的 h3
function parseRows(html) {
  var text = String(html || ''), seen = {}, rows = [], m;
  var re = /<a href="(\/archives\/\d+\/)"[^>]*>/g;
  while ((m = re.exec(text))) {
    var id = idOf(m[1]);
    if (!id || seen[id]) continue;
    var tail = text.slice(m.index, m.index + 1500);
    var titleHit = /title="([^"]+)"/.exec(tail) || /<h3[^>]*>([\s\S]*?)<\/h3>/.exec(tail);
    var img = /z-image-loader-url="([^"]+)"/.exec(tail);
    seen[id] = true;
    rows.push({ id: id, title: clean(titleHit ? titleHit[1] : '') || ('作品 ' + id), cover: absUrl(img ? img[1] : '') });
  }
  return rows;
}

// 详情页：DPlayer 的 data-config 里带播放地址
function parseDetail(html) {
  var cfg = /data-config='([\s\S]*?)'/.exec(String(html || ''));
  var url = '';
  if (cfg) {
    try {
      var parsed = JSON.parse(decodeEntities(cfg[1]));
      if (parsed && parsed.video && typeof parsed.video.url === 'string') url = parsed.video.url;
    } catch (_) {}
  }
  if (!url) {
    var raw = /"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"/.exec(decodeEntities(String(html || '')));
    if (raw) url = decodeEntities(raw[1]);
  }
  return { url: url };
}

var known = {};

var LumeSource = {
  id: 'mitaow_video',
  name: '蜜桃网',
  version: '1.0.0',
  category: 'video',

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() { return { groups: [] }; },

  async home() {
    var result = await this.list({ page: 1 });
    return result.items;
  },

  async list(args) {
    var a = args || {};
    if (a.filters && Object.keys(a.filters).length) throw new Error('该站点未提供筛选规则');
    var page = Math.max(1, Number(a.page) || 1);
    var keyword = String(a.keyword || '').trim();
    var url;

    if (keyword) {
      url = site() + 'search/' + encodeURIComponent(keyword) + '/';
    } else {
      var cat = CATS[0];
      var wanted = String(a.categoryId || cat.id);
      CATS.forEach(function (c) { if (c.id === wanted) cat = c; });
      if (PAGED.test(cat.path)) {
        url = site().replace(/\/$/, '') + cat.path + (page > 1 ? 'page/' + page + '/' : '');
      } else {
        // 分类页只有首屏 60 条，站点没有 /page/N/（实测 404）
        if (page > 1) return { items: [], hasMore: false };
        url = site().replace(/\/$/, '') + cat.path;
      }
    }

    var html = await fetchPage(url);
    var rows = parseRows(html);
    if (!rows.length) {
      if (page > 1) return { items: [], hasMore: false };
      throw new Error(keyword ? '没有搜到内容' : '该分类没有解析到条目');
    }
    rows.forEach(function (row) { known[row.id] = known[row.id] || {}; });

    var hasMore = false;
    if (!keyword && PAGED.test(url.replace(site(), '/'))) hasMore = rows.length >= 20;
    return { items: rows, hasMore: hasMore };
  },

  async detail(a) {
    var id = String((a && a.id) || '');
    if (!id) return null;
    var html = await fetchPage(site() + 'archives/' + id + '/');
    var title = /<title>([\s\S]*?)<\/title>/.exec(html);
    var heading = /<h3[^>]*class="[^"]*text-line-ellipsis-2[^"]*"[^>]*>([\s\S]*?)<\/h3>/.exec(html)
      || /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(html)
      || /<h2[^>]*>([\s\S]*?)<\/h2>/.exec(html);
    var title2 = clean(heading ? heading[1] : '') || clean(title ? title[1] : '').replace(/\s*\|\s*蜜桃网.*$/, '');
    var desc = /<meta[^>]+name="description"[^>]+content="([^"]*)"/i.exec(html) || /<meta[^>]+property="og:description"[^>]+content="([^"]*)"/i.exec(html);
    // 封面：优先正文 defaultimg 的主图，退而取第一个真图（avatar 是占位值）
    var posters = [], pre = /z-image-loader-url="([^"]+)"/g, pm;
    while ((pm = pre.exec(html))) posters.push(pm[1]);
    var main = /class="defaultimg"[\s\S]{0,400}?z-image-loader-url="([^"]+)"/.exec(html);
    var poster = (main && /^`?https?:\/\//i.test(main[1]) ? main[1] : '')
      || posters.filter(function (u) { return /^`?https?:\/\//i.test(u); })[0] || '';
    var parsed = parseDetail(html);
    if (parsed.url) known[id] = { url: parsed.url };

    return {
      id: id,
      title: title2 || ('作品 ' + id),
      cover: absUrl(poster),
      description: clean(desc ? desc[1] : '')
    };
  },

  async chapters(a) {
    return [{ id: String((a && a.id) || ''), title: '播放' }];
  },

  async content(a) {
    var id = String((a && (a.id || a.chapterId)) || '');
    var row = known[id];
    var url = row && row.url ? row.url : '';
    if (!url) {
      var html = await fetchPage(site() + 'archives/' + id + '/');
      url = parseDetail(html).url;
      if (url) known[id] = { url: url };
    }
    if (!url) throw new Error('该条目没有解析到播放地址');
    return { kind: 'video', url: url, headers: { 'User-Agent': UA, Referer: site() } };
  }
};
