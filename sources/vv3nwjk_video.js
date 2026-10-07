// LumeSource: {"id":"vv3nwjk_video","name":"金牌影院","version":"1.0.1","category":"video"}

// 站点：https://www.vv3nwjk.com （Next.js + 自建 JSON API）
//
// ⚠️ 重要现状（2026-10-08 复测，务必先读）：
//   站点整站（HTML 与 `/api/mw-movie/**` 一并）挂在 **OKooK-CDN 的
//   Google reCAPTCHA v3 WAF** 后面。未过验证的客户端（浏览器外的任何
//   HTTP 客户端：curl / Node / Dart / 本 App 的网络层都一样）会收到
//   `521`，响应体是一个「跳转到自身并带 waf_captcha_marker」的脚本，
//   随后弹出人机验证页；只有真实浏览器执行 reCAPTCHA v3、再命中
//   `/okokcdn_recaptcha_verify` 通过后，才会被放行。
//
//   验证结论（都实测过）：
//     - 不是 TLS/JA3 指纹问题：用 curl_cffi 模拟 chrome/safari/firefox
//       全部 521；反而是带 Electron UA 的真实浏览器能过。
//     - 不是 Cookie 问题：浏览器 `document.cookie` 里**没有任何鉴权
//       Cookie**，`credentials:'omit'`（完全不带 Cookie）在浏览器里也能
//       拿到 200；而把浏览器会话的 Cookie 拷给 curl 仍然 521。
//     - 也就是：放行状态绑在「完成验证的会话 + 服务端 IP/会话信誉」上，
//       既不落在可读 Cookie 上，也无法靠 HTTP 客户端复现。
//
//   → **因此本脚本在 LumeBox 沙箱里直连会稳定拿到 `521`。** 沙箱没有任
//     何能力去解 reCAPTCHA（无浏览器、无 WebAssembly、无法执行验证页
//     脚本）。脚本对 521 给出了点名到原因的提示，方便用户判断。
//     若要让本源真正可用，需要在同一网络环境放一个「已过 WAF 的代理/
//     桥接」并改下面 BASE 指向它（见 docs/lumesource-guide.md 附录 B）。
//
// 下面这些是**已独立验证**的部分，一旦 WAF 被绕开（或通过可用代理转发）
// 即可直接工作：
//   2. API 前缀 `/api/mw-movie`，公共接口都在 `/anonymous/**` 下，需要一个
//      `sign` 头。签名算法（从站点 www.vv3nwjk.com 的 Next.js chunk 里还原、
//      并用线上真实请求逐个核对过）是：
//        t   = Date.now()
//        g   = GET：参数按 key 升序拼 `k=v&k=v`；POST：JSON.stringify(参数)
//              （参数为空时 g 为空串）
//        h   = (g ? g + '&' : '') + 'key=' + SIGN_KEY + '&t=' + t
//        sign = sha1(md5(h))            // 十六进制小写
//      SIGN_KEY 是前端内置常量：cb808529bae6b6be45ecfab29a4889bc
//   3. 请求还要带 `client-type: 1`、`deviceId`（一个稳定的 UUID）。
//      未登录时 `authorization` 传空串即可（实测可用）。
//
// 沙箱里没有 Node 的 crypto、也没有 atob，MD5 / SHA1 都在本脚本内用纯 JS 实现
// （下方 __md5 / __sha1）。哈希实现经过标准测试向量校验（abc 等）。
//
// 接口一览（均需上面那套头）：
//   GET  /anonymous/get/filer/type                      -> 顶级分类（电影/电视剧/…）
//   GET  /anonymous/get/filer/getClassByType?type1=     -> 某分类的筛选项（剧情/演员…）
//   GET  /anonymous/v1/home/all/list                    -> 首页各板块
//   GET  /anonymous/video/list?type1=&typeId=&page=&pageSize=  -> 分类列表（分页）
//   GET  /anonymous/video/searchByWordPageable?keyword=&page=&pageSize= -> 搜索
//   GET  /anonymous/video/detail?id=                    -> 详情 + episodeList
//   GET  /anonymous/v2/video/episode/url?clientType=1&id=&nid= -> 播放地址（多清晰度）
//   GET  /anonymous/v1/rank/all                          -> 排行榜

var SITE_URL = 'https://www.vv3nwjk.com';
var API_URL = SITE_URL + '/api/mw-movie';
var SIGN_KEY = 'cb808529bae6b6be45ecfab29a4889bc';
var PAGE_SIZE = 24;
var DEVICE_KEY = 'vv3nwjk/device-id';

var LumeSource = {
  id: 'vv3nwjk_video',
  name: '金牌影院',
  version: '1.0.1',
  category: 'video',

  async categories() {
    var types = await this.__api('/anonymous/get/filer/type', {});
    var list = types && Array.isArray(types.data) ? types.data : [];
    var result = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i] || {};
      result.push({
        id: String(item.typeId),
        title: String(item.typeName || item.typeId)
      });
    }
    if (!result.length) {
      result = [
        { id: '1', title: '电影' },
        { id: '2', title: '电视剧' },
        { id: '3', title: '综艺' },
        { id: '4', title: '动漫' },
        { id: '88', title: '短剧' }
      ];
    }
    return result;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';

    if (keyword) return await this.__search(keyword, page);
    if (!category || category === 'all') category = '1';

    var response = await this.__api('/anonymous/video/list', {
      clientType: '1',
      type1: category,
      page: page,
      pageSize: PAGE_SIZE
    });
    var payload = response && response.data ? response.data : {};
    var raw = Array.isArray(payload.list) ? payload.list : [];
    var items = [];
    for (var i = 0; i < raw.length; i++) items.push(this.__toItem(raw[i]));
    var total = Number(payload.totalCount) || 0;
    var hasMore = raw.length >= PAGE_SIZE && (total === 0 || page * PAGE_SIZE < total);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var response = await this.__api('/anonymous/video/detail', {
      clientType: '1',
      id: id
    });
    var info = response && response.data ? response.data : null;
    if (!info) return null;
    return {
      id: String(info.vodId != null ? info.vodId : id),
      title: String(info.vodName || id),
      cover: info.vodPic || '',
      subtitle: this.__remark(info),
      description: this.__clean(info.vodContent || info.vodBlurb || ''),
      tags: this.__tags(info),
      extra: {
        year: info.vodYear || info.vodPubdate || '',
        area: info.vodArea || '',
        actors: info.vodActor || '',
        director: info.vodDirector || '',
        score: info.vodDoubanScore || info.vodScore || ''
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var response = await this.__api('/anonymous/video/detail', {
      clientType: '1',
      id: id
    });
    var info = response && response.data ? response.data : {};
    var episodes = Array.isArray(info.episodeList) ? info.episodeList : [];
    var chapters = [];
    for (var i = 0; i < episodes.length; i++) {
      var ep = episodes[i] || {};
      if (ep.nid == null) continue;
      var name = String(ep.name || '').trim();
      chapters.push({
        id: String(ep.nid),
        title: name || ('第' + (i + 1) + '集')
      });
    }
    return chapters;
  },

  async content(argument) {
    var id = this.__id(argument);
    var nid = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!nid) throw new Error('金牌影院：缺少剧集 ID（请先选择一集）');

    var response = await this.__api('/anonymous/v2/video/episode/url', {
      clientType: '1',
      id: id,
      nid: nid
    });
    var payload = response && response.data ? response.data : {};
    var list = Array.isArray(payload.list) ? payload.list : [];
    if (!list.length) throw new Error('金牌影院：该剧集暂无播放地址');

    // 多清晰度：图源给什么就列什么，播放器只消费 label + url。
    var qualities = [];
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {};
      var url = entry.url ? String(entry.url) : '';
      if (!url) continue;
      var label = String(entry.resolutionName || '').trim();
      if (!label && entry.resolution) label = String(entry.resolution) + 'P';
      if (!label) label = '线路 ' + (i + 1);
      qualities.push({ label: label, url: url });
    }
    if (!qualities.length) throw new Error('金牌影院：该剧集没有可用的播放地址');

    // 优先选标清（480P，无需登录即可直连；高清晰度地址同样返回，
    // 留给播放器的「清晰度」开关，由用户按需切换）。
    var chosen = qualities[0];
    for (var j = 0; j < qualities.length; j++) {
      if (qualities[j].label.indexOf('480') >= 0) { chosen = qualities[j]; break; }
    }
    return {
      kind: 'video',
      url: chosen.url,
      headers: { 'Referer': SITE_URL + '/', 'User-Agent': 'Mozilla/5.0' },
      qualities: qualities
    };
  },

  // ---------------------------------------------------------------- 内部工具

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.vodId != null) id = String(argument.vodId);
    if (!id) throw new Error('金牌影院：缺少视频 ID');
    return id;
  },

  __toItem(item) {
    item = item || {};
    return {
      id: String(item.vodId != null ? item.vodId : item.id),
      title: String(item.vodName || item.vodId || ''),
      cover: item.vodPic || '',
      subtitle: this.__remark(item)
    };
  },

  __remark(item) {
    var parts = [];
    if (item.vodRemarks) parts.push(String(item.vodRemarks));
    if (item.vodScore || item.vodDoubanScore) {
      parts.push('评分 ' + (item.vodScore || item.vodDoubanScore));
    }
    if (item.vodVersion) parts.push(String(item.vodVersion));
    if (!parts.length && item.vodTotal) parts.push('共 ' + item.vodTotal + ' 集');
    return parts.join(' · ');
  },

  __tags(info) {
    var raw = String(info.vodClass || '').split(',');
    var tags = [];
    for (var i = 0; i < raw.length; i++) {
      var text = raw[i].trim();
      if (text) tags.push(text);
    }
    return tags;
  },

  __clean(html) {
    return String(html || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/\s+/g, ' ')
      .trim();
  },

  async __search(keyword, page) {
    var response = await this.__api('/anonymous/video/searchByWordPageable', {
      clientType: '1',
      keyword: keyword,
      page: page,
      pageSize: PAGE_SIZE
    });
    var payload = response && response.data ? response.data : {};
    var raw = Array.isArray(payload.list) ? payload.list : [];
    var items = [];
    for (var i = 0; i < raw.length; i++) items.push(this.__toItem(raw[i]));
    var total = Number(payload.totalCount) || 0;
    var hasMore = raw.length >= PAGE_SIZE && (total === 0 || page * PAGE_SIZE < total);
    return { items: items, hasMore: hasMore };
  },

  // 所有接口唯一的出口：拼签名头、发请求、解析 JSON 外壳。
  async __api(path, params) {
    var deviceId = await this.__deviceId();
    var t = new Date().getTime();
    var sign = this.__sign(params, t);

    var query = this.__query(params);
    var url = API_URL + path + (query ? '?' + query : '');

    var response = await LumeSource.http.get(url, {
      headers: {
        'Accept': 'application/json, text/plain, */*',
        'client-type': '1',
        'deviceId': deviceId,
        'authorization': '',
        'sign': sign,
        't': String(t),
        'Referer': SITE_URL + '/'
      }
    });
    if (!response || response.status !== 200) {
      var status = response ? response.status : 0;
      // 站点在生产环境启用了 reCAPTCHA v3 的 WAF：未过验证时整站（含 API）
      // 返回 521。沙箱里没有浏览器，跑不出这段验证，如实告诉用户原因与出路。
      if (status === 521) {
        throw new Error(
          '金牌影院：站点启用了人机验证（reCAPTCHA v3 WAF，HTTP 521）。' +
          '本 App 无法在脚本沙箱里完成验证；请改用网页/浏览器访问该站，' +
          '或为它配置一个已经通过验证的代理地址后再试。'
        );
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + path);
    }
    // 极少数情况下 WAF 会以 200 返回验证页（HTML 而非 JSON），一并点明。
    if (/waf_captcha_marker|okokcdn_recaptcha_verify/.test(response.body || '')) {
      throw new Error(
        '金牌影院：请求被站点的人机验证（reCAPTCHA v3 WAF）拦截，' +
        '无法在脚本沙箱内完成验证。请改用网页访问，或配置已过验证的代理。'
      );
    }
    var parsed;
    try {
      parsed = JSON.parse(response.body || '{}');
    } catch (error) {
      throw new Error('金牌影院返回的不是合法 JSON：' + path);
    }
    if (parsed && parsed.code != null && Number(parsed.code) !== 200) {
      throw new Error('金牌影院接口错误：' + (parsed.msg || parsed.code) + ' ' + path);
    }
    return parsed;
  },

  // 稳定设备号：一台设备只生成一次，存在沙盒存储里（站点的 deviceId 只是
  // 一个客户端标识，不需要跨设备一致；但同一台设备内保持一致最稳妥）。
  async __deviceId() {
    try {
      var saved = await LumeSource.fs.readText(DEVICE_KEY);
      if (saved) return saved;
    } catch (error) { /* 读不到就重新生成 */ }
    var id = this.__uuid();
    try { await LumeSource.fs.writeText(DEVICE_KEY, id); } catch (error) { /* 存不下也能用 */ }
    return id;
  },

  __uuid() {
    var chars = '0123456789abcdef';
    var out = '';
    for (var i = 0; i < 32; i++) {
      out += chars.charAt(Math.floor(Math.random() * 16));
    }
    return out.slice(0, 8) + '-' + out.slice(8, 12) + '-' + out.slice(12, 16)
      + '-' + out.slice(16, 20) + '-' + out.slice(20, 32);
  },

  // GET：参数按 key 升序拼 `k=v&k=v`（与站点一致）。
  __query(params) {
    var keys = Object.keys(params || {}).sort();
    var parts = [];
    for (var i = 0; i < keys.length; i++) {
      parts.push(encodeURIComponent(keys[i]) + '=' + encodeURIComponent(params[keys[i]]));
    }
    return parts.join('&');
  },

  __sign(params, t) {
    var keys = Object.keys(params || {}).sort();
    var parts = [];
    for (var i = 0; i < keys.length; i++) {
      parts.push(keys[i] + '=' + params[keys[i]]);
    }
    var g = parts.join('&');
    var h = (g ? g + '&' : '') + 'key=' + SIGN_KEY + '&t=' + t;
    return this.__sha1(this.__md5(h));
  },

  // ---------------------------------------------------------------- 哈希
  // 纯 JS 的 MD5 / SHA1，输出十六进制小写。QuickJS 沙箱没有 Node 的 crypto，
  // 也没有 atob，所以这两个必须自带。已用标准测试向量校验。

  __md5(str) {
    function add32(a, b) { return (a + b) & 0xFFFFFFFF; }
    function rotl(n, c) { return ((n << c) | (n >>> (32 - c))) >>> 0; }
    function cmn(q, a, b, x, s, t) {
      a = add32(add32(a, q), add32(x, t));
      return add32(rotl(a, s), b);
    }
    function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
    function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
    function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
    function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
    function hexLE(v) {
      var s = '';
      for (var i = 0; i < 4; i++) s += ('0' + ((v >>> (i * 8)) & 255).toString(16)).slice(-2);
      return s;
    }

    var bytes = this.__utf8Bytes(str);
    var n = bytes.length;
    var total = ((n + 8) >> 6 << 4) + 16;
    var x = [];
    var z;
    for (z = 0; z < total; z++) x[z] = 0;
    for (z = 0; z < n; z++) x[z >> 2] |= bytes[z] << ((z % 4) * 8);
    x[n >> 2] |= 0x80 << ((n % 4) * 8);
    x[total - 2] = n * 8;

    var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
    for (z = 0; z < total; z += 16) {
      var oa = a, ob = b, oc = c, od = d;
      a = ff(a, b, c, d, x[z], 7, -680876936); d = ff(d, a, b, c, x[z + 1], 12, -389564586);
      c = ff(c, d, a, b, x[z + 2], 17, 606105819); b = ff(b, c, d, a, x[z + 3], 22, -1044525330);
      a = ff(a, b, c, d, x[z + 4], 7, -176418897); d = ff(d, a, b, c, x[z + 5], 12, 1200080426);
      c = ff(c, d, a, b, x[z + 6], 17, -1473231341); b = ff(b, c, d, a, x[z + 7], 22, -45705983);
      a = ff(a, b, c, d, x[z + 8], 7, 1770035416); d = ff(d, a, b, c, x[z + 9], 12, -1958414417);
      c = ff(c, d, a, b, x[z + 10], 17, -42063); b = ff(b, c, d, a, x[z + 11], 22, -1990404162);
      a = ff(a, b, c, d, x[z + 12], 7, 1804603682); d = ff(d, a, b, c, x[z + 13], 12, -40341101);
      c = ff(c, d, a, b, x[z + 14], 17, -1502002290); b = ff(b, c, d, a, x[z + 15], 22, 1236535329);
      a = gg(a, b, c, d, x[z + 1], 5, -165796510); d = gg(d, a, b, c, x[z + 6], 9, -1069501632);
      c = gg(c, d, a, b, x[z + 11], 14, 643717713); b = gg(b, c, d, a, x[z], 20, -373897302);
      a = gg(a, b, c, d, x[z + 5], 5, -701558691); d = gg(d, a, b, c, x[z + 10], 9, 38016083);
      c = gg(c, d, a, b, x[z + 15], 14, -660478335); b = gg(b, c, d, a, x[z + 4], 20, -405537848);
      a = gg(a, b, c, d, x[z + 9], 5, 568446438); d = gg(d, a, b, c, x[z + 14], 9, -1019803690);
      c = gg(c, d, a, b, x[z + 3], 14, -187363961); b = gg(b, c, d, a, x[z + 8], 20, 1163531501);
      a = gg(a, b, c, d, x[z + 13], 5, -1444681467); d = gg(d, a, b, c, x[z + 2], 9, -51403784);
      c = gg(c, d, a, b, x[z + 7], 14, 1735328473); b = gg(b, c, d, a, x[z + 12], 20, -1926607734);
      a = hh(a, b, c, d, x[z + 5], 4, -378558); d = hh(d, a, b, c, x[z + 8], 11, -2022574463);
      c = hh(c, d, a, b, x[z + 11], 16, 1839030562); b = hh(b, c, d, a, x[z + 14], 23, -35309556);
      a = hh(a, b, c, d, x[z + 1], 4, -1530992060); d = hh(d, a, b, c, x[z + 4], 11, 1272893353);
      c = hh(c, d, a, b, x[z + 7], 16, -155497632); b = hh(b, c, d, a, x[z + 10], 23, -1094730640);
      a = hh(a, b, c, d, x[z + 13], 4, 681279174); d = hh(d, a, b, c, x[z], 11, -358537222);
      c = hh(c, d, a, b, x[z + 3], 16, -722521979); b = hh(b, c, d, a, x[z + 6], 23, 76029189);
      a = hh(a, b, c, d, x[z + 9], 4, -640364487); d = hh(d, a, b, c, x[z + 12], 11, -421815835);
      c = hh(c, d, a, b, x[z + 15], 16, 530742520); b = hh(b, c, d, a, x[z + 2], 23, -995338651);
      a = ii(a, b, c, d, x[z], 6, -198630844); d = ii(d, a, b, c, x[z + 7], 10, 1126891415);
      c = ii(c, d, a, b, x[z + 14], 15, -1416354905); b = ii(b, c, d, a, x[z + 5], 21, -57434055);
      a = ii(a, b, c, d, x[z + 12], 6, 1700485571); d = ii(d, a, b, c, x[z + 3], 10, -1894986606);
      c = ii(c, d, a, b, x[z + 10], 15, -1051523); b = ii(b, c, d, a, x[z + 1], 21, -2054922799);
      a = ii(a, b, c, d, x[z + 8], 6, 1873313359); d = ii(d, a, b, c, x[z + 15], 10, -30611744);
      c = ii(c, d, a, b, x[z + 6], 15, -1560198380); b = ii(b, c, d, a, x[z + 13], 21, 1309151649);
      a = ii(a, b, c, d, x[z + 4], 6, -145523070); d = ii(d, a, b, c, x[z + 11], 10, -1120210379);
      c = ii(c, d, a, b, x[z + 2], 15, 718787259); b = ii(b, c, d, a, x[z + 9], 21, -343485551);
      a = add32(a, oa); b = add32(b, ob); c = add32(c, oc); d = add32(d, od);
    }
    return hexLE(a) + hexLE(b) + hexLE(c) + hexLE(d);
  },

  __sha1(str) {
    function rotl(n, c) { return ((n << c) | (n >>> (32 - c))) >>> 0; }
    function hexBE(v) {
      var s = '';
      for (var i = 0; i < 4; i++) s += ('0' + ((v >>> ((3 - i) * 8)) & 255).toString(16)).slice(-2);
      return s;
    }

    var bytes = this.__utf8Bytes(str);
    var n = bytes.length;
    var total = ((n + 8) >> 6 << 4) + 16;
    var w = [];
    var z;
    for (z = 0; z < total; z++) w[z] = 0;
    for (z = 0; z < n; z++) w[z >> 2] |= bytes[z] << (24 - (z % 4) * 8);
    w[n >> 2] |= 0x80 << (24 - (n % 4) * 8);
    w[total - 1] = n * 8;

    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    for (var j = 0; j < total; j += 16) {
      var ww = w.slice(j, j + 16);
      for (var k = 16; k < 80; k++) {
        ww[k] = rotl(ww[k - 3] ^ ww[k - 8] ^ ww[k - 14] ^ ww[k - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (k = 0; k < 80; k++) {
        var f, g;
        if (k < 20) { f = (b & c) | (~b & d); g = 0x5A827999; }
        else if (k < 40) { f = b ^ c ^ d; g = 0x6ED9EBA1; }
        else if (k < 60) { f = (b & c) | (b & d) | (c & d); g = 0x8F1BBCDC; }
        else { f = b ^ c ^ d; g = 0xCA62C1D6; }
        var t = (rotl(a, 5) + f + e + g + ww[k]) | 0;
        e = d; d = c; c = rotl(b, 30); b = a; a = t;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
    }
    return hexBE(h0) + hexBE(h1) + hexBE(h2) + hexBE(h3) + hexBE(h4);
  },

  // 把 JS 字符串按 UTF-8 编成字节数组（沙箱没有 TextEncoder 时也能用）。
  __utf8Bytes(text) {
    var str = String(text);
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        var next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return bytes;
  }
};
