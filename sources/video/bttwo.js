// LumeSource: {"id":"bttwo_video","name":"两个BT影视","version":"2.0.2","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://www.bttwo.life","https://www.bttwo.org","https://www.bttwo.top","https://www.bttwo.me"],"network":"direct","icon":"https://www.bttwo.life/ico.png"}
// LumeRuntime: javascript
//
// 站点：两个BT影视（发布页 https://bttwo.vip/ → 列出 bttwo.life / .org / .top / .me；
//       旧域名 bttwoo.com、bttwo.net 已失效，不再写进 mirrors）。
// 形态：Alpine.js 服务端渲染 HTML。全量片库 /filter?page=N（24 条/页，真分页）、
//       栏目 /movie /tv /anime（服务端单页）、搜索 /search?q=<词>、详情/播放页 /play/<slug>。
//
// ── 播放：本源自己算签名，直接拿 m3u8（不再依赖网页播放器）──
//   播放页每个分集有自己的 slug 和 dataid（/play/ch4qhla8l，dataid=41045），
//   前端调 /static/wasm/nbmovie_wasm.js 的 build_play_url(dataid, slug, 清晰度, userlink)
//   生成 /video/play?p=&v=&q=&s=&t=&k= 再请求，响应里才是 m3u8。三个参数全部逆出来了
//   （wasm 反汇编 + 运行时 hook 校验）：
//     · s = HMAC-SHA256(key = slug, msg = "<dataid>:<t>:<slug>") 的前 32 个 hex 字符；
//       改任意一位 → 403「你没有权限」。数据段里的 "nbmovie2024secretkey" 只用于 k，不参与 s。
//     · t = 毫秒时间戳；与站点 <meta id="nb-st"> 相差毫秒级即可，不需要对齐站点时钟。
//     · k = base64(xor("nbmovie2024secretkey", userlink))，userlink 取播放页 x-data 里的值
//       （游客也有，形如 X1VUXENZ…）；k=0 亦可通过（游客等价）。
//   实测（纯 JS 复现）：1080p 直出 m3u8 200 + #EXTM3U，分片 .ts 200 且不需要 Referer。
//
//   清晰度：1080 免费；720 / 480 返回「需要VIP会员才能观看」；4k 返回「仅支持客户端播放」。
//   → 本源只用 1080，不伪造 VIP，也不假装能播 4K。
//
// ── VIP（v2.0.1 复核：破不了，有实测回显；v2.0.2 起支持用自己的会员账号）──
//   · q=720 / q=480 → `{"code":401,"message":"需要VIP会员才能观看，请先登录"}`；
//   · q=4k        → `{"code":403,"message":"4K清晰度仅支持客户端播放，Web端不支持"}`；
//   · q=1080 的响应里 4K 那档是 `{"isvip":true,"locked":true,"url":"1"}`（占位值，不是地址）。
//   试过并排除的路子：
//     1) 换清晰度编码：q=1..5 / hd / sd / fhd / uhd / 2160 / "1080,720" / all —— 除 1080、4k 外全部回落 1080；
//     2) 换客户端：okhttp / Dart / 自造 App UA，加 &client=1 / &app=1 / &platform=android / &type=app —— 仍然 401/403；
//     3) CDN 路径推导：1080 的 m3u8 是 `https://zijieapi.douyinbyte.com/m3u8/<32位hash>.m3u8`，
//        采样 6 条，md5(dataid / dataid+清晰度 / …) 全部对不上；同 hash 加 _720/-720/_hd 等后缀一律
//        `404 token 不存在或已过期`（CDN 按路径签名）；
//     4) 接口越权：站内只有 `/api/vod/<id>/hits|play|viewer`（统计用），
//        `/api/video/play`、`/video/playv2`、`/video/playall`、`/api/app/config` 全 404；
//        wasm 里也只导出 `build_play_url(dataid, secret_key, quality, play_key)` 一个函数；
//     5) 页面层：播放页 HTML 里没有任何 720/480 地址；「影片下载」跳的是另一个 BT 站（btbtla.com），本站不给磁力。
//   → VIP 是**服务端账号门禁**（按 `k` 里的用户标识判），匿名拿不到 720/480。扫码注册要邮箱验证码，
//     属于「需要用户账号」的范畴，本源不做，也不伪造会员身份。因此：只取 1080 免费档，VIP 档给可读错误。
//
//   v2.0.2：给「有会员账号的人」留了一个口子——源设置里填 `会员 userlink`（站点登录后播放页源码里的
//   `userlink:'……'`），`content()` 就用它当 `k` 去请求，等价于用你自己的登录态取 720/480 与会员专享片。
//   留空＝游客（只有 1080）。4K 那条是「仅官方客户端」，填了也没用。
//
// 限制：栏目页 /movie /tv /anime 服务端只有一页（?page= 不换内容），真分页在 /filter；
//       综艺（classify=4）站点本身为空，如实返回空并说明，不拿别的分类顶替。

var HOST = 'https://www.bttwo.life';
var MIRRORS = [
  'https://www.bttwo.life', 'https://www.bttwo.org',
  'https://www.bttwo.top', 'https://www.bttwo.me'
];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var SALT = 'nbmovie2024secretkey';
var PAGE_SIZE = 24;

var CATS = [
  { id: 'filter', title: '全部影片', path: '/filter' },
  { id: 'movie', title: '电影', path: '/movie' },
  { id: 'tv', title: '剧集', path: '/tv' },
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
// k = base64(xor(salt, userlink))；userlink 是播放页里给的游客/用户标识
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
// 卡片形如：<a href="/play/<slug>" ...><img data-src="封面" alt="标题">
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
    if (!name || name === 'item.title' || name === '两个BT影视' || name === '4k影视') continue;
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
    title = clean(titleTag[1]).replace(/\s*-\s*第\s*\d+\s*集\s*/g, ' ')
      .replace(/\s*-\s*两个BT影视\s*$/, '').replace(/\s*-\s*4k影视\s*$/, '').trim();
  }
  var link = /userlink:'([^']+)'/.exec(source);
  return {
    title: title,
    cover: ogImage ? unescapeHtml(ogImage[1]) : '',
    description: desc ? unescapeHtml(desc[1]).trim() : '',
    keywords: keywords ? unescapeHtml(keywords[1]) : '',
    episodes: parseEpisodes(source),
    userlink: link ? link[1] : ''
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
    var number = Number(match[3]);
    if (!number || seen[number]) continue;
    seen[number] = true;
    out.push({ slug: match[1], number: number, line: Number(match[2]) || 1, dataid: match[4] });
  }
  out.sort(function (a, b) { return a.number - b.number; });
  return out;
}

// ------------------------------------------------------------------ 播放地址
// /video/play?p=<dataid>&v=<slug>&q=<清晰度>&s=<HMAC>&t=<毫秒>&k=<k令牌>
function signPlayUrl(dataid, slug, quality, userlink, stamp) {
  var t = String(stamp);
  var s = hmacSha256Hex(slug, dataid + ':' + t + ':' + slug).slice(0, 32);
  return '/video/play?p=' + enc(dataid) + '&v=' + enc(slug) + '&q=' + enc(quality) +
    '&s=' + s + '&t=' + t + '&k=' + enc(playKey(userlink));
}

// 站点会一次返回多档：1080 免费，4K 常带 isvip/locked 且 url 是占位符 "1"。
// 只取「未锁定 + 非 VIP + 真 http 地址」的那一档，绝不把锁定档当成可播地址。
// v2.0.1：不再取「第一条未锁定」，而是按清晰度从高到低挑（站点哪天放开 720 也不会退档）。
function qualityRank(row) {
  var text = String((row && (row.title || '')) || '') + ' ' + String((row && row.description) || '');
  var bitrate = Number((row && row.bitrate) || 0);
  var m = /(\d{3,4})\s*p/i.exec(text);
  var height = m ? Number(m[1]) : 0;
  if (!height) {
    if (/4k|2160/i.test(text)) height = 2160;
    else if (bitrate >= 2000000) height = 2160;
    else if (bitrate >= 1000000) height = 1080;
    else if (bitrate >= 700) height = 720;
    else if (bitrate > 0) height = 480;
  }
  return height || bitrate;
}
function unlockedList(rows) {
  var list = rows || [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row || !row.url) continue;
    var url = String(row.url);
    if (!/^https?:\/\//i.test(url)) continue;
    if (row.isvip === true || row.locked === true) continue;
    out.push({ url: url, title: String(row.title || ('清晰度 ' + (i + 1))), rank: qualityRank(row) });
  }
  out.sort(function (a, b) { return b.rank - a.rank; });
  return out;
}
function pickUrl(rows) {
  var list = unlockedList(rows);
  return list.length ? list[0].url : '';
}
// 站点是否把这一集全部标成 VIP/锁定（用于给出准确提示）
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
// 播放页 <meta id="nb-st" content="<毫秒>">：站点签发播放地址时的时间基准
async function siteStamp(slug) {
  try {
    var html = await get('/play/' + slug);
    var m = /id="nb-st" content="(\d+)"/.exec(String(html || ''));
    return m ? Number(m[1]) : 0;
  } catch (e) {
    return 0;
  }
}

// 站点按账号判 VIP：设置里填了自己的会员 userlink 就用它，否则用页面里的游客 userlink
function settingText(key, fallback) {
  var settings = (LumeSource.config && LumeSource.config.settings) || {};
  var value = settings[key];
  return value == null || String(value).trim() === '' ? fallback : String(value).trim();
}

// 拿一集的可播地址：1080 免费；720/480 需 VIP；4k 仅官方客户端
// v2.0.1：返回 {url, qualities}，并把「整片会员专享」与「只是高清档要会员」分开报。
async function resolveEpisode(episode, userlink) {
  var quality = '1080';
  var settings = LumeSource.config && LumeSource.config.commonSettings;
  if (settings && settings.quality === '1080') quality = '1080';
  var now = Date.now ? Date.now() : new Date().getTime();
  var attempt = await requestPlay(signPlayUrl(episode.dataid, episode.slug, quality, userlink, now));
  var build = function (rows) {
    var list = unlockedList(rows);
    return list.length ? { url: list[0].url, qualities: list } : null;
  };
  if (usable(attempt)) {
    var hit = build(attempt.data.data.quality_urls);
    if (hit) return hit;
    if (lockedOnly(attempt.data.data.quality_urls)) {
      throw new Error('这一集在站点上只有 VIP/4K 档（返回的地址是锁定的占位值），1080p 未开放，本源不绕过。');
    }
  }

  // 时间戳偏差过大时站点会拒签：用页面 nb-st 再试一次
  var stamp = await siteStamp(episode.slug);
  if (stamp && String(stamp) !== String(now)) {
    attempt = await requestPlay(signPlayUrl(episode.dataid, episode.slug, quality, userlink, stamp));
    if (usable(attempt)) {
      var retryHit = build(attempt.data.data.quality_urls);
      if (retryHit) return retryHit;
    }
  }

  var data = attempt.data || {};
  var message = String(data.message || attempt.body || '').trim();
  if (data.code === 401) {
    // 连 1080 都回 401 = 整片是会员专享；否则只是这个清晰度要会员
    throw new Error('这一集是站点会员专享（' + (message || '需要VIP会员') + '）。' +
      '实测匿名只有 1080p 免费档，720/480 要会员登录，4K 仅官方客户端；本源不伪造会员身份，也不绕过付费墙。');
  }
  if (data.code === 403) {
    throw new Error('站点拒绝了这个清晰度' + (message ? '（' + message + '）' : '') +
      '：4K 仅官方客户端可播。');
  }
  throw new Error('拿不到播放地址：' + (message.slice(0, 80) || ('HTTP ' + attempt.status)));
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'bttwo_video',
  name: '两个BT影视',
  version: '2.0.2',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/ico.png',
  commonSettings: [
    {
      key: 'pageSize', title: '每页条数', type: 'select',
      options: [{ value: '24', title: '24 条（站点默认）' }, { value: '48', title: '48 条' }],
      default: '24'
    },
    {
      key: 'quality', title: '清晰度', type: 'select',
      options: [{ value: '1080', title: '1080p（站点免费档）' }],
      default: '1080'
    }
  ],
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://bttwo.vip/',
      description: '站点换域名时先看这里（发布页列出全部可用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '两个BT影视（bttwo.life，另有 .org / .top / .me 三个同内容域名）。本源直接解析出 m3u8：1080p 免费直连；720/480 需站点 VIP，4K 仅官方客户端，都不绕过。栏目页（电影/剧集/动漫）站点本身只有一页，全量翻页请用「全部影片」。'
    },
    {
      key: 'vipUserlink',
      type: 'text',
      title: '会员 userlink（可选）',
      description: '站点按账号判 VIP：整片会员专享的条目（连 1080p 都回 401）、以及 720/480 清晰度，只对「已登录且是会员」的会话下发。' +
        '本源默认是游客身份，所以只能播免费条目。想用你自己的会员账号：在站点登录后打开任意一集的播放页，查看网页源码，找 `userlink:\'……\'`，把引号里那串粘到这里（留空＝游客）。' +
        '注意：4K 是「仅官方客户端」，填了也没用；本源不伪造会员身份，只复用你自己的登录态。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点的筛选参数（classify/types/areas/years/tags/sort_by）实测全部生效，且可组合。
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
            { id: '25', title: '情色' }
          ]
        },
        {
          key: 'areas', title: '地区', multiple: true, options: [
            { id: '7', title: '中国' }, { id: '52', title: '中国大陆' }, { id: '14', title: '中国香港' },
            { id: '21', title: '中国台湾' }, { id: '5', title: '美国' }, { id: '11', title: '日本' },
            { id: '12', title: '韩国' }, { id: '30', title: '英国' }, { id: '6', title: '法国' },
            { id: '18', title: '德国' }, { id: '24', title: '西班牙' }, { id: '33', title: '泰国' },
            { id: '34', title: '印度' }
          ]
        },
        {
          key: 'years', title: '年份', multiple: false, options: [
            { id: '1', title: '2026' }, { id: '3', title: '2025' }, { id: '4', title: '2024' },
            { id: '56', title: '2023' }, { id: '13', title: '2022' }, { id: '2', title: '2021' },
            { id: '6', title: '2020' }, { id: '8', title: '2019' }, { id: '9', title: '2018' },
            { id: '12', title: '2017' }, { id: '11', title: '2016' }
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
    if (info.episodes.length > 1) bits.push('共 ' + info.episodes.length + ' 集');
    else if (info.episodes.length === 1) bits.push('正片');
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
        '播放说明：本源直接解析站点签名，取 1080p 的 m3u8 直链，可在 App 里直接播放和选集；' +
        '720p/480p 属站点 VIP 清晰度，4K 仅官方客户端，本源不绕过。',
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
      // 没有分集按钮的条目（单片）：当前页就是唯一一集
      if (/dataid="\d+"/.test(html)) return [{ id: slug, title: '正片' }];
      throw new Error('这一条在站点上没有可播放的分集');
    }
    return episodes.map(function (ep) {
      return {
        id: ep.slug,
        title: episodes.length > 1 ? ('第 ' + ep.number + ' 集') : '正片'
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
      // 该 slug 不在分集列表里（单片），用页面里第一个 dataid
      var only = /dataid="(\d+)"/.exec(html);
      if (!only) throw new Error('这一条在站点上没有可播放的地址');
      episode = { slug: slug, dataid: only[1], number: 1, line: 1 };
    }
    var userlink = settingText('vipUserlink', info.userlink);
    var resolved = await resolveEpisode(episode, userlink);
    if (!resolved || !resolved.url) throw new Error('站点没有返回可播放地址');
    var out = {
      kind: 'video',
      url: resolved.url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
    if (resolved.qualities && resolved.qualities.length > 1) out.qualities = resolved.qualities;
    return out;
  }
};
