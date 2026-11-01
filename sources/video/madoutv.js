// LumeSource: {"id":"madoutv_video","name":"麻豆TV","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://b5wesi2.xyz"],"network":"direct","settings":[{"key":"note","type":"info","title":"站点说明","description":"麻豆TV（b5wesi2.xyz，umi SPA + spi.d5c4a712.com 后端）：接口全 POST，请求体与响应体都是 AES-256-CBC（key 固定、iv = 前缀+6 位随机 suffix，suffix 同时放请求头），请求还要 md5 签名。60 个频道（麻豆/糖心/蜜桃/天美/SWAG/JVID/日本AV 等），列表接口 /video/listcache 返回 2.5 万条、每页自选条数，条目自带 m3u8 直链；播放为 HLS，带 Referer 可播。不提供搜索。"}]}
// LumeRuntime: javascript
//
// 站点：麻豆TV（https://b5wesi2.xyz）——umi + antd 的 SPA，数据走后端 spi.d5c4a712.com。
// 协议（2026-11-01 实测，用 Chrome CDP 抓到真实请求后逐字段还原）：
//   请求 POST /<接口>，头 `suffix: <6 位随机>`，体 {"post-data": base64(AES-256-CBC(json))}
//        key = Vq234zBeSdGgYXzVTEfnnjjdmaTkk7A4（32 字节）
//        iv  = '-p9B[~PnPs' + suffix（10+6=16 字节），PKCS7
//        明文里必须有 timestamp（毫秒）与 encode_sign
//        encode_sign = md5( 排序后的 "k=v" 以 & 连接 + '&' + SIGN_SALT )
//   响应 {"suffix":"<6 位>","data":"<base64>"}，用响应自带的 suffix 拼 iv 解密。
// 接口：
//   /video/channel  {}                                  → 60 个频道（id/name/total）
//   /video/listcache {page,list_row,type:2,channel?}     → total/per_page/current_page/last_page/data[]
//                                                         条目含 video_url（m3u8 直链）
//   /video/info     {id}                                → 单个作品
// 沙箱没有 atob/Buffer/crypto，所以下面自带纯 JS 的 base64 / UTF-8 / AES-256-CBC / MD5。
// 列表与详情都不需要登录；分类是站点自己的厂牌频道。

var SITE = 'https://b5wesi2.xyz';
var API = 'https://spi.d5c4a712.com';
var AES_KEY = 'Vq234zBeSdGgYXzVTEfnnjjdmaTkk7A4';
var IV_PREFIX = '-p9B[~PnPs';
var SIGN_SALT = 'm}q%ea6:LDcmS?aK)CeF287bPvd99@E,9Up^';
var SUFFIX_CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
var PAGE_SIZE = 24;

var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function b64ToBytes(text) {
  var source = String(text == null ? '' : text).replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  var buffer = 0;
  var bits = 0;
  for (var index = 0; index < source.length; index++) {
    var ch = source.charAt(index);
    if (ch === '=') break;
    var value = B64_CHARS.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function bytesToB64(bytes) {
  var out = '';
  var index = 0;
  while (index < bytes.length) {
    var b0 = bytes[index++] & 0xff;
    var b1 = index < bytes.length ? bytes[index++] & 0xff : -1;
    var b2 = index < bytes.length ? bytes[index++] & 0xff : -1;
    out += B64_CHARS.charAt(b0 >> 2);
    out += B64_CHARS.charAt(((b0 & 0x03) << 4) | (b1 < 0 ? 0 : b1 >> 4));
    out += b1 < 0 ? '=' : B64_CHARS.charAt(((b1 & 0x0f) << 2) | (b2 < 0 ? 0 : b2 >> 6));
    out += b2 < 0 ? '=' : B64_CHARS.charAt(b2 & 0x3f);
  }
  return out;
}

function utf8Bytes(text) {
  var out = [];
  var source = String(text == null ? '' : text);
  for (var index = 0; index < source.length; index++) {
    var code = source.charCodeAt(index);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < source.length) {
      var low = source.charCodeAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        index++;
        var point = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
        continue;
      }
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var index = 0;
  while (index < bytes.length) {
    var first = bytes[index++];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      continue;
    }
    var extra = 0;
    var code = 0;
    if (first >= 0xc0 && first < 0xe0) {
      code = first & 0x1f;
      extra = 1;
    } else if (first >= 0xe0 && first < 0xf0) {
      code = first & 0x0f;
      extra = 2;
    } else if (first >= 0xf0) {
      code = first & 0x07;
      extra = 3;
    } else {
      out += String.fromCharCode(first);
      continue;
    }
    for (var step = 0; step < extra; step++) code = (code << 6) | ((bytes[index + step] || 0) & 0x3f);
    index += extra;
    if (code > 0xffff) {
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

var AES_EXP = new Array(256);
var AES_LOG = new Array(256);
(function buildTables() {
  var x = 1;
  for (var index = 0; index < 255; index++) {
    AES_EXP[index] = x;
    AES_LOG[x] = index;
    x = x ^ (((x << 1) ^ ((x >> 7) * 0x11b)) & 0xff);
  }
  AES_EXP[255] = AES_EXP[0];
})();

function aesMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return AES_EXP[(AES_LOG[a] + AES_LOG[b]) % 255];
}

var AES_SBOX = new Array(256);
var AES_INV_SBOX = new Array(256);
(function buildSbox() {
  for (var index = 0; index < 256; index++) {
    var inverse = index === 0 ? 0 : AES_EXP[(255 - AES_LOG[index]) % 255];
    var rotated = inverse;
    var value = inverse;
    for (var step = 0; step < 4; step++) {
      rotated = ((rotated << 1) | (rotated >> 7)) & 0xff;
      value ^= rotated;
    }
    value ^= 0x63;
    AES_SBOX[index] = value;
    AES_INV_SBOX[value] = index;
  }
})();

var AES_MUL2 = new Array(256);
var AES_MUL3 = new Array(256);
var AES_MUL9 = new Array(256);
var AES_MUL11 = new Array(256);
var AES_MUL13 = new Array(256);
var AES_MUL14 = new Array(256);
(function buildMulTables() {
  for (var index = 0; index < 256; index++) {
    AES_MUL2[index] = aesMul(index, 2);
    AES_MUL3[index] = aesMul(index, 3);
    AES_MUL9[index] = aesMul(index, 9);
    AES_MUL11[index] = aesMul(index, 11);
    AES_MUL13[index] = aesMul(index, 13);
    AES_MUL14[index] = aesMul(index, 14);
  }
})();

function aesExpandKey(keyBytes) {
  var nk = keyBytes.length / 4;
  var rounds = nk + 6;
  var words = 4 * (rounds + 1);
  var schedule = new Array(words * 4);
  var index;
  for (index = 0; index < keyBytes.length; index++) schedule[index] = keyBytes[index];
  var rcon = 1;
  for (index = nk; index < words; index++) {
    var t0 = schedule[(index - 1) * 4];
    var t1 = schedule[(index - 1) * 4 + 1];
    var t2 = schedule[(index - 1) * 4 + 2];
    var t3 = schedule[(index - 1) * 4 + 3];
    if (index % nk === 0) {
      var swap = t0;
      t0 = AES_SBOX[t1] ^ rcon;
      t1 = AES_SBOX[t2];
      t2 = AES_SBOX[t3];
      t3 = AES_SBOX[swap];
      rcon = aesMul(rcon, 2);
    } else if (nk > 6 && index % nk === 4) {
      t0 = AES_SBOX[t0];
      t1 = AES_SBOX[t1];
      t2 = AES_SBOX[t2];
      t3 = AES_SBOX[t3];
    }
    schedule[index * 4] = schedule[(index - nk) * 4] ^ t0;
    schedule[index * 4 + 1] = schedule[(index - nk) * 4 + 1] ^ t1;
    schedule[index * 4 + 2] = schedule[(index - nk) * 4 + 2] ^ t2;
    schedule[index * 4 + 3] = schedule[(index - nk) * 4 + 3] ^ t3;
  }
  return { schedule: schedule, rounds: rounds };
}

function aesEncryptBlock(block, expanded) {
  var state = block.slice();
  var index;
  var round;
  for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[index];
  for (round = 1; round <= expanded.rounds; round++) {
    for (index = 0; index < 16; index++) state[index] = AES_SBOX[state[index]];
    var shifted = new Array(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) shifted[row + 4 * col] = state[row + 4 * ((col + row) % 4)];
    }
    state = shifted;
    if (round !== expanded.rounds) {
      for (var c = 0; c < 4; c++) {
        var base = 4 * c;
        var a0 = state[base];
        var a1 = state[base + 1];
        var a2 = state[base + 2];
        var a3 = state[base + 3];
        state[base] = AES_MUL2[a0] ^ AES_MUL3[a1] ^ a2 ^ a3;
        state[base + 1] = a0 ^ AES_MUL2[a1] ^ AES_MUL3[a2] ^ a3;
        state[base + 2] = a0 ^ a1 ^ AES_MUL2[a2] ^ AES_MUL3[a3];
        state[base + 3] = AES_MUL3[a0] ^ a1 ^ a2 ^ AES_MUL2[a3];
      }
    }
    for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[round * 16 + index];
  }
  return state;
}

function aesInvShiftRows(state) {
  for (var row = 1; row < 4; row++) {
    var tmp = [state[row], state[row + 4], state[row + 8], state[row + 12]];
    for (var col = 0; col < 4; col++) state[row + 4 * ((col + row) % 4)] = tmp[col];
  }
}

function aesInvMixColumns(state) {
  for (var col = 0; col < 4; col++) {
    var base = 4 * col;
    var a0 = state[base];
    var a1 = state[base + 1];
    var a2 = state[base + 2];
    var a3 = state[base + 3];
    state[base] = AES_MUL14[a0] ^ AES_MUL11[a1] ^ AES_MUL13[a2] ^ AES_MUL9[a3];
    state[base + 1] = AES_MUL9[a0] ^ AES_MUL14[a1] ^ AES_MUL11[a2] ^ AES_MUL13[a3];
    state[base + 2] = AES_MUL13[a0] ^ AES_MUL9[a1] ^ AES_MUL14[a2] ^ AES_MUL11[a3];
    state[base + 3] = AES_MUL11[a0] ^ AES_MUL13[a1] ^ AES_MUL9[a2] ^ AES_MUL14[a3];
  }
}

function aesDecryptBlock(block, expanded) {
  var state = block.slice();
  var index;
  for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[expanded.rounds * 16 + index];
  for (var round = expanded.rounds - 1; round >= 1; round--) {
    aesInvShiftRows(state);
    for (index = 0; index < 16; index++) state[index] = AES_INV_SBOX[state[index]];
    for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[round * 16 + index];
    aesInvMixColumns(state);
  }
  aesInvShiftRows(state);
  for (index = 0; index < 16; index++) state[index] = AES_INV_SBOX[state[index]];
  for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[index];
  return state;
}

function aesCbcDecrypt(data, keyBytes, ivBytes) {
  var expanded = aesExpandKey(keyBytes);
  var previous = ivBytes.slice(0, 16);
  var plain = [];
  for (var offset = 0; offset + 16 <= data.length; offset += 16) {
    var block = data.slice(offset, offset + 16);
    var decoded = aesDecryptBlock(block, expanded);
    for (var index = 0; index < 16; index++) plain.push(decoded[index] ^ previous[index]);
    previous = block;
  }
  var pad = plain.length ? plain[plain.length - 1] : 0;
  if (pad > 0 && pad <= 16 && pad <= plain.length) plain = plain.slice(0, plain.length - pad);
  return plain;
}

function aesCbcEncrypt(plainBytes, keyBytes, ivBytes) {
  var expanded = aesExpandKey(keyBytes);
  var previous = ivBytes.slice(0, 16);
  var data = plainBytes.slice();
  var pad = 16 - (data.length % 16);
  for (var p = 0; p < pad; p++) data.push(pad);
  var out = [];
  for (var offset = 0; offset < data.length; offset += 16) {
    var block = data.slice(offset, offset + 16);
    for (var index = 0; index < 16; index++) block[index] ^= previous[index];
    var encoded = aesEncryptBlock(block, expanded);
    for (var k = 0; k < 16; k++) out.push(encoded[k]);
    previous = encoded;
  }
  return out;
}

// 自写 md5（沙箱无 crypto，也不依赖别的源里可能被切坏的实现）
function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function rol(v, s) { return (v << s) | (v >>> (32 - s)); }
  var bytes = utf8Bytes(String(input == null ? '' : input));
  var bitLen = bytes.length * 8;
  var padded = bytes.slice();
  padded.push(0x80);
  while (padded.length % 64 !== 56) padded.push(0);
  var hi = Math.floor(bitLen / 4294967296);
  var lo = bitLen >>> 0;
  padded.push(lo & 0xff, (lo >>> 8) & 0xff, (lo >>> 16) & 0xff, (lo >>> 24) & 0xff);
  padded.push(hi & 0xff, (hi >>> 8) & 0xff, (hi >>> 16) & 0xff, (hi >>> 24) & 0xff);

  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  var K = [];
  for (var k = 0; k < 64; k++) K[k] = Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0;

  for (var offset = 0; offset < padded.length; offset += 64) {
    var m = [];
    for (var w = 0; w < 16; w++) {
      m[w] = (padded[offset + w * 4] | (padded[offset + w * 4 + 1] << 8) |
        (padded[offset + w * 4 + 2] << 16) | (padded[offset + w * 4 + 3] << 24)) >>> 0;
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (var i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D;
      D = C;
      C = B;
      B = add32(B, rol(add32(add32(A, F & 0xffffffff), add32(K[i], m[g])), S[i]));
      A = tmp;
    }
    a0 = add32(a0, A);
    b0 = add32(b0, B);
    c0 = add32(c0, C);
    d0 = add32(d0, D);
  }

  function hex32(value) {
    var out = '';
    for (var j = 0; j < 4; j++) {
      var byte = (value >>> (j * 8)) & 0xff;
      out += ('0' + byte.toString(16)).slice(-2);
    }
    return out;
  }
  return hex32(a0) + hex32(b0) + hex32(c0) + hex32(d0);
}

/* ───────────── 接口协议 ───────────── */

function randomSuffix() {
  var out = '';
  for (var i = 0; i < 6; i++) out += SUFFIX_CHARS.charAt(Math.floor(Math.random() * SUFFIX_CHARS.length));
  return out;
}

// 明文参与签名：过滤掉 undefined / null / 空串，键值按 "k=v" 拼、整体排序后再加盐 md5
function signOf(payload) {
  var pairs = [];
  Object.keys(payload).forEach(function (key) {
    var value = payload[key];
    if (value === undefined || value === null || value === '') return;
    pairs.push(key + '=' + value);
  });
  pairs.sort();
  return md5Hex(pairs.join('&') + '&' + SIGN_SALT);
}

function decodeBody(raw) {
  var outer = JSON.parse(raw);
  if (!outer || !outer.data || !outer.suffix) throw new Error('接口返回格式异常');
  var plain = utf8Decode(aesCbcDecrypt(b64ToBytes(outer.data), utf8Bytes(AES_KEY), utf8Bytes(IV_PREFIX + outer.suffix)));
  return JSON.parse(plain);
}

async function postApi(path, data) {
  var payload = {};
  Object.keys(data || {}).forEach(function (k) { payload[k] = data[k]; });
  payload.timestamp = Date.now();
  payload.encode_sign = signOf(payload);

  var suffix = randomSuffix();
  var cipher = aesCbcEncrypt(utf8Bytes(JSON.stringify(payload)), utf8Bytes(AES_KEY), utf8Bytes(IV_PREFIX + suffix));
  var body = JSON.stringify({ 'post-data': bytesToB64(cipher) });

  var res = await LumeSource.http.post(API + path, body, {
    headers: {
      'Content-Type': 'application/json',
      suffix: suffix,
      Origin: SITE,
      Referer: SITE + '/'
    }
  });
  if (!res || res.status < 200 || res.status >= 300) throw new Error('接口请求失败 HTTP ' + (res && res.status));
  var parsed = decodeBody(res.body);
  if (Number(parsed.code) !== 0) throw new Error('接口返回错误：' + (parsed.msg || parsed.code));
  return parsed;
}

/* ───────────── 数据整理 ───────────── */

var known = {};

function textOf(value) { return value === undefined || value === null ? '' : String(value); }

function rowOf(v) {
  var id = textOf(v.id);
  if (!id) return null;
  var title = textOf(v.title).replace(/\s+/g, ' ').trim();
  if (!title) return null;
  var cover = textOf(v.thumb) || textOf(v.preview);
  known[id] = { url: textOf(v.video_url), referer: SITE + '/' };
  return {
    id: id,
    title: title,
    cover: cover,
    subtitle: textOf(v.comefrom_title)
  };
}

function mediaOf(v) {
  var url = textOf(v.video_url);
  if (url) return url;
  var test = textOf(v.test_video_url);
  return /\.(?:m3u8|mp4)(?:[?#]|$)/i.test(test) ? test : '';
}

/* ───────────── 五个入口 ───────────── */

var LumeSource = {
  id: 'madoutv_video',
  name: '麻豆TV',
  version: '1.0.0',
  category: 'video',

  async categories() {
    var res = await postApi('/video/channel', {});
    var rows = res.data || [];
    return [{ id: 'all', title: '全部' }].concat(rows.map(function (c) {
      return { id: String(c.id), title: textOf(c.name) || ('频道 ' + c.id) };
    }));
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var result = await this.list({ page: 1 });
    return result.items;
  },

  async list(args) {
    var a = args || {};
    if (a.keyword) throw new Error('该接口未提供搜索，请用分类浏览');
    if (a.filters && Object.keys(a.filters).length) throw new Error('该接口未提供筛选规则');
    var page = Math.max(1, Number(a.page) || 1);
    var payload = { page: page, list_row: PAGE_SIZE, type: 2 };
    if (a.categoryId && String(a.categoryId) !== 'all') payload.channel = String(a.categoryId);

    var res = await postApi('/video/listcache', payload);
    var body = res.data || {};
    var rows = body.data || [];
    var items = [];
    rows.forEach(function (v) { var row = rowOf(v); if (row) items.push(row); });
    if (!items.length && page === 1) throw new Error('该分类没有返回条目');
    return {
      items: items,
      hasMore: Number(body.current_page || page) < Number(body.last_page || 0)
    };
  },

  async detail(a) {
    var id = String((a && a.id) || '');
    if (!id) return null;
    var res = await postApi('/video/info', { id: id });
    var v = res.data || {};
    return {
      id: String(v.id || id),
      title: textOf(v.title).replace(/\s+/g, ' ').trim() || id,
      cover: textOf(v.thumb) || textOf(v.preview),
      description: textOf(v.description)
    };
  },

  async chapters(a) {
    var id = String((a && a.id) || '');
    return [{ id: id, title: '播放' }];
  },

  async content(a) {
    var id = String((a && a.id) || '');
    var row = known[id];
    var url = row && row.url ? row.url : '';
    if (!url) {
      var res = await postApi('/video/info', { id: id });
      var v = res.data || {};
      url = mediaOf(v);
      if (url) known[id] = { url: url, referer: SITE + '/' };
    }
    if (!url) throw new Error('该条目没有公开播放地址（可能需要登录或该片已下架）');
    return { kind: 'video', url: url, headers: { Referer: SITE + '/' } };
  }
};
