// LumeSource: {"id":"czzy_video","name":"厂长资源","version":"1.0.3","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.4kcz.com","https://czzy.top","https://www.cz4k.com"],"network":"direct","icon":"https://www.4kcz.com/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：厂长资源 CZZY（导航页 https://cz01.vip/ → 新地址 www.4kcz.com，易记 cz01.tv；
//       导航里同时给出 czzy.top / www.cz4k.com / www.czzy.site，实测 czzy.top 返回 468（WAF），
//       只进 mirrors 供手选）。
// 形态：WordPress + mibt 主题（`movie_bt` 自定义文章类型）：
//   栏目  /zuixindianying /dbtop250 /gcj /meijutt /hanjutv /fanju /riju /haiwaijuqita /
//         /gaofenyingshi /huayudianying /oumeidianying /hanguodianying /ribendianying /
//         /yindudianying /eluosidianying /jianadadianying /dongmanjuchangban，分页 /<栏目>/page/N
//   全量  /movie_bt/（Beautiful Taxonomy Filters 表单）
//   筛选  /movie_bt/?movie_bt_series=&movie_bt_cat=&movie_bt_tags=&movie_bt_year=&paged=N
//         实测：?movie_bt_cat=meiguo（20 条）、?movie_bt_year=2026、
//         ?movie_bt_tags=maoxian&movie_bt_cat=meiguo（首条变化 → 真组合），
//         分页参数是 WordPress 的 paged（page 无效）。
//   搜索  /nimasile/?q=<词>
//   详情  /movie/<id>.html
//   播放  /v_play/<base64>.html —— base64 解出来是 `mv_<影片id>-nm_<序号>`；页面里 iframe 的
//         `url=` 参数就是真 m3u8（如 m3hlsm3.py1080p.com:907/hls3/hls/<片名>.m3u8），
//         实测 200 + application/vnd.apple.mpegurl（132 KB / 124 KB），分片不需要 Referer。
//   VIP：站点没有付费墙（「会员专区」movie_bt_series/huiyuanzhuanqu 实测 0 条，详情页无
//        VIP/会员/收费标记），匿名即可取到全部清晰度，本源不做额外绕过。

var HOST = 'https://www.4kcz.com';
// 镜像：czzy.top / www.cz4k.com 是导航页列出的内容域名（本机访问回 468 WAF，留作手选）；
// czzy.site 实测是「导航页」（2 KB，只列 4kcz.com / czzy.top / cz4k.com / cz01.tv），不是内容站，已移出 mirrors。
var MIRRORS = ['https://www.4kcz.com', 'https://czzy.top', 'https://www.cz4k.com'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

var CATS = [
  { id: 'movie_bt', title: '全部影片', path: '/movie_bt/' },
  { id: 'zuixindianying', title: '最新电影', path: '/zuixindianying' },
  { id: 'dbtop250', title: '豆瓣 Top250', path: '/dbtop250' },
  { id: 'gaofenyingshi', title: '高分影视', path: '/gaofenyingshi' },
  { id: 'huayudianying', title: '华语电影', path: '/huayudianying' },
  { id: 'oumeidianying', title: '欧美电影', path: '/oumeidianying' },
  { id: 'hanguodianying', title: '韩国电影', path: '/hanguodianying' },
  { id: 'ribendianying', title: '日本电影', path: '/ribendianying' },
  { id: 'yindudianying', title: '印度电影', path: '/yindudianying' },
  { id: 'eluosidianying', title: '俄罗斯电影', path: '/eluosidianying' },
  { id: 'jianadadianying', title: '加拿大电影', path: '/jianadadianying' },
  { id: 'gcj', title: '国产剧', path: '/gcj' },
  { id: 'meijutt', title: '美剧', path: '/meijutt' },
  { id: 'hanjutv', title: '韩剧', path: '/hanjutv' },
  { id: 'riju', title: '日剧', path: '/riju' },
  { id: 'fanju', title: '番剧', path: '/fanju' },
  { id: 'dongmanjuchangban', title: '剧场版', path: '/dongmanjuchangban' },
  { id: 'haiwaijuqita', title: '海外剧（其他）', path: '/haiwaijuqita' }
];

// 筛选选项都取自 /movie_bt/ 筛选表单里 cat-url 的真实 slug
var SERIES = [
  ['dyy', '电影'], ['dianshiju', '电视剧'], ['guochanju', '国产剧'], ['mj', '美剧'], ['hj', '韩剧'],
  ['rj', '日剧'], ['hwj', '海外剧（其他）'], ['dohua', '动画'], ['huayudianying', '华语电影'],
  ['meiguodianying', '欧美电影'], ['hanguodianying', '韩国电影'], ['ribendianying', '日本电影'],
  ['yindudianying', '印度电影'], ['eluosidianying', '俄罗斯电影'], ['jianadadianying', '加拿大电影'],
  ['zhanchangtuijian', '站长推荐']
];
var AREAS = [
  ['zh', '中国大陆'], ['hk', '中国香港'], ['tw', '中国台湾'], ['meiguo', '美国'], ['yinguo', '英国'],
  ['fg', '法国'], ['dg', '德国'], ['ydl', '意大利'], ['xby', '西班牙'], ['els', '俄罗斯'],
  ['riben', '日本'], ['hggggg', '韩国'], ['yidu', '印度'], ['taiguo', '泰国'], ['adly', '澳大利亚'],
  ['jnd', '加拿大'], ['bx', '巴西'], ['mxg', '墨西哥'], ['agenting', '阿根廷'], ['ruishi', '瑞士'],
  ['ruidian', '瑞典'], ['nuewei', '挪威'], ['fenlan', '芬兰'], ['danmai', '丹麦'], ['bilishi', '比利时'],
  ['hnwe', '荷兰'], ['bolan', '波兰'], ['jieke', '捷克'], ['aodili', '奥地利'], ['xila', '希腊'],
  ['tuerqi', '土耳其'], ['yuenan', '越南'], ['xinjiapo', '新加坡'], ['malaixiya', '马来西亚'],
  ['yindunixiya', '印度尼西亚'], ['taiguo2', '菲律宾'], ['yilang', '伊朗'], ['ysl', '以色列'],
  ['aiji', '埃及'], ['nanfei', '南非'], ['xinxilan', '新西兰'], ['aierlan', '爱尔兰'],
  ['baojialiya', '保加利亚'], ['luomaniya', '罗马尼亚'], ['xiongyali', '匈牙利'], ['wukelan', '乌克兰'],
  ['baieluosi', '白俄罗斯'], ['saipulusi', '塞浦路斯'], ['maerta', '马耳他'], ['lusenbao', '卢森堡'],
  ['monage', '摩纳哥'], ['island', '冰岛'], ['qt', '其他']
];
var TAGS = [
  ['juqing', '剧情'], ['dozuo', '动作'], ['xiju', '喜剧'], ['aiqing', '爱情'], ['kh', '科幻'],
  ['kubu', '恐怖'], ['kingsong', '惊悚'], ['xuanyi', '悬疑'], ['fanzui', '犯罪'], ['maoxian', '冒险'],
  ['qihuan', '奇幻'], ['dhh', '动画'], ['doman', '动漫'], ['lishi', '历史'], ['guzhuang', '古装'],
  ['zhanzheng', '战争'], ['wuxia', '武侠'], ['jiating', '家庭'], ['chuanji', '传记'], ['zainan', '灾难'],
  ['jlpp', '纪录片'], ['dp', '短片'], ['xiju2', '歌舞'], ['yundong', '运动'], ['yy', '音乐'],
  ['tongxing', '同性'], ['zrx', '真人秀'], ['qingse', '情色'], ['xb', '西部'], ['gw', '歌舞']
];
var YEARS = [
  ['19002000nd', '1900~2000 年代'], ['20012010nd', '2001~2010 年代'],
  ['2011nd', '2011'], ['2012', '2012'], ['2013', '2013'], ['2014', '2014'], ['2015', '2015'],
  ['2016', '2016'], ['2017', '2017'], ['2018', '2018'], ['2019', '2019'], ['2020', '2020'],
  ['2021', '2021'], ['2022', '2022'], ['2023', '2023'], ['2024', '2024'], ['2025', '2025'],
  ['2026', '2026'], ['2027', '2027'], ['2028', '2028']
];

var discoveredHost = '';
var detailCache = {};
var hostLoaded = false;
var loadedDomain = '';
async function readPersistent(key) {
  if (LumeSource.storage && LumeSource.storage.get) return LumeSource.storage.get(key, '');
  return LumeSource.fs.readText(key);
}
async function writePersistent(key, value) {
  if (LumeSource.storage && LumeSource.storage.set) return LumeSource.storage.set(key, value);
  return LumeSource.fs.writeText(key, value);
}
function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (discoveredHost || d || HOST).replace(/\/+$/, '');
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
async function readHost() {
  var configured = String(LumeSource.config && LumeSource.config.domain || HOST).replace(/\/+$/, '');
  if (hostLoaded && loadedDomain === configured) return;
  hostLoaded = true; loadedDomain = configured; discoveredHost = '';
  try {
    var record = JSON.parse(await readPersistent('czzy-host.json') || '{}');
    if (record.configured === configured && Date.now() - record.time < 6 * 3600000 && /^https:\/\/[a-z0-9.-]+$/i.test(record.host)) discoveredHost = record.host;
  } catch (_) {}
}
function requestPage(url) {
  return LumeSource.http.request({url: url, method: 'GET', headers: {
    'User-Agent': UA, 'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9', 'Referer': base() + '/'
  }});
}
function challenge(reply) {
  var body = String(reply && reply.body || '');
  var headers = reply && reply.headers || {};
  for (var key in headers) if (/^cf-mitigated$/i.test(key)) return true;
  return /<title[^>]*>\s*(?:just a moment|attention required)|challenge-platform|checking your browser/i.test(body);
}
async function discoverHost(path) {
  // Read only the primary address explicitly published by the official page.
  // Do not automatically rotate through known WAF-blocked mirrors.
  var nav = await requestPage('https://cz01.vip/');
  if (!nav || nav.status !== 200) return null;
  var match = /href:\s*['"](https:\/\/[a-z0-9.-]+)['"]/i.exec(String(nav.body || ''));
  if (!match || match[1] === base()) return null;
  var reply = await requestPage(match[1] + path);
  if (!reply || reply.status !== 200 || challenge(reply) || !/\/movie\/|\/v_play\//i.test(String(reply.body || ''))) return null;
  discoveredHost = match[1];
  try { await writePersistent('czzy-host.json', JSON.stringify({
    configured: String(LumeSource.config && LumeSource.config.domain || HOST).replace(/\/+$/, ''),
    host: discoveredHost, time: Date.now()
  })); } catch (_) {}
  return reply;
}
var pendingDetails = {};
function get(path, referer) {
  if (!/^\/(?:detail|movie)\//.test(path)) return getOnce(path, referer);
  var key = base() + path;
  if (pendingDetails[key]) return pendingDetails[key];
  var pending = getOnce(path, referer);
  pendingDetails[key] = pending;
  return pending.then(function (value) { delete pendingDetails[key]; return value; },
    function (error) { delete pendingDetails[key]; throw error; });
}
async function getOnce(path) {
  await readHost();
  var absolute = /^https?:\/\//i.test(path);
  var url = absolute ? path : base() + path;
  var cached = detailCache[url];
  if (!absolute && /^\/movie\//.test(path) && cached && Date.now() - cached.time < 60000) return cached.body;
  var reply;
  try { reply = await requestPage(url); }
  catch (error) {
    if (absolute) throw error;
    try { reply = await discoverHost(path); } catch (_) {}
    if (!reply) throw error;
  }
  var status = reply && reply.status || 0;
  if (challenge(reply)) throw new Error('NEED_WEBVIEW_VERIFY：厂长资源需要网页校验，请完成后重试：' + (absolute ? path : base() + path));
  if (!absolute && (status === 0 || status >= 500)) {
    try { var alternate = await discoverHost(path); if (alternate) { reply = alternate; status = reply.status; } } catch (_) {}
  }
  if (status === 404) return '';
  if (!status) throw new Error('连不上厂长资源，请检查网络或通过源设置打开发布页：' + base());
  if (status !== 200) throw new Error('厂长资源返回 HTTP ' + status + '：' + path);
  var body = String(reply.body || '');
  if (!absolute && /^\/movie\//.test(path)) {
    detailCache = {}; detailCache[base() + path] = {time: Date.now(), body: body};
  }
  return body;
}

function fixImage(url) {
  var u = unescapeHtml(url);
  if (!u) return '';
  if (/blank\.gif/i.test(u)) return '';
  if (u.indexOf('//') === 0) u = 'https:' + u;
  return u;
}

// 卡片：<li><a href="…/movie/<id>.html"><img … alt="标题" data-original="封面">…<h3 class="dytit">
function parseCards(html) {
  var source = String(html || '');
  var out = [];
  var seen = {};
  var parts = source.split(/<a[^>]+href="https?:\/\/[^"]*\/movie\/(\d+)\.html"[^>]*>/);
  for (var i = 1; i + 1 < parts.length; i += 2) {
    var id = parts[i];
    if (!id || seen[id]) continue;
    var block = String(parts[i + 1] || '').slice(0, 1500);
    var img = /<img[^>]*>/i.exec(block);
    var title = '';
    var cover = '';
    if (img) {
      var alt = /alt="([^"]*)"/i.exec(img[0]);
      var dataOriginal = /data-original="([^"]+)"/i.exec(img[0]);
      title = alt ? unescapeHtml(alt[1]).trim() : '';
      cover = dataOriginal ? fixImage(dataOriginal[1]) : '';
    }
    if (!title) {
      var h3 = /<h3[^>]*class="dytit"[^>]*>\s*<a[^>]*>([^<]*)<\/a>/i.exec(block);
      if (h3) title = unescapeHtml(h3[1]).trim();
    }
    if (!title) continue;
    var remarks = /<div class="jidi"><span>([^<]*)<\/span>/.exec(block);
    var kind = /<div class="hdinfo">\s*<span[^>]*>([^<]*)<\/span>/.exec(block);
    var rating = /<div class="rating">([\d\.]+)<\/div>/.exec(block);
    var bits = [];
    if (kind && clean(kind[1])) bits.push(clean(kind[1]));
    if (remarks && clean(remarks[1])) bits.push(clean(remarks[1]));
    if (rating) bits.push(clean(rating[1]) + ' 分');
    seen[id] = true;
    out.push({ id: id, title: title, cover: cover || null, subtitle: bits.join(' · ') });
  }
  return out;
}

// 详情页：标题 / 封面 / 简介 / 播放按钮列表
function parseDetail(html) {
  var source = String(html || '');
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  var title = clean(titleTag ? titleTag[1] : '').replace(/\s*_\s*厂长资源\s*$/i, '')
    .replace(/《([^》]+)》.*$/, '$1').replace(/^《|》$/g, '');
  var h1 = /<h1[^>]*class="[^"]*yp_title[^"]*"[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(source) ||
    /<div class="yp_title"[^>]*>([\s\S]{0,200}?)<\/div>/i.exec(source);
  if (h1) title = clean(h1[1]);
  var og = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
  var cover = og ? fixImage(og[1]) : '';
  if (!cover) {
    var thumb = /<img[^>]+class="[^"]*thumb[^"]*"[^>]+data-original="([^"]+)"/i.exec(source);
    if (thumb) cover = fixImage(thumb[1]);
  }
  var descBlock = /<div class="yp_context">([\s\S]{0,4000}?)<\/div>/i.exec(source);
  var desc = descBlock ? clean(descBlock[1].replace(/<br\s*\/?>/gi, '\n')) : '';
  if (!desc) {
    var metad = /<meta name="description" content="([^"]*)"/i.exec(source);
    desc = metad ? unescapeHtml(metad[1]).trim() : '';
  }
  var plays = [];
  var seen = {};
  var re = /<a[^>]+href="([^"]*\/v_play\/[^"]+)"[^>]*>([\s\S]{0,80}?)<\/a>/gi;
  var m;
  while ((m = re.exec(source)) !== null) {
    var url = unescapeHtml(m[1]);
    var hit = /\/v_play\/([A-Za-z0-9_\-=]+)\.html/.exec(url);
    if (!hit || seen[hit[1]]) continue;
    seen[hit[1]] = true;
    var label = clean(m[2]);
    plays.push({ id: hit[1], title: label || ('线路 ' + (plays.length + 1)) });
  }
  var tags = [];
  var tagRe = /\/movie_bt_tags\/[a-z0-9\-]+"[^>]*>([^<]{1,10})</g;
  var tm;
  while ((tm = tagRe.exec(source)) !== null) {
    var t = clean(tm[1]);
    if (t && tags.indexOf(t) < 0) tags.push(t);
  }
  return { title: title, cover: cover, description: desc, plays: plays, tags: tags.slice(0, 8) };
}

function filterQuery(filters) {
  var params = [];
  if (filters.series) params.push('movie_bt_series=' + enc(filters.series));
  if (filters.cat) params.push('movie_bt_cat=' + enc(filters.cat));
  if (filters.tags) params.push('movie_bt_tags=' + enc(filters.tags));
  if (filters.year) params.push('movie_bt_year=' + enc(filters.year));
  return params.join('&');
}

function hasNext(html, page, query) {
  var source = String(html || '');
  if (query) return source.indexOf('paged=' + (page + 1)) >= 0;
  return new RegExp('/page/' + (page + 1) + '/?"').test(source) || source.indexOf('/page/' + (page + 1)) >= 0;
}

var LumeSource = {
  id: 'czzy_video',
  name: '厂长资源',
  version: '1.0.3',
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
      url: 'https://cz01.vip/',
      description: '导航页（会列出当前可用域名：www.4kcz.com / czzy.top / www.cz4k.com / cz01.tv）'
    },
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '厂长资源（www.4kcz.com，导航页 cz01.vip）。WordPress + mibt 主题；本源从 /v_play 播放页的 iframe 里取真 m3u8 直连。站点没有付费墙（会员专区实测为空），匿名可播。校验过期时会提示在网页视图重新验证；连接失败会从官方发布页发现并验证新的主地址，详情与分集复用 60 秒缓存。筛选（系列/地区/类型/年份）按站点 Beautiful Taxonomy Filters 的查询串拼接，实测可组合；翻页用 WordPress 的 paged。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    return {
      groups: [
        {
          key: 'series', title: '系列', multiple: false,
          options: SERIES.map(function (s) { return { id: s[0], title: s[1] }; })
        },
        {
          key: 'cat', title: '地区', multiple: false,
          options: AREAS.map(function (s) { return { id: s[0], title: s[1] }; })
        },
        {
          key: 'tags', title: '类型', multiple: false,
          options: TAGS.map(function (s) { return { id: s[0], title: s[1] }; })
        },
        {
          key: 'year', title: '年份', multiple: false,
          options: YEARS.map(function (s) { return { id: s[0], title: s[1] }; })
        }
      ]
    };
  },

  async home() {
    var html = await get('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最近更新', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = clean(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};

    if (keyword) {
      var found = parseCards(await get('/nimasile/?q=' + enc(keyword)));
      return { items: found, hasMore: false };
    }

    var query = filterQuery(filters);
    var html;
    if (query) {
      html = await get('/movie_bt/?' + query + (page > 1 ? '&paged=' + page : ''));
    } else {
      var cat = null;
      for (var i = 0; i < CATS.length; i++) {
        if (CATS[i].id === category) { cat = CATS[i]; break; }
      }
      if (!cat) cat = CATS[0];
      var path = cat.path.replace(/\/+$/, '');
      html = await get(path + '/' + (page > 1 ? 'page/' + page + '/' : ''));
    }
    var items = parseCards(html);
    return { items: items, hasMore: hasNext(html, page, query) };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var html = '';
    html = await get('/movie/' + id + '.html');
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var bits = [];
    bits.push(info.plays.length > 1 ? info.plays.length + ' 条播放线路' : '正片');
    bits.push('m3u8 直连');
    return {
      id: id,
      title: info.title,
      cover: info.cover || null,
      subtitle: bits.join(' · '),
      description: (info.description || '') +
        (info.description ? '\n\n' : '') +
        '播放说明：本源从站点 /v_play 播放页里的播放器 iframe 取真实 m3u8 直链（站点没有付费墙），' +
        '多条播放线路会分别列在选集里。',
      tags: info.tags
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    var html = await get('/movie/' + id + '.html');
    if (!html) throw new Error('厂长资源上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.plays.length) throw new Error('这一条在站点上没有播放线路');
    return info.plays.map(function (p) { return { id: p.id, title: p.title }; });
  },

  async content(argument) {
    var args = argument || {};
    var chapter = String(args.chapterId || '').trim();
    var id = String(args.id || args.itemId || '').replace(/[^0-9]/g, '');
    var playId = /^[A-Za-z0-9_\-=]+$/.test(chapter) ? chapter : '';
    var pageUrl;
    if (!playId) {
      if (!id) throw new Error('条目参数无效，请重新打开详情页');
      var html0 = await get('/movie/' + id + '.html');
      var info0 = parseDetail(html0);
      if (!info0.plays.length) throw new Error('这一条在站点上没有播放线路');
      playId = info0.plays[0].id;
    }
    pageUrl = base() + '/v_play/' + playId + '.html';
    var html = await get('/v_play/' + playId + '.html');
    if (!html) throw new Error('播放页打不开（可能已下架）：' + pageUrl);
    // 播放器 iframe：src="…/player/…?…&url=<m3u8>"
    var frames = [];
    var re = /<iframe[^>]+src="([^"]+)"/gi;
    var m;
    while ((m = re.exec(html)) !== null) frames.push(unescapeHtml(m[1]));
    for (var i = 0; i < frames.length; i++) {
      var src = frames[i];
      if (!/^https?:\/\//i.test(src)) continue;
      var q = /[?&]url=([^&]+)/.exec(src);
      if (!q) continue;
      var url = decodeURIComponent(q[1]);
      if (/^https?:\/\//i.test(url)) {
        // 形如 https://m3hlsm3.py1080p.com:907/hls3/hls/<片名>.m3u8 —— 直连 m3u8
        return {
          kind: 'video',
          url: url,
          headers: { 'User-Agent': UA, Referer: pageUrl }
        };
      }
      // 另一种是播放器令牌（videos<token>）：由站点自己的 py.php 播放器解出真地址，
      // 页面里 `const mysvg = '<m3u8>'` / `art.url = '<m3u8>'`。
      try {
        var player = await get(src);
        var hit = /(?:const\s+mysvg|art\.url)\s*=\s*['"](https?:\/\/[^'"]+\.m3u8[^'"]*)['"]/i.exec(String(player || ''));
        if (hit) {
          return {
            kind: 'video',
            url: hit[1],
            headers: { 'User-Agent': UA, Referer: src }
          };
        }
      } catch (e) {
        /* 令牌解不出来时继续找其它 iframe */
      }
    }
    // 没有可直取的地址：交给 App 的网页播放器打开站点自己的播放页
    return { kind: 'webplayer', pageUrl: pageUrl, headers: { 'User-Agent': UA, Referer: base() + '/' } };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
