// LumeSource: {"id":"ppnix_video","name":"PPnix","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.ppnix.com","https://ppnix.com"],"network":"direct","icon":"https://www.ppnix.com/r/logo.png"}
// LumeRuntime: javascript
//
// 站点：PPnix（https://www.ppnix.com/cn/ 简体；同站 /tw/ 繁体、/ 英文，是同一套片库的语言路径，不当镜像）。
// 形态：自研 PHP 站点（服务端渲染 HTML + artplayer + hls.js）：
//   栏目  /cn/movie/  电影、/cn/tv/  电视剧
//   筛选  /cn/{movie|tv}/{类型}-{国家}-{年代}-{页码0基}-{排序}.html
//         实测：/cn/movie/剧情---1-.html（剧情第 2 页）、/cn/movie/-韩国---.html、
//         /cn/movie/剧情-韩国-2026--.html（组合筛选，24 → 8 条）、
//         /cn/movie/----onclick.html（热门）、----rating.html（评分）、----year.html（按年份）都生效；
//         未知排序键会直接返回 0 条，所以下面只列实测可用的四个。
//   搜索  /cn/search/<词>--.html
//   详情  /cn/{movie|tv}/<infoid>.html：页面内联 `infoid=8616; m3u8=['1080P']`（剧集是 ['1'..'23']）
//   播放  /info/m3u8/<infoid>/<param>.m3u8 —— 直接返回 HLS 清单（实测 200 + application/vnd.apple.mpegurl），
//         电影 179 KB、剧集单集 60 KB；分片 key 走清单里的相对 ../key，不需要 Referer。
//   VIP：站点详情页、播放页均无 VIP/会员/收费标记，`/info/m3u8/` 对匿名一律放行（实测 24 条随机电影全通），
//        所以本源不做额外绕过，也不声明 quality 设置。
//
// 限制：站点只有「电影/电视剧」两个栏目（导航就这两项）；筛选组的选项来自站点筛选区，逐项实测有效。

var HOST = 'https://www.ppnix.com';
var MIRRORS = ['https://www.ppnix.com', 'https://ppnix.com'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
var PAGE_SIZE = 24;
var LANG = '/cn';

var CATS = [
  { id: 'movie', title: '电影', path: '/movie' },
  { id: 'tv', title: '电视剧', path: '/tv' }
];

var TYPES = ['剧情', '喜剧', '动作', '惊悚', '爱情', '犯罪', '冒险', '恐怖', '悬疑', '奇幻', '科幻', '动画', '战争', '传记', '历史', '家庭', '音乐', '同性', '纪录片', '歌舞', '运动', '古装', '灾难', '武侠', '西部', '儿童', '短片', '黑色电影', '戏曲'];
var AREAS = ['美国', '英国', '日本', '中国大陆', '法国', '中国香港', '韩国', '德国', '加拿大', '意大利', '西班牙', '澳大利亚', '台湾', '印度', '泰国', '俄罗斯', '新加坡', '马来西亚', '瑞典', '丹麦', '荷兰', '波兰', '巴西', '墨西哥', '阿根廷', '土耳其', '越南', '菲律宾', '印度尼西亚', '比利时', '瑞士', '挪威', '芬兰', '奥地利', '捷克', '爱尔兰', '新西兰', '南非', '希腊', '葡萄牙', '冰岛', '塞尔维亚', '保加利亚', '罗马尼亚', '匈牙利', '智利', '伊朗', '苏联', '阿联酋', '以色列', '乌克兰', '埃及', '古巴', '秘鲁', '哥伦比亚', '克罗地亚', '爱沙尼亚', '拉脱维亚', '立陶宛', '斯洛文尼亚', '斯洛伐克', '卢森堡', '马耳他', '西德', '摩纳哥', '巴基斯坦', '孟加拉国', '斯里兰卡', '尼泊尔'];
var YEARS = ['2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015', '2014', '2013', '2012', '2011', '2010', '2009', '2008', '2007', '2006', '2005', '2004', '2003', '2002', '2001', '2000', '1999', '1998', '1997', '1996', '1995', '1994', '1993', '1992', '1991', '1990', '1989', '1988', '1987', '1986', '1985', '1984', '1983', '1982', '1981', '1980'];
// 站点筛选区的「排序」区（实测生效的键）
var SORTS = [
  { id: '', title: '最新更新' },
  { id: 'onclick', title: '最热（点击）' },
  { id: 'rating', title: '评分最高' },
  { id: 'year', title: '按年份' }
];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(text) { return encodeURIComponent(String(text == null ? '' : text)); }
function unescapeHtml(text) {
  return String(text == null ? '' : text)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#x27;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code)); });
}
function clean(text) {
  return unescapeHtml(String(text == null ? '' : text).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}
function get(path) {
  return LumeSource.http.request({
    url: base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + LANG + '/'
    }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('PPnix 返回 HTTP ' + status + '：' + path);
    return reply.body == null ? '' : String(reply.body);
  });
}

// ------------------------------------------------------------------ 解析
// 卡片：<li><a href="/cn/movie/<id>.html" class="thumbnail"><img ... src="封面" alt="标题">
function parseCards(html) {
  var source = String(html || '');
  var out = [];
  var seen = {};
  var re = /<a\s+href="\/cn\/(movie|tv)\/(\d+)\.html"\s+class="thumbnail"[^>]*>([\s\S]{0,800}?)<\/a>/gi;
  var match;
  while ((match = re.exec(source)) !== null) {
    var key = match[1] + ':' + match[2];
    if (seen[key]) continue;
    seen[key] = true;
    var block = match[3];
    var img = /<img[^>]*>/i.exec(block);
    var title = '';
    var cover = '';
    if (img) {
      var alt = /alt="([^"]*)"/i.exec(img[0]);
      var src = /src="([^"]+)"/i.exec(img[0]);
      title = alt ? unescapeHtml(alt[1]).trim() : '';
      cover = src ? unescapeHtml(src[1]) : '';
    }
    var rate = /<span class="rate">([\d\.]+)<\/span>/.exec(block);
    var note = /<div class="note"><span>([^<]*)<\/span><\/div>/.exec(block);
    var country = /<div class="countrie"><span[^>]*>([^<]*)<\/span>/.exec(block);
    var bits = [];
    if (country) bits.push(clean(country[1]));
    if (note && clean(note[1])) bits.push(clean(note[1]));
    out.push({
      id: key,
      title: title || ('影片 ' + match[2]),
      cover: cover,
      subtitle: bits.join(' · '),
      rating: rate ? rate[1] : ''
    });
  }
  return out;
}

// 详情页内联：classid=1;classurl='/movie/';infoid=8616;sub='|en|cn|tw|';m3u8=['1080P']
function parseDetail(html) {
  var source = String(html || '');
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  var title = clean(titleTag ? titleTag[1] : '').replace(/\s*-\s*PPnix\s*$/i, '');
  var h1 = /<h1 class="product-title">([\s\S]{0,200}?)<\/h1>/i.exec(source);
  if (h1) {
    title = clean(h1[1]).replace(/\s*\(\d{4}\)\s*$/, '').replace(/\s*(?:star star\d+|rate[\s\S]*)$/i, '').trim();
    var yearIn = /\((\d{4})\)/.exec(clean(h1[1]));
    if (yearIn) title = clean(h1[1]).split('(')[0].trim();
  }
  var thumb = /<header class="product-header"><img src="([^"]+)"/i.exec(source);
  var desc = /<meta name="description" content="([^"]*)"/i.exec(source);
  var info = /classid=(\d+);classurl='([^']*)';infoid=(\d+);sub='([^']*)';m3u8=(\[[^\]]*\])/.exec(source);
  var params = [];
  if (info) {
    try {
      params = JSON.parse(String(info[5]).replace(/'/g, '"')) || [];
    } catch (e) {
      params = [];
    }
  }
  var director = /导演：<span><a[^>]*>([^<]*)<\/a>/.exec(source);
  var actors = /主演：<span>([\s\S]{0,600}?)<\/span>/.exec(source);
  var kinds = [];
  var kindRe = /类型：<span>([\s\S]{0,400}?)<\/span>/.exec(source);
  if (kindRe) {
    var km = kindRe[1].match(/>([^<>]{1,10})</g) || [];
    for (var i = 0; i < km.length; i++) {
      var t = clean(km[i].replace(/[<>]/g, ''));
      if (t && t !== '/' && kinds.indexOf(t) < 0) kinds.push(t);
    }
  }
  return {
    title: title,
    cover: thumb ? unescapeHtml(thumb[1]) : '',
    description: desc ? unescapeHtml(desc[1]).trim() : '',
    infoid: info ? info[3] : '',
    classid: info ? info[1] : '1',
    classurl: info ? info[2] : '/movie/',
    subs: info ? String(info[4]).split('|').filter(Boolean) : [],
    params: params,
    director: director ? clean(director[1]) : '',
    actors: actors ? clean(actors[1].replace(/<[^>]+>/g, ' ')).split(/\s*\/\s*/).slice(0, 6).join(' / ') : '',
    tags: kinds
  };
}

function hasNext(html, page) {
  return new RegExp('/---' + page + '-[^"]*\\.html"').test(String(html || '').replace(/&amp;/g, '&'));
}

// /cn/{movie|tv}/{type}-{area}-{year}-{page-1}-{sort}.html
function listPath(category, page, filters) {
  var cat = category === 'tv' ? 'tv' : 'movie';
  var type = String(filters.type || '').trim();
  var area = String(filters.area || '').trim();
  var year = String(filters.year || '').trim();
  var sort = String(filters.sort || '').trim();
  if (type && TYPES.indexOf(type) < 0) type = '';
  if (area && AREAS.indexOf(area) < 0) area = '';
  if (year && YEARS.indexOf(year) < 0) year = '';
  var sortOk = false;
  for (var i = 0; i < SORTS.length; i++) if (SORTS[i].id === sort) sortOk = true;
  if (!sortOk) sort = '';
  var index = page > 1 ? String(page - 1) : '';
  return LANG + '/' + cat + '/' + type + '-' + area + '-' + year + '-' + index + '-' + sort + '.html';
}

var LumeSource = {
  id: 'ppnix_video',
  name: 'PPnix',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/r/logo.png',
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: 'PPnix（ppnix.com，简体 /cn/，繁体 /tw/）。本源直接取站点自己的 HLS 接口 /info/m3u8/<id>/<集>.m3u8 播整片；站点没有 VIP/收费标记，匿名可播。只有「电影 / 电视剧」两个栏目，筛选（类型/国家/年代/排序）按站点 URL 规则拼接，实测可组合。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    return {
      groups: [
        {
          key: 'type', title: '类型', multiple: false,
          options: TYPES.map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'area', title: '国家/地区', multiple: false,
          options: AREAS.map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'year', title: '年代', multiple: false,
          options: YEARS.map(function (t) { return { id: t, title: t }; })
        },
        {
          key: 'sort', title: '排序', multiple: false,
          options: SORTS.map(function (s) { return { id: s.id, title: s.title }; })
        }
      ]
    };
  },

  async home() {
    var html = await get(LANG + '/');
    var items = parseCards(html);
    var hot = [];
    try {
      hot = parseCards(await get(listPath('movie', 1, { sort: 'onclick' })));
    } catch (e) {
      hot = [];
    }
    var blocks = [];
    if (items.length) blocks.push({ title: '正在上映', items: items.slice(0, 24) });
    if (hot.length) blocks.push({ title: '热门电影', moreUrl: 'movie', items: hot.slice(0, 24) });
    if (!blocks.length) throw new Error('PPnix：首页没有解析出条目（站点可能改版）');
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
      var found = parseCards(await get(LANG + '/search/' + enc(keyword.replace(/-/g, ' ')) + '--.html'));
      return { items: found, hasMore: false };
    }
    var path = listPath(category, page, filters);
    var html = await get(path);
    var items = parseCards(html);
    if (!items.length && !filters.type && !filters.area && !filters.year && !filters.sort) {
      console.warn('[ppnix] 列表没解析出条目：' + path);
    }
    return { items: items, hasMore: items.length >= PAGE_SIZE - 2 };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    var hit = /^(movie|tv):(\d+)$/.exec(id);
    if (!hit) return null;
    var path = LANG + '/' + hit[1] + '/' + hit[2] + '.html';
    var html = '';
    try {
      html = await get(path);
    } catch (e) {
      return null;
    }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var bits = [];
    if (info.params.length > 1) bits.push('共 ' + info.params.length + ' 集');
    else bits.push('正片');
    if (info.director) bits.push('导演 ' + info.director);
    var desc = info.description || '';
    if (info.actors) desc += (desc ? '\n' : '') + '主演：' + info.actors;
    desc += (desc ? '\n\n' : '') + '播放说明：直接取站点 HLS 接口（/info/m3u8/…），剧集按集切换。';
    return {
      id: id,
      title: info.title,
      cover: info.cover || null,
      subtitle: bits.join(' · '),
      description: desc,
      tags: info.tags
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    var hit = /^(movie|tv):(\d+)$/.exec(id);
    if (!hit) return [];
    var html = await get(LANG + '/' + hit[1] + '/' + hit[2] + '.html');
    if (!html) throw new Error('PPnix 上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.params.length) throw new Error('这一条在站点上没有播放参数');
    var many = info.params.length > 1;
    return info.params.map(function (p) {
      return { id: String(p), title: many ? (/^\d+$/.test(String(p)) ? '第 ' + p + ' 集' : String(p)) : '正片（' + p + '）' };
    });
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.itemId || '').trim();
    var hit = /^(movie|tv):(\d+)$/.exec(id);
    if (!hit) throw new Error('条目参数无效，请重新打开详情页');
    var html = await get(LANG + '/' + hit[1] + '/' + hit[2] + '.html');
    var info = parseDetail(html);
    if (!info.infoid) throw new Error('站点页面里没有 infoid（可能改版）');
    var param = String(args.chapterId || '').trim();
    if (!param) param = info.params.length ? String(info.params[0]) : '1080P';
    var url = base() + '/info/m3u8/' + info.infoid + '/' + enc(param) + '.m3u8';
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, 'Referer': base() + LANG + '/' + hit[1] + '/' + hit[2] + '.html' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
