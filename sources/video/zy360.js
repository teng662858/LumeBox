// LumeSource: {"id":"zy360_video","name":"360资源","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://360zy.com"],"network":"direct","icon":"https://360zy.com/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：360资源（资源站，360zy.com；苹果CMS v10 标准 JSON 接口）。
//   「看片狂人」里「720高清云」那条线就是它；接口里的 vod_time 与剧集上线时间同步（实测 20:58 更新的剧，
//   接口里就是 20:58），国产剧 4500+ 条、全库 7.4 万条，master 清单实测 RESOLUTION=1920x1080。
//
//   接口：
//     GET /api.php/provide/vod/?ac=list                          分类树
//     GET /api.php/provide/vod/?ac=detail&t=<type_id>&pg=<n>     分类分页（20 条/页，按更新时间倒序）
//     GET /api.php/provide/vod/?ac=detail&wd=<关键词>&pg=<n>     搜索
//     GET /api.php/provide/vod/?ac=detail&ids=<vod_id>           单条详情
//
//   和暴风资源同一套苹果CMS规范，但片库不同（两家互补），所以做成两个源。
//   父类（电影/连续剧/综艺/动漫）用 t= 查会返回 0 条，分类只取叶子类目。

var HOST = 'https://360zy.com';
var API = HOST + '/api.php/provide/vod/';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var PAGE_SIZE = 20;

var CATS = [
  { id: '13', title: '国产剧' },
  { id: '16', title: '欧美剧' },
  { id: '14', title: '香港剧' },
  { id: '15', title: '韩国剧' },
  { id: '31', title: '日本剧' },
  { id: '30', title: '台湾剧' },
  { id: '33', title: '泰国剧' },
  { id: '32', title: '海外剧' },
  { id: '6', title: '动作片' },
  { id: '11', title: '剧情片' },
  { id: '9', title: '科幻片' },
  { id: '38', title: '国产动漫' },
  { id: '34', title: '大陆综艺' },
  { id: '46', title: '爽文短剧' },
  { id: '47', title: '现代都市短剧' },
  { id: '51', title: '反转爽剧' }
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
  id: 'zy360_video',
  name: '360资源',
  version: '1.0.0',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '360资源（360zy.com）：另一家资源站接口，7.4 万条库、更新同样按剧集上线时间走，国产剧 4500+，master 清单实测 1920x1080。和「暴风资源」片库互补，两个都可以装。支持分类与搜索。'
    }
  ],

  async categories() { return CATS; },

  async list(argument) {
    var a = argument || {};
    var page = Math.max(1, Number(a.page || 1) || 1);
    var kw = String(a.keyword || '').trim();
    var cat = String(a.categoryId || '').trim() || '13';
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
      description: clean(x.vod_content || x.vod_blurb || '360资源（360zy.com）')
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
