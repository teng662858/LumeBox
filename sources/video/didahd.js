// LumeSource: {"id":"didahd_video","name":"嘀嗒影视","version":"1.0.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.didahd.xyz","https://www.dida.im"],"network":"direct","icon":"https://www.didahd.xyz/template/mytheme/statics/img/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：嘀嗒影视（https://www.didahd.xyz；首页底部给出备用域 www.dida.im）。
// 形态：苹果CMS v10 + mytheme(myui) 模板：
//   栏目  /type/<tid>-<页>.html（tid 1 电影 / 2 电视剧 / 3 纪录片 / 4 动漫 / 5 综艺，48 条/页）
//   列表接口 /index.php/ajax/data?mid=1&tid=<tid>&page=<页>&limit=20（JSON，pagecount 51 页，
//         本源用它做真分页；缺字段时回落 HTML 栏目页）
//   榜单  /index.php/label/hot.html（热播榜，60 条）
//   搜索  /search/-------------.html?wd=<词>
//   详情  /detail/<id>.html
//   播放  /play/<id>-<sid>-<nid>.html（sid=线路，nid=集）
//        页面里 `var player_aaaa={"encrypt":3,"from":"<播放器>","url":"<...>"}`：
//          · from=quark/baidu/ucpan/pikpak/kuake → 网盘线路（不是在线视频）
//          · from=ffm3u8/lzm3u8/wjm3u8/1080zyk… → url 就是明文 m3u8，可直连
//          · from=rrmj/NBY/BBA/4kvm… → url 是 hex 密文，站点用 /static/player/rrmj.js →
//            /static/player/artplayer/?url=<hex> 里的混淆脚本（CryptoJS）现解，源里不复制这段
//            → 这类线路交给 App 的网页播放器（打开站点播放页即可播）
//
// ── VIP ──：站点没有会员/收费墙（详情页、播放页都没有 VIP/会员/付费标记，匿名可取全部线路），
//   本源只做线路分类，不做额外绕过；网盘线路如实标注「网盘，不可在线播放」。
//
// 限制：真实视频线路多为 hex 密文（artplayer 混淆脚本现解），所以 `content()` 对这类线路返回
//       webplayer；明文 m3u8 线路（高清线路①②/备用线路）直接给 video。

var HOST = 'https://www.didahd.xyz';
var MIRRORS = ['https://www.didahd.xyz', 'https://www.dida.im'];
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
var PAGE_SIZE = 20;

var CATS = [
  { id: 'hot', title: '热播榜', path: '/index.php/label/hot.html' },
  { id: '1', title: '电影' },
  { id: '2', title: '电视剧' },
  { id: '3', title: '纪录片' },
  { id: '4', title: '动漫' },
  { id: '5', title: '综艺' }
];

// 播放器代号 → 站点显示名（取自 /static/js/playerconfig.js 的 player_list）
var PLAYER_NAMES = {
  '4kvm': '线路一', MuiPlayer: '线路一', seven: '线路二', BBA: '蓝光G', yynb: '蓝光E',
  rrmj: '蓝光B', jdyx: '4K蓝光', gwj: '蓝光L', '857_': '动漫专线一', '1080dy': '线路三',
  hjkk: '线路四', hd5: '线路五', hd0: '线路Zero', zxyy: '蓝光B', b23: '蓝光D', bhyy: '蓝光A',
  xlyy: '蓝光E', cczz: '蓝光F', lbyy: '蓝光C', '03yy': '蓝光H', dytt: '备用线路', coze: '蓝光J',
  nkyy: '蓝光M', NBY: '蓝光K', lzm3u8: '高清线路②', ffm3u8: '高清线路①', pikpak: 'PikPak网盘',
  ucpan: 'UC网盘', kuake: '夸克网盘', quark: '夸克网盘', baidu: '百度网盘', wjm3u8: '高清备用③',
  '1080zyk': '备用线路①', bfzym3u8: '备用线路②', leshi: '极速有广①', '360zy': '极速有广②',
  dplayer: 'DP', videojs: 'videojs', iva: 'iva', iframe: '外链', link: '外链', art: 'artplayer',
  mlhd: '蓝光B', noyy: '蓝光E', sqys: '蓝光G', http: 'http下载', xunlei: '迅雷下载'
};
var NETDISK = { pikpak: 1, ucpan: 1, kuake: 1, quark: 1, baidu: 1 };

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
function decodeJsonText(text) {
  // player_aaaa 里的中文是 \uXXXX，JSON.parse 能直接还原
  return String(text == null ? '' : text).replace(/\\\//g, '/');
}
function fixImage(url) {
  var u = unescapeHtml(url);
  if (!u || u === '/') return '';
  return u;
}
function get(path) {
  return LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': base() + '/'
    }
  }).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('嘀嗒影视返回 HTTP ' + status + '：' + path);
    return reply.body == null ? '' : String(reply.body);
  });
}
function getJson(path) {
  return get(path).then(function (body) {
    try { return JSON.parse(body); } catch (e) { return null; }
  });
}

// ------------------------------------------------------------------ 解析
function parseCards(html) {
  var source = String(html || '');
  var out = [];
  var seen = {};
  // 卡片链接有 /detail/<id>.html 与 /play/<id>-<sid>-<nid>.html 两种；标题可能在 <a title> 或 <img alt>
  var re = /<a[^>]+href="\/(?:detail\/(\d+)\.html|play\/(\d+)-\d+-\d+\.html)"([^>]*)>/g;
  var m;
  while ((m = re.exec(source)) !== null) {
    var id = m[1] || m[2];
    if (!id || seen[id]) continue;
    var attrs = m[3] || '';
    var block = source.slice(re.lastIndex, re.lastIndex + 1200);
    var img = /<img[^>]*>/i.exec(block);
    if (!img) continue;
    var titleAttr = /\btitle="([^"]*)"/.exec(attrs);
    var alt = /alt="([^"]*)"/i.exec(img[0]);
    var title = titleAttr ? unescapeHtml(titleAttr[1]).trim() : (alt ? unescapeHtml(alt[1]).trim() : '');
    if (!title) continue;
    var dataOriginal = /data-original="([^"]+)"/i.exec(img[0]);
    var src = /src="([^"]+)"/i.exec(img[0]);
    var cover = dataOriginal ? fixImage(dataOriginal[1]) : (src ? fixImage(src[1]) : '');
    if (/load\.png|blank\.gif|placeholder/i.test(cover)) cover = '';
    var remark = /<span class="pic-tag[^"]*">([^<]*)<\/span>/.exec(block) ||
      /<span class="[^"]*text-red[^"]*">([^<]*)<\/span>/.exec(block) ||
      /<span class="text-right[^"]*">([^<]*)<\/span>/.exec(block);
    seen[id] = true;
    out.push({ id: id, title: title, cover: cover || null, subtitle: remark ? clean(remark[1]) : '' });
  }
  return out;
}

function parseDetail(html) {
  var source = String(html || '');
  var h1 = /<h1[^>]*>([\s\S]{0,200}?)<\/h1>/i.exec(source);
  var titleTag = /<title>([^<]*)<\/title>/i.exec(source);
  var title = clean(h1 ? h1[1] : '');
  if (!title && titleTag) title = clean(titleTag[1]).replace(/\s*-\s*嘀嗒影视\s*$/, '');
  var cover = '';
  var thumb = /<img[^>]+class="[^"]*(?:lazyload|thumb)[^"]*"[^>]+data-original="([^"]+)"/i.exec(source);
  if (thumb) cover = fixImage(thumb[1]);
  if (!cover) {
    var og = /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i.exec(source);
    if (og) cover = fixImage(og[1]);
  }
  var descBlock = /<div class="[^"]*(?:yp_context|data-content|vod_content)[^"]*"[^>]*>([\s\S]{0,3000}?)<\/div>/i.exec(source);
  var desc = descBlock ? clean(descBlock[1].replace(/<br\s*\/?>/gi, '\n')) : '';
  if (!desc) {
    var metad = /<meta name="description" content="([^"]*)"/i.exec(source);
    desc = metad ? unescapeHtml(metad[1]).trim() : '';
  }
  // 播放按钮：/play/<id>-<sid>-<nid>.html
  var playIds = [];
  var seen = {};
  var re = /\/play\/(\d+)-(\d+)-(\d+)\.html/g;
  var m;
  while ((m = re.exec(source)) !== null) {
    var sid = Number(m[2]);
    var nid = Number(m[3]);
    var key = sid + '-' + nid;
    if (seen[key]) continue;
    seen[key] = true;
    playIds.push({ id: m[1] + '-' + sid + '-' + nid, sid: sid, nid: nid });
  }
  playIds.sort(function (a, b) { return a.sid - b.sid || a.nid - b.nid; });
  var tags = [];
  var tagRe = /\/search\/[^"]*"[^>]*>([^<]{1,10})</g;
  var tm;
  while ((tm = tagRe.exec(source)) !== null) {
    var t = clean(tm[1]);
    if (t && tags.indexOf(t) < 0 && tags.length < 8) tags.push(t);
  }
  return { title: title, cover: cover, description: desc, episodes: playIds, tags: tags };
}

// player_aaaa：{"encrypt":3,"from":"rrmj","url":"<hex|m3u8>","sid":1,"nid":1}
function parsePlayer(html) {
  var source = String(html || '');
  var m = /var\s+player_aaaa\s*=\s*(\{[\s\S]*?\})\s*<\/script>/.exec(source);
  if (!m) return null;
  var json = decodeJsonText(m[1]);
  var data = null;
  try { data = JSON.parse(json); } catch (e) { data = null; }
  if (!data) return null;
  data.url = unescapeHtml(String(data.url || ''));
  return data;
}

function isHttpUrl(url) {
  return /^https?:\/\//i.test(String(url || ''));
}

var LumeSource = {
  id: 'didahd_video',
  name: '嘀嗒影视',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/template/mytheme/statics/img/favicon.ico',
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '嘀嗒影视（didahd.xyz，备用域 dida.im），苹果CMS mytheme 模板。列表走站内 AJAX 接口（真分页）；播放页为每个线路/分集单独页。明文 m3u8 线路直接播，hex 密文线路（蓝光B/K/G 等，由站点混淆脚本现解）交给 App 网页播放器；网盘线路（夸克/百度/UC/PikPak）不可在线播放，已在选集里标注。站点无会员/收费墙。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 站点的筛选是苹果CMS 的 /search/<类型>-<地区>-<年>-<字母>-----------.html，需要逐个分类试，
    // 站点当前没有开放组合筛选入口，这里如实不给假选项。
    return { groups: [] };
  },

  async home() {
    var blocks = [];
    var hot = parseCards(await get('/index.php/label/hot.html'));
    if (hot.length) blocks.push({ title: '热播榜', moreUrl: 'hot', items: hot.slice(0, 24) });
    var latest = parseCards(await get('/'));
    if (latest.length) blocks.push({ title: '最近更新', items: latest.slice(0, 24) });
    if (!blocks.length) throw new Error('嘀嗒影视：首页没有解析出条目（站点可能改版）');
    return blocks;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = clean(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var found = parseCards(await get('/search/-------------.html?wd=' + enc(keyword)));
      return { items: found, hasMore: false };
    }
    if (category === 'hot' || !category) {
      if (page > 1) return { items: [], hasMore: false };
      var hot = parseCards(await get('/index.php/label/hot.html'));
      if (!hot.length) throw new Error('嘀嗒影视：热播榜暂时为空');
      return { items: hot, hasMore: false };
    }
    var tid = category.replace(/[^0-9]/g, '');
    if (!tid) throw new Error('嘀嗒影视：认不出这个分类（' + category + '）');
    var json = await getJson('/index.php/ajax/data?mid=1&tid=' + tid + '&page=' + page + '&limit=' + PAGE_SIZE);
    var rows = (json && (json.list || json.data)) || [];
    if (rows.length) {
      var items = rows.map(function (row) {
        return {
          id: String(row.vod_id),
          title: String(row.vod_name || ''),
          cover: fixImage(row.vod_pic) || null,
          subtitle: [row.vod_remarks, row.vod_year].filter(Boolean).join(' · ')
        };
      }).filter(function (it) { return it.id && it.title; });
      var pages = Number(json.pagecount || 1);
      return { items: items, hasMore: page < pages };
    }
    // 接口没数据时回落 HTML 栏目页
    var html = await get('/type/' + tid + (page > 1 ? '-' + page : '') + '.html');
    var cards = parseCards(html);
    return { items: cards, hasMore: cards.length > 0 };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var html = '';
    try {
      html = await get('/detail/' + id + '.html');
    } catch (e) {
      return null;
    }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var lines = {};
    for (var i = 0; i < info.episodes.length; i++) lines[info.episodes[i].sid] = true;
    var bits = [];
    bits.push(Object.keys(lines).length + ' 条线路');
    bits.push(info.episodes.length > Object.keys(lines).length ? '共 ' + Math.max.apply(null, info.episodes.map(function (e) { return e.nid; })) + ' 集' : '正片');
    return {
      id: id,
      title: info.title,
      cover: info.cover || null,
      subtitle: bits.join(' · '),
      description: (info.description || '') +
        (info.description ? '\n\n' : '') +
        '播放说明：明文 m3u8 线路直接播放；站点把蓝光线路的地址做成混淆脚本现解，这类线路用 App 的网页播放器打开站点播放页；' +
        '网盘线路（夸克/百度/UC/PikPak）不能在线播放，已在选集标题里标注。',
      tags: info.tags
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    var html = await get('/detail/' + id + '.html');
    if (!html) throw new Error('嘀嗒影视上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.episodes.length) throw new Error('这一条在站点上没有播放线路');
    // 每条线路取第一集的播放页，读出 from → 显示名（同时识别网盘线路）
    var lineInfo = {};
    var sids = [];
    for (var i = 0; i < info.episodes.length; i++) {
      if (sids.indexOf(info.episodes[i].sid) < 0) sids.push(info.episodes[i].sid);
    }
    for (var s = 0; s < sids.length && s < 8; s++) {
      var first = null;
      for (var k = 0; k < info.episodes.length; k++) {
        if (info.episodes[k].sid === sids[s]) { first = info.episodes[k]; break; }
      }
      if (!first) continue;
      var label = '线路 ' + sids[s];
      var netdisk = false;
      try {
        var page = await get('/play/' + first.id + '.html');
        var player = parsePlayer(page);
        if (player && player.from) {
          label = PLAYER_NAMES[player.from] || String(player.from);
          netdisk = !!NETDISK[player.from];
        }
      } catch (e) { /* 读不到就保留默认名 */ }
      lineInfo[sids[s]] = { label: label, netdisk: netdisk };
    }
    var out = [];
    for (var j = 0; j < info.episodes.length; j++) {
      var ep = info.episodes[j];
      var meta = lineInfo[ep.sid] || { label: '线路 ' + ep.sid, netdisk: false };
      var many = info.episodes.length > 1;
      out.push({
        id: ep.id,
        title: meta.label + (meta.netdisk ? '（网盘·不可在线播放）' : '') + (many ? ' · 第 ' + ep.nid + ' 集' : ''),
        netdisk: meta.netdisk
      });
    }
    // 能在线播的线路排前面（网盘线路只是分享链接，放最后不挡默认选集）
    out.sort(function (a, b) { return (a.netdisk ? 1 : 0) - (b.netdisk ? 1 : 0); });
    return out.map(function (it) { return { id: it.id, title: it.title }; });
  },

  async content(argument) {
    var args = argument || {};
    var chapterId = String(args.chapterId || '').trim();
    var hit = /^(\d+)-(\d+)-(\d+)$/.exec(chapterId);
    var pageId = hit ? chapterId : '';
    if (!pageId) {
      var id = String(args.id || args.itemId || '').replace(/[^0-9]/g, '');
      if (!id) throw new Error('条目参数无效，请重新打开详情页');
      var html0 = await get('/detail/' + id + '.html');
      var info0 = parseDetail(html0);
      if (!info0.episodes.length) throw new Error('这一条在站点上没有播放线路');
      pageId = info0.episodes[0].id;
    }
    var pageUrl = base() + '/play/' + pageId + '.html';
    var html = await get('/play/' + pageId + '.html');
    if (!html) throw new Error('播放页打不开（可能已下架）：' + pageUrl);
    var player = parsePlayer(html);
    if (!player) throw new Error('播放页里没有 player_aaaa（站点可能改版）');
    if (NETDISK[player.from]) {
      throw new Error('这条是「' + (PLAYER_NAMES[player.from] || player.from) + '」线路，站点只提供网盘分享，不能在线播放；请换一条线路。');
    }
    if (isHttpUrl(player.url) && /\.(?:m3u8|mp4)(?:[?#]|$)/i.test(player.url)) {
      return {
        kind: 'video',
        url: player.url,
        headers: { 'User-Agent': UA, Referer: pageUrl }
      };
    }
    // hex 密文线路（artplayer 混淆脚本现解）→ 交给 App 的网页播放器
    return {
      kind: 'webplayer',
      pageUrl: pageUrl,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};

if (typeof module !== 'undefined' && module.exports) module.exports = LumeSource;
