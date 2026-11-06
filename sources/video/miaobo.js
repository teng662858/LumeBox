// LumeSource: {"id":"miaobo_video","name":"秒播","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://edge-ov12.00h.quest"],"network":"direct","icon":"https://edge-ov12.00h.quest/favicon.ico","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开秒播发布页","url":"https://mmss.pro/","description":"站点换域名时从官方发布页找回当前地址。"},{"key":"note","type":"info","title":"站点说明","description":"18+ 视频站。页面双层 Base64 包装；分类、分页、关键词搜索按站点真实路由请求。封面为 Base64 文本加循环 XOR，需新版 App 图片解码支持。播放使用站点网页播放器，站点专用线路的令牌不是可直接播放的媒体地址。"}]}
// LumeRuntime: javascript
// Page wrapping and thumbnail encoding mirror the site's own public renderer.
var ORIGIN = 'https://edge-ov12.00h.quest';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';
function base() { return String(LumeSource.config && LumeSource.config.domain || ORIGIN).replace(/\/+$/, ''); }
function abs(path) {
  var value = String(path || '').trim();
  if (/^https?:\/\//i.test(value)) return value;
  if (value.indexOf('//') === 0) return 'https:' + value;
  return base() + (value.charAt(0) === '/' ? '' : '/') + value;
}
function clean(value) {
  return String(value || '').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
}
function headers() { return { 'User-Agent': UA, Referer: base() + '/' }; }
var cachedHome = null;
async function page(path) {
  var reply = await LumeSource.http.get(abs(path), { headers: headers() });
  var text = String(reply && reply.body || '');
  if (/Just a moment|cf-chl-|captcha/i.test(text) || Number(reply.status) === 403) {
    throw new Error('NEED_WEBVIEW_VERIFY：秒播当前线路需要网页校验');
  }
  if (Number(reply.status) !== 200) throw new Error('秒播页面请求失败：HTTP ' + reply.status);
  var wrapped = /var\s+str\s*=\s*['"]([A-Za-z0-9+/=]+)\s*['"]/.exec(text);
  if (wrapped) {
    text = await LumeSource.tools.base64Decode(wrapped[1]);
    text = await LumeSource.tools.base64Decode(text);
  }
  if (/<script[^>]*>\s*function strDecode/.test(text)) throw new Error('页面包装格式已变化');
  return text.replace(/<!--[\s\S]*?-->/g, '');
}
async function homepage() {
  if (cachedHome && cachedHome.origin === base() && Date.now() - cachedHome.time < 60000) return cachedHome.html;
  var html = await page('/'); cachedHome = { html: html, time: Date.now(), origin: base() }; return html;
}
function coverHeaders(url) {
  var h = headers();
  if (/\.txt(?:[?#]|$)/i.test(url)) {
    h['x-lume-image-encoding'] = 'xor-base64';
    h['x-lume-image-key'] = 'OzoTeoS7D>6Y^@z39JmD';
  }
  return h;
}
function cards(html) {
  var items = [], seen = {}, re = /<li\b[^>]*class=["'][^"']*content-item[^"']*["'][^>]*>([\s\S]*?)<\/li>/gi, hit;
  while ((hit = re.exec(html))) {
    var block = hit[1], link = /href=["'](?:https?:\/\/[^/"']+)?\/index\.php\/vod\/detail\/id\/(\d+)\.html["']/.exec(block);
    if (!link || seen[link[1]]) continue;
    var title = /<p\b[^>]*>([\s\S]*?)<\/p>/i.exec(block);
    var image = /<img\b[^>]*\bsrc=["']([^"']+)["']/i.exec(block);
    var name = clean(title ? title[1] : ''); if (!name) continue;
    var cover = image ? abs(image[1]) : '';
    seen[link[1]] = true; items.push({ id: link[1], title: name, cover: cover, coverHeaders: coverHeaders(cover) });
  }
  return items;
}
function categoriesOf(html) {
  var out = [], seen = {}, re = /href=["']\/index\.php\/vod\/type\/id\/(\d+)\.html["'][^>]*>([\s\S]*?)<\/a>/g, hit;
  while ((hit = re.exec(html))) {
    var title = clean(hit[2]); if (!title || seen[hit[1]]) continue;
    seen[hit[1]] = true; out.push({ id: hit[1], title: title });
  }
  return out;
}
function idOf(value) {
  var text = String(value || ''); return /^\d+$/.test(text) ? text : '';
}
function chaptersOf(html) {
  var out = [], seen = {}, re = /<a\b[^>]*href=["'](\/index\.php\/vod\/play\/id\/\d+\/sid\/\d+\/nid\/\d+\.html)["'][^>]*>([\s\S]*?)<\/a>/gi, hit;
  while ((hit = re.exec(html))) {
    if (seen[hit[1]]) continue; seen[hit[1]] = true;
    out.push({ id: hit[1], title: clean(hit[2]) || '播放' });
  }
  return out;
}
var LumeSource = {
  id: 'miaobo_video', name: '秒播', version: '1.0.0', category: 'video', contentCategory: 'adult',
  mirrors: [ORIGIN], network: 'direct', icon: ORIGIN + '/favicon.ico',
  async categories() {
    var out = categoriesOf(await homepage());
    if (!out.length) throw new Error('秒播导航未解析出分类');
    return out;
  },
  async filters() { return { groups: [] }; },
  async home() {
    var items = cards(await homepage());
    if (!items.length) throw new Error('秒播首页未解析出条目');
    return [{ title: '首页推荐', items: items }];
  },
  async list(args) {
    args = args || {}; var number = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword || '').trim();
    var category = idOf(args.categoryId) || '3';
    var path = keyword ? '/index.php/vod/search/wd/' + encodeURIComponent(keyword) + '/page/' + number + '.html'
      : '/index.php/vod/type/id/' + category + (number > 1 ? '/page/' + number : '') + '.html';
    var html = await page(path), items = cards(html);
    if (!items.length && number === 1 && !keyword) throw new Error('秒播该栏目没有解析出条目');
    return { items: items, hasMore: new RegExp('/page/' + (number + 1) + '\\.html').test(html) };
  },
  async detail(args) {
    var id = idOf(args && args.id); if (!id) return null;
    var html = await page('/index.php/vod/detail/id/' + id + '.html');
    var title = /<meta[^>]*name=["']keywords["'][^>]*content=["']([^"']+)["']/i.exec(html);
    var image = /<img[^>]*src=["']([^"']+\.txt(?:\?[^"']*)?)["']/i.exec(html);
    var cover = image ? abs(image[1]) : '';
    if (!chaptersOf(html).length) return null;
    return { id: id, title: clean(title ? title[1].split(/剧情介绍|在线观看|在线收看|[,，]/)[0].replace(/[-,，]+$/, '') : '秒播视频'),
      cover: cover, coverHeaders: coverHeaders(cover), description: '使用站点网页播放器，线路可在选集中选择。' };
  },
  async chapters(args) {
    var id = idOf(args && args.id); if (!id) return [];
    var out = chaptersOf(await page('/index.php/vod/detail/id/' + id + '.html'));
    if (!out.length) throw new Error('秒播详情没有可用播放线路');
    return out;
  },
  async content(args) {
    var path = String(args && args.chapterId || '');
    if (!/^\/index\.php\/vod\/play\/id\/\d+\/sid\/\d+\/nid\/\d+\.html$/.test(path)) throw new Error('播放线路无效');
    return { kind: 'webplayer', url: abs(path), headers: headers() };
  }
};
