// LumeSource: {"id":"bfzy_video","name":"暴风资源","version":"1.0.1","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://bfzyapi.com"],"network":"direct","icon":"https://bfzy.tv/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：暴风资源（资源站，接口域 bfzyapi.com；苹果CMS v10 标准 JSON 接口）。
//   为什么做它：它是「看片狂人 / 剧迷 / 各类聚合站」里「暴风SD」那条线的上游，更新速度比聚合站更快
//   —— 实测 01:15 上线的剧集，接口里 vod_time 就是 01:15，全集 m3u8 同时可播。
//
//   接口（全部是苹果CMS标准参数，不需要登录、不需要 Referer）：
//     GET /api.php/provide/vod/?ac=list                          分类树（class[]）
//     GET /api.php/provide/vod/?ac=detail&t=<type_id>&pg=<n>     分类分页，20 条/页（默认按 vod_time 倒序 = 最新更新）
//     GET /api.php/provide/vod/?ac=detail&wd=<关键词>&pg=<n>     搜索
//     GET /api.php/provide/vod/?ac=detail&ids=<vod_id>           单条详情（含 vod_play_url）
//
//   播放：vod_play_url 就是「集名$m3u8#集名$m3u8」，多线路用 $$$ 分隔、线路名在 vod_play_from。
//   实测国产剧的 master 清单带 RESOLUTION=1920x1080（部分老片 1920x800），单个 m3u8 200 + #EXTM3U。
//
//   说明：资源站只给「叶子分类」出片，父类（电影片/连续剧/动漫片）用 t= 查会返回 0 条，所以分类只取叶子。

var HOST = 'https://bfzyapi.com';
var API = HOST + '/api.php/provide/vod/';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var PAGE_SIZE = 20;

var CATS = [
  { id: '31', title: '国产剧' },
  { id: '32', title: '欧美剧' },
  { id: '33', title: '香港剧' },
  { id: '34', title: '韩国剧' },
  { id: '36', title: '日本剧' },
  { id: '35', title: '台湾剧' },
  { id: '38', title: '泰国剧' },
  { id: '37', title: '海外剧' },
  { id: '21', title: '动作片' },
  { id: '26', title: '剧情片' },
  { id: '24', title: '科幻片' },
  { id: '40', title: '国产动漫' },
  { id: '46', title: '大陆综艺' },
  { id: '58', title: '短剧大全' },
  { id: '62', title: '反转爽文短剧' },
  { id: '59', title: '重生民国短剧' }
];

// ------------------------------------------------------------------ 工具
function clean(t) {
  return String(t == null ? '' : t)
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{2,}/g, '\n')
    .trim();
}
function mmdd(v) {
  var s = String(v || '');
  var m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/.exec(s);
  if (!m) return s;
  return m[2] + '-' + m[3] + ' ' + m[4] + ':' + m[5];
}
function api(params) {
  var q = [];
  for (var k in params) if (Object.prototype.hasOwnProperty.call(params, k)) q.push(k + '=' + encodeURIComponent(params[k]));
  var url = API + '?' + q.join('&');
  return LumeSource.http.get(url, {
    headers: { 'User-Agent': UA, 'Accept': 'application/json, text/plain, */*' }
  }).then(function (r) {
    var s = r ? r.status : 0;
    if (!s) throw new Error('连不上资源站接口，请检查网络');
    if (s !== 200) throw new Error('资源站接口返回 HTTP ' + s);
    var body = String(r.body || '');
    var json = null;
    try { json = JSON.parse(body); } catch (e) { json = null; }
    if (!json) throw new Error('资源站接口返回的不是 JSON（站点可能换了接口地址）');
    return json;
  });
}

// ------------------------------------------------------------------ 入口
var LumeSource = {
  id: 'bfzy_video',
  name: '暴风资源',
  version: '1.0.0',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '暴风资源（bfzyapi.com）：国产剧/短剧/电影的资源站接口，17 万条库、分钟级更新（比聚合站更快出片），直接给 1080P m3u8 直链。分类取叶子类目（国产剧/各国剧/动作片/动漫/综艺/短剧细分），支持搜索。'
    }
  ],

  async categories() { return CATS; },

  async list(argument) {
    var a = argument || {};
    var page = Math.max(1, Number(a.page || 1) || 1);
    var kw = String(a.keyword || '').trim();
    var cat = String(a.categoryId || '').trim() || '31';
    var params = { ac: 'detail', pg: page };
    if (kw) params.wd = kw;
    else params.t = cat;

    var json = await api(params);
    var rows = Array.isArray(json.list) ? json.list : [];
    var items = [];
    for (var i = 0; i < rows.length; i++) {
      var x = rows[i] || {};
      var id = x.vod_id != null ? String(x.vod_id) : '';
      if (!id) continue;
      var sub = [clean(x.vod_remarks), x.vod_area || '', mmdd(x.vod_time)].filter(Boolean).join(' · ');
      items.push({
        id: id,
        title: clean(x.vod_name) || ('作品 ' + id),
        cover: String(x.vod_pic || ''),
        subtitle: sub
      });
    }
    var total = Number(json.pagecount || 0);
    return { items: items, hasMore: total ? page < total : items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return null;
    var json = await api({ ac: 'detail', ids: id });
    var x = (Array.isArray(json.list) && json.list[0]) || null;
    if (!x) return null;
    return {
      id: id,
      title: clean(x.vod_name) || ('作品 ' + id),
      cover: String(x.vod_pic || ''),
      subtitle: [clean(x.vod_remarks), x.vod_year || '', x.vod_area || ''].filter(Boolean).join(' · '),
      description: clean(x.vod_content || x.vod_blurb || '暴风资源（bfzyapi.com）')
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return [];
    var json = await api({ ac: 'detail', ids: id });
    var x = (Array.isArray(json.list) && json.list[0]) || null;
    if (!x) return [];
    var groups = String(x.vod_play_url || '').split('$$$');
    var names = String(x.vod_play_from || '').split('$$');
    var out = [];
    for (var g = 0; g < groups.length; g++) {
      var line = clean(names[g] || '').slice(0, 12) || ('线路' + (g + 1));
      var parts = groups[g].split('#');
      for (var j = 0; j < parts.length; j++) {
        var seg = parts[j];
        if (!seg) continue;
        var cut = seg.indexOf('$');
        var epName = cut > 0 ? clean(seg.slice(0, cut)) : ('第' + (j + 1) + '集');
        var url = cut > 0 ? seg.slice(cut + 1).trim() : seg.trim();
        if (!/^https?:\/\//i.test(url)) continue;
        out.push({
          id: 'u:' + url,
          title: groups.length > 1 ? (line + ' · ' + epName) : epName
        });
      }
    }
    return out;
  },

  async content(argument) {
    var raw = String((argument && argument.chapterId) || '');
    var url = raw.indexOf('u:') === 0 ? raw.slice(2) : raw;
    if (!/^https?:\/\//i.test(url)) throw new Error('该集没有可用的播放地址');
    if (!/\.(m3u8|mp4)(\?|$)/i.test(url)) {
      return { kind: 'webplayer', url: url };
    }
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, 'Referer': HOST + '/' }
    };
  }
};
