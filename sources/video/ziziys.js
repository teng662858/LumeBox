// LumeSource: {"id":"ziziys_video","name":"子子影视","version":"1.0.1","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://www.ziziys.org","https://www.ziziys.net","https://www.ziziys.com"],"network":"direct","icon":"https://zizi.staticimgjs.org/uploads/2026/05/logo-2.png"}
// LumeRuntime: javascript
//
// 站点：子子影视（发布页 https://www.ziziys.info/ → 主用 www.ziziys.org；
//       镜像 www.ziziys.net；www.ziziys.com 官方标注「国内无法访问」，只进 mirrors 供手选）。
// 形态：与 4k影视 / 两个BT影视同一套「Alpine SSR + nbmovie wasm」CMS：
//       全量片库 /filter?page=N（24 条/页，真分页）、栏目 /movie /tv /anime（服务端单页）、
//       搜索 /search?q=<词>、详情/播放页 /play/<slug>。
//
// ── 播放：本源自己算签名，直接拿 m3u8 ──
//   播放页每个分集有自己的 slug 和 dataid，前端由 /static/wasm/nbmovie_wasm.js 的
//   build_play_url() 生成 /video/play?p=&v=&q=&s=&t=&k= 再请求。签名算法（实测复现）：
//     · s = HMAC-SHA256(key = slug, msg = "<dataid>:<t>:<slug>") 的前 32 个 hex；改一位即 403；
//     · t = 毫秒时间戳（站点 <meta id="nb-st"> 与本地时钟差在毫秒级，不必对齐）；
//     · k = base64(xor("nbmovie2024secretkey", userlink))，userlink 在播放页 x-data 里，游客也有；k=0 亦可。
//   实测：/video/play 返回 quality_urls，1080p 未锁定 → m3u8 200 + #EXTM3U（oss.douyinbit.com）。
//
// ── VIP 档（实测回显）──
//   q=720 → {"code":401,"message":"需要VIP会员才能观看，请先登录"}；
//   q=4k  → {"code":403,"message":"4K清晰度仅支持客户端播放，Web端不支持"}；
//   同一次 q=1080 响应里 4K 那一档是 {"isvip":true,"locked":true,"url":"1"} 的占位值。
//   → 本源取「未锁定」的那一档（1080p 蓝光），站内 VIP 只挡更高清晰度，此处不伪造、不绕过。
//
// 限制：栏目页（/movie /tv /anime）服务端只有一页，真分页在 /filter；「综艺」（classify=4）
//       站点本身为空，如实返回空并说明，不拿别的分类顶替。

var HOST = 'https://www.ziziys.org';
var MIRRORS = [
  'https://www.ziziys.org',
  'https://www.ziziys.net',
  'https://www.ziziys.com'
];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var SALT = 'nbmovie2024secretkey';
var PAGE_SIZE = 24;

var CATS = [
  { id: 'filter', title: '全部影片', path: '/filter' },
  { id: 'movie', title: '电影', path: '/movie' },
  { id: 'tv', title: '电视剧', path: '/tv' },
  { id: 'anime', title: '动漫', path: '/anime' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }

function unescapeHtml(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#x27;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code)); });
}
function clean(text) {
  return unescapeHtml(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}
function get(path) {
  return LumeSource.http.request({
    url: base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + '/'
    }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
    return reply.body == null ? '' : String(reply.body);
  });
}
function getJson(path) {
  return LumeSource.http.request({
    url: base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'application/json, text/plain, */*',
      'Referer': base() + '/'
    }
  }).then(function (reply) {
    var body = reply && reply.body != null ? String(reply.body) : '';
    var data = null;
    try { data = JSON.parse(body); } catch (e) { data = null; }
    return { status: (reply && reply.status) || 0, data: data, body: body };
  });
}

// ------------------------------------------------------------------ 纯 JS SHA-256 / HMAC
// video 沙箱没有 crypto / Buffer / atob，签名只能自己算。标准 FIPS 180-4 实现。
var SHA_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
function utf8Bytes(str) {
  var out = [];
  var text = String(str == null ? '' : str);
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
      var next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        var cp = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        i++;
        continue;
      }
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  return out;
}
function sha256Words(bytes) {
  var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  var bitLen = bytes.length * 8;
  var data = bytes.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  var hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
  data.push((hi >>> 24) & 255, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255);
  data.push((lo >>> 24) & 255, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
  var w = new Array(64);
  for (var off = 0; off < data.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = ((data[off + i * 4] << 24) | (data[off + i * 4 + 1] << 16) |
              (data[off + i * 4 + 2] << 8) | data[off + i * 4 + 3]) >>> 0;
    }
    for (var j = 16; j < 64; j++) {
      var x = w[j - 15], y = w[j - 2];
      var s0 = (rotr(x, 7) ^ rotr(x, 18) ^ (x >>> 3)) >>> 0;
      var s1 = (rotr(y, 17) ^ rotr(y, 19) ^ (y >>> 10)) >>> 0;
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) >>> 0;
    }
    var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (var r = 0; r < 64; r++) {
      var S1 = (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) >>> 0;
      var ch = ((e & f) ^ ((~e) & g)) >>> 0;
      var t1 = (h + S1 + ch + SHA_K[r] + w[r]) >>> 0;
      var S0 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) >>> 0;
      var mj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      var t2 = (S0 + mj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0;
    H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0;
    H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
  }
  return H;
}
function wordsToBytes(words) {
  var out = [];
  for (var i = 0; i < words.length; i++) {
    out.push((words[i] >>> 24) & 255, (words[i] >>> 16) & 255, (words[i] >>> 8) & 255, words[i] & 255);
  }
  return out;
}
function bytesToHex(bytes) {
  var s = '';
  for (var i = 0; i < bytes.length; i++) s += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  return s;
}
function hmacSha256Hex(key, message) {
  var kb = utf8Bytes(key);
  if (kb.length > 64) kb = wordsToBytes(sha256Words(kb));
  while (kb.length < 64) kb.push(0);
  var ipad = [], opad = [];
  for (var i = 0; i < 64; i++) { ipad.push(kb[i] ^ 0x36); opad.push(kb[i] ^ 0x5c); }
  var inner = wordsToBytes(sha256Words(ipad.concat(utf8Bytes(message))));
  return bytesToHex(wordsToBytes(sha256Words(opad.concat(inner))));
}

// ------------------------------------------------------------------ k 令牌（base64 + xor）
var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function base64Encode(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i];
    var b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    var b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64_ALPHABET[b0 >> 2];
    out += B64_ALPHABET[((b0 & 3) << 4) | (b1 >> 4)];
    out += i + 1 < bytes.length ? B64_ALPHABET[((b1 & 15) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < bytes.length ? B64_ALPHABET[b2 & 63] : '=';
  }
  return out;
}
function playKey(userlink) {
  var link = String(userlink == null ? '' : userlink).trim();
  if (!link || link === '0') return '0';
  var bytes = utf8Bytes(link);
  var salt = utf8Bytes(SALT);
  var mixed = [];
  for (var i = 0; i < bytes.length; i++) mixed.push(bytes[i] ^ salt[i % salt.length]);
  return base64Encode(mixed);
}

// ------------------------------------------------------------------ HTML 解析
function parseCards(html) {
  var source = String(html || '');
  var items = [];
  var seen = {};
  var chunks = source.split(/<a\s[^>]*href="\/play\/([A-Za-z0-9]+)"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var slug = chunks[i];
    if (!slug || seen[slug]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 2500);
    var img = /<img\s[^>]*>/i.exec(block);
    if (!img) continue;
    var tag = img[0];
    var title = /alt="([^"]*)"/i.exec(tag);
    var cover = /data-src="([^"]+)"/i.exec(tag) || /src="([^"]+)"/i.exec(tag);
    var name = unescapeHtml(title ? title[1] : '').trim();
    if (!name || name === 'item.title' || name === '子子影视' || name === '4k影视') continue;
    var pic = cover ? unescapeHtml(cover[1]) : '';
    if (/placeholder/.test(pic)) pic = '';
    var badge = /<span[^>]*>([^<]{1,20})<\/span>/i.exec(block);
    seen[slug] = true;
    items.push({
      id: slug,
      title: name,
      cover: pic,
      subtitle: badge ? clean(badge[1]) : ''
    });
  }
  return items;
}

function parseDetail(html) {
  var source = String(html || '');
  var ogImage = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
  var desc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(source);
  var keywords = /<meta\s+name="keywords"\s+content="([^"]*)"/i.exec(source);
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  var heading = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(source);
  var title = clean(heading ? heading[1] : '');
  if (!title && titleTag) {
    // 形如「镖人：风起大漠 - 第1集 -子子影视」
    title = clean(titleTag[1]).replace(/\s*-\s*第\s*\d+\s*集\s*/g, ' ')
      .replace(/\s*-\s*子子影视\s*$/, '').replace(/\s*-\s*4k影视\s*$/, '').trim();
  }
  var link = /userlink:'([^']+)'/.exec(source);
  var total = /更新至(\d+)\/(\d+)集/.exec(source);
  return {
    title: title,
    cover: ogImage ? unescapeHtml(ogImage[1]) : '',
    description: desc ? unescapeHtml(desc[1]).trim() : '',
    keywords: keywords ? unescapeHtml(keywords[1]) : '',
    episodes: parseEpisodes(source),
    userlink: link ? link[1] : '',
    updated: total ? Number(total[1]) : 0,
    total: total ? Number(total[2]) : 0
  };
}

// 分集按钮：href="/play/<slug>" data-line="1" data-episode="N" dataid="123"
function parseEpisodes(html) {
  var source = String(html || '');
  var out = [];
  var seen = {};
  var re = /href="\/play\/([A-Za-z0-9]+)"[^>]*data-line="(\d+)"[^>]*data-episode="(\d+)"[^>]*dataid="(\d+)"/g;
  var match;
  while ((match = re.exec(source)) !== null) {
    var key = match[1] + ':' + match[3];
    if (seen[key]) continue;
    seen[key] = true;
    out.push({ slug: match[1], line: Number(match[2]) || 1, number: Number(match[3]), dataid: match[4] });
  }
  out.sort(function (a, b) { return a.line - b.line || a.number - b.number; });
  return out;
}

// ------------------------------------------------------------------ 播放地址
function signPlayUrl(dataid, slug, quality, userlink, stamp) {
  var t = String(stamp);
  var s = hmacSha256Hex(slug, dataid + ':' + t + ':' + slug).slice(0, 32);
  return '/video/play?p=' + enc(dataid) + '&v=' + enc(slug) + '&q=' + enc(quality) +
    '&s=' + s + '&t=' + t + '&k=' + enc(playKey(userlink));
}
// 站点一次返回多档：未锁定的才可用；isvip / locked / 占位 "1" 一律跳过
function pickUrl(rows) {
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row || !row.url) continue;
    var url = String(row.url);
    if (!/^https?:\/\//i.test(url)) continue;
    if (row.isvip === true || row.locked === true) continue;
    return url;
  }
  return '';
}
function lockedOnly(rows) {
  var list = rows || [];
  if (!list.length) return false;
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (row && /^https?:\/\//i.test(String(row.url || '')) && row.isvip !== true && row.locked !== true) {
      return false;
    }
  }
  return true;
}
function requestPlay(path) {
  return getJson(path).catch(function () {
    return { status: 0, data: null, body: '' };
  });
}
function usable(attempt) {
  return !!(attempt && attempt.data && attempt.data.code === 200 &&
    attempt.data.data && attempt.data.data.quality_urls);
}
async function siteStamp(slug) {
  try {
    var html = await get('/play/' + slug);
    var m = /id="nb-st" content="(\d+)"/.exec(String(html || ''));
    return m ? Number(m[1]) : 0;
  } catch (e) {
    return 0;
  }
}

// 拿一集的可播地址：优先 1080（站点免费档）
async function resolveEpisode(episode, userlink) {
  var now = Date.now ? Date.now() : new Date().getTime();
  var attempt = await requestPlay(signPlayUrl(episode.dataid, episode.slug, '1080', userlink, now));
  if (usable(attempt)) {
    var url = pickUrl(attempt.data.data.quality_urls);
    if (url) return url;
    if (lockedOnly(attempt.data.data.quality_urls)) {
      throw new Error('这一集在站点上只给出 VIP/4K 锁定档，1080p 未开放，本源不绕过。');
    }
  }
  // 时间戳偏差过大时站点会拒签：用页面 nb-st 再试一次
  var stamp = await siteStamp(episode.slug);
  if (stamp && String(stamp) !== String(now)) {
    attempt = await requestPlay(signPlayUrl(episode.dataid, episode.slug, '1080', userlink, stamp));
    if (usable(attempt)) {
      var retryUrl = pickUrl(attempt.data.data.quality_urls);
      if (retryUrl) return retryUrl;
    }
  }
  // 401「请提供访问令牌」= k 里编的 userlink 失效（游客链接会过期）：重读播放页拿新的再试一次
  var first = (attempt && attempt.data) || {};
  if (first.code === 401 && /令牌/.test(String(first.message || ''))) {
    try {
      var fresh = String(await get('/play/' + episode.slug) || '');
      var freshLink = /userlink:\s*'([^']+)'/.exec(fresh);
      var freshId = /dataid="(\d+)"/.exec(fresh);
      if (freshLink && freshLink[1] && (!userlink || freshLink[1] !== userlink)) {
        var again = await requestPlay(signPlayUrl(freshId ? freshId[1] : episode.dataid, episode.slug, '1080', freshLink[1], stamp || now));
        if (usable(again)) {
          var againUrl = pickUrl(again.data.data.quality_urls);
          if (againUrl) return againUrl;
        }
        attempt = again;
      }
    } catch (e2) { /* 保持后面的可读报错 */ }
  }
  var data = (attempt && attempt.data) || {};
  var message = String(data.message || (attempt && attempt.body) || '').trim();
  if (data.code === 401) {
    if (/令牌/.test(message)) {
      throw new Error('站点要求播放令牌（游客 userlink 已过期）：刷新详情页或稍后重试即可。');
    }
    throw new Error('站点把这一集标成 VIP 清晰度（' + (message || '需要会员') + '），1080p 未开放，本源不绕过。');
  }
  if (data.code === 403) {
    throw new Error('站点拒绝了这个清晰度' + (message ? '（' + message + '）' : '') + '：4K 仅官方客户端可播。');
  }
  throw new Error('拿不到播放地址：' + (message.slice(0, 80) || ('HTTP ' + ((attempt && attempt.status) || 0))));
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'ziziys_video',
  name: '子子影视',
  version: '1.0.1',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: 'https://zizi.staticimgjs.org/uploads/2026/05/logo-2.png',
  commonSettings: [
    {
      key: 'quality', title: '清晰度', type: 'select',
      options: [{ value: '1080', title: '1080p 蓝光（站点免费档）' }],
      default: '1080'
    }
  ],
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://www.ziziys.info/',
      description: '站点换域名时先看这里（发布页列出主用/备用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '子子影视（www.ziziys.org，镜像 ziziys.net；ziziys.com 官方标注国内无法访问）。本源直接算播放签名取 1080p m3u8 直连；4K 档站点只给客户端、720p 需站点 VIP，都不绕过。栏目页（电影/电视剧/动漫）站点本身只有一页，全量翻页请用「全部影片」；综艺分类站点为空。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 选项取自站点 /filter 页的真实链接（?types=1 …），实测每个都生效且可与 classify/areas/years 组合。
    return {
      groups: [
        {
          key: 'classify', title: '分类', multiple: false, options: [
            { id: '1', title: '电影' }, { id: '2', title: '电视剧' },
            { id: '3', title: '动漫' }, { id: '4', title: '综艺' }
          ]
        },
        {
          key: 'types', title: '类型', multiple: true, options: [
            { id: '1', title: '剧情' }, { id: '2', title: '悬疑' }, { id: '3', title: '恐怖' },
            { id: '4', title: '惊悚' }, { id: '5', title: '喜剧' }, { id: '6', title: '爱情' },
            { id: '9', title: '犯罪' }, { id: '10', title: '动作' }, { id: '11', title: '动画' },
            { id: '12', title: '奇幻' }, { id: '13', title: '音乐' }, { id: '14', title: '科幻' },
            { id: '15', title: '历史' }, { id: '16', title: '战争' }, { id: '18', title: '冒险' },
            { id: '19', title: '家庭' }, { id: '20', title: '纪录' }, { id: '23', title: '西部' },
            { id: '24', title: '电视电影' }, { id: '25', title: '情色' }, { id: '26', title: '真人秀' },
            { id: '27', title: '古装' }, { id: '28', title: '传记' }, { id: '29', title: '同性' },
            { id: '30', title: '运动' }, { id: '31', title: '武侠' }, { id: '32', title: '歌舞' },
            { id: '33', title: '纪录片' }, { id: '34', title: '灾难' }, { id: '35', title: '短片' }
          ]
        },
        {
          key: 'areas', title: '地区', multiple: true, options: [
            { id: '7', title: '中国' }, { id: '52', title: '中国大陆' }, { id: '14', title: '中国香港' },
            { id: '21', title: '中国台湾' }, { id: '5', title: '美国' }, { id: '11', title: '日本' },
            { id: '12', title: '韩国' }, { id: '30', title: '英国' }, { id: '6', title: '法国' },
            { id: '18', title: '德国' }, { id: '24', title: '西班牙' }, { id: '33', title: '泰国' },
            { id: '34', title: '印度' }, { id: '16', title: '俄罗斯' }, { id: '22', title: '澳大利亚' },
            { id: '32', title: '加拿大' }, { id: '19', title: '意大利' }
          ]
        },
        {
          key: 'years', title: '年份', multiple: false, options: [
            { id: '1', title: '2026' }, { id: '3', title: '2025' }, { id: '4', title: '2024' },
            { id: '56', title: '2023' }, { id: '13', title: '2022' }, { id: '2', title: '2021' },
            { id: '6', title: '2020' }, { id: '8', title: '2019' }, { id: '9', title: '2018' },
            { id: '12', title: '2017' }, { id: '11', title: '2016' }, { id: '14', title: '2015' },
            { id: '15', title: '2014' }, { id: '22', title: '2013' }, { id: '10', title: '2012' },
            { id: '17', title: '2011' }, { id: '25', title: '2010' }, { id: '20', title: '2009' },
            { id: '23', title: '2008' }, { id: '30', title: '2007' }, { id: '31', title: '2006' },
            { id: '7', title: '2005' }, { id: '24', title: '2004' }, { id: '28', title: '2003' },
            { id: '19', title: '2002' }, { id: '29', title: '2001' }, { id: '43', title: '2000' },
            { id: '45', title: '1999' }, { id: '33', title: '1998' }, { id: '37', title: '1996' },
            { id: '21', title: '1995' }
          ]
        },
        {
          key: 'tags', title: '标签', multiple: false, options: [
            { id: '1', title: '4K' }, { id: '36', title: '院线' },
            { id: '37', title: 'HD' }, { id: '38', title: 'TC' }
          ]
        },
        {
          key: 'sort_by', title: '排序', multiple: false, options: [
            { id: 'update_time', title: '最新上映' },
            { id: 'hits', title: '最受欢迎' },
            { id: 'score', title: '评分最高' }
          ]
        }
      ]
    };
  },

  async home() {
    var html = await get('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    if (keyword) {
      var found = parseCards(await get('/search?q=' + enc(keyword)));
      // 站点的搜索页要先有会话 Cookie（首个请求直接搜会返回 0 条）：空结果时先摸一次首页再重搜。
      if (!found.length) {
        try { await get('/'); } catch (e) { /* 首页打不开就按空结果返回 */ }
        found = parseCards(await get('/search?q=' + enc(keyword)));
      }
      return { items: found, hasMore: false };
    }

    // 栏目页（/movie /tv /anime）服务端固定一页；全量分页走 /filter
    var cat = null;
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { cat = CATS[i]; break; }
    }
    if (cat && cat.id !== 'filter') {
      if (page !== 1) return { items: [], hasMore: false };
      var catItems = parseCards(await get(cat.path));
      if (!catItems.length) {
        throw new Error('站点「' + cat.title + '」栏目当前没有内容（该栏目在源站本身为空）');
      }
      return { items: catItems, hasMore: false };
    }

    var query = ['page=' + page];
    if (filters.classify) query.push('classify=' + enc(filters.classify));
    if (filters.types) query.push('types=' + enc(filters.types));
    if (filters.areas) query.push('areas=' + enc(filters.areas));
    if (filters.years) query.push('years=' + enc(filters.years));
    if (filters.tags) query.push('tags=' + enc(filters.tags));
    if (filters.sort_by) {
      query.push('sort_by=' + enc(filters.sort_by));
      query.push('order=desc');
    }
    var items = parseCards(await get('/filter?' + query.join('&')));
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var slug = String((argument && argument.id) || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(slug)) return null;
    var html = '';
    try {
      html = await get('/play/' + slug);
    } catch (e) {
      return null; // 站点对不存在的条目回 400/404：按「找不到」处理，不抛给用户
    }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var bits = [];
    if (info.total > 0 && info.updated > 0) bits.push('更新至 ' + info.updated + '/' + info.total + ' 集');
    else if (info.episodes.length > 1) bits.push('共 ' + info.episodes.length + ' 集');
    else bits.push('正片');
    bits.push('1080p 直连');
    var tags = info.keywords.split(/[,，]/).map(function (t) { return t.trim(); }).filter(function (t) {
      return t && t.length <= 12;
    }).slice(0, 6);
    return {
      id: slug,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: (info.description || '') +
        (info.description ? '\n\n' : '') +
        '播放说明：本源直接算站点播放签名，取未锁定的 1080p m3u8 直链，可在 App 里直接播放和选集；' +
        '720p 属站点 VIP 清晰度（401），4K 仅官方客户端（403），本源不绕过。',
      tags: tags
    };
  },

  async chapters(argument) {
    var slug = String((argument && argument.id) || '').trim();
    if (!slug) return [];
    var html = await get('/play/' + slug);
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var episodes = parseEpisodes(html);
    if (!episodes.length) {
      if (/dataid="\d+"/.test(html)) return [{ id: slug, title: '正片' }];
      throw new Error('这一条在站点上没有可播放的分集');
    }
    var lines = {};
    for (var i = 0; i < episodes.length; i++) lines[episodes[i].line] = (lines[episodes[i].line] || 0) + 1;
    var multi = Object.keys(lines).length > 1;
    return episodes.map(function (ep) {
      return {
        id: ep.slug,
        title: (multi ? '线路 ' + ep.line + ' · ' : '') + (episodes.length > 1 ? ('第 ' + ep.number + ' 集') : '正片')
      };
    });
  },

  async content(argument) {
    var args = argument || {};
    var slug = String(args.chapterId || args.id || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(slug)) throw new Error('条目参数无效，请重新打开详情页');
    var html = await get('/play/' + slug);
    if (!html) throw new Error('站点上没有这一集（可能已下架）');
    var info = parseDetail(html);
    var episode = null;
    for (var i = 0; i < info.episodes.length; i++) {
      if (info.episodes[i].slug === slug) { episode = info.episodes[i]; break; }
    }
    if (!episode) {
      var only = /dataid="(\d+)"/.exec(html);
      if (!only) throw new Error('这一条在站点上没有可播放的地址');
      episode = { slug: slug, dataid: only[1], number: 1, line: 1 };
    }
    var url = await resolveEpisode(episode, info.userlink);
    if (!url) throw new Error('站点没有返回可播放地址');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
