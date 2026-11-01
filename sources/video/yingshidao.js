// LumeSource: {"id":"ysd_video","name":"影视岛","version":"2.0.1","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://tv.yingshidao.com","https://www.yingshidao.com"],"network":"direct","icon":"https://tv.yingshidao.com/brand/icon-180.f528dac723b16dab.png"}
// LumeRuntime: javascript
//
// 站点：影视岛（tv.yingshidao.com，面向海外华人的华语影视站，条目带 has4k 字段）。
//
// ── 开放接口（免登录，实测）────────────────────────────────────────────
//   GET  /api/v1/video/category?categoryId=<1..10>&page=<n>[&type=&regions=&years=]
//   GET  /api/v1/video/search?q=<词>&page=<n>
//   GET  /api/v1/video/detail?id=<mov_…>
//   GET  /api/v1/video/list?id=<mov_…>&page=1&limit=5000&include_free=1   ← 整部剧分集（含 is_free / is_vip / 片头片尾时间点）
//   POST /api/v1/video/playback/access  {episode_id, play_attempt_id, purpose:"PLAYBACK", ckey_prepare:{direct_guest:true}}
//        → {decision:"ALLOW", play_url:[{n:"1080p", u:"https://tv.yingshidao.com/media/index.m3u8?url=…"}],
//           playback_token, device_token, locked_qualities:[{n:"4k", reason:"FOUR_K_ENTITLEMENT_REQUIRED"}]}
//   POST /api/v1/pingPlay/<episode_id>  （带 X-Playback-Token）
//
// ── 播放 ───────────────────────────────────────────────────────────
//   免费集：guest 会发 play_url（1080p），但要播放 Cookie（__Host-ysd_media）才放行；
//          本源把 Cookie 一并塞进 headers，返回前先自探一次，探活不过就退回网页播放器。
//   会员集 / 4K：guest 直接 DENY（MEMBERSHIP）或 4K 锁（paid_members）。点播还要设备密钥
//          （ECDSA P-256 + CKey wasm），纯 JS 沙箱复刻不了 → 网页播放器里登录后由站点自解。
//   账号登录态与设备公钥绑定（新设备登录回 DEVICE_KEY_SESSION_MISMATCH），本源不代登录、不存密码。

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

// 从响应里尽量把 Set-Cookie 抠出来（运行时暴露方式不同，取不到就返回空）
function cookiesFrom(r) {
  var out = [];
  function push(line) {
    var first = String(line || '').split(';')[0];
    if (first && first.indexOf('=') > 0) out.push(first.trim());
  }
  if (r && r.setCookie) {
    if (Array.isArray(r.setCookie)) for (var i = 0; i < r.setCookie.length; i++) push(r.setCookie[i]);
    else push(r.setCookie);
  }
  var h = (r && r.headers) || {};
  for (var k in h) {
    if (k.toLowerCase() !== 'set-cookie') continue;
    var v = h[k];
    if (Array.isArray(v)) for (var j = 0; j < v.length; j++) push(v[j]);
    else String(v).split('\n').forEach(push);
  }
  return out;
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
  version: '2.0.1',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '影视岛（tv.yingshidao.com）：海外华语站，条目带 has4k（真 4K 档位）。分类/筛选/搜索/分集都走开放接口；分集标题直接标「免费 / 会员」。免费集能取到 1080p m3u8（连带播放 Cookie，探活通过才下发）；会员集和 4K 走网页播放器——站内点播要设备密钥（ECDSA）+ CKey，在网页里登录一次即可。账号登录态绑定设备，本源不代登录、不存密码。'
    }
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
    var webUrl = base() + '/video/' + encodeURIComponent(mediaId) + '?play=1';
    if (raw.indexOf('web:') === 0 || !mediaId) return { kind: 'webplayer', url: webUrl };

    var epId = raw.indexOf('ep:') === 0 ? raw.slice(3) : raw;
    var dev = deviceIdentity();
    var access;
    try {
      access = await req(
        'POST',
        '/api/v1/video/playback/access',
        {
          episode_id: epId,
          play_attempt_id: 'web_' + randHex(24),
          purpose: 'PLAYBACK',
          supports_watch_prompts: true,
          supports_watch_usage: true,
          startup_admission: true,
          ckey_prepare: { direct_guest: true }
        },
        { 'Content-Type': 'application/json', 'X-Playback-Startup-Admission': '1' },
        dev
      );
    } catch (e) {
      return { kind: 'webplayer', url: webUrl };
    }
    var d = (jsonOf(access) || {}).data || null;
    var urls = (d && Array.isArray(d.play_url)) ? d.play_url : [];
    if (!urls.length) return { kind: 'webplayer', url: webUrl };

    var best = urls[0];
    for (var i = 1; i < urls.length; i++) {
      if (Number(urls[i].quality_height || 0) > Number(best.quality_height || 0)) best = urls[i];
    }
    var cookies = cookiesFrom(access);
    if (!cookies.length && d.device_token) cookies = ['watchtv_device_token=' + String(d.device_token)];

    if (d.playback_token) {
      try {
        var ping = await req('POST', '/api/v1/pingPlay/' + encodeURIComponent(epId), '{}', {
          'Content-Type': 'application/json',
          'X-Playback-Token': String(d.playback_token),
          'Cookie': cookies.join('; ')
        }, dev);
        cookies = cookies.concat(cookiesFrom(ping));
      } catch (e) { /* 没有 Cookie 就退回网页播放器 */ }
    }

    var cookieLine = cookies.join('; ');
    var userCookie = (LumeSource.config && LumeSource.config.cookie) ? String(LumeSource.config.cookie) : '';
    if (userCookie) cookieLine = cookieLine ? (userCookie + '; ' + cookieLine) : userCookie;
    if (!/__Host-ysd_media=/.test(cookieLine)) return { kind: 'webplayer', url: webUrl };

    var headers = { 'User-Agent': UA, 'Referer': base() + '/', 'Cookie': cookieLine };
    var qualities = [];
    for (var j = 0; j < urls.length; j++) {
      if (!urls[j] || !urls[j].u) continue;
      qualities.push({ label: String(urls[j].n || urls[j].quality_height || ('线路' + (j + 1))), url: String(urls[j].u), headers: headers });
    }
    // 直链令牌和本次播放会话绑定、很快就失效：返回前先自探一次，探活不过就退回网页播放器
    try {
      var probe = await LumeSource.http.get(String(best.u), { headers: headers });
      var pbody = String((probe && probe.body) || '');
      if (!probe || probe.status !== 200 || pbody.indexOf('#EXTM3U') < 0) return { kind: 'webplayer', url: webUrl };
    } catch (e2) {
      return { kind: 'webplayer', url: webUrl };
    }
    return { kind: 'video', url: String(best.u), headers: headers, qualities: qualities };
  }
};
