// LumeSource: {"id":"d9y1w_video","name":"四色视频 18+","version":"1.0.3","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.z2g9w.top","https://www.x5p2n.top","https://www.zie2.com"],"network":"direct","icon":"https://www.z2g9w.top/favicon.ico","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（站点自救页）","url":"https://www.z2g9w.top/help/help.html","description":"站点换域名时先看这里：官方页写明本站 3 天换一次域名，页内有正确访问方式与找回邮箱"},{"key":"note","type":"info","title":"站点说明","description":"四色视频（maomi 模板，全站 18+）。域名 3 天轮换一次：当前实测可用 www.z2g9w.top、www.x5p2n.top；官方长期地址 www.zie2.com（本机 TLS 被劫持，打不开就在镜像里换一台）。找回最新域名：邮件 liumangtu@mail.com，或看站点 /help/help.html。脚本已内置换域名自愈：域名只剩 302 到「进入页」时会自动换到能用的镜像。"}]}
//
// 站点：https://www.z2g9w.top/index/home.html（「maomi」模板成人站，2026-11-01 逐页实测）
//
// ── 〇、域名与镜像（2026-11-01 重测：整站换域名了）
//    官方在 /help/help.html 里写明「本站 3 天换一次域名」，并给出长期地址 https://www.zie2.com
//    与找回邮箱 liumangtu@mail.com。
//    · 当前可用：www.z2g9w.top（主站）、www.x5p2n.top（镜像，两站同内容、同 favicon）
//    · 旧域 www.z8f0q.top / www.d9y1w.top 还在响应，但**整站 302 到新域名的 /enter/index.html**
//      （那天看到「首页没有解析到板块」就是它：桥接层跟完 302 只拿到「进入页」的 HTML，
//      里面既没有 home-list-item 也没有 video-item，而且 App 的 http 不回报 reply.url，
//      读不到 302 的 Location）。所以这两个域既不当主站也不当镜像，只在脚本里做跳转样识别。
//    · 官方长期地址 www.zie2.com 在本机 TLS 仍被劫持（握手失败），只放进 mirrors 供用户手选。
//    · 脚本一律用「当前可用主机」：LumeSource.config.domain（用户手选）→ 缓存里上次成功的域 → SITE，
//      任一台只剩「进入页」就自动换到下一台并缓存结果（见 〇·二）。
//
// ── 一、页面形态（都不是 JSON 接口）
//    首页   GET /index/home.html → 三个横滑板块（最新剧情 / 最新电影 / 最新精选），每块 10 张卡
//    分类   GET /{juqing|shipin|jingpin}/lists.html?page=N（全部）
//           GET /{juqing|shipin|jingpin}/list-<标签>.html?page=N（麻豆传媒 / 日系 AV / onlyfans …）
//           分类来自首页顶部的菜单：`<a data-link="<AES>" ...><span class="…dec-ti" title="<AES>">`
//           （2026-10-30 起 data-link 由明文 `/cYc…` 改成了 AES 密文，解开后仍是 `/cYc…`）
//    搜索   GET /search/{juqing|shipin|jingpin}-<关键词>-<页码>.html → JSON 数组（10 条/页）
//           {id, title:<AES>, thumb, tags:<AES>, channel, insert_time}
//    详情   GET /{channel}/play-<id>.html —— 只有一个 <title>（AES）与两条线路，
//           **没有简介、没有封面**（封面靠列表带出来缓存）
//    播放   play 页内联 `var video = decodeString('<base64>')`（m3u8 相对路径）与
//           `m3u8_host / m3u8_host1 = decodeString('<base64>')`；
//           2026-11-01 实测 play 页给的是 4sv.0827.la（主）与 s4.dt188.site（备），
//           两台 m3u8 200 + 封面 JPEG 200，都能播；
//           老的 www.0734.la（连不上）、s5.sanheyiliao.xyz（NXDOMAIN）已从兜底里去掉。
//
// ── 二、两套编码（站点自己的 JS）
//    decodeString(x)        = base64 → UTF-8 明文（m3u8 路径 / 线路域名 / 链接里的中文）
//    Decrypt(x, "883346")   = AES-256-CBC / PKCS7（key、iv 写在 /assets/js/common/encrypt.js，
//                             2026-10-30 起文件里改成 base64 包了一层，解出来还是同一对 key/iv）
//    卡片链接               = `/cYc` + base64(明文路径) + `.html`（有的保留 `%3D%3D` 补齐，有的没有）
//    菜单链接               = AES(同上「卡片链接」整串)，即多了一层，先 AES 再 base64
//    纯明文路径（/juqing/play-438649.html、/juqing/list-麻豆传媒.html）直接可访问，
//    所以本源只解不拼：卡片/菜单链接先还原，再按明文路径取页。
//
// ── 三、封面
//    卡片封面是 `data-base64="/videos/…/poster2.jpg"`，站点自己经
//    `fetchBase64Img(…, 'https://base4s.0827.la/')` 取回一段 `data:image/jpg;base64,…` 文本。
//    App 的图片管线不吃「文本 body」，但**同一个路径在媒体 CDN 上就是真 JPEG**
//    （2026-11-01 复测 4sv.0827.la 与 s4.dt188.site 都回 200 image/jpeg），所以封面直接用媒体域名拼。
//    媒体域名优先用播放时探活成功的那台（缓存 6 小时），站点换 CDN 时封面自动跟着换。
//
// ── 四、成人向
//    全站 18+；tupian（图集）/ meinv / xiaoshuo（小说）/ yousheng（有声）与赌博外链一律不做，
//    只做三个视频频道。

var SITE = 'https://www.z2g9w.top';
// 用户手选的镜像坏了、站点又换域名时按这张表依次试（都是实测同内容 / 官方公布的地址）
var MIRRORS = ['https://www.z2g9w.top', 'https://www.x5p2n.top', 'https://www.zie2.com'];
// 媒体 CDN：2026-11-01 复测 play 页给的两台——4sv.0827.la（主）与 s4.dt188.site（备）
// 都是「m3u8 / 分片 / 封面 JPEG 全 200」；老的 www.0734.la / s5.sanheyiliao.xyz 已连不上，
// 不再当兜底（少一次必败的探活）。
var IMAGE_HOST = 'https://4sv.0827.la';
var MEDIA_HOSTS = ['https://4sv.0827.la', 'https://s4.dt188.site'];
var UA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';
var PAGE_SIZE = 20;
var SEARCH_PAGE = 10;

var CHANNELS = { juqing: '剧情', shipin: '视频', jingpin: '精品' };
var CHANNEL_ORDER = ['juqing', 'shipin', 'jingpin'];

// 站点 AES-256-CBC 的 key / iv（/assets/js/common/encrypt.js：key/iv 各是一段 base64，
// iv 只有前 10 字节，后 6 字节是固定后缀 "883346"，见 common.js 的 decodeString2）。
var TITLE_KEY = 'IdTJq0HklpuI6mu8iB%OO@!vd^4K&uXW';
var TITLE_IV = '$0v@krH7V2883346';

// 菜单抓不到时的兜底分类（只用来保浏览可用；正常路径永远是实时抓）
var FALLBACK_CATS = [
  { id: 'juqing:', title: '全部剧情' },
  { id: 'shipin:', title: '全部视频' },
  { id: 'jingpin:', title: '全部精品' },
  { id: 'juqing:麻豆传媒', title: '剧情 · 麻豆传媒' },
  { id: 'juqing:天美传媒', title: '剧情 · 天美传媒' },
  { id: 'juqing:星空果冻', title: '剧情 · 星空果冻' },
  { id: 'juqing:蜜桃精东', title: '剧情 · 蜜桃精东' },
  { id: 'juqing:韩国伦理', title: '剧情 · 韩国伦理' },
  { id: 'juqing:COSPLAY', title: '剧情 · COSPLAY' },
  { id: 'juqing:经典三级', title: '剧情 · 经典三级' },
  { id: 'juqing:中文字幕', title: '剧情 · 中文字幕' },
  { id: 'shipin:日本av', title: '视频 · 日本av' },
  { id: 'shipin:韩国热舞', title: '视频 · 韩国热舞' },
  { id: 'shipin:欧美精品', title: '视频 · 欧美精品' },
  { id: 'shipin:动漫电影', title: '视频 · 动漫电影' },
  { id: 'shipin:国产自拍', title: '视频 · 国产自拍' },
  { id: 'shipin:岛国无码', title: '视频 · 岛国无码' },
  { id: 'shipin:JVID', title: '视频 · JVID' },
  { id: 'shipin:SM调教', title: '视频 · SM调教' },
  { id: 'jingpin:软萌福利姬', title: '精品 · 软萌福利姬' },
  { id: 'jingpin:黑料头条', title: '精品 · 黑料头条' },
  { id: 'jingpin:明星AI', title: '精品 · 明星AI' },
  { id: 'jingpin:人妖伪娘', title: '精品 · 人妖伪娘' },
  { id: 'jingpin:onlyfans', title: '精品 · onlyfans' },
  { id: 'jingpin:探花系列', title: '精品 · 探花系列' },
  { id: 'jingpin:主播大秀', title: '精品 · 主播大秀' },
  { id: 'jingpin:韩国主播', title: '精品 · 韩国主播' },
];

/* ════════════════════════════ 纯 JS 工具（沙箱没有 atob / Buffer / crypto） ════════════════════════════ */

var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var B64_MAP = null;

function b64Map() {
  if (B64_MAP) return B64_MAP;
  var map = {}, i;
  for (i = 0; i < B64_CHARS.length; i++) map[B64_CHARS.charAt(i)] = i;
  B64_MAP = map;
  return map;
}

function utf8Bytes(text) {
  var out = [], i, c, d;
  var s = String(text == null ? '' : text);
  for (i = 0; i < s.length; i++) {
    c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      d = s.charCodeAt(++i);
      c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
      out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return out;
}

function bytesText(bytes) {
  var out = '', i = 0, b, c;
  var n = bytes.length;
  while (i < n) {
    b = bytes[i++];
    if (b < 0x80) out += String.fromCharCode(b);
    else if (b > 0xbf && b < 0xe0 && i < n) out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
    else if (b > 0xdf && b < 0xf0 && i + 1 < n) {
      c = ((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      out += String.fromCharCode(c);
    } else if (b > 0xef && i + 2 < n) {
      c = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      c -= 0x10000;
      out += String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff));
    } else out += '\ufffd';
  }
  return out;
}

function b64Bytes(input) {
  var map = b64Map();
  var text = String(input == null ? '' : input).replace(/\s+/g, '');
  var out = [], acc = 0, bits = 0, i, ch, v;
  for (i = 0; i < text.length; i++) {
    ch = text.charAt(i);
    if (ch === '=') break;
    v = map[ch];
    if (v == null) continue;
    acc = ((acc << 6) | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((acc >> bits) & 0xff);
    }
  }
  return out;
}

function b64Text(input) {
  return bytesText(b64Bytes(input));
}

/* ─────────────────────────── 纯 JS AES-256-CBC 解密（tiny-AES 思路的字节实现） ─────────────────────────── */

// S 盒写死（现算逆元要 20 万次 GF 乘法，QuickJS 里会比解密本身还慢）
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
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

var AES_T = null;

function aesT() {
  if (AES_T) return AES_T;
  var rsbox = new Array(256), i;
  for (i = 0; i < 256; i++) rsbox[AES_SBOX[i]] = i;
  AES_T = { sbox: AES_SBOX, rsbox: rsbox, mul: gmul };
  return AES_T;
}

function gmul(a, b) {
  var r = 0, k, hi;
  for (k = 0; k < 8; k++) {
    if (b & 1) r ^= a;
    hi = a & 0x80;
    a = (a << 1) & 0xff;
    if (hi) a ^= 0x1b;
    b >>= 1;
  }
  return r & 0xff;
}

// AES-256：Nk=8、Nr=14，密钥表 240 字节
function aesExpand256(key) {
  var T = aesT(), rk = new Array(240), i, j, tmp, rcon = 1;
  for (i = 0; i < 32; i++) rk[i] = key[i];
  for (i = 32; i < 240; i += 4) {
    tmp = [rk[i - 4], rk[i - 3], rk[i - 2], rk[i - 1]];
    if (i % 32 === 0) {
      tmp = [tmp[1], tmp[2], tmp[3], tmp[0]];
      tmp[0] = T.sbox[tmp[0]] ^ rcon;
      tmp[1] = T.sbox[tmp[1]];
      tmp[2] = T.sbox[tmp[2]];
      tmp[3] = T.sbox[tmp[3]];
      rcon = gmul(rcon, 2) || 0x1b;
    } else if (i % 32 === 16) {
      tmp[0] = T.sbox[tmp[0]];
      tmp[1] = T.sbox[tmp[1]];
      tmp[2] = T.sbox[tmp[2]];
      tmp[3] = T.sbox[tmp[3]];
    }
    for (j = 0; j < 4; j++) rk[i + j] = rk[i - 32 + j] ^ tmp[j];
  }
  return rk;
}

function aesDecryptBlock(block, rk, rounds) {
  var T = aesT(), s = block.slice(0), i, a0, a1, a2, a3, t, round, m = T.mul;
  function addKey(r) {
    for (var k = 0; k < 16; k++) s[k] ^= rk[r * 16 + k];
  }
  function invShift() {
    t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
  }
  addKey(rounds);
  for (round = rounds - 1; round >= 1; round--) {
    invShift();
    for (i = 0; i < 16; i++) s[i] = T.rsbox[s[i]];
    addKey(round);
    for (i = 0; i < 4; i++) {
      a0 = s[i * 4]; a1 = s[i * 4 + 1]; a2 = s[i * 4 + 2]; a3 = s[i * 4 + 3];
      s[i * 4] = m(a0, 14) ^ m(a1, 11) ^ m(a2, 13) ^ m(a3, 9);
      s[i * 4 + 1] = m(a0, 9) ^ m(a1, 14) ^ m(a2, 11) ^ m(a3, 13);
      s[i * 4 + 2] = m(a0, 13) ^ m(a1, 9) ^ m(a2, 14) ^ m(a3, 11);
      s[i * 4 + 3] = m(a0, 11) ^ m(a1, 13) ^ m(a2, 9) ^ m(a3, 14);
    }
  }
  invShift();
  for (i = 0; i < 16; i++) s[i] = T.rsbox[s[i]];
  addKey(0);
  return s;
}

var AES_RK = null;
var AES_RK_TAG = '';

function aes256CbcDecrypt(cipherB64, keyText, ivText) {
  var key = utf8Bytes(keyText);
  var iv = utf8Bytes(ivText);
  if (key.length !== 32) throw new Error('AES-256 密钥长度不对：' + key.length);
  if (iv.length !== 16) throw new Error('AES IV 长度不对：' + iv.length);
  var data = b64Bytes(cipherB64);
  if (!data.length || data.length % 16 !== 0) return '';
  var tag = keyText + '|' + ivText;
  if (!AES_RK || AES_RK_TAG !== tag) {
    AES_RK = aesExpand256(key);
    AES_RK_TAG = tag;
  }
  var rk = AES_RK;
  var prev = iv, out = [], i, j, plain;
  for (i = 0; i < data.length; i += 16) {
    var block = data.slice(i, i + 16);
    plain = aesDecryptBlock(block, rk, 14);
    for (j = 0; j < 16; j++) out.push(plain[j] ^ prev[j]);
    prev = block;
  }
  var pad = out[out.length - 1];
  if (pad > 0 && pad <= 16) out = out.slice(0, out.length - pad);
  return bytesText(out);
}

/* ══════════════════════════════════════ 站点编解码 ══════════════════════════════════════ */

function clean(text) {
  return String(text == null ? '' : text)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// 页面里到处是 `&#26368&#26032` 这种不带分号的数字实体（art-template 的输出习惯）
function decodeEntities(text) {
  return String(text == null ? '' : text).replace(/&#(\d+);?/g, function (m, code) {
    var n = Number(code);
    return n > 0 && n < 0x10ffff ? String.fromCharCode(n) : m;
  });
}

// 站点的 Decrypt()：AES-256-CBC + PKCS7；解不开就返回空串（调用方决定怎么兜底）
function decRaw(cipher) {
  var text = String(cipher == null ? '' : cipher).replace(/\\\//g, '/').trim();
  if (!text) return '';
  try {
    return aes256CbcDecrypt(text, TITLE_KEY, TITLE_IV);
  } catch (error) {
    return '';
  }
}

function decTitle(cipher) {
  return clean(decRaw(cipher));
}

// `/cYc<base64>.html` → 明文路径；广告跳转与站外链接返回空串
function decodeLink(href) {
  var text = String(href == null ? '' : href).trim();
  if (!text) return '';
  var cut = text.search(/[?#]/);
  if (cut >= 0) text = text.substring(0, cut);
  if (text.indexOf('/redirect302') === 0) return '';
  if (text.indexOf('/cYc') === 0) {
    var body = text.substring(4);
    if (/\.html$/.test(body)) body = body.substring(0, body.length - 5);
    try {
      body = decodeURIComponent(body);
    } catch (error) {}
    var path = b64Text(body);
    return path.charAt(0) === '/' ? path : '/' + path;
  }
  if (text.charAt(0) === '/') {
    try {
      return decodeURIComponent(text);
    } catch (error) {
      return text;
    }
  }
  return '';
}

// 菜单/同行链接有两种形态：老的明文 `/cYc…`，新的 AES 密文（解出来还是 `/cYc…`）。
// 认不出的一律返回空串，让调用方跳过，别把密文当路径去请求。
function resolveLink(raw) {
  var text = String(raw == null ? '' : raw).trim();
  if (!text) return '';
  if (text.charAt(0) === '/' || /^https?:\/\//i.test(text)) return decodeLink(text);
  var plain = decRaw(text);
  return plain ? decodeLink(plain) : '';
}

/* ══════════════════════════════════════ 宿主 / 网络 ══════════════════════════════════════ */

// ── 换域名自愈 ──
// 站点 3 天换一次域名，旧域还活着但整站 302 到新域的 /enter/index.html。
// App 的 HTTP 桥会跟随 302，却既不回报 reply.url 也不回 302 的 Location，落到手的 body
// 就是那张「进入页」——形态上没有 video-item，只有 enter-content / qrcodeSmall 两个标记。
// 认得出来就记一笔「这台只剩进入页」，按 MIRRORS 依次换台重试，成功的那台缓存 12 小时。
var HOST_FILE = 'host.json';
var HOST_TTL = 12 * 3600 * 1000;

function configDomain() {
  var value = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return value ? value.replace(/\/+$/, '') : '';
}

var ACTIVE_HOST = '';

// 用户手选 > 缓存里上次成功的域 > 内置主站
async function siteHost() {
  var selected = configDomain();
  var cached = await readJson(HOST_FILE);
  if (cached && cached.host && cached.selected === selected &&
      Date.now() - Number(cached.at || 0) < HOST_TTL) {
    return String(cached.host).replace(/\/+$/, '');
  }
  return selected || SITE;
}

async function rememberHost(host) {
  var text = String(host || '').replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) return;
  ACTIVE_HOST = text;
  var selected = configDomain();
  var cached = await readJson(HOST_FILE);
  if (cached && cached.host === text && cached.selected === selected &&
      Date.now() - Number(cached.at || 0) < HOST_TTL / 2) return;
  await writeJson(HOST_FILE, { at: Date.now(), selected: selected, host: text });
}

async function base() {
  var host = await siteHost();
  ACTIVE_HOST = host;
  return host;
}

function looksLikeGate(body) {
  var text = String(body == null ? '' : body);
  if (!text) return false;
  if (text.indexOf('video-item') >= 0) return false;
  return text.indexOf('enter-content') >= 0 || text.indexOf('qrcodeSmall') >= 0;
}

async function hostCandidates() {
  var out = [];
  function push(host) {
    var text = String(host || '').replace(/\/+$/, '');
    if (!text || out.indexOf(text) >= 0) return;
    out.push(text);
  }
  push(ACTIVE_HOST);
  push(await siteHost());
  push(configDomain());
  push(SITE);
  for (var i = 0; i < MIRRORS.length; i++) push(MIRRORS[i]);
  return out;
}

function readJson(file) {
  return LumeSource.fs.readText(file).then(function (raw) {
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (error) { return null; }
  }).catch(function () { return null; });
}

function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}

async function getText(path, referer) {
  var hosts = await hostCandidates();
  var lastError = null;
  for (var i = 0; i < hosts.length; i++) {
    var host = hosts[i];
    var reply = null;
    try {
      reply = await LumeSource.http.get(host + path, {
        headers: {
          'User-Agent': UA,
          Accept: 'text/html,application/xhtml+xml,application/json,*/*;q=0.8',
          Referer: referer || (host + '/'),
        },
      });
    } catch (error) {
      lastError = error;
      continue;
    }
    var status = reply ? reply.status : 0;
    if (status === 403 || status === 503) {
      throw new Error('NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP ' + status + '）');
    }
    var body = reply && reply.body ? String(reply.body) : '';
    if (status === 200 && looksLikeGate(body)) {
      // 这台只剩 302 后的「进入页」，换下一台
      lastError = new Error('域名只剩进入页：' + host);
      continue;
    }
    if (status !== 200) {
      lastError = new Error('页面打不开：HTTP ' + status + '（' + path + '）');
      continue;
    }
    await rememberHost(host);
    return body;
  }
  throw new Error('已知域名都取不到页面（' + path + '）：' +
    (lastError && lastError.message ? lastError.message : String(lastError || '未知错误')) +
    '；站点 3 天换一次域名，请到「源设置 → 打开发布页」看最新地址');
}

async function getJson(path, referer) {
  var body = await getText(path, referer);
  try {
    return JSON.parse(body);
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
}

/* ══════════════════════════════════════ 列表/详情缓存 ══════════════════════════════════════ */

var CACHE_FILE = 'items.json';
var CACHE_MAX = 2000;

async function remember(items) {
  if (!items || !items.length) return;
  var cached = (await readJson(CACHE_FILE)) || {};
  var map = cached.map || {};
  var keys = Object.keys(map);
  if (keys.length > CACHE_MAX) map = {};
  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    if (!item || !item.id) continue;
    map[item.id] = {
      title: item.title,
      cover: item.cover,
      subtitle: item.subtitle,
      channel: item.channel || '',
      tag: item.tag || '',
    };
  }
  await writeJson(CACHE_FILE, { at: Date.now(), map: map });
}

async function recall(id) {
  var cached = await readJson(CACHE_FILE);
  return (cached && cached.map && cached.map[id]) || null;
}

// 媒体 CDN 域名随站点轮换：播放时探活成功的那台存下来给封面用；超过 7 天不用就当过期
async function mediaHost() {
  var cached = await readJson('media.json');
  var host = cached && cached.host ? String(cached.host) : '';
  if (!host) return IMAGE_HOST;
  if (Date.now() - Number(cached.at || 0) > 7 * 24 * 3600 * 1000) return IMAGE_HOST;
  return host.replace(/\/+$/, '') || IMAGE_HOST;
}

async function setMediaHost(host) {
  var text = String(host || '').trim().replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) return;
  var cached = await readJson('media.json');
  if (cached && cached.host === text && Date.now() - Number(cached.at || 0) < 6 * 3600 * 1000) return;
  await writeJson('media.json', { at: Date.now(), host: text });
}

function mediaUrl(path, host) {
  var raw = String(path == null ? '' : path);
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return String(host || IMAGE_HOST).replace(/\/+$/, '') + (raw.charAt(0) === '/' ? raw : '/' + raw);
}

/* ══════════════════════════════════════ 解析 ══════════════════════════════════════ */

function splitPlayPath(path) {
  var matched = /^\/([a-z]+)\/play-(\d+)\.html/.exec(String(path || ''));
  if (!matched) return null;
  var channel = matched[1];
  if (!CHANNELS[channel]) return null;
  return { channel: channel, num: matched[2] };
}

// 卡片列表：一次性抓 `<a class="video-item"` 段，段内取 封面 / 标题 / 日期
async function parseCards(chunk, host) {
  var text = String(chunk || '');
  var parts = text.split('<a class="video-item"');
  var out = [];
  var seen = {};
  var undecodable = 0;
  for (var i = 1; i < parts.length; i++) {
    var seg = parts[i].slice(0, 2000);
    var href = /href="([^"]+)"/.exec(seg);
    if (!href) continue;
    var play = splitPlayPath(decodeLink(href[1]));
    if (!play) continue;
    var id = play.channel + '-' + play.num;
    if (seen[id]) continue;
    var cover = /data-base64="([^"]*)"/.exec(seg);
    var cipher = /class="video-item-title[^"]*"\s+title="([^"]+)"/.exec(seg);
    var plain = /class="video-item-title[^"]*">([^<]{1,120})</.exec(seg);
    var title = cipher ? decTitle(cipher[1]) : clean(decodeEntities(plain ? plain[1] : ''));
    if (!title) {
      undecodable++;
      title = '视频 ' + play.num;
    }
    var date = /class="video-item-date">([^<]*)</.exec(seg);
    seen[id] = true;
    out.push({
      id: id,
      channel: play.channel,
      num: play.num,
      title: title,
      cover: cover ? mediaUrl(cover[1].replace(/\\\//g, '/'), host) : '',
      subtitle: date ? clean(decodeEntities(date[1])) : '',
      tag: '',
    });
  }
  if (out.length && undecodable === out.length && out.length > 1) {
    throw new Error('标题一条都解不开（站点换加密 key 了？请在源里更新 TITLE_KEY）');
  }
  return out;
}

function toItem(row) {
  return {
    id: row.id,
    title: row.title,
    cover: row.cover || '',
    subtitle: row.subtitle || '',
  };
}

async function playInfo(id) {
  var parsed = splitId(id);
  if (!parsed) throw new Error('缺少视频 ID');
  var cacheFile = 'play-' + parsed.channel + '-' + parsed.num + '.json';
  var cached = await readJson(cacheFile);
  if (cached && Date.now() - Number(cached.at || 0) < 15 * 60 * 1000 && cached.video) return cached;

  var html = await getText('/' + parsed.channel + '/play-' + parsed.num + '.html');
  var videoMatch = /var\s+video\s*=\s*decodeString\('([^']+)'\)/.exec(html);
  if (!videoMatch) throw new Error('详情页里没有播放地址（视频可能已下架）');
  var videoPath = b64Text(videoMatch[1]);
  if (!videoPath) throw new Error('播放地址解不开（站点改版了？）');

  var hosts = [];
  var primary = /var\s+m3u8_host\s*=\s*decodeString\('([^']+)'\)/.exec(html);
  var backup = /var\s+m3u8_host1\s*=\s*decodeString\('([^']+)'\)/.exec(html);
  if (primary) {
    var first = b64Text(primary[1]).replace(/\/+$/, '');
    if (first) hosts.push(first);
  }
  if (backup) {
    var second = b64Text(backup[1]).replace(/\/+$/, '');
    if (second && hosts.indexOf(second) < 0) hosts.push(second);
  }

  var titleTag = /class="play-title"[\s\S]{0,240}?title="([^"]{8,})"/.exec(html);
  var channelTag = /data-channel="([a-z]+)"\s+data-tags="([^"]*)"/.exec(html);
  var info = {
    at: Date.now(),
    video: videoPath,
    hosts: hosts,
    title: titleTag ? decTitle(titleTag[1]) : '',
    channel: channelTag ? channelTag[1] : parsed.channel,
    tag: channelTag ? decTitle(channelTag[2]) : '',
  };
  await writeJson(cacheFile, info);
  return info;
}

// 播放候选主机：记住的那台（真机验证过）→ 站点给的线路 → 内置媒体 CDN。
// 站点两条线路都换过域名/挂掉过，所以不信任任何单一来源，按顺序探活取第一个能用的。
async function playCandidates(info, lineIndex) {
  var out = [];
  function push(url) {
    var text = String(url || '').trim().replace(/\/+$/, '');
    if (!text || out.indexOf(text) >= 0) return;
    out.push(text);
  }
  var cached = await readJson('media.json');
  var remembered = cached && cached.host && Date.now() - Number(cached.at || 0) < 6 * 3600 * 1000
    ? String(cached.host).replace(/\/+$/, '')
    : '';
  // 用户明确点了「线路二」就先把站点给的那条排前面
  if (lineIndex > 0 && info.hosts[lineIndex]) push(info.hosts[lineIndex]);
  push(remembered);
  // 2026-11-01 起站点 play 页给的是 4sv.0827.la / s4.dt188.site（两台都实测能播），
  // 内置 CDN 仍排在站点线路前面：冷启动只要探一次，站点线路换域名也不影响播放。
  for (var j = 0; j < MEDIA_HOSTS.length; j++) push(MEDIA_HOSTS[j]);
  for (var i = 0; i < info.hosts.length; i++) push(info.hosts[i]);
  return { list: out, remembered: remembered };
}

function splitId(id) {
  var text = String(id == null ? '' : id).trim();
  var matched = /^([a-z]+)-(\d+)$/.exec(text);
  if (matched && CHANNELS[matched[1]]) return { channel: matched[1], num: matched[2] };
  matched = /^(\d+)$/.exec(text);
  if (matched) return { channel: 'juqing', num: matched[1] };
  return null;
}

// 分类 id：`<channel>:<标签>`（标签为空 = 该频道「全部」）
function parseCategory(categoryId) {
  var text = String(categoryId == null ? '' : categoryId).trim();
  var cut = text.indexOf(':');
  if (cut > 0) {
    var channel = text.substring(0, cut);
    if (CHANNELS[channel]) return { channel: channel, tag: text.substring(cut + 1) };
  }
  if (CHANNELS[text]) return { channel: text, tag: '' };
  return null;
}

function listPath(category, page) {
  var tail = page > 1 ? '?page=' + page : '';
  if (!category.tag) return '/' + category.channel + '/lists.html' + tail;
  return '/' + category.channel + '/list-' + encodeURIComponent(category.tag) + '.html' + tail;
}

/* ══════════════════════════════════════ 图源 ══════════════════════════════════════ */

var LumeSource = {
  id: 'd9y1w_video',
  name: '四色视频 18+',
  version: '1.0.3',
  category: 'video',
  contentCategory: 'adult',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: ['https://www.z2g9w.top', 'https://www.x5p2n.top', 'https://www.zie2.com'],
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页（站点自救页）',
      url: 'https://www.z2g9w.top/help/help.html',
      description: '站点自己说 3 天换一次域名；这页有正确访问方式、找回邮箱与 APP 下载',
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '四色视频（maomi 模板，全站 18+）。域名 3 天轮换：当前可用 www.z2g9w.top / www.x5p2n.top，官方长期地址 www.zie2.com。找回最新域名：邮件 liumangtu@mail.com 或看 /help/help.html。脚本已内置换域名自愈，镜像只剩「进入页」时会自动换台。',
    },
  ],

  async categories() {
    var cached = await readJson('categories.json');
    if (cached && Date.now() - Number(cached.at || 0) < 30 * 60 * 1000 && cached.list && cached.list.length) {
      return cached.list;
    }
    var out = [
      { id: 'juqing:', title: '全部剧情' },
      { id: 'shipin:', title: '全部视频' },
      { id: 'jingpin:', title: '全部精品' },
    ];
    var seen = { 'juqing:': true, 'shipin:': true, 'jingpin:': true };
    try {
      var html = await getText('/index/home.html');
      var pattern = /<a data-link="([^"]+)"[\s\S]{0,400}?<span class="menu-desktop-content-item dec-ti" title="([^"]+)"/g;
      var matched;
      while ((matched = pattern.exec(html)) !== null) {
        var path = resolveLink(matched[1]);
        var parsed = /^\/([a-z]+)\/list-(.+)\.html$/.exec(path);
        if (!parsed) continue;
        var channel = parsed[1];
        if (!CHANNELS[channel]) continue;
        var title = decTitle(matched[2]);
        if (!title) continue;
        var id = channel + ':' + parsed[2];
        if (seen[id]) continue;
        seen[id] = true;
        out.push({ id: id, title: CHANNELS[channel] + ' · ' + title });
      }
    } catch (error) {
      if (out.length <= 3) return FALLBACK_CATS.slice(0);
    }
    if (out.length <= 3) return FALLBACK_CATS.slice(0);
    await writeJson('categories.json', { at: Date.now(), list: out });
    return out;
  },

  async home() {
    var html = await getText('/index/home.html');
    var host = await mediaHost();
    var boards = [];
    var chunks = String(html).split('<div class="home-list-item">');
    for (var i = 1; i < chunks.length; i++) {
      var chunk = chunks[i];
      var head = chunk.slice(0, 400);
      var nameTag = /<span>([\s\S]*?)<\/span>/.exec(head);
      var title = nameTag ? clean(decodeEntities(nameTag[1])) : '';
      var moreTag = /<a href="([^"]+)"/.exec(head);
      var morePath = moreTag ? resolveLink(moreTag[1]) : '';
      var moreParsed = /^\/([a-z]+)\/list(s)?\.html$/.exec(morePath);
      var moreUrl = moreParsed && CHANNELS[moreParsed[1]] ? moreParsed[1] + ':' : '';
      var items = await parseCards(chunk, host);
      if (!items.length) continue;
      await remember(items);
      boards.push({
        title: title || (moreUrl ? CHANNELS[moreUrl.substring(0, moreUrl.length - 1)] : '推荐'),
        moreUrl: moreUrl,
        items: items.slice(0, 12).map(toItem),
      });
    }
    if (!boards.length) throw new Error('首页没有解析到板块（站点改版了？）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1) || 1;
    var keyword = clean(String(args.keyword == null ? '' : args.keyword));
    var host = await mediaHost();

    if (keyword) {
      var channels = CHANNEL_ORDER;
      var lists = await Promise.all(channels.map(function (channel) {
        var path = '/search/' + channel + '-' + encodeURIComponent(keyword) + '-' + page + '.html';
        return getJson(path).catch(function () { return []; });
      }));
      var rows = [];
      var seen = {};
      var hasMore = false;
      for (var i = 0; i < lists.length; i++) {
        var data = lists[i];
        if (!Array.isArray(data)) continue;
        if (data.length >= SEARCH_PAGE) hasMore = true;
        for (var j = 0; j < data.length; j++) {
          var row = data[j] || {};
          var channel = String(row.channel || CHANNEL_ORDER[i]);
          if (!CHANNELS[channel] || !row.id) continue;
          var num = String(row.id).replace(/[^0-9]/g, '');
          if (!num) continue;
          var id = channel + '-' + num;
          if (seen[id]) continue;
          var title = decTitle(row.title);
          if (!title) continue;
          seen[id] = true;
          rows.push({
            id: id,
            channel: channel,
            num: num,
            title: title,
            cover: mediaUrl(String(row.thumb || '').replace(/\\\//g, '/'), host),
            subtitle: row.insert_time ? stampDate(row.insert_time) : '',
            tag: decTitle(row.tags),
          });
        }
      }
      await remember(rows);
      return { items: rows.map(toItem), hasMore: hasMore };
    }

    var category = parseCategory(args.categoryId);
    if (!category && args.filters && args.filters.category) category = parseCategory(args.filters.category);
    if (!category) category = { channel: 'juqing', tag: '' };
    var html = await getText(listPath(category, page));
    var items = await parseCards(html, host);
    for (var k = 0; k < items.length; k++) items[k].tag = category.tag;
    await remember(items);
    return { items: items.map(toItem), hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '');
    var parsed = splitId(id);
    if (!parsed) return null;
    var cached = await recall(id);
    var info = null;
    try {
      info = await playInfo(id);
    } catch (error) {
      // 详情页打不开时仍可给出列表里已知的标题/封面（播放会按需报错）
      if (!cached) throw error;
    }
    var title = (info && info.title) || (cached && cached.title) || ('视频 ' + parsed.num);
    var channelName = CHANNELS[(info && info.channel) || parsed.channel] || '';
    var tag = (info && info.tag) || (cached && cached.tag) || '';
    var lines = ['分类：' + channelName + (tag ? ' · ' + tag : '')];
    if (cached && cached.subtitle) lines.push('收录：' + cached.subtitle);
    lines.push('来源：四色视频，单集视频，提供两条线路。');
    return {
      id: id,
      title: title,
      cover: (cached && cached.cover) || '',
      subtitle: tag || (cached && cached.subtitle) || channelName,
      description: lines.join('\n'),
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '');
    var info = await playInfo(id);
    var out = [{ id: '1', title: '线路一' }];
    if (info.hosts.length > 1) out.push({ id: '2', title: '线路二（备用）' });
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || '');
    var chapterId = String(args.chapterId == null ? '' : args.chapterId);
    var info = await playInfo(id);
    var index = Number(chapterId.replace(/[^0-9]/g, '')) - 1;
    if (!(index >= 0 && index < info.hosts.length)) index = 0;
    var siteBase = await base();
    var headers = { 'User-Agent': UA, Referer: siteBase + '/' };

    // 站点 play 页给的两条 m3u8_host 换过好几次域名，所以按「记住的 → 内置 CDN → 站点线路」
    // 顺序探活，第一个出 #EXTM3U 的胜出并记住；6 小时内验证过的那台不重复探，省一次请求。
    var picked = await playCandidates(info, index);
    var candidates = picked.list;
    var host = '';
    for (var i = 0; i < candidates.length; i++) {
      var candidate = candidates[i];
      if (candidate === picked.remembered) {
        host = candidate;
        break;
      }
      var ok = false;
      try {
        var probe = await LumeSource.http.get(candidate + info.video, { headers: headers });
        var body = probe && probe.body ? String(probe.body) : '';
        ok = probe && probe.status === 200 && body.indexOf('#EXTM3U') >= 0;
      } catch (error) {
        ok = false;
      }
      if (ok) {
        host = candidate;
        break;
      }
    }
    if (!host) throw new Error('所有播放线路都探不通（站点又换 CDN 了？）');
    await setMediaHost(host);
    return { kind: 'video', url: host + info.video, headers: headers };
  },
};

function stampDate(seconds) {
  var n = Number(seconds);
  if (!n || n < 0) return '';
  var date = new Date(n * 1000);
  var month = date.getMonth() + 1;
  var day = date.getDate();
  return date.getFullYear() + '-' + (month < 10 ? '0' + month : month) + '-' + (day < 10 ? '0' + day : day);
}
