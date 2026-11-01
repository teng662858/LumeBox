// LumeSource: {"id":"kpkuang_video","name":"看片狂人","version":"1.1.0","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://kpkuang.com","https://www.kpkuang.one","https://kpkuang.one","https://www.kpkuang.com"],"network":"direct","icon":"https://kpkuang.com/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：看片狂人（kpkuang.com；实测同内容镜像 www.kpkuang.one / kpkuang.one / www.kpkuang.com）。
//   形态：macCMS「vfed」模板，服务端渲染；详情页 1 MB 上下，结构稳定。
//
//   栏目   /vodtype/{tid}/            48 条/页，真分页 /vodtype/{tid}/page/{n}/
//          （1 电影 / 2 连续剧 / 37 短剧 是「总览页」——一页里分 10 个 12 条的小栏目、页码容易取到旧内容，
//           本源改用它们的子栏目：13 国产剧、14 港台剧、15 日韩剧、16 欧美剧、20 台剧、21 泰剧、
//           23 韩剧、30 海外剧、6–12 电影分类型、36/39–46 短剧细分、3 综艺、4 动漫、29 纪录片 —— 都是干净的 48 条列表）
//   详情   /voddetail/{id}/           标题、年份、简介、站内封面（/upload/ 兜底），以及「线路 → 分集」两组
//   播放   /vodplay/{id}-{sid}-{nid}.html
//            · data-play = 「若干字节前缀 + base64(真实地址)」。前缀长度随线路变，所以按 base64 里的
//              "aHR0c"（"http"）锚点截取，再纯 JS 解码（沙箱没有 atob / Buffer）。
//            · 解出来是 m3u8 / mp4 → 直接播；是腾讯/优酷/B站/Abyss/mixdrop 等外链 → 交网页播放器。
//   搜索   站内 /vodsearch/ 被 Cloudflare 挡（Just a moment），本源改走站点自己的搜索接口：
//            GET https://kpdata.flixfiend.top/esearch/index?kw=&ts=&callback=<jsonp>
//            → {"code":1,"js":"<base64 的 JSON 数组>"}；接口对同 IP 有短时限流（连发会 429），本源给可读提示。
//
//   线路排序：详情页常有 4–23 条线路（「4K/2160P」「1080P」「睿映HD」「720高清云」…以及「超清BY线」
//   「腾讯视频-VIP解析」这类外链线）。本源用「线路按钮 data-lineid → 线路名」建表，按
//   ①名字里的清晰度 ②资源站实测可用度 ③集数是否完整 排序，取前 4 条线路的分集进 chapters。

var HOST = 'https://kpkuang.com';
var MIRRORS = ['https://kpkuang.com', 'https://www.kpkuang.one', 'https://kpkuang.one', 'https://www.kpkuang.com'];
var ES_HOST = 'https://kpdata.flixfiend.top';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var PAGE_MIN = 40;       // 一页 48 条，少于此值视为最后一页
var LINE_LIMIT = 4;      // 进 chapters 的线路数

var CATS = [
  { id: '13', title: '国产剧' },
  { id: '14', title: '港台剧' },
  { id: '15', title: '日韩剧' },
  { id: '16', title: '欧美剧' },
  { id: '30', title: '海外剧' },
  { id: '20', title: '台剧' },
  { id: '23', title: '韩剧' },
  { id: '21', title: '泰剧' },
  { id: '36', title: '爽文短剧' },
  { id: '39', title: '现代都市短剧' },
  { id: '11', title: '剧情片' },
  { id: '6', title: '动作片' },
  { id: '9', title: '科幻片' },
  { id: '3', title: '综艺' },
  { id: '4', title: '动漫' },
  { id: '29', title: '纪录片' }
];

// 资源站权重（实测：rym3u8 / 360zy / ikunyun / moduplay 等 CDN 较稳；1080zyk 的 yzzy CDN 对本机 403）
var SRC_WEIGHT = {
  rym3u8: 45, moduplay: 30, ikunyun: 30, iqyplay: 26, '360zy': 18, lzm3u8: 24,
  wjm3u8: 22, sdm3u8: 22, ukm3u8: 20, ffm3u8: 20, hnm3u8: 20, gsm3u8: 18,
  xlm3u8: 18, jinyingm3u8: 18, bfzym3u8: 16, bfzy: 16, hnzy: 16, jszy: 16,
  mdzy: 16, ikzy: 16, jyzy: 16, tyyszy: 14, '1080zyk': 10, jisuplay: 10,
  subplay: 8, suoniplay: 4, huyaplay: 4, dyttplay: 2, hohuplay: 2
};
var EXTERNAL_SRC = { qq: 1, youku: 1, bilibili: 1, bys: 1, aby: 1, dara: 1, mixdrop: 1, vidara: 1, mgtv: 1, sohu: 1, qiyi: 1 };

// ------------------------------------------------------------------ 基础工具
function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function clean(t) {
  return String(t == null ? '' : t)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}
function abs(u) {
  var s = String(u || '').trim();
  if (!s) return '';
  if (/^https?:\/\//i.test(s)) return s;
  if (/^\/\//.test(s)) return 'https:' + s;
  return base() + (s.charAt(0) === '/' ? s : '/' + s);
}
function get(url, referer) {
  return LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer || base() + '/'
    }
  }).then(function (r) {
    var s = r ? r.status : 0;
    if (!s) throw new Error('连不上站点，请检查网络或到「源设置 → 站点网络」配置代理');
    if (s === 403 && /just a moment|challenge|cf-/i.test(String(r.body || '').slice(0, 400))) {
      throw new Error('NEED_WEBVIEW_VERIFY: ' + url);
    }
    if (s !== 200) throw new Error('站点返回 HTTP ' + s);
    return r.body ? String(r.body) : '';
  });
}
function readJson(file) {
  return LumeSource.fs.readText(file).then(function (t) {
    if (!t) return null;
    try { return JSON.parse(t); } catch (e) { return null; }
  }).catch(function () { return null; });
}
function writeJson(file, v) {
  return LumeSource.fs.writeText(file, JSON.stringify(v)).catch(function () { return null; });
}

// 纯 JS base64 解码（沙箱没有 atob / Buffer）
var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function b64decode(input) {
  var s = String(input || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var raw = '', i, buf = 0, bits = 0, idx;
  for (i = 0; i < s.length; i++) {
    var ch = s.charAt(i);
    if (ch === '=') break;
    idx = B64.indexOf(ch);
    if (idx < 0) continue;
    buf = (buf << 6) | idx;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      raw += String.fromCharCode((buf >> bits) & 0xFF);
    }
  }
  // UTF-8 还原
  var res = '', j = 0, code;
  while (j < raw.length) {
    code = raw.charCodeAt(j++);
    if (code < 0x80) res += String.fromCharCode(code);
    else if (code >= 0xC0 && code < 0xE0 && j < raw.length) {
      res += String.fromCharCode(((code & 0x1F) << 6) | (raw.charCodeAt(j++) & 0x3F));
    } else if (code >= 0xE0 && code < 0xF0 && j + 1 < raw.length) {
      res += String.fromCharCode(((code & 0x0F) << 12) | ((raw.charCodeAt(j++) & 0x3F) << 6) | (raw.charCodeAt(j++) & 0x3F));
    } else if (code >= 0xF0) {
      var c2 = j < raw.length ? raw.charCodeAt(j++) & 0x3F : 0;
      var c3 = j < raw.length ? raw.charCodeAt(j++) & 0x3F : 0;
      var c4 = j < raw.length ? raw.charCodeAt(j++) & 0x3F : 0;
      var cp = ((code & 0x07) << 18) | (c2 << 12) | (c3 << 6) | c4;
      cp -= 0x10000;
      res += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
    }
  }
  return res;
}

// data-play：「前缀 + base64(http…)」；按 "aHR0c"（base64 的 "http"）锚点截取最稳
function decodePlay(raw) {
  var s = String(raw == null ? '' : raw);
  if (!s) return '';
  var at = s.indexOf('aHR0c');
  if (at >= 0) return b64decode(s.slice(at));
  return b64decode(s.replace(/^[^A-Za-z0-9+/]*/, ''));
}
function isMedia(u) {
  return /^https?:\/\//i.test(u) && /\.(m3u8|mp4)(\?|$)/i.test(u);
}

// ------------------------------------------------------------------ 列表解析
function parseCards(html) {
  var text = String(html || ''), out = [], seen = {};
  var re = /<li id="listid_(\d+)_\d+"[\s\S]{0,1400}?href="\/voddetail\/\1\/"[^>]*title="([^"]{1,80})"[^>]*data-original="([^"]+)"/g;
  var m;
  while ((m = re.exec(text)) !== null) {
    var id = m[1];
    if (seen[id]) continue;
    seen[id] = 1;
    var near = text.slice(m.index, m.index + 1800);
    var remark = (/fed-list-remarks[^>]*>\s*([^<]{1,24}?)\s*</.exec(near) || [])[1] || '';
    var cover = abs(m[3]);
    var item = { id: id, title: clean(m[2]), cover: cover, subtitle: clean(remark) };
    if (/doubanio\.com/i.test(cover)) item.coverHeaders = { 'Referer': base() + '/' };
    out.push(item);
  }
  return out;
}

// ------------------------------------------------------------------ 详情解析
function parseDetail(html) {
  var text = String(html || '');
  var info = { title: '', year: '', cover: '', description: '', lines: [] };

  var h1 = (/<h1[^>]*>([\s\S]{0,300}?)<\/h1>/.exec(text) || [])[1] || '';
  info.title = clean((/<a[^>]*>([\s\S]{0,120}?)<\/a>/.exec(h1) || [])[1] || h1);
  info.year = (/<span class="uk-text-muted">\((\d{4})\)/.exec(h1) || [])[1] || '';

  // 站内封面优先（豆瓣外链封面要 Referer，站内 /upload/ 不需要）
  var defCover = (/var def_cover="([^"]+)"/.exec(text) || [])[1] || '';
  var ogCover = (/property="og:image"[^>]*content="([^"]+)"/.exec(text) || [])[1] || '';
  info.cover = defCover ? abs(defCover) : abs(ogCover);
  info.description = clean((/<meta name="description"[^>]*content="([\s\S]{0,400}?)"/.exec(text) || [])[1] || '');

  // 线路按钮：data-linename → data-lineid（src）
  var srcByName = {};
  var bRe = /id="from_([a-zA-Z0-9]+)"[^>]*data-linename="([^"]{1,40})"/g;
  var bm;
  while ((bm = bRe.exec(text)) !== null) srcByName[clean(bm[2])] = bm[1];

  // 每个 fed-play-item 块 = 一条线路（来自 X 的播放列表 + 该线路的分集）
  var chunks = text.split('class="fed-play-item fed-drop-item"');
  for (var i = 1; i < chunks.length; i++) {
    var body = chunks[i];
    var name = clean((/来自\s*<span class="uk-label">([^<]{1,40})<\/span>/.exec(body) || [])[1] || ('线路 ' + i));
    var eps = [], seen = {};
    var eRe = /href="\/vodplay\/\d+-(\d+)-(\d+)\.html"[^>]*>([\s\S]{0,240}?)<\/a>/g;
    var em;
    while ((em = eRe.exec(body)) !== null) {
      var key = em[1] + '-' + em[2];
      if (seen[key]) continue;
      seen[key] = 1;
      eps.push({ sid: em[1], nid: em[2], title: clean(em[3]) });
    }
    if (eps.length) info.lines.push({ name: name, src: srcByName[name] || '', sid: eps[0].sid, eps: eps });
  }
  return info;
}

// 线路排序：清晰度（4K/1080）> 资源站可用度 > 720；外链站压到最后
function lineScore(line) {
  var s = 0;
  var src = String(line.src || '').toLowerCase();
  var n = String(line.name || '');
  if (SRC_WEIGHT[src]) s += SRC_WEIGHT[src];
  if (EXTERNAL_SRC[src]) s -= 80;
  if (/4K|2160|蓝光|UHD/i.test(n)) s += 100;
  if (/1080/i.test(n)) s += 60;
  if (/高清|超清|HD/i.test(n)) s += 25;
  if (/720/i.test(n)) s -= 5;
  return s + Math.min(line.eps.length, 80) / 10;
}
function pickLines(lines) {
  var list = lines.slice(0);
  list.sort(function (a, b) { return lineScore(b) - lineScore(a); });
  return list.slice(0, LINE_LIMIT);
}

// ------------------------------------------------------------------ 入口
var LumeSource = {
  id: 'kpkuang_video',
  name: '看片狂人',
  version: '1.1.0',
  category: 'video',
  settingsApiVersion: 2,
  requiresSettings: ['settingsActions'],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '看片狂人（kpkuang.com）：国产剧、短剧、电影更新快，一条片子常有 4–23 条线路，含「4K/2160P」「1080P」等高码率线。直链 m3u8 直接播；腾讯/优酷/B站/Abyss 等外链线路自动交给网页播放器。个别资源站 CDN 会挡部分地区的 IP，播放失败时在选集里换一条线路。搜索走站点自带接口，不需要登录。'
    }
  ],

  async categories() { return CATS; },

  async list(argument) {
    var a = argument || {};
    var page = Math.max(1, Number(a.page || 1) || 1);
    var kw = String(a.keyword || '').trim();
    var cat = String(a.categoryId || '').trim();

    if (kw) {
      var api = ES_HOST + '/esearch/index?kw=' + encodeURIComponent(kw) + '&ts=' + Date.now() + '&callback=lume';
      var raw = '';
      try {
        raw = await get(api);
      } catch (e) {
        var msg = String((e && e.message) || e);
        if (/429/.test(msg)) throw new Error('站点搜索接口限流（HTTP 429）：站点限制搜索频率，稍等十几秒再搜');
        throw e;
      }
      var at = raw.indexOf('('), end = raw.lastIndexOf(')');
      if (at < 0 || end <= at) throw new Error('搜索接口返回格式异常');
      var payload = null;
      try { payload = JSON.parse(raw.slice(at + 1, end)); } catch (e2) { payload = null; }
      if (!payload || Number(payload.code) !== 1 || !payload.js) return { items: [], hasMore: false };
      var rows = [];
      try { rows = JSON.parse(b64decode(payload.js)) || []; } catch (e3) { rows = []; }
      var found = [];
      for (var i = 0; i < rows.length; i++) {
        var d = (rows[i] && rows[i].data) || {};
        var id = rows[i] && rows[i].id ? String(rows[i].id) : '';
        if (!id) continue;
        var cover = d.vod_douban_cover || (d.vod_pic ? abs(d.vod_pic) : '');
        var it = {
          id: id,
          title: clean(d.vod_name || ('作品 ' + id)),
          cover: cover,
          subtitle: clean([d.vod_year, d.vod_area].filter(Boolean).join(' '))
        };
        if (/doubanio\.com/i.test(cover)) it.coverHeaders = { 'Referer': base() + '/' };
        found.push(it);
      }
      return { items: found, hasMore: false };
    }

    if (!cat) cat = '13';
    if (!/^\d+$/.test(cat)) throw new Error('未知分类：' + cat);
    var url = base() + '/vodtype/' + cat + '/' + (page > 1 ? 'page/' + page + '/' : '');
    var cards = parseCards(await get(url));
    if (!cards.length) return { items: [], hasMore: false };

    var cache = (await readJson('items.json')) || { map: {} };
    var map = cache.map || {};
    for (var k = 0; k < cards.length; k++) map[cards[k].id] = { title: cards[k].title, cover: cards[k].cover };
    await writeJson('items.json', { at: Date.now(), map: map });
    return { items: cards, hasMore: cards.length >= PAGE_MIN && page < 900 };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return null;
    var cache = (await readJson('items.json')) || { map: {} };
    var row = cache.map ? cache.map[id] : null;
    var info = null;
    try {
      info = parseDetail(await get(base() + '/voddetail/' + id + '/'));
    } catch (e) {
      if (!row) throw e;
    }
    if (!info && !row) return null;
    var title = (info && info.title) || (row && row.title) || ('作品 ' + id);
    var cover = (info && info.cover) || (row && row.cover) || '';
    var out = {
      id: id,
      title: title,
      cover: cover,
      subtitle: (info && info.year) || '',
      description: (info && info.description) || '看片狂人（kpkuang.com）'
    };
    if (/doubanio\.com/i.test(cover)) out.coverHeaders = { 'Referer': base() + '/' };
    return out;
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return [];
    var info = parseDetail(await get(base() + '/voddetail/' + id + '/'));
    if (!info.lines.length) {
      return [{ id: 'web:' + id, title: '网页播放（该片暂无线路）' }];
    }
    var lines = pickLines(info.lines);
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      for (var j = 0; j < line.eps.length; j++) {
        var ep = line.eps[j];
        var epName = ep.title && ep.title !== '开始播放' ? ep.title : ('第' + (j + 1) + '集');
        out.push({ id: ep.sid + '|' + ep.nid, title: line.name + ' · ' + epName });
      }
    }
    return out;
  },

  async content(argument) {
    var a = argument || {};
    var id = String(a.id || '').replace(/\D/g, '');
    var raw = String(a.chapterId || '');
    if (raw.indexOf('web:') === 0 || raw.indexOf('|') < 0) {
      return { kind: 'webplayer', url: base() + '/voddetail/' + id + '/' };
    }
    var parts = raw.split('|');
    var sid = String(parts[0] || '').replace(/\D/g, '');
    var nid = String(parts[1] || '').replace(/\D/g, '');
    if (!sid || !nid) return { kind: 'webplayer', url: base() + '/voddetail/' + id + '/' };

    var playUrl = base() + '/vodplay/' + id + '-' + sid + '-' + nid + '.html';
    var html = await get(playUrl, base() + '/voddetail/' + id + '/');
    var dp = (/data-play="([^"]*)"/.exec(html) || [])[1] || '';
    var media = decodePlay(dp);
    if (isMedia(media)) {
      return { kind: 'video', url: media, headers: { 'User-Agent': UA, 'Referer': base() + '/' } };
    }
    return { kind: 'webplayer', url: playUrl };
  }
};
