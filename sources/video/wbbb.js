// LumeSource: {"id":"wbbb_video","name":"歪比巴卜","version":"3.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.wbbb1.com","https://wbbb1.com","https://v.wbbb1.com"],"network":"direct","icon":"https://www.wbbb1.com/mxtheme/images/favicon.png"}
// LumeRuntime: javascript
//
// 站点：歪比巴卜（wbbb1.com；地址发布页 xn--clr79vmzkema.com = 歪比巴卜.com）
// 形态：苹果CMS v10 + 自定义主题（服务端渲染 HTML）。列表 /show/{类型}--------{页}---.html，
//       详情 /detail/{id}.html，播放页 /vplay/{id}-{线路}-{集}.html。
//
// ── 门槛 1：首访 403 ──
//   任何页面第一次请求都返回 403 + Set-Cookie，页内 JS 再跳回同一地址才 200。
//   本源遇到 403 会重发一次（宿主会把 Cookie 带上），与浏览器行为一致。
//
// ── v3.0.0：解出原生直链（不再走网页播放器）──
//   播放地址是**两层**加密的，两层都已在源里用纯 JS 复现：
//   第一层（拿载荷）见下面「签名」；第二层（解媒体地址）：
//     K  = rc4(key22, base64decode(resp.aes_key))   → 16 字节（实测是 "OddfJktEbGu7gCv9" 这种 ASCII）
//     IV = rc4(key22, base64decode(resp.aes_iv))    → 16 字节
//     媒体地址 = AES-128-CBC(PKCS#7 解密)(base64decode(resp.url), K, IV)
//   坑：key/iv 不是「响应里的 aes_key 直接当 AES key」，也不是「整条 query 做 RC4」——
//       必须先按 key22 做一遍 RC4，再用结果当 AES-128 的 key/iv；少这一步解出来全是乱码。
//   实测：电影解出 `https://wxsnsdysvp.wxs.qq.com/…/stodownload?...&filename=BBA.mp4`（206 + video/mp4），
//         剧集解出 `https://1853039965.cdn.123clouddisk.com/…/醉梦EP01.m3u8`（206 + #EXTM3U 40,452 B）。
//   → 现在 `content()` 直接返回 `kind:'video'`；万一站点改算法，会自动退回网页播放器（并打日志）。
//
// ── v2.0.0 改了什么 ──
//   v1.0.0 的 `content()` 把 **详情页** `/detail/{id}.html` 交给网页播放器，那是片库页而不是播放器，
//   所以看着“不像在播放”。v2 做了三件事：
//     1. 详情页解析出「播放源」列表（`#y-playList` 里的 tab：推荐/蓝光A/蓝光B/高清C/BF有广/LZ有广…）
//        与每个 tab 对应的分集面板，**线路 × 分集** 全部列进章节（章节 id = `<sid>-<nid>`）；
//     2. `content()` 先取出这一集的 `/vplay/{id}-{sid}-{nid}.html`，读出 `player_aaaa` 里的密文 `url`
//        和 `link_next`，再据此拼出站点自己用的播放器地址
//        `https://xn--qvr2v.850088.xyz/player/?url=<密文>&next=<下一集>&title=<页标题>`，
//        交给 App 的网页播放器 —— 打开就是这一线路这一集的播放器，不再是详情页；
//     3. 解析接口的签名已经逆出来了（下面「签名」一节），实测能拿到 `{"code":200,...}` 的播放载荷。
//
// ── 签名（已逆出，实测被服务端接受）──
//   播放器把整条 query 当 `url` 传：`Q = <密文> + '&next=' + <'//'+域名+link_next 或 '//'>`
//   key22  = md5(Q) 的后 20 位 hex + ' P'          （calculate）
//   key    = base64( rc4(key22, md5(Q + 'stray')) )  （enplay）
//   vkey   = base64( rc4(key22, 秒级时间戳 + md5(key22 + 'stray')) )
//   ckey   = base64( rc4(key22, md5(播放器域名 + 'stray')) )
//   POST https://xn--qvr2v.850088.xyz/player/api.php  {url:Q, key, vkey, ckey} → 200 + 载荷
//   （其中 aesplay = 标准 RC4；enplay/deplay 都是它。）
//   实测：key/ckey 错一个就是 nginx 404；vkey 传错仍 200 —— 服务端只校验 key/ckey。
//
// 门槛 3：站内搜索 /search/<词>-------------.html 被 WAF 拦（返回「系统安全验证」页），
//   本源改用本地索引：浏览过的条目会被记住，搜索时在索引里过滤；索引为空时先抓一页。
//   不伪造搜索结果。

var HOST = 'https://www.wbbb1.com';
var MIRRORS = ['https://www.wbbb1.com', 'https://wbbb1.com', 'https://v.wbbb1.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
// 站点 parse.js 里写死的解析播放器
var PLAYER_HOST = 'https://xn--qvr2v.850088.xyz';
var PAGE_SIZE = 20;
var INDEX_FILE = 'index.json';
var INDEX_CAP = 4000;

var CATS = [
  { id: 'movie', type: 1, title: '电影' },
  { id: 'tv', type: 2, title: '剧集' },
  { id: 'anime', type: 3, title: '动漫' },
  { id: 'variety', type: 4, title: '综艺' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }
function readJson(file) {
  return LumeSource.fs.readText(file).then(function (text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}
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

// 403 = 首访门（站点先塞 Cookie 再让刷新），重发一次即可；「系统安全验证」= WAF 页，如实报错
async function fetchHtml(path, retried) {
  var reply = await LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + '/'
    }
  });
  var status = (reply && reply.status) || 0;
  var body = reply && reply.body != null ? String(reply.body) : '';
  if (!status) throw new Error('连不上站点：' + base() + path);
  if (status === 403 && !retried) return await fetchHtml(path, true);
  if (status === 429) throw new Error('站点限流（HTTP 429），稍后再试');
  if (status === 404) return '';
  if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + path);
  if (body.indexOf('系统安全验证') >= 0) throw new Error('这一页触发了站点的安全验证（WAF），请稍后再试');
  return body;
}

// ------------------------------------------------------------------ HTML 解析
function parseCards(html) {
  var source = String(html || '');
  var chunks = source.split(/<a\s[^>]*href="\/detail\/(\d+)\.html"/);
  var items = [];
  var seen = {};
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 1500);
    var img = /<img\s[^>]*>/i.exec(block);
    var name = '';
    var cover = '';
    if (img) {
      var alt = /alt="([^"]*)"/i.exec(img[0]);
      var pic = /data-original="([^"]+)"/i.exec(img[0]) || /data-src="([^"]+)"/i.exec(img[0]) || /src="([^"]+)"/i.exec(img[0]);
      name = alt ? unescapeHtml(alt[1]).trim() : '';
      cover = pic ? unescapeHtml(pic[1]) : '';
    }
    if (/load\.gif|errorpic/.test(cover)) cover = '';
    if (!name) continue;
    var note = /module-item-note">([^<]{1,30})</.exec(block);
    seen[id] = true;
    items.push({ id: id, title: name, cover: cover, subtitle: note ? clean(note[1]) : '' });
  }
  return items;
}

function parseDetail(html) {
  var source = String(html || '');
  var h1 = /<h1[^>]*>([\s\S]{0,160}?)<\/h1>/i.exec(source);
  var pic = /class="mac_history_set"[^>]*data-pic="([^"]*)"/i.exec(source)
    || /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
  var intro = /module-info-introduction-content[^>]*>([\s\S]{0,1500}?)<\/div>/i.exec(source);
  return {
    title: h1 ? clean(h1[1]) : clean((/<title>([^<]*)<\/title>/i.exec(source) || [])[1] || ''),
    cover: pic ? unescapeHtml(pic[1]) : '',
    description: intro ? clean(intro[1]) : ''
  };
}

// 播放源（线路）+ 每个线路的分集：tab 名称与分集面板按出现顺序一一对应
function parseSources(html, id) {
  var source = String(html || '');
  var names = [];
  var tabRe = /data-dropdown-value="([^"]+)"[^>]*>\s*<span>[^<]*<\/span>\s*<small>(\d+)<\/small>/g;
  var m;
  while ((m = tabRe.exec(source)) !== null) names.push({ name: unescapeHtml(m[1]).trim(), count: Number(m[2]) });

  // 分集面板：每个 module-play-list 块里是同一线路的分集链接
  var panels = [];
  var parts = source.split(/class="module-play-list-content([^"]*)"/);
  for (var i = 1; i < parts.length; i += 2) {
    var block = String(parts[i + 1] || '');
    var eps = [];
    var re = new RegExp('/vplay/' + id + '-(\\d+)-(\\d+)\\.html"[^>]*>\\s*<span>([^<]*)</', 'g');
    var hit;
    while ((hit = re.exec(block)) !== null) {
      eps.push({ sid: Number(hit[1]), nid: Number(hit[2]), label: clean(hit[3]) });
    }
    if (eps.length) panels.push(eps);
  }

  var out = [];
  for (var p = 0; p < panels.length; p++) {
    var eps = panels[p];
    var name = names[p] ? names[p].name : ('线路 ' + (p + 1));
    for (var k = 0; k < eps.length; k++) {
      out.push({ sid: eps[k].sid, nid: eps[k].nid, label: eps[k].label, line: name });
    }
  }
  return out;
}

function indexOf(items) {
  if (!items || !items.length) return Promise.resolve(null);
  return readJson(INDEX_FILE).then(function (current) {
    var map = (current && current.map) || {};
    for (var i = 0; i < items.length; i++) {
      map[items[i].id] = { title: items[i].title, cover: items[i].cover };
    }
    var keys = Object.keys(map);
    if (keys.length > INDEX_CAP) {
      for (var k = 0; k < keys.length - INDEX_CAP; k++) delete map[keys[k]];
    }
    return writeJson(INDEX_FILE, { at: Date.now(), map: map });
  });
}

async function loadListPage(category, page) {
  var type = 1;
  for (var i = 0; i < CATS.length; i++) {
    if (CATS[i].id === category) { type = CATS[i].type; break; }
  }
  var path = page <= 1
    ? '/show/' + type + '-----------.html'
    : '/show/' + type + '--------' + page + '---.html';
  var html = await fetchHtml(path);
  var items = parseCards(html);
  await indexOf(items);
  return { items: items, hasMore: items.length >= PAGE_SIZE - 5 };
}

function searchIndex(keyword, page) {
  return readJson(INDEX_FILE).then(function (data) {
    var map = (data && data.map) || {};
    var only = keyword.toLowerCase();
    var hits = [];
    for (var id in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id)) continue;
      if (String(map[id].title || '').toLowerCase().indexOf(only) < 0) continue;
      hits.push({ id: id, title: map[id].title, cover: map[id].cover || '', subtitle: '' });
    }
    var start = (page - 1) * PAGE_SIZE;
    return { items: hits.slice(start, start + PAGE_SIZE), hasMore: hits.length > start + PAGE_SIZE };
  });
}

// 播放页 → player_aaaa（密文 url / link_next / 页标题）
// 注意：电影页是原样 JSON，剧集页是「转义过的 JSON 字符串」（\"flag\":…），两种都要认。
function parsePlayer(html) {
  var source = String(html || '');
  var m = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*(?:;|<\/script>)/.exec(source);
  if (!m) return null;
  var raw = String(m[1]).replace(/\\"/g, '"').replace(/\\\//g, '/');
  var data = null;
  try { data = JSON.parse(raw); } catch (e) { return null; }
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  return {
    url: String(data.url || ''),
    from: String(data.from || ''),
    next: String(data.link_next || ''),
    title: titleTag ? clean(titleTag[1]) : ''
  };
}

// 站点 parse.js 拼的播放器地址：?url=<密文>&next=//<域名><下一集>&title=<标题前半段>
function playerUrl(info) {
  var domain = base().replace(/^https?:\/\//, '');
  var nextPart = info.next ? '//' + domain + info.next : '//';
  var title = String(info.title || '').split('-')[0].trim();
  return PLAYER_HOST + '/player/?url=' + encodeURIComponent(info.url) +
    '&next=' + nextPart + '&title=' + enc(title);
}

// ------------------------------------------------------------------ 纯 JS 加密（沙箱没有 crypto/Buffer/atob）
function utf8Bytes(str) {
  var out = [];
  var text = String(str == null ? '' : str);
  for (var i = 0; i < text.length; i++) {
    var c = text.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
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
function utf8FromBytes(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
  try { return decodeURIComponent(escape(out)); } catch (e) { return out; }
}
function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function cmn(q, a, b, x, s, t) { a = add32(add32(a, q), add32(x, t)); return add32((a << s) | (a >>> (32 - s)), b); }
  function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
  function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
  function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
  function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
  function cycle(x, k) {
    var a = x[0], b = x[1], c = x[2], d = x[3];
    a = ff(a, b, c, d, k[0], 7, -680876936); d = ff(d, a, b, c, k[1], 12, -389564586);
    c = ff(c, d, a, b, k[2], 17, 606105819); b = ff(b, c, d, a, k[3], 22, -1044525330);
    a = ff(a, b, c, d, k[4], 7, -176418897); d = ff(d, a, b, c, k[5], 12, 1200080426);
    c = ff(c, d, a, b, k[6], 17, -1473231341); b = ff(b, c, d, a, k[7], 22, -45705983);
    a = ff(a, b, c, d, k[8], 7, 1770035416); d = ff(d, a, b, c, k[9], 12, -1958414417);
    c = ff(c, d, a, b, k[10], 17, -42063); b = ff(b, c, d, a, k[11], 22, -1990404162);
    a = ff(a, b, c, d, k[12], 7, 1804603682); d = ff(d, a, b, c, k[13], 12, -40341101);
    c = ff(c, d, a, b, k[14], 17, -1502002290); b = ff(b, c, d, a, k[15], 22, 1236535329);
    a = gg(a, b, c, d, k[1], 5, -165796510); d = gg(d, a, b, c, k[6], 9, -1069501632);
    c = gg(c, d, a, b, k[11], 14, 643717713); b = gg(b, c, d, a, k[0], 20, -373897302);
    a = gg(a, b, c, d, k[5], 5, -701558691); d = gg(d, a, b, c, k[10], 9, 38016083);
    c = gg(c, d, a, b, k[15], 14, -660478335); b = gg(b, c, d, a, k[4], 20, -405537848);
    a = gg(a, b, c, d, k[9], 5, 568446438); d = gg(d, a, b, c, k[14], 9, -1019803690);
    c = gg(c, d, a, b, k[3], 14, -187363961); b = gg(b, c, d, a, k[8], 20, 1163531501);
    a = gg(a, b, c, d, k[13], 5, -1444681467); d = gg(d, a, b, c, k[2], 9, -51403784);
    c = gg(c, d, a, b, k[7], 14, 1735328473); b = gg(b, c, d, a, k[12], 20, -1926607734);
    a = hh(a, b, c, d, k[5], 4, -378558); d = hh(d, a, b, c, k[8], 11, -2022574463);
    c = hh(c, d, a, b, k[11], 16, 1839030562); b = hh(b, c, d, a, k[14], 23, -35309556);
    a = hh(a, b, c, d, k[1], 4, -1530992060); d = hh(d, a, b, c, k[4], 11, 1272893353);
    c = hh(c, d, a, b, k[7], 16, -155497632); b = hh(b, c, d, a, k[10], 23, -1094730640);
    a = hh(a, b, c, d, k[13], 4, 681279174); d = hh(d, a, b, c, k[0], 11, -358537222);
    c = hh(c, d, a, b, k[3], 16, -722521979); b = hh(b, c, d, a, k[6], 23, 76029189);
    a = hh(a, b, c, d, k[9], 4, -640364487); d = hh(d, a, b, c, k[12], 11, -421815835);
    c = hh(c, d, a, b, k[15], 16, 530742520); b = hh(b, c, d, a, k[2], 23, -995338651);
    a = ii(a, b, c, d, k[0], 6, -198630844); d = ii(d, a, b, c, k[7], 10, 1126891415);
    c = ii(c, d, a, b, k[14], 15, -1416354905); b = ii(b, c, d, a, k[5], 21, -57434055);
    a = ii(a, b, c, d, k[12], 6, 1700485571); d = ii(d, a, b, c, k[3], 10, -1894986606);
    c = ii(c, d, a, b, k[10], 15, -1051523); b = ii(b, c, d, a, k[1], 21, -2054922799);
    a = ii(a, b, c, d, k[8], 6, 1873313359); d = ii(d, a, b, c, k[15], 10, -30611744);
    c = ii(c, d, a, b, k[6], 15, -1560198380); b = ii(b, c, d, a, k[13], 21, 1309151649);
    a = ii(a, b, c, d, k[4], 6, -145523070); d = ii(d, a, b, c, k[11], 10, -1120210379);
    c = ii(c, d, a, b, k[2], 15, 718787259); b = ii(b, c, d, a, k[9], 21, -343485551);
    x[0] = add32(a, x[0]); x[1] = add32(b, x[1]); x[2] = add32(c, x[2]); x[3] = add32(d, x[3]);
  }
  function blk(s) {
    var out = [];
    for (var i = 0; i < 64; i += 4) out[i >> 2] = s.charCodeAt(i) + (s.charCodeAt(i + 1) << 8) + (s.charCodeAt(i + 2) << 16) + (s.charCodeAt(i + 3) << 24);
    return out;
  }
  var bytes = utf8Bytes(input);
  var s = '';
  for (var bi = 0; bi < bytes.length; bi++) s += String.fromCharCode(bytes[bi]);
  var n = s.length;
  var state = [1732584193, -271733879, -1732584194, 271733878];
  var i;
  for (i = 64; i <= n; i += 64) cycle(state, blk(s.substring(i - 64, i)));
  s = s.substring(i - 64);
  var tail = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  for (i = 0; i < s.length; i++) tail[i >> 2] |= s.charCodeAt(i) << ((i % 4) << 3);
  tail[i >> 2] |= 0x80 << ((i % 4) << 3);
  if (i > 55) { cycle(state, tail); for (i = 0; i < 16; i++) tail[i] = 0; }
  tail[14] = n * 8;
  cycle(state, tail);
  var hex = '0123456789abcdef', out = '';
  for (i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      var byte = (state[i] >> (j * 8)) & 0xff;
      out += hex.charAt((byte >> 4) & 0xf) + hex.charAt(byte & 0xf);
    }
  }
  return out;
}
function rc4Bytes(keyStr, bytes) {
  var S = [];
  var i;
  for (i = 0; i < 256; i++) S[i] = i;
  var j = 0;
  for (i = 0; i < 256; i++) {
    j = (j + S[i] + keyStr.charCodeAt(i % keyStr.length)) % 256;
    var t = S[i]; S[i] = S[j]; S[j] = t;
  }
  var out = [];
  var x = 0;
  j = 0;
  for (var n = 0; n < bytes.length; n++) {
    x = (x + 1) % 256;
    j = (j + S[x]) % 256;
    var tt = S[x]; S[x] = S[j]; S[j] = tt;
    out.push(bytes[n] ^ S[(S[x] + S[j]) % 256]);
  }
  return out;
}
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
function base64Decode(text) {
  var s = String(text == null ? '' : text).replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < s.length; i += 4) {
    var c0 = B64_ALPHABET.indexOf(s.charAt(i));
    var c1 = B64_ALPHABET.indexOf(s.charAt(i + 1));
    var c2 = s.charAt(i + 2) === '=' ? -1 : B64_ALPHABET.indexOf(s.charAt(i + 2));
    var c3 = s.charAt(i + 3) === '=' ? -1 : B64_ALPHABET.indexOf(s.charAt(i + 3));
    if (c0 < 0 || c1 < 0) break;
    out.push(((c0 << 2) | (c1 >> 4)) & 0xff);
    if (c2 >= 0) out.push(((c1 & 15) << 4 | (c2 >> 2)) & 0xff);
    if (c3 >= 0) out.push(((c2 & 3) << 6 | c3) & 0xff);
  }
  return out;
}
var AES_SBOX = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
];
var AES_INV_SBOX = new Array(256);
for (var _si = 0; _si < 256; _si++) AES_INV_SBOX[AES_SBOX[_si]] = _si;
var AES_RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
function aesMul(a, b) {
  var p = 0;
  for (var i = 0; i < 8; i++) {
    if (b & 1) p ^= a;
    var hi = a & 0x80;
    a = (a << 1) & 0xff;
    if (hi) a ^= 0x1b;
    b >>= 1;
  }
  return p & 0xff;
}
function aesExpandKey(key) {
  var w = [];
  var i;
  for (i = 0; i < 4; i++) w[i] = ((key[i * 4] << 24) | (key[i * 4 + 1] << 16) | (key[i * 4 + 2] << 8) | key[i * 4 + 3]) >>> 0;
  for (i = 4; i < 44; i++) {
    var temp = w[i - 1];
    if (i % 4 === 0) {
      temp = ((temp << 8) | (temp >>> 24)) >>> 0;
      var b0 = (temp >>> 24) & 0xff, b1 = (temp >>> 16) & 0xff, b2 = (temp >>> 8) & 0xff, b3 = temp & 0xff;
      temp = (((AES_SBOX[b0] << 24) | (AES_SBOX[b1] << 16) | (AES_SBOX[b2] << 8) | AES_SBOX[b3]) ^ (AES_RCON[i / 4] << 24)) >>> 0;
    }
    w[i] = (w[i - 4] ^ temp) >>> 0;
  }
  return w;
}
function aesDecryptBlock(block, w) {
  var s = block.slice();
  var i, r;
  for (i = 0; i < 4; i++) {
    var word = w[40 + i];
    s[i * 4] ^= (word >>> 24) & 0xff;
    s[i * 4 + 1] ^= (word >>> 16) & 0xff;
    s[i * 4 + 2] ^= (word >>> 8) & 0xff;
    s[i * 4 + 3] ^= word & 0xff;
  }
  for (r = 9; r >= 0; r--) {
    // InvShiftRows
    var t;
    t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
    // InvSubBytes
    for (i = 0; i < 16; i++) s[i] = AES_INV_SBOX[s[i]];
    // AddRoundKey
    for (i = 0; i < 4; i++) {
      var wd = w[r * 4 + i];
      s[i * 4] ^= (wd >>> 24) & 0xff;
      s[i * 4 + 1] ^= (wd >>> 16) & 0xff;
      s[i * 4 + 2] ^= (wd >>> 8) & 0xff;
      s[i * 4 + 3] ^= wd & 0xff;
    }
    if (r > 0) {
      for (i = 0; i < 4; i++) {
        var a0 = s[i * 4], a1 = s[i * 4 + 1], a2 = s[i * 4 + 2], a3 = s[i * 4 + 3];
        s[i * 4] = aesMul(a0, 14) ^ aesMul(a1, 11) ^ aesMul(a2, 13) ^ aesMul(a3, 9);
        s[i * 4 + 1] = aesMul(a0, 9) ^ aesMul(a1, 14) ^ aesMul(a2, 11) ^ aesMul(a3, 13);
        s[i * 4 + 2] = aesMul(a0, 13) ^ aesMul(a1, 9) ^ aesMul(a2, 14) ^ aesMul(a3, 11);
        s[i * 4 + 3] = aesMul(a0, 11) ^ aesMul(a1, 13) ^ aesMul(a2, 9) ^ aesMul(a3, 14);
      }
    }
  }
  return s;
}
function aesCbcDecrypt(bytes, key, iv) {
  var w = aesExpandKey(key);
  var out = [];
  var prev = iv.slice();
  for (var off = 0; off + 16 <= bytes.length; off += 16) {
    var block = bytes.slice(off, off + 16);
    var dec = aesDecryptBlock(block, w);
    for (var i = 0; i < 16; i++) out.push(dec[i] ^ prev[i]);
    prev = block;
  }
  if (out.length) {
    var pad = out[out.length - 1];
    if (pad > 0 && pad <= 16 && pad <= out.length) {
      var ok = true;
      for (var k = out.length - pad; k < out.length; k++) if (out[k] !== pad) { ok = false; break; }
      if (ok) out = out.slice(0, out.length - pad);
    }
  }
  return out;
}

// 解析接口：签名（md5 + RC4）+ 响应二次加密（AES-128-CBC，key/iv 也要先 RC4 解一层）
function playerQ(info) {
  var domain = base().replace(/^https?:\/\//, '');
  var nextPart = info.next ? '//' + domain + info.next : '//';
  return info.url + '&next=' + nextPart;
}
async function resolveMedia(info) {
  var Q = playerQ(info);
  var key22 = (md5Hex(Q) + ' P').slice(-22);
  var key = base64Encode(rc4Bytes(key22, utf8Bytes(md5Hex(Q + 'stray'))));
  var now = Date.now ? Date.now() : new Date().getTime();
  var stamp = String(Math.floor(now / 1000));
  var vkey = base64Encode(rc4Bytes(key22, utf8Bytes(stamp + md5Hex(key22 + 'stray'))));
  var playerHost = PLAYER_HOST.replace(/^https?:\/\//, '');
  var ckey = base64Encode(rc4Bytes(key22, utf8Bytes(md5Hex(playerHost + 'stray'))));
  var body = 'url=' + encodeURIComponent(Q) + '&key=' + encodeURIComponent(key) +
    '&vkey=' + encodeURIComponent(vkey) + '&ckey=' + encodeURIComponent(ckey);
  var reply = await LumeSource.http.request({
    url: PLAYER_HOST + '/player/api.php',
    method: 'POST',
    headers: {
      'User-Agent': UA,
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Origin': PLAYER_HOST,
      'Referer': PLAYER_HOST + '/player/',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: body
  });
  var status = (reply && reply.status) || 0;
  var text = reply && reply.body != null ? String(reply.body) : '';
  if (!status) throw new Error('连不上站点解析服务');
  if (status !== 200) throw new Error('解析接口 HTTP ' + status);
  var data = null;
  try { data = JSON.parse(text); } catch (e) { data = null; }
  if (!data) throw new Error('解析接口返回的不是 JSON');
  if (data.code !== 200 || !data.url) throw new Error('解析接口报错：' + (data.msg || data.message || data.code));
  var k = rc4Bytes(key22, base64Decode(data.aes_key || ''));
  var iv = rc4Bytes(key22, base64Decode(data.aes_iv || ''));
  if (k.length < 16 || iv.length < 16) throw new Error('解析接口没有下发 key/iv');
  var plain = aesCbcDecrypt(base64Decode(data.url), k.slice(0, 16), iv.slice(0, 16));
  var media = utf8FromBytes(plain).trim();
  if (!/^https?:\/\//i.test(media)) throw new Error('解出来的不是播放地址（站点可能改版）');
  return { url: media, type: String(data.type || '') };
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'wbbb_video',
  name: '歪比巴卜',
  version: '3.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/mxtheme/images/favicon.png',
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://www.xn--clr79vmzkema.com/',
      description: '站点换域名时先看这里（发布页给出当前可用域名）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '歪比巴卜（wbbb1.com）。v2 起选集按「线路 × 分集」全部展开，点哪一集就用网页播放器直接打开那一集（不再是详情页）。站点把媒体地址做了二次加密，原生播放要再破一层，目前仍走网页播放器。站内搜索被 WAF 拦，本源用本地索引。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点分类页没有可用 URL 传参的筛选（地区/年份都在导航里，且翻页只吃 show 路径），如实返回空组。
    return { groups: [] };
  },

  async home() {
    var html = await fetchHtml('/');
    var items = parseCards(html);
    if (!items.length) return [];
    await indexOf(items);
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var cached = await searchIndex(keyword, page);
      if (cached.items.length || page > 1) return cached;
      try {
        await loadListPage(category || 'movie', 1);
      } catch (e) { /* 抓不到就算了，照样返回空 */ }
      return await searchIndex(keyword, page);
    }
    return await loadListPage(category || 'movie', page);
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = await fetchHtml('/detail/' + id + '.html');
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var eps = parseSources(html, id);
    var lines = {};
    for (var i = 0; i < eps.length; i++) lines[eps[i].line] = (lines[eps[i].line] || 0) + 1;
    var names = Object.keys(lines);
    var bits = [];
    if (names.length) {
      bits.push(names.length + ' 条线路');
      var maxEp = 0;
      for (var k = 0; k < names.length; k++) if (lines[names[k]] > maxEp) maxEp = lines[names[k]];
      bits.push(maxEp > 1 ? '共 ' + maxEp + ' 集' : '正片');
    }
    var desc = info.description ? info.description + '\n\n' : '';
    desc += '播放说明：选集里按「线路 · 分集」列出站点全部线路，点哪一集就用 App 的网页播放器打开站点对应那一集的播放器；' +
      '某条线路提示「解析失败」时换一条线路即可。';
    return {
      id: id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: desc
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var html = await fetchHtml('/detail/' + id + '.html');
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var eps = parseSources(html, id);
    if (!eps.length) throw new Error('这一条在站点上还没有播放源');
    return eps.map(function (ep) {
      var label = String(ep.label || '').trim();
      // 站点分集名本来就是「第01集 / 1080P / HD」这种，直接用；实在没有才补「第 N 集」
      var tail = label && label !== String(ep.nid) ? label : ('第 ' + ep.nid + ' 集');
      return { id: ep.sid + '-' + ep.nid, title: ep.line + ' · ' + tail };
    });
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.itemId || '').trim();
    var chapter = String(args.chapterId || '').trim();
    var hit = /^(\d+)-(\d+)$/.exec(chapter);
    var sid = hit ? hit[1] : '';
    var nid = hit ? hit[2] : '';
    if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
    if (!sid || !nid) {
      // 没带章节：退回详情页里第一条线路的第一集
      var page = await fetchHtml('/detail/' + id + '.html');
      var eps = parseSources(page, id);
      if (!eps.length) throw new Error('这一条在站点上没有播放源');
      sid = String(eps[0].sid);
      nid = String(eps[0].nid);
    }
    var vplay = await fetchHtml('/vplay/' + id + '-' + sid + '-' + nid + '.html');
    if (!vplay) throw new Error('播放页打不开（可能已下架）');
    var info = parsePlayer(vplay);
    if (!info || !info.url) throw new Error('播放页里没有取到播放参数（站点可能改版）');
    // 先试原生直链：解出 mp4/m3u8 就交给 App 播放器；解不出来才退回网页播放器
    try {
      var media = await resolveMedia(info);
      return {
        kind: 'video',
        url: media.url,
        headers: { 'User-Agent': UA, 'Referer': PLAYER_HOST + '/player/' }
      };
    } catch (e) {
      console.warn('[wbbb] 直链解析失败，回退网页播放器：' + (e && e.message));
    }
    return {
      kind: 'webplayer',
      pageUrl: playerUrl(info),
      headers: { 'User-Agent': UA, 'Referer': base() + '/' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
