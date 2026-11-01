// LumeSource: {"id":"ysd_video","name":"影视岛","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://tv.yingshidao.com","https://www.yingshidao.com"],"network":"direct","icon":"https://tv.yingshidao.com/brand/icon-180.f528dac723b16dab.png"}
// LumeRuntime: javascript
//
// 站点：影视岛（tv.yingshidao.com；面向海外华人的正版向视频站，首页/搜索/详情都能直连）。
//   库：电影 / 电视剧 / 综艺 / 动漫 / 纪录片 / 少儿 / 短剧 / 微剧，条目带 **has4k 标记**——这是目前
//   找到的唯一「国产剧 + 真 4K 档位」的海外站，4K 不是海报上的贴纸，是接口里的字段。
//
//   已实测可用的开放接口（不需要登录）：
//     GET /api/v1/video/category?categoryId=<1..10>&page=<n>
//           → {list:[{id,title,subtitle,coverUrl,has4k,isVip,totalEpisodes,first_episode_id,year,region,…}],has_more,filter_tags}
//     GET /api/v1/video/category?categoryId=2&type=tv-kdrama&regions=KR&years=2025&page=1   筛选（type/years/regions 实测生效）
//     GET /api/v1/video/search?q=<关键词>&page=<n>
//     GET /api/v1/video/detail?id=<mov_…>                    → 标题/封面/简介/年份/总集数/first_episode_id
//
//   **播放为什么走网页播放器**：本站的点播要「设备密钥 + CKey」——
//     · 登录后 enrollDeviceAfterLogin：WebCrypto 生成 ECDSA P-256 设备密钥对，签名
//       "ysd-ckey-direct-v1\n…\n<episode_id>\n<play_attempt_id>\n<issued_at>\n<nonce>" 后提交；
//     · POST /api/v1/video/playback/access 缺 CKey 直接返回 403 PLAYBACK_CKEY_INVALID；
//       换新设备登录还会返回 DEVICE_KEY_SESSION_MISMATCH（账号绑着原设备的公钥）；
//     · 拿到 playback_token 后才能取 HLS，源里没法在纯 JS 沙箱复刻 ECDSA + 设备注册，也不该硬来。
//   所以本源：列表/搜索/详情走接口，播放交 App 网页播放器（在网页里登录一次，站内播放器自己算 CKey，
//   4K 档位按账号权限给）。这和「4k影视」那条网页播放器线路是同一套做法。

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
function api(path, params) {
  var q = [];
  for (var k in params || {}) {
    if (!Object.prototype.hasOwnProperty.call(params, k)) continue;
    var v = params[k];
    if (v === '' || v == null) continue;
    q.push(encodeURIComponent(k) + '=' + encodeURIComponent(v));
  }
  var url = base() + path + (q.length ? (path.indexOf('?') >= 0 ? '&' : '?') + q.join('&') : '');
  return LumeSource.http.get(url, {
    headers: { 'User-Agent': UA, 'Accept': 'application/json' }
  }).then(function (r) {
    var s = r ? r.status : 0;
    if (!s) throw new Error('连不上影视岛，请检查网络或到「源设置 → 站点网络」配置代理');
    if (s !== 200) throw new Error('影视岛接口返回 HTTP ' + s);
    var body = String(r.body || '');
    var json = null;
    try { json = JSON.parse(body); } catch (e) { json = null; }
    if (!json || Number(json.code) !== 200) {
      throw new Error('影视岛接口返回异常：' + (json && (json.msg || json.message) ? (json.msg || json.message) : '无法解析'));
    }
    return json.data || {};
  });
}

function rowToItem(x) {
  var bits = [];
  if (x.has4k) bits.push('4K');
  if (x.isVip) bits.push('VIP');
  if (x.year) bits.push(String(x.year));
  if (x.region) bits.push(String(x.region));
  if (Number(x.totalEpisodes) > 1) bits.push('共' + x.totalEpisodes + '集');
  else if (clean(x.badge)) bits.push(clean(x.badge));
  return {
    id: String(x.id || ''),
    title: clean(x.title) || '未命名',
    cover: String(x.coverUrl || x.horizontalCover || ''),
    subtitle: bits.join(' · ')
  };
}

// ------------------------------------------------------------------ 入口
var LumeSource = {
  id: 'ysd_video',
  name: '影视岛',
  version: '1.0.0',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '影视岛（tv.yingshidao.com）：面向海外的华语影视站，条目带 has4k 标记（真 4K 档位），电影/电视剧/综艺/动漫/纪录片/少儿/短剧/微剧八类，支持类型/地区/年份筛选与搜索。列表和详情走开放接口；播放交网页播放器——站内点播要设备密钥（ECDSA）+ CKey，在网页里登录一次即可由站点自己算签名，4K 按账号权限给。'
    }
  ],

  async categories() { return CATS; },

  async filters() {
    var data = await api('/api/v1/video/category', { categoryId: '2' });
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
      data = await api('/api/v1/video/search', { q: kw, page: page });
    } else {
      data = await api('/api/v1/video/category', {
        categoryId: cat,
        page: page,
        type: f.type || '',
        regions: f.regions || '',
        years: f.years || ''
      });
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
    var d = await api('/api/v1/video/detail', { id: id });
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
      description: clean(d.description || '') || '影视岛（tv.yingshidao.com）'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    var d = await api('/api/v1/video/detail', { id: id });
    var total = Number(d.totalEpisodes || 1);
    var label = total > 1 ? ('网页播放（共 ' + total + ' 集，选集在网页里）') : '网页播放';
    return [{ id: 'web:' + id, title: label }];
  },

  async content(argument) {
    var a = argument || {};
    var id = String(a.id || '').trim();
    if (!id) throw new Error('缺少作品 id');
    return {
      kind: 'webplayer',
      url: base() + '/video/' + encodeURIComponent(id) + '?play=1'
    };
  }
};
