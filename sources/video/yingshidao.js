// LumeSource: {"id":"ysd_video","name":"影视岛","version":"2.0.2","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://tv.yingshidao.com","https://www.yingshidao.com"],"network":"direct","icon":"https://tv.yingshidao.com/brand/icon-180.f528dac723b16dab.png"}
// LumeRuntime: javascript
//
// 站点：影视岛（tv.yingshidao.com，面向海外华人的华语影视站，条目带 has4k 字段）。
//
// ── 开放接口（免登录，实测）────────────────────────────────────────────
//   GET  /api/v1/video/category?categoryId=<1..10>&page=<n>[&type=&regions=&years=]
//   GET  /api/v1/video/search?q=<词>&page=<n>
//   GET  /api/v1/video/detail?id=<mov_…>
//   GET  /api/v1/video/list?id=<mov_…>&page=1&limit=5000&include_free=1   ← 整部剧分集（含 is_free / is_vip / 片头片尾时间点）
//
// 播放统一使用站点网页：账号 Cookie、设备密钥、CKey 与媒体授权必须在同一浏览器会话内。
// 不预发游客播放请求，不复制网页 Cookie 到随机设备，不消费额外游客播放额度。
// 站点支持 ?play=1&ep=<episode_id>，登录页用 returnTo 保留影片与选集。
// 游客额度耗尽会跳 playback-limit（GUEST_IP_QUOTA_EXHAUSTED），需正常登录并使用已有权益。

var HOST = 'https://tv.yingshidao.com';
var MIRRORS = ['https://tv.yingshidao.com', 'https://www.yingshidao.com'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var PAGE_SIZE = 20;

var CATS = [
  { id: '2', title: '电视剧' },
  { id: '1', title: '电影' },
  { id: '4', title: '动漫' },
  { id: '3', title: '综艺' },
  { id: '7', title: '短剧' },
  { id: '10', title: '微剧' },
  { id: '5', title: '纪录片' },
  { id: '6', title: '少儿' }
];

// ------------------------------------------------------------------ 工具
function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function clean(t) {
  return String(t == null ? '' : t).replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
}
function randHex(n) {
  var s = '', chars = '0123456789abcdef';
  for (var i = 0; i < n; i++) s += chars.charAt(Math.floor(Math.random() * 16));
  return s;
}
function deviceIdentity() {
  return {
    headers: {
      'X-App-Version': 'web',
      'X-Client-Platform': 'web',
      'X-Client-Actions': '2',
      'X-Device-Id': 'webv2_' + randHex(32),
      'X-Device-Fingerprint': 'fpwebv2_' + randHex(32),
      'X-Request-Id': 'req_' + randHex(32)
    }
  };
}
function req(method, path, body, extra, dev) {
  var url = path.indexOf('http') === 0 ? path : base() + path;
  var headers = { 'User-Agent': UA, 'Accept': 'application/json', 'Origin': base(), 'Referer': base() + '/' };
  var d = dev && dev.headers ? dev.headers : deviceIdentity().headers;
  for (var k in d) headers[k] = d[k];
  var userCookie = (LumeSource.config && LumeSource.config.cookie) ? String(LumeSource.config.cookie) : '';
  if (userCookie) headers['Cookie'] = userCookie;
  for (var e in extra || {}) headers[e] = extra[e];
  var opts = { headers: headers };
  if (body != null) opts.body = typeof body === 'string' ? body : JSON.stringify(body);
  var p = method === 'POST' ? LumeSource.http.post(url, opts.body, opts) : LumeSource.http.get(url, opts);
  return p.then(function (r) {
    var s = r ? r.status : 0;
    if (!s) throw new Error('连不上影视岛，请检查网络或到「源设置 → 站点网络」配置代理');
    return r;
  });
}
function jsonOf(r) {
  var body = String((r && r.body) || '');
  try { return JSON.parse(body); } catch (e) { return null; }
}
function apiData(r) {
  var j = jsonOf(r);
  if (!j || Number(j.code) !== 200) {
    var msg = (j && (j.msg || j.message)) || ('HTTP ' + (r ? r.status : '?'));
    throw new Error('影视岛接口返回异常：' + msg);
  }
  return j.data;
}

function rowToItem(x) {
  var bits = [];
  if (x.has4k) bits.push('4K');
  if (x.isVip) bits.push('VIP');
  if (x.year) bits.push(String(x.year));
  if (x.region) bits.push(String(x.region));
  if (Number(x.totalEpisodes) > 1) bits.push('共' + x.totalEpisodes + '集');
  else if (clean(x.badge)) bits.push(clean(x.badge));
  var item = {
    id: String(x.id || ''),
    title: clean(x.title) || '未命名',
    cover: String(x.coverUrl || x.horizontalCover || ''),
    subtitle: bits.join(' · ')
  };
  if (/yingshiduo\.com|yingshidao\.com/i.test(item.cover)) {
    item.coverHeaders = { 'Referer': base() + '/' };
  }
  return item;
}

// ------------------------------------------------------------------ 入口
var LumeSource = {
  id: 'ysd_video',
  name: '影视岛',
  version: '2.0.2',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '影视岛的播放统一由站点网页处理，保留选中的集数。出现「游客试看已结束」时，请点击网页中的「已有账号，去登录」，登录后返回原集继续。也可先用下方入口登录；在 App 里填写账号资料并不代表网页已经登录。账号 Cookie 与设备密钥需保留在同一个网页会话中。会员及 4K 按账号实际权益开放，不保证注册赠送权益包含所有档位。'
    },
    { key: 'siteLogin', type: 'action', action: 'openWebsite', title: '登录影视岛网页', url: HOST + '/login', description: '在站点网页完成登录后，再返回影片播放；请勿只填写 App 账号资料。' }
  ],

  async categories() { return CATS; },

  async filters() {
    var data = apiData(await req('GET', '/api/v1/video/category?categoryId=2'));
    var tags = data.filter_tags || {};
    var groups = [];
    if (Array.isArray(tags.types) && tags.types.length) {
      groups.push({ id: 'type', title: '类型', options: tags.types.map(function (t) { return { id: String(t.key), title: clean(t.label || t.key) }; }) });
    }
    if (Array.isArray(tags.regions) && tags.regions.length) {
      groups.push({ id: 'regions', title: '地区', options: tags.regions.map(function (t) { return { id: String(t.key), title: clean(t.label || t.key) }; }) });
    }
    if (Array.isArray(tags.years) && tags.years.length) {
      groups.push({ id: 'years', title: '年份', options: tags.years.map(function (t) { return { id: String(t.key || t.label), title: clean(t.label || t.key) }; }) });
    }
    return groups;
  },

  async list(argument) {
    var a = argument || {};
    var page = Math.max(1, Number(a.page || 1) || 1);
    var kw = String(a.keyword || '').trim();
    var cat = String(a.categoryId || '').trim() || '2';
    var f = a.filters || {};
    var data;
    if (kw) {
      data = apiData(await req('GET', '/api/v1/video/search?q=' + encodeURIComponent(kw) + '&page=' + page));
    } else {
      var q = '/api/v1/video/category?categoryId=' + encodeURIComponent(cat) + '&page=' + page;
      if (f.type) q += '&type=' + encodeURIComponent(f.type);
      if (f.regions) q += '&regions=' + encodeURIComponent(f.regions);
      if (f.years) q += '&years=' + encodeURIComponent(f.years);
      data = apiData(await req('GET', q));
    }
    var rows = Array.isArray(data.list) ? data.list : [];
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var it = rowToItem(rows[i] || {});
      if (it.id) items.push(it);
    }
    return { items: items, hasMore: !!data.has_more || items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return null;
    var d = apiData(await req('GET', '/api/v1/video/detail?id=' + encodeURIComponent(id)));
    if (!d || !d.id) return null;
    var bits = [];
    if (d.has4k) bits.push('4K');
    if (d.year) bits.push(String(d.year));
    if (d.region) bits.push(String(d.region));
    if (Number(d.totalEpisodes) > 1) bits.push('共' + d.totalEpisodes + '集');
    if (clean(d.badge)) bits.push(clean(d.badge));
    return {
      id: String(d.id),
      title: clean(d.title) || ('作品 ' + d.id),
      cover: String(d.coverUrl || d.horizontalCover || ''),
      subtitle: bits.join(' · '),
      description: clean(d.description || '') || '影视岛（tv.yingshidao.com）',
      coverHeaders: { 'Referer': base() + '/' }
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var list = apiData(await req('GET', '/api/v1/video/list?id=' + encodeURIComponent(id) + '&page=1&limit=5000&include_free=1'));
    var eps = Array.isArray(list) ? list : (list.list || []);
    if (!eps.length) return [{ id: 'web:' + id, title: '网页播放（选集在网页里）' }];
    var out = [];
    for (var i = 0; i < eps.length; i++) {
      var e = eps[i] || {};
      if (!e.id) continue;
      var title = clean(e.title) || ('第' + (e.episode_num || i + 1) + '集');
      if (e.is_free) title += ' · 免费';
      else if (e.is_vip) title += ' · 会员';
      out.push({ id: 'ep:' + e.id, title: title });
    }
    return out;
  },

  async content(argument) {
    var a = argument || {};
    var mediaId = String(a.id || '').trim();
    var raw = String(a.chapterId || '');
    if (!mediaId) throw new Error('影视岛缺少影片编号，请返回详情页重试');
    var webUrl = base() + '/video/' + encodeURIComponent(mediaId) + '?play=1';
    var epId = raw.indexOf('ep:') === 0 ? raw.slice(3) : raw;
    if (epId && raw.indexOf('web:') !== 0) webUrl += '&ep=' + encodeURIComponent(epId);
    return { kind: 'webplayer', url: webUrl };
  }
};
