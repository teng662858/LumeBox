// LumeSource: {"id":"lxxlxx_video","name":"LXXLXX","version":"1.1.0","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://zhs.lxxxxlxxx.com","https://zhs.lxxlxx.com","https://www.lxxlxx.com","https://hk.lxxlxx.com"],"network":"direct","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开站点（站方新域）","url":"https://zhs.lxxxxlxxx.com/","description":"站方自己的 301 目标：zhx./zhy.lxxlxx.com 都跳这里。源站恢复后从这里直接进站"},{"key":"note","type":"info","title":"站点说明","description":"LXXLXX（繁中成人短片）。2026-11-02 复测：zhs.lxxxxlxxx.com 与 lxxlxx.com 的 www./zhs./hk. 全系仍不可达（本机与第三方代理同为 Cloudflare 522，源站全球挂，不是脚本问题）；zhx./zhy.lxxlxx.com 还能回 301 指向新域。本源现在会**按 mirrors 依次自动换台**（每次请求最多试两台、总预算 8.5 秒），换到能开的那台会记住；全部打不通就明确报「源站不可达」，等站方恢复即可。"}]}
//
// 站点：https://zhs.lxxxxlxxx.com （繁中成人短片站；2026-11-01 复测：**站点改名换域了**）
//
// ── 〇、域名（2026-11-01 实测）
//   旧域 lxxlxx.com 全系现在只做跳转：zhx./zhy.lxxlxx.com 301 → https://zhs.lxxxxlxxx.com，
//   而 www./m./zhs./hk. 这些子域的源站已经挂了，直接回 **Cloudflare 522**（约 20s 才回，
//   所以 App 里看到的是「请求超时：调用超时：LumeSource.home」而不是站点错误）。
//   lxxxxlxxx.com 就是「字母加倍」的新域（同前缀 zhs.），本机与第三方代理实测同为 522 —— 源站全球挂，
//   不是本机网络问题。所以本源：
//     · mirrors 以新域 zhs.lxxxxlxxx.com 为主，旧 zhs./www. 留作备用（源站恢复后它们会 301 过去）；
//     · 每个请求都带 **4.5 秒软超时**（App 单次调用预算 10s）：源站不回就立刻抛出可读错误，
//       不再让用户干等 20 秒然后只看到「请求超时」；
//     · 5xx（520/521/522/523/524/525/527）明确报「源站不可达」，并把失败记 60 秒，
//       期间点重试立刻失败，不会每次都等一轮。
//
// 结构：
//   列表     GET /new/、/best/、/hot/、/hd/                 （各自只有第 1 页；站点自己给的分页链接是坏的）
//   标签     GET /tags/<Tag>/ → /tags/<Tag>/<N>/            （只有标签页的分页是好的，1 基）
//   搜索     GET /search/?key=<词>                          （表单 action="/search/"，参数名 key；无分页）
//   卡片     `<div class="thumb"><div class="pic"><a href="/video/<Slug>.html"><img src="/imgs/sfiles/…jpg"
//            alt="标题">
//            <u>标题</u><t>1:24:09</t></a></div></div>`
//   详情     GET /video/<Slug>.html → `<h1>` 标题、`<div class="video-info">` 时长/观看/日期、
//            `<div class="video-tags">` 标签；播放器是 `<script src="/vjs/<n>.js"></script>`
//   播放     三段跳：
//            ① /vjs/<n>.js        → `document.write('<script src="//m4-player-a-lx-cn.gotojs.xyz/<build>/vjs/<n>.js">')`
//            ② 那个 player js     → `document.writeln("<source src='//m4-a-mail-cn2p.gotojs.xyz/b_kJ5p9a/move/
//                                    <YYYYMM>/<n>_<tok>.mp4' type='video/mp4'/>")` + `poster='/imgs/files/…jpg'`
//            ③ mp4 直链
//   实测结论（重要）：①② 稳定，③ 的 mp4 在本机代理出口（HK）**恒 404**
//            （`HTTP Error 404. The requested resource is not found.`，试过换 UA / Referer / 换 cn1p、cn3p、
//            http、带 ? 都一样）。站点也没有 m3u8 备档。所以 content() 的规矩是：
//            **先把真实 mp4 地址解析出来并做一次 Range 探活，2xx/3xx 才返回 video，否则老实退 webplayer
//            （pageUrl 指向详情页）**——换到能回源的网络就是直链，回不了源也不会给假地址。
var H = {
  name: 'LXXLXX',
  defaultBase: 'https://zhs.lxxxxlxxx.com',
  base: 'https://zhs.lxxxxlxxx.com',
  softTimeoutMs: 4500,
  downTtlMs: 60 * 1000,
  ua: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',

  useDomain: function () {
    var c = (typeof LumeSource !== 'undefined' && LumeSource.config) || null;
    this.base = String((c && c.domain) || this.defaultBase).replace(/\/+$/, '');
    return this.base;
  },
  entity: function (s) {
    return String(s == null ? '' : s).replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, function (all, code) {
      var map = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ', '#39': "'", '#34': '"' };
      if (map[code] !== undefined) return map[code];
      if (code.charAt(0) === '#') {
        var n = code.charAt(1) === 'x' || code.charAt(1) === 'X' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
        if (isFinite(n) && n > 0 && n < 0x110000) return String.fromCharCode(n);
      }
      return all;
    });
  },
  clean: function (s) {
    return this.entity(String(s == null ? '' : s).replace(/<script\b[\s\S]*?<\/script>/gi, ' ').replace(/<style\b[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
  },
  abs: function (u) {
    u = this.entity(String(u == null ? '' : u)).trim();
    if (!u) return '';
    if (u.indexOf('//') === 0) return 'https:' + u;
    if (/^https?:\/\//i.test(u)) return u;
    if (u.charAt(0) === '/') return this.base + u;
    return this.base + '/' + u;
  },
  headers: function (referer) {
    return { 'User-Agent': this.ua, 'Referer': referer || this.base + '/', 'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8' };
  },
  response: function (r) {    if (!r) throw new Error(this.name + '：没有网络响应');
    var s = Number(r.status);
    if (s === 403 || s === 503) throw new Error('NEED_WEBVIEW_VERIFY：' + this.name + ' 要求网页验证（HTTP ' + s + '）');
    if (s === 520 || s === 521 || s === 522 || s === 523 || s === 524 || s === 525 || s === 527) {
      throw new Error(this.name + '：站点源站当前不可达（Cloudflare ' + s + '），换域名/修源站中，稍后重试');
    }
    if (s === 404) throw new Error(this.name + '：页面不存在（HTTP 404）');
    if (s !== 200) throw new Error(this.name + '：请求失败（HTTP ' + s + '）');
    return String(r.body || '');
  },
  // App 单次调用预算 10s，而源站挂掉时 Cloudflare 要约 20s 才回 522 —— 干等只会得到「请求超时」。
  // 这里给每个请求套一个软超时：超时立刻换下一台镜像；两台都不行就抛可读错误，并记 60 秒
  // 「本站不可达」，期间再点重试直接失败，不重复等。
  totalBudgetMs: 8500,
  hosts: function () {
    var out = [];
    function push(value) {
      var text = String(value == null ? '' : value).replace(/\/+$/, '');
      if (/^https?:\/\//i.test(text) && out.indexOf(text) < 0) out.push(text);
    }
    var c = (typeof LumeSource !== 'undefined' && LumeSource.config) || null;
    push(c && c.domain);
    push(this.base);
    push(this.defaultBase);
    var mirrors = (typeof LumeSource !== 'undefined' && LumeSource.mirrors) || [];
    for (var i = 0; i < mirrors.length; i++) push(mirrors[i]);
    return out;
  },
  // 单台取页（带软超时）：{ ok, text } / { reason } / { fatal }
  attempt: async function (host, path, referer) {
    var self = this;
    var url = /^https?:\/\//i.test(path) ? path : host + path;
    var budget = Math.max(1500, Math.min(self.softTimeoutMs, self.deadline - Date.now()));
    var timer = null;
    var raced = await Promise.race([
      LumeSource.http.get(url, { headers: self.headers(referer) }).then(
        function (reply) { return { reply: reply }; },
        function (error) { return { failure: error }; }
      ),
      new Promise(function (resolve) {
        timer = setTimeout(function () { resolve({ timeout: true }); }, budget);
      })
    ]);
    if (timer) clearTimeout(timer);
    if (raced.timeout) return { reason: budget + 'ms 内没有响应（' + host + '）' };
    if (raced.failure) {
      var message = String((raced.failure && raced.failure.message) || raced.failure);
      return { reason: '连不上（' + host + '）：' + message };
    }
    try {
      return { ok: true, text: self.response(raced.reply) };
    } catch (error) {
      var text = String((error && error.message) || '');
      if (/NEED_WEBVIEW_VERIFY/.test(text)) return { fatal: error };
      return { reason: text };
    }
  },
  down: function (reason) {
    var now = Date.now();
    if (this._downAt && now - this._downAt < this.downTtlMs) {
      throw new Error(this.name + '：站点源站当前不可达（' + (this._downWhy || reason) + '），约 1 分钟后再试');
    }
    this._downAt = now;
    this._downWhy = reason;
    var hint = /52[0-7]/.test(reason)
      ? '这是站方源站挂了（Cloudflare 5xx），不是脚本解析错'
      : '已知镜像全都没响应，多半是源站宕机或正在换域';
    throw new Error(this.name + '：站点源站当前不可达（' + reason + '）。' + hint +
      '；等站方恢复即可，或到「源设置 → 换网址」换一台镜像再试');
  },
  get: async function (path, referer) {
    if (this._downAt && Date.now() - this._downAt < this.downTtlMs) {
      throw new Error(this.name + '：站点源站当前不可达（' + (this._downWhy || '无响应') + '），约 1 分钟后再试');
    }
    var hosts = this.hosts();
    var reasons = [];
    this.deadline = Date.now() + this.totalBudgetMs;
    for (var i = 0; i < hosts.length && i < 2; i++) {
      if (Date.now() >= this.deadline) break;
      var result = await this.attempt(hosts[i], path, referer);
      if (result.fatal) throw result.fatal;
      if (result.ok) {
        this.base = hosts[i];
        this._downAt = 0;
        return result.text;
      }
      reasons.push(result.reason);
    }
    this.down(reasons.length ? reasons.join('；') : '没有可用镜像');
  }
};

var LumeSource = {
  id: 'lxxlxx_video',
  name: 'LXXLXX',
  version: '1.1.0',
  category: 'video',
  contentCategory: 'adult',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: ['https://zhs.lxxxxlxxx.com', 'https://zhs.lxxlxx.com', 'https://www.lxxlxx.com', 'https://hk.lxxlxx.com'],
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开站点（站方新域）',
      url: 'https://zhs.lxxxxlxxx.com/',
      description: '站方自己的 301 目标：zhx./zhy.lxxlxx.com 都跳这里；源站恢复后从这儿进站最稳',
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: 'LXXLXX（繁中成人短片）。2026-11-02 复测：新域 zhs.lxxxxlxxx.com 与旧域 lxxlxx.com 的 www./zhs./hk. 全系仍回 Cloudflare 522 / 超时（本机与第三方代理一致，源站全球挂）；zhx./zhy.lxxlxx.com 还能 301 到新域。脚本现在会自动按 mirrors 换台（每次请求最多两台、总预算 8.5 秒），能开的那台会被记住；全挂时明确报「源站不可达」，等站方恢复即可。',
    },
  ],

  async home() {
    H.useDomain();
    var page = await this.list({ categoryId: '/new/', page: 1 });
    if (!page.items.length) throw new Error('LXXLXX：首页没认出条目（站点可能改版）');
    return [{ title: '最新', moreUrl: '/new/', items: page.items.slice(0, 24) }];
  },

  async categories() {
    H.useDomain();
    return [
      { id: '/new/', title: '最新' },
      { id: '/best/', title: '最佳' },
      { id: '/hot/', title: '熱門' },
      { id: '/hd/', title: '高清' },
      { id: '/tags/Chinese/', title: '中國' },
      { id: '/tags/Japanese/', title: '日本' },
      { id: '/tags/Asian/', title: '亞洲' },
      { id: '/tags/Uncensored/', title: '無碼' },
      { id: '/tags/Lesbians/', title: '女同' },
      { id: '/tags/Big-Tits/', title: '巨乳' }
    ];
  },

  async list(argument) {
    H.useDomain();
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = H.clean(args.keyword || '').trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim() || '/new/';
    var path, isTag = false;
    if (keyword) {
      path = '/search/?key=' + encodeURIComponent(keyword);
    } else {
      path = category.charAt(0) === '/' ? category : '/' + category;
      if (!/\/$/.test(path)) path += '/';
      isTag = /^\/tags\/[^/]+\/$/.test(path);
      // 只有 /tags/<Tag>/ 支持分页（/tags/Chinese/12/）；/new/、/best/ 这类站点的分页链接是坏的（href=" 2"）
      if (isTag && page > 1) path = path + page + '/';
    }
    var html = await H.get(path);
    var items = this.__items(html);
    if (!items.length) console.warn('[lxxlxx] 列表没解析出条目：' + path);
    var hasMore = isTag && /下一頁|Next/i.test(html);
    return { items: items, hasMore: hasMore };
  },

  __items: function (html) {
    var text = String(html), out = [], seen = {};
    var chunks = text.split('class="thumb"');
    for (var i = 1; i < chunks.length; i++) {
      var block = chunks[i].slice(0, 1400);
      var hit = /<a[^>]+href="(\/video\/[^"]+\.html)"[^>]*>/.exec(block);
      if (!hit) continue;
      var path = hit[1];
      if (seen[path]) continue;
      seen[path] = 1;
      var img = /<img[^>]+src="([^"]+)"[^>]*alt="([^"]*)"/i.exec(block) || /<img[^>]+alt="([^"]*)"[^>]+src="([^"]+)"/i.exec(block);
      var cover = '', title = '';
      if (img) {
        if (/^\/|^https?:/i.test(img[1])) { cover = img[1]; title = img[2] || ''; }
        else { title = img[1]; cover = img[2] || ''; }
      }
      if (!title) title = (/<u>([\s\S]{0,300}?)<\/u>/.exec(block) || [])[1] || '';
      if (!cover) cover = (/<img[^>]+src="([^"]+)"/i.exec(block) || [])[1] || '';
      var dur = (/<t>([^<]{0,20})<\/t>/.exec(block) || [])[1] || '';
      out.push({
        id: H.base + path,
        title: H.clean(title) || H.clean(path.replace(/^\/video\//, '').replace(/\.html$/i, '').replace(/-/g, ' ')),
        cover: cover ? H.abs(cover) : null,
        coverHeaders: H.headers(),
        subtitle: H.clean(dur)
      });
    }
    return out;
  },

  async detail(argument) {
    H.useDomain();
    var id = String(argument && argument.id ? argument.id : '').trim();
    var m = /(\/video\/[^"'?#]+\.html)/i.exec(id);
    if (!m) return null;
    var pageUrl = H.base + m[1];
    var html = await H.get(pageUrl);
    var title = (/<h1[^>]*>([\s\S]{0,300}?)<\/h1>/i.exec(html) || [])[1] || '';
    if (!title) {
      var t = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
      title = t ? H.clean(t[1]).replace(/\s*[-|].*$/, '') : '';
    }
    var info = (/<div class="video-info">([\s\S]{0,400}?)<\/div>/i.exec(html) || [])[1] || '';
    var tags = '';
    var tre = /<div class="pagination">([\s\S]{0,1200}?)<\/ul>/i.exec(html);
    if (tre) tags = H.clean(tre[1].replace(/<\/li>/gi, '、')).replace(/[、\s]+$/, '');
    var cover = '';
    try {
      var resolved = await this.__resolve(m[1]);
      cover = resolved.poster || '';
    } catch (error) {
      console.warn('[lxxlxx] 取海报失败：' + error);
    }
    return {
      id: pageUrl,
      title: H.clean(title) || 'LXXLXX',
      cover: cover ? H.abs(cover) : null,
      coverHeaders: H.headers(),
      subtitle: H.clean(info).slice(0, 120),
      description: tags ? '類別：' + tags : H.clean(info)
    };
  },

  async chapters(argument) {
    if (!argument || !argument.id) return [];
    return [{ id: 'play', title: '正片' }];
  },

  async content(argument) {
    H.useDomain();
    var id = String(argument && argument.id ? argument.id : '').trim();
    var m = /(\/video\/[^"'?#]+\.html)/i.exec(id);
    if (!m) throw new Error('LXXLXX：认不出视频地址（' + id + '）——id 应来自 list()');
    var pageUrl = H.base + m[1];
    var resolved = await this.__resolve(m[1]);
    if (!resolved.mp4) {
      return { kind: 'webplayer', pageUrl: pageUrl, headers: H.headers(pageUrl) };
    }
    // 真探活：拿 1KB 看是不是 video（回源不通就退 webplayer，不给假地址）
    var ok = false, status = 0, type = '';
    try {
      var probe = await LumeSource.http.get(resolved.mp4, {
        headers: { 'User-Agent': H.ua, 'Referer': pageUrl, 'Range': 'bytes=0-1023' }
      });
      status = Number(probe && probe.status) || 0;
      type = String((probe && probe.headers && (probe.headers['content-type'] || probe.headers['Content-Type'])) || '');
      ok = status >= 200 && status < 400 && /video|octet-stream|mp4/i.test(type);
    } catch (error) {
      console.warn('[lxxlxx] mp4 探活失败：' + error);
    }
    if (!ok) {
      console.warn('[lxxlxx] mp4 回源不可用（HTTP ' + status + ' / ' + (type || '无 content-type') + '），退 webplayer：' + resolved.mp4);
      return { kind: 'webplayer', pageUrl: pageUrl, direct: resolved.mp4, headers: H.headers(pageUrl) };
    }
    return {
      kind: 'video',
      url: resolved.mp4,
      headers: { 'Referer': pageUrl, 'User-Agent': H.ua, 'Range': 'bytes=0-1023' },
      qualities: [{ label: 'MP4', url: resolved.mp4 }]
    };
  },

  /// /video/<Slug>.html → /vjs/<n>.js → <player host>/.../vjs/<n>.js → {mp4, poster}
  __resolve: async function (videoPath) {
    var pageUrl = H.base + videoPath;
    var html = await H.get(pageUrl);
    var vjs = (/<script[^>]+src="(\/vjs\/\d+\.js)"/i.exec(html) || [])[1] || '';
    if (!vjs) return { mp4: '', poster: '', pageUrl: pageUrl };
    var first = await H.get(vjs, pageUrl);
    var inner = (/src="(\/\/[^"]+\.js)"/i.exec(first) || [])[1] || '';
    if (!inner) return { mp4: '', poster: '', pageUrl: pageUrl };
    var second = await H.get('https:' + inner, pageUrl);
    // player js 里是 document.writeln("… <source src=\'//host/…mp4\' …")，注意避开转义用的反斜杠
    var mp4 = (/source src=\\?['"](\/\/[^'"\\]+\.mp4[^'"\\]*)\\?['"]/.exec(second) || [])[1] || '';
    if (!mp4) mp4 = (/['"](\/\/[^'"\\\s]+\.mp4[^'"\\\s]*)\\?['"]/.exec(second) || [])[1] || '';
    var poster = (/poster=\\?['"]([^'"\\]+)\\?['"]/.exec(second) || [])[1] || '';
    return { mp4: mp4 ? H.abs(mp4) : '', poster: poster, pageUrl: pageUrl };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
