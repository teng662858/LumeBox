// LumeSource: {"id":"iyf_video","name":"爱壹帆","version":"1.0.1","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.iyf.tv","https://www.aiyifan.tv","https://www.wyav.tv","https://www.flyv.tv","https://www.jssp.tv"],"network":"direct","icon":"https://www.iyf.tv/favicon-32x32.png"}
// LumeRuntime: javascript
//
// 站点：爱壹帆 iyf.tv（站内配置里自带的同内容域名：aiyifan.tv / wyav.tv / flyv.tv / jssp.tv）。
// 形态：Angular SPA，数据全在 `m10.iyf.tv` 上，分两套前缀：
//   /api/*  → list/index、list/FilmType…、list/GetSearchCondition、home/GetPlayRank
//   /v3/*   → video/detail、video/languagesplaylist、video/play
//
// ── 请求签名（本源纯 JS 复现，实测通过）──
//   首页 HTML 里服务端会渲染 `"pConfig":{"publicKey":"…","privateKey":["…"]}`（每次请求都会变）。
//   每个请求的 query 后面要带：`&vv=<md5(publicKey + "&" + query.toLowerCase() + "&" + privateKey[0])>&pub=<publicKey>`。
//   少它 → `{"code":1,"msg":"用户签名错误"}`；带上 → code 0 正常返回。
//
// ── 播放 ──
//   detail(id=<key>) 给 taxis / cid；languagesplaylist(vid=<key>&lsk=0&taxis&cid) 给整季 playList
//   （每集有自己的 key，isVip 标记）；play(id=<每集key>&a=1&lang&usersign=1&region&device&sharpness&line)
//   返回 flvPathList[]（isHls 的 result 就是 m3u8，实测 200 + #EXTM3U，576p/1080p 不同 sharpness）。
//   站点对高频请求回 `{"code":5,"msg":"访问过量"}`，本源每次调用只发一个请求，并在 429/5 时给出可读提示。
//
// ── VIP ──：剧集条目带 charge/vipResource，play 返回 isPreView / isLimitedStream；
//   站点只对「免费篇」下发整片 m3u8，收费篇服务端截断（本源如实提示，不伪造）。

var HOST = 'https://www.iyf.tv';
var API_HOST = 'https://m10.iyf.tv';
// 镜像：只有 www.iyf.tv 实测可用（首页能取到 pConfig、接口签名通过）。
// aiyifan.tv 打开是 200 但页面里没有 pConfig（过不了签名，选了也用不了），已移出；
// wyav.tv / flyv.tv / jssp.tv 是站内配置里列的同内容域名，本机（含代理）连不上，
// 按规则留在 mirrors 供手选，脚本自动解析永远走 www.iyf.tv。
var MIRRORS = [
  'https://www.iyf.tv',
  'https://www.wyav.tv',
  'https://www.flyv.tv',
  'https://www.jssp.tv'
];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
var PAGE_SIZE = 24;

var CATS = [
  { id: 'movie', title: '电影', cid: '0,1,3' },
  { id: 'tv', title: '电视剧', cid: '0,1,4' },
  { id: 'variety', title: '综艺', cid: '0,1,5' },
  { id: 'anime', title: '动漫', cid: '0,1,6' },
  { id: 'documentary', title: '纪录片', cid: '0,1,7' },
  { id: 'rank', title: '排行榜', cid: '' }
];

var REGIONS = ['大陆', '香港', '台湾', '日本', '韩国', '欧美'];
var STATES = [
  { id: '-1', title: '全部' },
  { id: '0', title: '全集' },
  { id: '1', title: '连载中' }
];

function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }
function unescapeHtml(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code)); });
}
function clean(text) {
  return unescapeHtml(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

// ------------------------------------------------------------------ 纯 JS MD5（沙箱没有 crypto）
function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function cmn(q, a, b, x, s, t) {
    a = add32(add32(a, q), add32(x, t));
    return add32((a << s) | (a >>> (32 - s)), b);
  }
  function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
  function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
  function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
  function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
  function md5cycle(x, k) {
    var a = x[0], b = x[1], c = x[2], d = x[3];
    a = ff(a, b, c, d, k[0], 7, -680876936);
    d = ff(d, a, b, c, k[1], 12, -389564586);
    c = ff(c, d, a, b, k[2], 17, 606105819);
    b = ff(b, c, d, a, k[3], 22, -1044525330);
    a = ff(a, b, c, d, k[4], 7, -176418897);
    d = ff(d, a, b, c, k[5], 12, 1200080426);
    c = ff(c, d, a, b, k[6], 17, -1473231341);
    b = ff(b, c, d, a, k[7], 22, -45705983);
    a = ff(a, b, c, d, k[8], 7, 1770035416);
    d = ff(d, a, b, c, k[9], 12, -1958414417);
    c = ff(c, d, a, b, k[10], 17, -42063);
    b = ff(b, c, d, a, k[11], 22, -1990404162);
    a = ff(a, b, c, d, k[12], 7, 1804603682);
    d = ff(d, a, b, c, k[13], 12, -40341101);
    c = ff(c, d, a, b, k[14], 17, -1502002290);
    b = ff(b, c, d, a, k[15], 22, 1236535329);
    a = gg(a, b, c, d, k[1], 5, -165796510);
    d = gg(d, a, b, c, k[6], 9, -1069501632);
    c = gg(c, d, a, b, k[11], 14, 643717713);
    b = gg(b, c, d, a, k[0], 20, -373897302);
    a = gg(a, b, c, d, k[5], 5, -701558691);
    d = gg(d, a, b, c, k[10], 9, 38016083);
    c = gg(c, d, a, b, k[15], 14, -660478335);
    b = gg(b, c, d, a, k[4], 20, -405537848);
    a = gg(a, b, c, d, k[9], 5, 568446438);
    d = gg(d, a, b, c, k[14], 9, -1019803690);
    c = gg(c, d, a, b, k[3], 14, -187363961);
    b = gg(b, c, d, a, k[8], 20, 1163531501);
    a = gg(a, b, c, d, k[13], 5, -1444681467);
    d = gg(d, a, b, c, k[2], 9, -51403784);
    c = gg(c, d, a, b, k[7], 14, 1735328473);
    b = gg(b, c, d, a, k[12], 20, -1926607734);
    a = hh(a, b, c, d, k[5], 4, -378558);
    d = hh(d, a, b, c, k[8], 11, -2022574463);
    c = hh(c, d, a, b, k[11], 16, 1839030562);
    b = hh(b, c, d, a, k[14], 23, -35309556);
    a = hh(a, b, c, d, k[1], 4, -1530992060);
    d = hh(d, a, b, c, k[4], 11, 1272893353);
    c = hh(c, d, a, b, k[7], 16, -155497632);
    b = hh(b, c, d, a, k[10], 23, -1094730640);
    a = hh(a, b, c, d, k[13], 4, 681279174);
    d = hh(d, a, b, c, k[0], 11, -358537222);
    c = hh(c, d, a, b, k[3], 16, -722521979);
    b = hh(b, c, d, a, k[6], 23, 76029189);
    a = hh(a, b, c, d, k[9], 4, -640364487);
    d = hh(d, a, b, c, k[12], 11, -421815835);
    c = hh(c, d, a, b, k[15], 16, 530742520);
    b = hh(b, c, d, a, k[2], 23, -995338651);
    a = ii(a, b, c, d, k[0], 6, -198630844);
    d = ii(d, a, b, c, k[7], 10, 1126891415);
    c = ii(c, d, a, b, k[14], 15, -1416354905);
    b = ii(b, c, d, a, k[5], 21, -57434055);
    a = ii(a, b, c, d, k[12], 6, 1700485571);
    d = ii(d, a, b, c, k[3], 10, -1894986606);
    c = ii(c, d, a, b, k[10], 15, -1051523);
    b = ii(b, c, d, a, k[1], 21, -2054922799);
    a = ii(a, b, c, d, k[8], 6, 1873313359);
    d = ii(d, a, b, c, k[15], 10, -30611744);
    c = ii(c, d, a, b, k[6], 15, -1560198380);
    b = ii(b, c, d, a, k[13], 21, 1309151649);
    a = ii(a, b, c, d, k[4], 6, -145523070);
    d = ii(d, a, b, c, k[11], 10, -1120210379);
    c = ii(c, d, a, b, k[2], 15, 718787259);
    b = ii(b, c, d, a, k[9], 21, -343485551);
    x[0] = add32(a, x[0]); x[1] = add32(b, x[1]);
    x[2] = add32(c, x[2]); x[3] = add32(d, x[3]);
  }
  function md5blk(s) {
    var md5blks = [];
    for (var i = 0; i < 64; i += 4) {
      md5blks[i >> 2] = s.charCodeAt(i) + (s.charCodeAt(i + 1) << 8) +
        (s.charCodeAt(i + 2) << 16) + (s.charCodeAt(i + 3) << 24);
    }
    return md5blks;
  }
  function utf8(str) {
    var out = '';
    var text = String(str == null ? '' : str);
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c < 0x80) out += String.fromCharCode(c);
      else if (c < 0x800) out += String.fromCharCode(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        var next = text.charCodeAt(i + 1);
        var cp = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00);
        out += String.fromCharCode(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63),
          0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        i++;
      } else out += String.fromCharCode(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }
  var s = utf8(input);
  var n = s.length;
  var state = [1732584193, -271733879, -1732584194, 271733878];
  var i;
  var tail;
  for (i = 64; i <= n; i += 64) md5cycle(state, md5blk(s.substring(i - 64, i)));
  s = s.substring(i - 64);
  tail = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  for (i = 0; i < s.length; i++) tail[i >> 2] |= s.charCodeAt(i) << ((i % 4) << 3);
  tail[i >> 2] |= 0x80 << ((i % 4) << 3);
  if (i > 55) {
    md5cycle(state, tail);
    for (i = 0; i < 16; i++) tail[i] = 0;
  }
  tail[14] = n * 8;
  md5cycle(state, tail);
  var hex = '0123456789abcdef';
  var out = '';
  for (i = 0; i < 4; i++) {
    for (var j = 0; j < 4; j++) {
      var byte = (state[i] >> (j * 8)) & 0xff;
      out += hex.charAt((byte >> 4) & 0xf) + hex.charAt(byte & 0xf);
    }
  }
  return out;
}

// ------------------------------------------------------------------ 网络 + 签名
function cacheGet(key) {
  return LumeSource.fs.readText('sign-' + key + '.json').then(function (text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function cacheSet(key, value) {
  return LumeSource.fs.writeText('sign-' + key + '.json', JSON.stringify(value)).catch(function () {});
}
function getHost() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}

// pConfig（publicKey / privateKey）来自站点首页 HTML，每次请求都会变；缓存 20 分钟
function loadConfig() {
  var now = Date.now ? Date.now() : new Date().getTime();
  return cacheGet('pconfig').then(function (cached) {
    if (cached && cached.pub && cached.priv && now - cached.at < 20 * 60 * 1000) return cached;
    return LumeSource.http.request({
      url: getHost() + '/',
      method: 'GET',
      headers: { 'User-Agent': UA, 'Accept': 'text/html', 'Referer': getHost() + '/' }
    }).then(function (reply) {
      var body = reply && reply.body != null ? String(reply.body) : '';
      var m = /"pConfig":\{"publicKey":"([^"]+)","privateKey":\["([^"]+)"\]/.exec(body);
      if (!m) throw new Error('爱壹帆：首页里没有取到 pConfig（站点可能改版）');
      var value = { pub: m[1], priv: m[2], at: now };
      cacheSet('pconfig', value);
      return value;
    });
  });
}

function signedQuery(raw, cfg) {
  // 站点的签名是对「URL 解码后的 query」做 MD5（前端 get_query 会 decodeURIComponent 每个值），
  // 所以哈希用原值、发送时再编码；两者不能混。
  return md5Hex(cfg.pub + '&' + raw.toLowerCase() + '&' + cfg.priv);
}
// params: [['cinema','1'],['cid','0,1,3']] —— 原值传进来，发送时逐项 encodeURIComponent
function buildPair(params) {
  var raw = [];
  var encoded = [];
  for (var i = 0; i < params.length; i++) {
    var k = String(params[i][0]);
    var v = String(params[i][1]);
    raw.push(k + '=' + v);
    encoded.push(enc(k) + '=' + enc(v));
  }
  return { raw: raw.join('&'), encoded: encoded.join('&') };
}

function sleep(ms) {
  return new Promise(function (resolve) {
    if (typeof setTimeout !== 'function') return resolve();
    setTimeout(resolve, ms);
  });
}

function api(prefix, path, params) {
  return apiOnce(prefix, path, params, 0);
}

function apiOnce(prefix, path, params, attempt) {
  return loadConfig().then(function (cfg) {
    var pair = buildPair(params || [['cinema', '1']]);
    var vv = signedQuery(pair.raw, cfg);
    var url = API_HOST + '/' + prefix + '/' + path + '?' + pair.encoded +
      '&vv=' + vv + '&pub=' + cfg.pub;
    return LumeSource.http.request({
      url: url,
      method: 'GET',
      headers: {
        'User-Agent': UA,
        'Accept': 'application/json, text/plain, */*',
        'Origin': getHost(),
        'Referer': getHost() + '/'
      }
    });
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    var body = reply && reply.body != null ? String(reply.body) : '';
    if (!status) throw new Error('连不上爱壹帆（' + API_HOST + '）');
    if (status === 429) throw new Error('爱壹帆：请求太频繁，被限流了，请稍后再试');
    if (status !== 200) throw new Error('爱壹帆接口 HTTP ' + status);
    var data = null;
    try { data = JSON.parse(body); } catch (e) { data = null; }
    if (!data) throw new Error('爱壹帆接口返回的不是 JSON');
    if (data.ret !== 200) throw new Error('爱壹帆接口报错：' + (data.msg || data.ret));
    var payload = data.data || {};
    if (payload.code === 5) {
      // 站点按出口限流：等一会儿重试一次，仍失败再报可读错误
      if (attempt < 1) {
        return sleep(3500).then(function () { return apiOnce(prefix, path, params, attempt + 1); });
      }
      throw new Error('爱壹帆：访问过量（站点限流），请稍后再试');
    }
    if (payload.code === 1) throw new Error('爱壹帆：' + (payload.msg || '用户签名错误'));
    if (payload.code && payload.code !== 0) throw new Error('爱壹帆：' + (payload.msg || ('错误码 ' + payload.code)));
    return payload;
  });
}

function toItem(row) {
  return {
    id: String(row.key),
    title: clean(row.title),
    cover: row.image ? unescapeHtml(row.image) : null,
    subtitle: [row.lastName, row.regional, row.year, row.rating && row.rating !== '0.0' ? row.rating + ' 分' : ''].filter(Boolean).join(' · ')
  };
}

// detail 结果缓存：站点限流很紧，chapters()/detail() 复用同一份，少发一次请求
function readDetailCache(key) {
  return LumeSource.fs.readText('detail-' + key + '.json').then(function (text) {
    if (!text) return null;
    var cached = JSON.parse(text);
    var now = Date.now ? Date.now() : new Date().getTime();
    if (!cached || !cached.row || now - cached.at > 10 * 60 * 1000) return null;
    return cached.row;
  }).catch(function () { return null; });
}
function writeDetailCache(key, row) {
  var now = Date.now ? Date.now() : new Date().getTime();
  return LumeSource.fs.writeText('detail-' + key + '.json', JSON.stringify({ at: now, row: row })).catch(function () {});
}
function fetchDetail(key) {
  return readDetailCache(key).then(function (cached) {
    if (cached) return cached;
    return api('v3', 'video/detail', [
      ['id', key], ['cinema', '1'], ['device', 'desktop'], ['player', 'CkPlayer'],
      ['tech', 'HLS'], ['country', 'HU'], ['lang', 'cns'], ['v', '1']
    ]).then(function (payload) {
      var rows = payload.info || [];
      if (!rows.length) return null;
      writeDetailCache(key, rows[0]);
      return rows[0];
    });
  });
}

var LumeSource = {
  id: 'iyf_video',
  name: '爱壹帆',
  version: '1.0.1',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/favicon-32x32.png',
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '爱壹帆（iyf.tv，另有 aiyifan.tv / wyav.tv / flyv.tv / jssp.tv 同内容域名）。接口在 m10.iyf.tv，每个请求都要站点首页下发的 pConfig 签名（本源已用纯 JS 复现 MD5 签名）。电影/电视剧/综艺/动漫/纪录片 + 排行榜；筛选支持地区与连载状态。站点对高频请求会限流（访问过量），一次操作只发一个请求。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点 /api/list/GetSearchCondition 给的条件里，只有 region（地区）与 isSerial（连载状态）
    // 在 list/index 上实测生效；year / lang 传了会被忽略，所以不列。
    return {
      groups: [
        {
          key: 'region', title: '地区', multiple: false,
          options: REGIONS.map(function (r) { return { id: r, title: r }; })
        },
        {
          key: 'state', title: '状态', multiple: false,
          options: STATES.map(function (s) { return { id: s.id, title: s.title }; })
        }
      ]
    };
  },

  async home() {
    var payload = await api('api', 'list/index',
      [['cinema', '1'], ['page', '1'], ['cid', '0,1,3'], ['size', '18'], ['isn', '0'], ['isfree', '-1']]);
    var list = payload.info || [];
    if (!list.length) throw new Error('爱壹帆：首页没有条目');
    return [{ title: '最新电影', moreUrl: 'movie', items: list.map(toItem).slice(0, 18) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = clean(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    if (keyword) {
      // 搜索：rank 域上的 Solr 简搜（cinema 固定 1，page 从 1 起）
      var found = await api('api', 'list/briefsearch', [
        ['cinema', '1'], ['tags', keyword], ['page', String(page)],
        ['size', String(PAGE_SIZE)], ['orderby', '0'], ['desc', '0']
      ]);
      var list = found.info || found.list || [];
      if (!Array.isArray(list)) list = [];
      return { items: list.map(toItem), hasMore: list.length >= PAGE_SIZE };
    }

    if (category === 'rank') {
      var ranked = await api('api', 'home/GetPlayRank', [['cinema', '1']]);
      var groups = Array.isArray(ranked.info) ? ranked.info : [];
      var out = [];
      for (var g = 0; g < groups.length; g++) {
        var rows = groups[g] && groups[g].rankList ? groups[g].rankList : [];
        for (var r = 0; r < rows.length; r++) {
          var row = rows[r];
          out.push({
            id: String(row.key || row.id || ''),
            title: clean(row.title || row.name || ''),
            cover: row.image ? unescapeHtml(row.image) : null,
            subtitle: [row.regional, row.year].filter(Boolean).join(' · ')
          });
        }
      }
      return { items: out.filter(function (it) { return it.id && it.title; }), hasMore: false };
    }

    var cat = null;
    for (var i = 0; i < CATS.length; i++) if (CATS[i].id === category) cat = CATS[i];
    if (!cat) cat = CATS[0];
    var params = [
      ['cinema', '1'], ['page', String(page)], ['cid', cat.cid],
      ['size', String(PAGE_SIZE)], ['isn', filters.state == null ? '-1' : String(filters.state)],
      ['isfree', '-1']
    ];
    if (filters.region) params.push(['region', String(filters.region)]);
    var payload = await api('api', 'list/index', params);
    var items = (payload.info || []).map(toItem);
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var key = String((argument && argument.id) || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(key)) return null;
    var row = await fetchDetail(key);
    if (!row) return null;
    var bits = [];
    if (row.isSerial && String(row.lastName || '').indexOf('集') >= 0) bits.push('更新 ' + row.lastName);
    else bits.push('正片');
    if (row.regional) bits.push(row.regional);
    if (row.post_Year) bits.push(String(row.post_Year));
    if (row.score && String(row.score).indexOf('暂无') < 0) bits.push(String(row.score));
    var desc = clean(row.contxt || '');
    var directors = row.directors && row.directors.length ? row.directors.map(function (d) { return d.name || d; }).join(' / ') : '';
    var stars = row.stars && row.stars.length ? row.stars.slice(0, 6).map(function (s) { return s.name || s; }).join(' / ') : '';
    if (directors) desc += (desc ? '\n' : '') + '导演：' + directors;
    if (stars) desc += (desc ? '\n' : '') + '主演：' + stars;
    desc += (desc ? '\n\n' : '') + '播放说明：本源用站点签名接口取每集 m3u8 直链（免费篇整片）；收费篇由服务端截断，不伪造。';
    return {
      id: key,
      title: clean(row.title),
      cover: row.imgPath ? unescapeHtml(row.imgPath) : null,
      subtitle: bits.join(' · '),
      description: desc,
      tags: row.tags && row.tags.length ? row.tags.slice(0, 8).map(function (t) { return t.name || t; }) : []
    };
  },

  async chapters(argument) {
    var key = String((argument && argument.id) || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(key)) return [];
    var row = await fetchDetail(key);
    if (!row) throw new Error('爱壹帆上没有这一条');
    var payload = await api('v3', 'video/languagesplaylist', [
      ['vid', key], ['lsk', '0'], ['taxis', String(row.taxis || 0)],
      ['cid', String(row.cid || '')], ['cinema', '1']
    ]);
    var groups = payload.info || [];
    var playList = (groups[0] && groups[0].playList) || [];
    if (!playList.length) {
      // 电影没有分集表：detail 的 key 就是唯一一集
      return [{ id: key, title: '正片' }];
    }
    return playList.map(function (ep) {
      var name = String(ep.name || '');
      var title = /^\d+$/.test(name) ? ('第 ' + name + ' 集') : ('正片（' + name + '）');
      return { id: String(ep.key), title: title + (ep.isVip ? '（VIP）' : '') };
    });
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.chapterId || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(id)) id = String(args.id || args.itemId || '').trim();
    if (!/^[A-Za-z0-9]+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
    var payload = await api('v3', 'video/play', [
      ['id', id], ['cinema', '1'], ['a', '1'], ['lang', 'cns'], ['usersign', '1'],
      ['region', 'GL.'], ['device', '1'], ['isMasterSupport', '0'],
      ['sharpness', '0'], ['line', '0']
    ]);
    var rows = payload.info || [];
    if (!rows.length) throw new Error('爱壹帆没有返回播放信息');
    var row = rows[0];
    if (row.needLogin) throw new Error('这一集需要登录站点才能播放');
    var urls = row.flvPathList || [];
    var hls = [];
    var mp4 = '';
    for (var i = 0; i < urls.length; i++) {
      var it = urls[i];
      var link = String(it.result || it.backup || '');
      if (!/^https?:\/\//i.test(link)) continue;
      if (it.isHls && /\.m3u8/i.test(link)) hls.push({ url: link, title: (it.bitrate || 0) + 'p' });
      else if (!it.isHls && /\.mp4/i.test(link) && !mp4) mp4 = link;
    }
    if (hls.length) {
      return {
        kind: 'video',
        url: hls[0].url,
        qualities: hls,
        headers: { 'User-Agent': UA, 'Referer': getHost() + '/' }
      };
    }
    if (mp4) {
      return { kind: 'video', url: mp4, headers: { 'User-Agent': UA, 'Referer': getHost() + '/' } };
    }
    throw new Error('爱壹帆没有给出可播地址（可能是收费篇，服务端不下发）');
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
