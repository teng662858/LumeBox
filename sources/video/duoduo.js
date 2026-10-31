// LumeSource: {"id":"duoduo_video","name":"多多追剧","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://323433ssdfd.top","https://duoduosdf12223234334.top","https://xds2435u23422342342u.top","https://dduotv01.top"],"network":"direct","icon":"https://323433ssdfd.top/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：多多追剧（发布页 https://duoduozhuiju.com/ → js/config.js 里的线路表：
//       323433ssdfd.top / duoduosdf12223234334.top / xds2435u23422342342u.top / dduotv01.top，四条线路同内容）。
// 形态：Vue3 SPA（/assets/index-*.js），数据走同源 JSON 接口 `/api.php/web/*`：
//   需要两个头：`X-Client: 8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a`、`web-sign: ddtvf65f3a83d6d9ad6f`（前端常量）。
//   首页    /api.php/web/index/home            → {categories:[{type_id,type_name,videos[]}], recommend, hotSearch}
//   列表    /api.php/web/filter/vod?page=&sort=&type_id=&class=&area=&year= → {data,total,page,pageCount}
//   搜索    /api.php/web/search/index?wd=&page=&limit=
//   详情    /api.php/web/vod/get_detail?vod_id= → data[0] 带 vod_play_from / vod_play_url
//   榜单    /api.php/web/ranking/list
//   分类/筛选选项取自站点 TypePage 的常量表（电影/剧集/综艺/动漫 各自的 class/area/year；排序 hits/time/score/year）。
//   播放线路：vod_play_from 形如 `PAN1$$$zijianm3u8$$$CO4K$$$NBY$$$qsvip$$$BBA`，每条线路的每一集是
//   一个 xxx 令牌（如 `PAN1-<base64>`、`jjkk-<hex>`），真地址要由站点 `/api.php/web/decode/url` 解——
//   该接口是 protobuf + wasm（`get_signature_headers` 生成 aid/ave/nonc/sign/time 请求头）签名，
//   纯 JS 沙箱算不出来（实测手工构造 protobuf 一律回 401「签名验证失败: 缺少必要参数」）。
//   → 所以本源把「播放」交给 App 的网页播放器：打开站点自己的 /play/<vod_id>，线路和选集在页面里选。
//
// 限制：播放只能网页播放（令牌解码要站点 wasm 签名）；分类/筛选/排序/搜索/详情都是真数据。

var HOST = 'https://323433ssdfd.top';
var MIRRORS = [
  'https://323433ssdfd.top',
  'https://duoduosdf12223234334.top',
  'https://xds2435u23422342342u.top',
  'https://dduotv01.top'
];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
var API_CLIENT = '8f3d2a1c7b6e5d4c9a0b1f2e3d4c5b6a';
var API_SIGN = 'ddtvf65f3a83d6d9ad6f';
var PAGE_SIZE = 24;

var CATS = [
  { id: '1', title: '电影', typeName: '电影' },
  { id: '2', title: '剧集', typeName: '剧集' },
  { id: '3', title: '综艺', typeName: '综艺' },
  { id: '4', title: '动漫', typeName: '动漫' }
];

// 站点 TypePage 里的筛选常量（各分类取值不同，错配的组站方会返回空列表）
var CLASSES = {
  '1': ['动作', '喜剧', '爱情', '科幻', '恐怖', '悬疑', '犯罪', '战争', '动画', '冒险', '历史', '灾难', '纪录', '剧情'],
  '2': ['爱情', '古装', '武侠', '历史', '家庭', '喜剧', '悬疑', '犯罪', '战争', '奇幻', '科幻', '恐怖'],
  '3': ['真人秀', '音乐', '脱口秀', '歌舞', '爱情'],
  '4': ['冒险', '奇幻', '科幻', '武侠', '悬疑']
};
var AREAS = {
  '1': ['大陆', '香港', '台湾', '美国', '日本', '韩国', '泰国', '印度', '英国', '法国', '德国', '加拿大', '西班牙', '意大利', '澳大利亚'],
  '2': ['大陆', '香港', '台湾', '美国', '日本', '韩国', '泰国', '英国'],
  '3': ['大陆', '香港', '台湾', '美国', '日本', '韩国'],
  '4': ['大陆', '日本', '欧美']
};
var YEARS = {
  '1': ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015-2011', '2010-2000', '90年代', '80年代', '更早'],
  '2': ['2026', '2025', '2024', '2023', '2022', '2021', '2020-2016', '2015-2011', '2010-2000', '更早'],
  '3': ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015', '2014', '2013', '2012', '2011', '更早'],
  '4': ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015', '2014', '2013', '2012', '2011', '更早']
};
var SORTS = [
  { id: 'hits', title: '人气' },
  { id: 'time', title: '最新' },
  { id: 'score', title: '评分' },
  { id: 'year', title: '年份' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
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
function headers() {
  return {
    'User-Agent': UA,
    'Accept': 'application/json, text/plain, */*',
    'X-Client': API_CLIENT,
    'web-sign': API_SIGN,
    'Referer': base() + '/',
    'Origin': base()
  };
}
function api(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  return LumeSource.http.request({ url: url, method: 'GET', headers: headers() }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    var body = reply && reply.body != null ? String(reply.body) : '';
    if (!status) throw new Error('连不上站点：' + base());
    if (status !== 200) throw new Error('多多追剧接口 HTTP ' + status + '：' + path);
    var data = null;
    try { data = JSON.parse(body); } catch (e) { data = null; }
    if (!data) throw new Error('多多追剧接口返回的不是 JSON（站点可能改版）');
    if (data.code !== 200) throw new Error('多多追剧接口报错：' + (data.msg || data.code));
    return data;
  });
}

function toItem(row) {
  var area = row.vod_area;
  if (area && area.length && typeof area !== 'string') area = area.join('/');
  return {
    id: String(row.vod_id),
    title: clean(row.vod_name),
    cover: row.vod_pic ? unescapeHtml(row.vod_pic) : null,
    subtitle: [row.vod_remarks, row.vod_year, area].filter(Boolean).join(' · ')
  };
}

function parsePlayLines(row) {
  var froms = String(row.vod_play_from || '').split('$$$');
  var urls = String(row.vod_play_url || '').split('$$$');
  var lines = [];
  for (var i = 0; i < froms.length; i++) {
    var code = String(froms[i] || '').trim();
    if (!code) continue;
    var eps = String(urls[i] || '').split('#').filter(Boolean);
    lines.push({ code: code, count: eps.length });
  }
  return lines;
}

var LumeSource = {
  id: 'duoduo_video',
  name: '多多追剧',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/favicon.ico',
  settings: [
    {
      key: 'publishPage',
      type: 'action',
      action: 'openWebsite',
      title: '打开发布页',
      url: 'https://duoduozhuiju.com/',
      description: '发布页会自动测速四条线路（323433ssdfd.top 等），换域名时先看这里'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '多多追剧（四条线路同库）。列表/搜索/详情走站点 JSON 接口（需要 X-Client 与 web-sign 两个头，已内置）。播放地址是逐集令牌，要站点 protobuf+wasm 签名解码（纯 JS 算不出），所以播放交给 App 的网页播放器打开站点播放页；线路与选集在页面里选。分类/筛选/排序都是站点真实参数。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 各分类的类型/地区/年份取值不同（见上方常量表），这里取并集；错配的组合站点会返回空列表。
    function union(map) {
      var out = [];
      var keys = Object.keys(map);
      for (var i = 0; i < keys.length; i++) {
        var list = map[keys[i]];
        for (var j = 0; j < list.length; j++) if (out.indexOf(list[j]) < 0) out.push(list[j]);
      }
      return out;
    }
    return {
      groups: [
        {
          key: 'class', title: '类型', multiple: false,
          options: union(CLASSES).map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'area', title: '地区', multiple: false,
          options: union(AREAS).map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'year', title: '年份', multiple: false,
          options: union(YEARS).map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'sort', title: '排序', multiple: false,
          options: SORTS.map(function (s) { return { id: s.id, title: s.title }; })
        }
      ]
    };
  },

  async home() {
    var data = await api('/api.php/web/index/home');
    var payload = data.data || {};
    var blocks = [];
    if (Array.isArray(payload.recommend) && payload.recommend.length) {
      blocks.push({ title: '热门推荐', items: payload.recommend.map(toItem).slice(0, 24) });
    }
    var cats = Array.isArray(payload.categories) ? payload.categories : [];
    for (var i = 0; i < cats.length; i++) {
      var c = cats[i];
      if (!c || !Array.isArray(c.videos) || !c.videos.length) continue;
      blocks.push({ title: c.type_name || ('分类 ' + c.type_id), moreUrl: String(c.type_id), items: c.videos.map(toItem).slice(0, 24) });
    }
    if (!blocks.length) throw new Error('多多追剧：首页没有条目（接口可能改版）');
    return blocks;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = clean(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    if (keyword) {
      var found = await api('/api.php/web/search/index?wd=' + enc(keyword) + '&page=' + page + '&limit=' + PAGE_SIZE);
      var rows = Array.isArray(found.data) ? found.data : [];
      return { items: rows.map(toItem), hasMore: false };
    }

    var query = ['page=' + page, 'sort=' + enc(filters.sort || 'time')];
    if (category) query.push('type_id=' + enc(category));
    if (filters.class) query.push('class=' + enc(filters.class));
    if (filters.area) query.push('area=' + enc(filters.area));
    if (filters.year) query.push('year=' + enc(filters.year));
    var data = await api('/api.php/web/filter/vod?' + query.join('&'));
    var list = Array.isArray(data.data) ? data.data : [];
    // 站方 total/pageCount 恒为 24/1（不准），翻页按「本页是否满页」判断；实测 page=2 会换一批。
    return { items: list.map(toItem), hasMore: list.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var data = await api('/api.php/web/vod/get_detail?vod_id=' + id);
    var rows = Array.isArray(data.data) ? data.data : [];
    if (!rows.length) return null;
    var row = rows[0];
    var lines = parsePlayLines(row);
    var bits = [];
    if (lines.length) {
      var maxEp = 0;
      for (var i = 0; i < lines.length; i++) if (lines[i].count > maxEp) maxEp = lines[i].count;
      bits.push(lines.length + ' 条线路');
      if (maxEp > 1) bits.push('共 ' + maxEp + ' 集');
      else bits.push('正片');
    }
    bits.push('网页播放');
    var kinds = row.vod_class;
    if (kinds && kinds.length && typeof kinds !== 'string') kinds = kinds.join(' / ');
    return {
      id: id,
      title: clean(row.vod_name),
      cover: row.vod_pic ? unescapeHtml(row.vod_pic) : null,
      subtitle: bits.join(' · '),
      description: (clean(row.vod_content) || '') +
        (row.vod_content ? '\n\n' : '') +
        '播放说明：站点把每集地址做成令牌，需要站点的 protobuf + wasm 签名才能解（纯 JS 算不出），' +
        '所以播放交给 App 的网页播放器打开站点播放页，线路与选集在页面里选。',
      tags: clean(kinds).split(/\s*\/\s*/).filter(Boolean).slice(0, 6)
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    var data = await api('/api.php/web/vod/get_detail?vod_id=' + id);
    var rows = Array.isArray(data.data) ? data.data : [];
    if (!rows.length) throw new Error('多多追剧上没有这一条（可能已下架）');
    var lines = parsePlayLines(rows[0]);
    if (!lines.length) throw new Error('这一条在站点上没有播放线路');
    // 每条线路一项：播放时打开站点播放页，线路/选集在页面里选（令牌解码要站点 wasm）
    return lines.map(function (line, index) {
      return { id: 'line:' + index + ':' + line.code, title: line.code + '（' + line.count + ' 集）' };
    });
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.itemId || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('条目参数无效，请重新打开详情页');
    var pageUrl = base() + '/play/' + id;
    return {
      kind: 'webplayer',
      pageUrl: pageUrl,
      headers: { 'User-Agent': UA, 'Referer': base() + '/' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
