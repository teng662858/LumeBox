// LumeSource: {"id":"akmh_video","name":"18ak漫画·视频","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://www.18akmanhua.com"],"network":"direct","icon":"https://www.18akmanhua.com/logo.png"}
// LumeRuntime: javascript
//
// 站点：18ak漫画 / 爱看漫画（https://www.18akmanhua.com，全站 18+，Vue3 SPA）
// 来源：从「暮色」App（com.look.mbox / avbox 1.0.1）的内置源里挖出来的站点及其协议。
//
// 一、协议（2026-11-02 从前端 index-*.js 的 axios 拦截器还原 + 真机响应验证）
//   baseURL = /api；每个请求带
//     timestamp = parseInt(Date.now()/1000)
//     sign      = md5(timestamp + "api" + path + METHOD + "6F7A4DF7000C045C636B9123B11E4EC7").toLowerCase()
//   响应 200 时是 {"code":200,"data":{"suffix":"<6 hex>","data":"<base64>"}}：
//     key = "9a2d65b4a693ad0e40e5b156df25e406"（32 字节 → AES-256）
//     iv  = "9a62e6977b" + suffix（10 + 6 = 16 字节）
//     AES-CBC / PKCS7，base64 输入，解出来是 JSON
//   沙箱没有 crypto/atob，所以 MD5 与 AES-256 都是源内纯 JS 实现（复用橙涩源的 AES 内核，
//   expandKey 改成按 key 长度选 nk=4/6/8，AES-256 多一条 j%nk==4 的 SubWord 分支）。
//
// 二、接口
//   GET /api/videoLists?page=&size=15&type=   type 0=漫画改编(695) 1=真人(836) 2+=全部(1531)
//        → {page,size,totalSize,totalPage,list:[{id,title,image,mark,view_num,pay_url,preview_url,type,duration}]}
//   GET /api/videoDetails?id=                 → 上面字段 + price/is_free/sales_num
//   GET /api/stacksCategories                  → 漫画分类（{id,name}）
//   GET /api/notices、/api/hotSearchBooks、/api/searchBooks?keyword=
//   size 服务端写死 15（传 20/50 都回 15），所以分页按 totalPage 判断。
//
// 三、付费（2026-11-02 实测：只挡前端）
//   videoDetails 对 price>0 / is_free=0 的片照样下发 pay_url（静态相对路径），
//   base + pay_url 实测 200 + #EXTM3U（分片 010.ts / 011.ts…），不需要登录、不需要买。
//   preview_url 是 10 秒试看，只在 pay_url 缺失时兜底。
//
// 四、限制
//   · 视频没有站内搜索（/searchVideos、/search 都是 404；漫画才有 /searchBooks）。
//   · 漫画板块（/stacks、/books）参数还没摸全，本源只做「视频」。
//   · 站点换域名/IP 时改 mirrors[0]；签名密钥若变，源会抛「接口结构变了 / 响应解不开」。

// ---------------- 站点与协议常量 ----------------
// 站点：18ak漫画（爱看漫画，全站 18+）。本站「视频」板块的接口全在 /api 下，带签名 + AES-256 响应密文。
//   · 签名：sign = md5(timestamp + "api" + path + METHOD + SECRET)，大写方法名，结果小写 hex
//           timestamp 是 10 位秒级时间戳，放在请求头 timestamp 里
//   · 响应：{"code":200,"data":{"suffix":"<6 hex>","data":"<base64 密文>"}}，
//           解密 key = "9a2d65b4a693ad0e40e5b156df25e406"（AES-256），iv = "9a62e6977b" + suffix（16 字节）
//   · 视频列表 /videoLists?page=&size=15&type=（type 0=漫画改编 695 条、1=真人 836 条、2+=全部 1531 条）
//   · 详情 /videoDetails?id= → pay_url（完整 m3u8）/ preview_url（试看）
//   · **付费片接口层不鉴权**：videoDetails 给 price>0、is_free=0，但 pay_url 是静态相对路径，
//     base + pay_url 实测 200 + #EXTM3U（分片 010.ts…），不需要登录或购买。
var SITE = 'https://www.18akmanhua.com';
var SIGN_SECRET = '6F7A4DF7000C045C636B9123B11E4EC7';
var AES_KEY = '9a2d65b4a693ad0e40e5b156df25e406';
var AES_IV_PREFIX = '9a62e6977b';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 15;

function siteBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || SITE).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function media(path) {
  var raw = String(path == null ? '' : path).trim();
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return siteBase() + (raw.charAt(0) === '/' ? '' : '/') + raw;
}

function durationText(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0));
  if (!total) return '';
  var h = Math.floor(total / 3600);
  var m = Math.floor((total % 3600) / 60);
  var s = total % 60;
  var mm = (m < 10 ? '0' : '') + m;
  var ss = (s < 10 ? '0' : '') + s;
  return h > 0 ? h + ':' + mm + ':' + ss : m + ':' + ss;
}

// ---------------- 接口 ----------------
async function api(path, query) {
  var root = siteBase();
  var ts = Math.floor(Date.now() / 1000);
  var sign = md5Hex(ts + 'api' + path + 'GET' + SIGN_SECRET).toLowerCase();
  var url = root + '/api' + path + (query ? '?' + query : '');
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'application/json, text/plain, */*',
      timestamp: String(ts),
      sign: sign,
      Referer: root + '/',
      Origin: root,
    },
  });
  if (!reply || reply.status !== 200) {
    throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  }
  var text = reply.body ? String(reply.body) : '';
  var wallet;
  try {
    wallet = JSON.parse(text);
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  var envelope = wallet && wallet.data;
  if (!envelope || !envelope.data || !envelope.suffix) {
    throw new Error('接口结构变了：' + path + (wallet && wallet.message ? '（' + wallet.message + '）' : ''));
  }
  var plain = aesCbcDecryptUtf8(String(envelope.data), AES_KEY, AES_IV_PREFIX + String(envelope.suffix));
  try {
    return JSON.parse(plain);
  } catch (error) {
    throw new Error('响应解不开（站点换密钥了？）：' + path);
  }
}

function rowOf(v) {
  if (!v) return null;
  var id = String(v.id == null ? '' : v.id);
  if (!id) return null;
  var title = clean(v.title);
  if (!title) return null;
  var bits = [];
  if (Number(v.price) > 0 && !Number(v.is_free)) bits.push('金币 ' + v.price + '（接口直发播放地址）');
  if (v.duration) bits.push(durationText(v.duration));
  if (v.view_num) bits.push('浏览 ' + v.view_num);
  return { id: id, title: title, cover: media(v.image), subtitle: bits.join(' · ') };
}

var CATEGORIES = [
  { id: 'all', title: '全部视频', type: '2' },
  { id: 'comic', title: '漫画改编', type: '0' },
  { id: 'real', title: '真人', type: '1' },
];

function typeOf(categoryId) {
  var id = String(categoryId == null ? '' : categoryId);
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === id) return CATEGORIES[i].type;
  return '2';
}

var RECENT = [];
var RECENT_MAX = 400;

function remember(rows) {
  if (!rows || !rows.length) return;
  RECENT = rows.concat(RECENT).slice(0, RECENT_MAX);
}

function recall(id) {
  for (var i = 0; i < RECENT.length; i++) if (RECENT[i].id === String(id)) return RECENT[i];
  return null;
}


// ---------------- 纯 JS：MD5 / AES-256-CBC（沙箱无 crypto、atob） ----------------
function utf8Bytes(text) {
  var out = [], str = String(text == null ? '' : text);
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      var low = str.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        i++;
        var pt = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (pt >> 18), 0x80 | ((pt >> 12) & 0x3f), 0x80 | ((pt >> 6) & 0x3f), 0x80 | (pt & 0x3f));
        continue;
      }
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return out;
}

function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function rol(v, s2) { return (v << s2) | (v >>> (32 - s2)); }
  var bytes = utf8Bytes(String(input == null ? '' : input));
  var bitLen = bytes.length * 8;
  var pad = bytes.slice();
  pad.push(0x80);
  while (pad.length % 64 !== 56) pad.push(0);
  var hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
  pad.push(lo & 0xff, (lo >>> 8) & 0xff, (lo >>> 16) & 0xff, (lo >>> 24) & 0xff);
  pad.push(hi & 0xff, (hi >>> 8) & 0xff, (hi >>> 16) & 0xff, (hi >>> 24) & 0xff);
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  var K = [];
  for (var k = 0; k < 64; k++) K[k] = Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0;
  for (var off = 0; off < pad.length; off += 64) {
    var m = [];
    for (var w = 0; w < 16; w++) {
      m[w] = (pad[off + w * 4] | (pad[off + w * 4 + 1] << 8) | (pad[off + w * 4 + 2] << 16) | (pad[off + w * 4 + 3] << 24)) >>> 0;
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (var i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D; D = C; C = B;
      B = add32(B, rol(add32(add32(A, F & 0xffffffff), add32(K[i], m[g])), S[i]));
      A = tmp;
    }
    a0 = add32(a0, A); b0 = add32(b0, B); c0 = add32(c0, C); d0 = add32(d0, D);
  }
  function hx(v) {
    var o = '';
    for (var j = 0; j < 4; j++) o += ('0' + ((v >>> (j * 8)) & 0xff).toString(16)).slice(-2);
    return o;
  }
  return hx(a0) + hx(b0) + hx(c0) + hx(d0);
}

// ---------------------------------------------------------------- 纯 JS：AES-128-CBC + Base64
var SBOX_HEX = '637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16';
var INV_SBOX_HEX = '52096ad53036a538bf40a39e81f3d7fb7ce339829b2fff87348e4344c4dee9cb547b9432a6c2233dee4c950b42fac34e082ea16628d924b2765ba2496d8bd12572f8f66486689816d4a45ccc5d65b6926c704850fdedb9da5e154657a78d9d8490d8ab008cbcd30af7e45805b8b34506d02c1e8fca3f0f02c1afbd0301138a6b3a9111414f67dcea97f2cfcef0b4e67396ac7422e7ad3585e2f937e81c75df6e47f11a711d29c5896fb7620eaa18be1bfc563e4bc6d279209adbc0fe78cd5af41fdda8338807c731b11210592780ec5f60517fa919b54a0d2de57a9f93c99cefa0e03b4dae2af5b0c8ebbb3c83539961172b047eba77d626e169146355210c7d';

function hexToBytes2(hex) {
  var out = [];
  for (var i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}
var SBOX = hexToBytes2(SBOX_HEX);
var INV_SBOX = hexToBytes2(INV_SBOX_HEX);
var MUL = (function () {
  var m = { mul2: [], mul3: [], mul9: [], mul11: [], mul13: [], mul14: [] };
  for (var i = 0; i < 256; i++) {
    var x = i;
    var x2 = ((x << 1) ^ (x & 0x80 ? 0x1b : 0)) & 0xff;
    var x4 = ((x2 << 1) ^ (x2 & 0x80 ? 0x1b : 0)) & 0xff;
    var x8 = ((x4 << 1) ^ (x4 & 0x80 ? 0x1b : 0)) & 0xff;
    m.mul2[i] = x2; m.mul3[i] = (x2 ^ x) & 0xff;
    m.mul9[i] = (x8 ^ x) & 0xff; m.mul11[i] = (x8 ^ x2 ^ x) & 0xff;
    m.mul13[i] = (x8 ^ x4 ^ x) & 0xff; m.mul14[i] = (x8 ^ x4 ^ x2) & 0xff;
  }
  return m;
})();

function expandKey(keyBytes) {
  var nk = Math.floor(keyBytes.length / 4);
  if (nk !== 4 && nk !== 6 && nk !== 8) nk = 4;
  var nr = nk + 6;
  var w = [];
  for (var i = 0; i < nk; i++) w.push(keyBytes.slice(4 * i, 4 * i + 4));
  var rcon = 1;
  for (var j = nk; j < 4 * (nr + 1); j++) {
    var t = w[j - 1].slice();
    if (j % nk === 0) {
      t = [SBOX[t[1]] ^ rcon, SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]];
      rcon = MUL.mul2[rcon];
    } else if (nk === 8 && j % nk === 4) {
      t = [SBOX[t[0]], SBOX[t[1]], SBOX[t[2]], SBOX[t[3]]];
    }
    w.push([w[j - nk][0] ^ t[0], w[j - nk][1] ^ t[1], w[j - nk][2] ^ t[2], w[j - nk][3] ^ t[3]]);
  }
  return { w: w, nr: nr };
}
function keyBytesOf(str) {
  return utf8Bytes(str);
}
function addRoundKey(stateArr, ks, round) {
  for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) stateArr[4 * c + r] ^= ks.w[round * 4 + c][r];
}
function subBytes(stateArr) { for (var i = 0; i < 16; i++) stateArr[i] = SBOX[stateArr[i]]; }
function invSubBytes(stateArr) { for (var i = 0; i < 16; i++) stateArr[i] = INV_SBOX[stateArr[i]]; }
function shiftRows(stateArr) {
  var t = stateArr.slice();
  for (var r = 1; r < 4; r++) for (var c = 0; c < 4; c++) stateArr[4 * c + r] = t[4 * ((c + r) % 4) + r];
}
function invShiftRows(stateArr) {
  var t = stateArr.slice();
  for (var r = 1; r < 4; r++) for (var c = 0; c < 4; c++) stateArr[4 * c + r] = t[4 * ((c - r + 4) % 4) + r];
}
function mixColumns(stateArr) {
  for (var c = 0; c < 4; c++) {
    var a0 = stateArr[4 * c], a1 = stateArr[4 * c + 1], a2 = stateArr[4 * c + 2], a3 = stateArr[4 * c + 3];
    stateArr[4 * c] = MUL.mul2[a0] ^ MUL.mul3[a1] ^ a2 ^ a3;
    stateArr[4 * c + 1] = a0 ^ MUL.mul2[a1] ^ MUL.mul3[a2] ^ a3;
    stateArr[4 * c + 2] = a0 ^ a1 ^ MUL.mul2[a2] ^ MUL.mul3[a3];
    stateArr[4 * c + 3] = MUL.mul3[a0] ^ a1 ^ a2 ^ MUL.mul2[a3];
  }
}
function invMixColumns(stateArr) {
  for (var c = 0; c < 4; c++) {
    var a0 = stateArr[4 * c], a1 = stateArr[4 * c + 1], a2 = stateArr[4 * c + 2], a3 = stateArr[4 * c + 3];
    stateArr[4 * c] = MUL.mul14[a0] ^ MUL.mul11[a1] ^ MUL.mul13[a2] ^ MUL.mul9[a3];
    stateArr[4 * c + 1] = MUL.mul9[a0] ^ MUL.mul14[a1] ^ MUL.mul11[a2] ^ MUL.mul13[a3];
    stateArr[4 * c + 2] = MUL.mul13[a0] ^ MUL.mul9[a1] ^ MUL.mul14[a2] ^ MUL.mul11[a3];
    stateArr[4 * c + 3] = MUL.mul11[a0] ^ MUL.mul13[a1] ^ MUL.mul9[a2] ^ MUL.mul14[a3];
  }
}
function encryptBlock(block, ks) {
  var st8 = block.slice();
  addRoundKey(st8, ks, 0);
  for (var round = 1; round < ks.nr; round++) {
    subBytes(st8); shiftRows(st8); mixColumns(st8); addRoundKey(st8, ks, round);
  }
  subBytes(st8); shiftRows(st8); addRoundKey(st8, ks, ks.nr);
  return st8;
}
function decryptBlock(block, ks) {
  var st8 = block.slice();
  addRoundKey(st8, ks, ks.nr);
  for (var round = ks.nr - 1; round >= 1; round--) {
    invShiftRows(st8); invSubBytes(st8); addRoundKey(st8, ks, round); invMixColumns(st8);
  }
  invShiftRows(st8); invSubBytes(st8); addRoundKey(st8, ks, 0);
  return st8;
}
function pkcs7Pad(bytes) {
  var n = 16 - (bytes.length % 16);
  var out = bytes.slice();
  for (var i = 0; i < n; i++) out.push(n);
  return out;
}
function pkcs7Unpad(bytes) {
  if (!bytes.length) return bytes;
  var n = bytes[bytes.length - 1];
  if (n < 1 || n > 16 || n > bytes.length) return bytes;
  return bytes.slice(0, bytes.length - n);
}
function base64Encode(bytes) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    out += chars.charAt(b0 >> 2);
    out += chars.charAt(((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4));
    out += b1 === undefined ? '=' : chars.charAt(((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6));
    out += b2 === undefined ? '=' : chars.charAt(b2 & 63);
  }
  return out;
}
function base64Decode(str) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  // 保留 '=' 让 indexOf 返回 -1，尾部填充才不会多解出字节
  var clean = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < clean.length; i += 4) {
    var c0 = chars.indexOf(clean.charAt(i));
    var c1 = chars.indexOf(clean.charAt(i + 1));
    var c2 = chars.indexOf(clean.charAt(i + 2));
    var c3 = chars.indexOf(clean.charAt(i + 3));
    out.push((c0 << 2) | (c1 >> 4));
    if (c2 >= 0) out.push(((c1 & 15) << 4) | (c2 >> 2));
    if (c3 >= 0) out.push(((c2 & 3) << 6) | c3);
  }
  return out;
}
function bytesToUtf8(bytes) {
  var out = '', i = 0;
  while (i < bytes.length) {
    var b = bytes[i++];
    if (b < 0x80) out += String.fromCharCode(b);
    else if (b < 0xe0) out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
    else if (b < 0xf0) out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    else {
      var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

function aesCbcEncryptB64(plainText, keyStr) {
  var ks = expandKey128(keyBytesOf(keyStr));
  var iv = keyBytesOf(keyStr);
  var data = pkcs7Pad(utf8Bytes(plainText));
  var prev = iv.slice();
  var out = [];
  for (var off = 0; off < data.length; off += 16) {
    var block = [];
    for (var i = 0; i < 16; i++) block.push(data[off + i] ^ prev[i]);
    var enc = encryptBlock(block, ks);
    for (var j = 0; j < 16; j++) out.push(enc[j]);
    prev = enc;
  }
  return base64Encode(out);
}

function aesCbcDecryptUtf8(b64, keyStr, ivStr) {
  var ks = expandKey(keyBytesOf(keyStr));
  var iv = keyBytesOf(ivStr === undefined || ivStr === null ? keyStr : ivStr);
  var data = base64Decode(b64);
  var prev = iv.slice();
  var out = [];
  for (var off = 0; off < data.length; off += 16) {
    var block = [];
    for (var i = 0; i < 16; i++) block.push(data[off + i]);
    var dec = decryptBlock(block, ks);
    for (var j = 0; j < 16; j++) out.push(dec[j] ^ prev[j]);
    prev = block;
  }
  return bytesToUtf8(pkcs7Unpad(out));
}


// ---------------- 入口 ----------------
var LumeSource = {
  id: 'akmh_video',
  name: '18ak漫画·视频',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://www.18akmanhua.com'],

  async home() {
    var boards = [];
    var plans = [
      { title: '最新视频', categoryId: 'all' },
      { title: '漫画改编', categoryId: 'comic' },
      { title: '真人', categoryId: 'real' },
    ];
    for (var i = 0; i < plans.length; i++) {
      var plan = plans[i];
      try {
        var data = await api('/videoLists', 'page=1&size=' + PAGE_SIZE + '&type=' + typeOf(plan.categoryId));
        var rows = [];
        var list = data && Array.isArray(data.list) ? data.list : [];
        for (var k = 0; k < list.length; k++) {
          var row = rowOf(list[k]);
          if (row) rows.push(row);
        }
        if (rows.length) {
          remember(rows);
          boards.push({ title: plan.title, moreUrl: plan.categoryId, items: rows.slice(0, 12) });
        }
      } catch (error) {
        if (i === 0) throw error;
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口签名或密钥可能变了');
    return boards;
  },

  async categories() {
    return CATEGORIES.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    var keyword = clean(a.keyword);
    if (keyword) throw new Error('这个站的视频没有站内搜索（只有漫画有 /searchBooks）');
    var categoryId = String(a.categoryId == null || a.categoryId === '' ? 'all' : a.categoryId);
    var data = await api('/videoLists', 'page=' + page + '&size=' + PAGE_SIZE + '&type=' + typeOf(categoryId));
    var rows = [];
    var list = data && Array.isArray(data.list) ? data.list : [];
    for (var i = 0; i < list.length; i++) {
      var row = rowOf(list[i]);
      if (row) rows.push(row);
    }
    remember(rows);
    var totalPage = Number(data && data.totalPage) || 0;
    var hasMore = totalPage ? page < totalPage : rows.length >= PAGE_SIZE;
    return { items: rows, hasMore: hasMore };
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var v = await api('/videoDetails', 'id=' + id);
    if (!v || v.id == null) return null;
    var row = rowOf(v);
    if (row) remember([row]);
    var desc = [];
    if (v.price != null) desc.push(Number(v.price) > 0 && !Number(v.is_free) ? '金币 ' + v.price + '（接口层不鉴权，播放地址直发）' : '免费');
    if (v.sales_num) desc.push('已售 ' + v.sales_num);
    if (v.view_num) desc.push('浏览 ' + v.view_num);
    if (v.duration) desc.push('时长 ' + durationText(v.duration));
    desc.push('来源：18ak漫画（' + siteBase() + '）');
    return {
      id: id,
      title: clean(v.title) || id,
      cover: media(v.image),
      subtitle: row ? row.subtitle : '',
      description: desc.join('\n'),
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    return [{ id: 'main', title: '正片' }];
  },

  async content(args) {
    var id = String((args && (args.id || args.chapterId)) || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('缺少视频 ID');
    var v = await api('/videoDetails', 'id=' + id);
    var url = media(v && v.pay_url ? v.pay_url : '');
    if (!url && v && v.preview_url) url = media(v.preview_url);
    if (!url) throw new Error('这条没有播放地址（详情里既没 pay_url 也没 preview_url）');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: siteBase() + '/' },
    };
  },
};
