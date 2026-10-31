// LumeSource: {"id":"bahaotv_video","name":"八号影视","version":"1.0.1","category":"video","contentCategory":"movie","settingsApiVersion":2,"requiresSettings":["commonSettings","settingsActions"],"mirrors":["https://www.bhtv001.com","https://www.bahaotv.com"],"network":"direct","icon":"https://www.bhtv001.com/icon.png"}
// LumeRuntime: javascript
//
// 站点：八号影视（bahaotv.com 的证书签发名是 bhtv001.com，两者同一台站；
//       本源默认走证书匹配的 www.bhtv001.com，避免 TLS 名称校验失败）。
// 形态：苹果CMS v10 + shoutu38 主题，服务端渲染 HTML。
//
// ── 播放：本源自己解出直链 ──
//   详情页 /details/<id>.html 列出线路（playlist1..N）与分集 /vodplay/<id>-<线路>-<集>.html；
//   播放页里是 `var player_aaaa={... "url":"https://xx.kanrenao.cn/v/ty/<sid>","from":"iframe"}`，
//   该 iframe 页再给出 `var rand="<16 位>"` 与 `var player="<base64>"`，
//   用 AES-128-CBC（key=VFBTzdujpR9FWBhe，iv=rand，Pkcs7）解出 JSON，里面才是真正的 mp4/m3u8 地址。
//   实测：解出的 mp4 走 206 + video/mp4（ftypisom 头），无 VIP/试看限制（trysee=0、points=0）。
//   站点有多条线路时全部保留，按线路分组交给 App 的线路/选集 UI。
//
// ── 会员 / VIP（v1.0.1 复核：本站没有付费墙，不需要破解）──
//   抽样 8 条（电影/剧集各 4 条）首集播放页：`trysee=0 / points=0 / encrypt=0`，全部 from=iframe 或 yg1，
//   iframe 里拿到的播放配置解出来就是完整 mp4（实测 206 + video/mp4 + ftypisom，可整片播放）。
//   站内 `/label/vip.html`、`/user/index.html` 都返回「网站维护中」，没有会员片库入口；
//   播放页与详情页也没有「会员/金币/收费」字样 → 站点不卖会员，本源不声明 VIP 限制。
//
// 分类 / 筛选 / 排序 / 搜索：
//   列表 /vodshow/<cat>-<area>-<order>-<class>-<lang>------<year>--<page>--.html
//   （11 个短横线段位，实测每个参数都换内容且可组合）
//   搜索 /so.html?wd=<词>

var HOST = 'https://www.bhtv001.com';
var MIRRORS = ['https://www.bhtv001.com', 'https://www.bahaotv.com'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PLAY_KEY = 'VFBTzdujpR9FWBhe';
var PAGE_SIZE = 24;

// 站点栏目（三栏各自一套筛选）
var CATS = [
  { id: 'movie', title: '电影' },
  { id: 'tvseries', title: '电视剧' },
  { id: 'anime', title: '动漫' }
];

// 各栏目的筛选项（从站点筛选条原样取）
var FILTER_SETS = {
  movie: {
    area: ['大陆', '香港', '台湾', '美国', '法国', '英国', '日本', '韩国', '德国', '泰国', '印度', '意大利', '西班牙', '加拿大', '其他'],
    class: ['喜剧', '爱情', '恐怖', '动作', '科幻', '剧情', '战争', '警匪', '犯罪', '动画', '奇幻', '武侠', '冒险', '枪战', '悬疑', '惊悚', '经典', '青春', '文艺', '微电影', '古装', '历史', '运动', '农村', '儿童', '网络电影'],
    lang: ['国语', '英语', '粤语', '闽南语', '韩语', '日语', '法语', '德语', '其它']
  },
  tvseries: {
    area: ['内地', '韩国', '香港', '台湾', '日本', '美国', '泰国', '英国', '新加坡', '其他'],
    class: ['古装', '战争', '青春偶像', '喜剧', '家庭', '犯罪', '动作', '奇幻', '剧情', '历史', '经典', '乡村', '情景', '商战', '网剧'],
    lang: ['国语', '英语', '粤语', '闽南语', '韩语', '日语', '其它']
  },
  anime: {
    area: ['国产', '日本', '欧美', '其他'],
    class: ['情感', '科幻', '热血', '推理', '搞笑', '冒险', '萝莉', '校园', '动作', '机战', '运动', '战争', '少年', '少女', '社会', '原创', '亲子', '益智', '励志', '其他'],
    lang: ['国语', '英语', '粤语', '闽南语', '韩语', '日语', '其它']
  }
};
var YEARS = ['2025', '2024', '2023', '2022', '2021', '2020', '2019', '2018', '2017', '2016', '2015', '2014', '2013', '2012', '2011', '2010'];

function base() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return (d || HOST).replace(/\/+$/, '');
}
function enc(t) { return encodeURIComponent(String(t == null ? '' : t)); }
function unescapeHtml(t) {
  return String(t == null ? '' : t)
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, function (a, c) { return String.fromCharCode(Number(c)); });
}
function clean(t) {
  return unescapeHtml(String(t == null ? '' : t).replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}
function req(path, referer) {
  return LumeSource.http.request({
    url: /^https?:\/\//i.test(path) ? path : base() + path,
    method: 'GET',
    headers: {
      'User-Agent': UA,
      'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer || (base() + '/')
    }
  });
}
function get(path, referer) {
  return req(path, referer).then(function (reply) {
    var status = (reply && reply.status) || 0;
    if (!status) throw new Error('连不上站点：' + base() + path);
    if (status === 404) return '';
    if (status !== 200) throw new Error('站点返回 HTTP ' + status + '：' + base() + path);
    return reply.body == null ? '' : String(reply.body);
  });
}

// ------------------------------------------------------------------ 纯 JS AES-128-CBC 解密
// 沙箱没有 crypto/atob，AES 自己实现（站点播放配置就是 AES-CBC + base64）。
var SBOX = null, INV_SBOX = null;
function buildSbox() {
  if (SBOX) return;
  SBOX = new Array(256); INV_SBOX = new Array(256);
  var p = 1, q = 1;
  do {
    p = (p ^ (p << 1) ^ (p & 0x80 ? 0x1b : 0)) & 0xff;
    q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff;
    if (q & 0x80) q ^= 0x09;
    var x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4));
    x = (x ^ 0x63) & 0xff;
    SBOX[p] = x;
    INV_SBOX[x] = p;
  } while (p !== 1);
  SBOX[0] = 0x63; INV_SBOX[0x63] = 0;
}
function xtime(a) { return ((a << 1) ^ (a & 0x80 ? 0x1b : 0)) & 0xff; }
function mul(a, b) {
  var r = 0;
  while (b) { if (b & 1) r ^= a; a = xtime(a); b >>= 1; }
  return r & 0xff;
}
function expandKey(key) {
  var nk = key.length / 4, nr = nk + 6;
  var w = [];
  for (var i = 0; i < nk; i++) w.push([key[i * 4], key[i * 4 + 1], key[i * 4 + 2], key[i * 4 + 3]]);
  var rcon = 1;
  for (var j = nk; j < 4 * (nr + 1); j++) {
    var t = w[j - 1].slice();
    if (j % nk === 0) {
      t.push(t.shift());
      for (var k = 0; k < 4; k++) t[k] = SBOX[t[k]];
      t[0] ^= rcon;
      rcon = xtime(rcon);
    } else if (nk > 6 && j % nk === 4) {
      for (var k2 = 0; k2 < 4; k2++) t[k2] = SBOX[t[k2]];
    }
    w.push([w[j - nk][0] ^ t[0], w[j - nk][1] ^ t[1], w[j - nk][2] ^ t[2], w[j - nk][3] ^ t[3]]);
  }
  return { w: w, nr: nr };
}
function aesDecryptBlock(block, ks) {
  var s = [];
  for (var i = 0; i < 4; i++) s.push([block[i * 4], block[i * 4 + 1], block[i * 4 + 2], block[i * 4 + 3]]);
  function addRoundKey(r) {
    for (var c = 0; c < 4; c++) for (var r2 = 0; r2 < 4; r2++) s[c][r2] ^= ks.w[r * 4 + c][r2];
  }
  addRoundKey(ks.nr);
  for (var round = ks.nr - 1; round >= 0; round--) {
    // InvShiftRows
    for (var r3 = 1; r3 < 4; r3++) {
      var row = [s[0][r3], s[1][r3], s[2][r3], s[3][r3]];
      for (var c2 = 0; c2 < 4; c2++) s[(c2 + r3) % 4][r3] = row[c2];
    }
    // InvSubBytes
    for (var c3 = 0; c3 < 4; c3++) for (var r4 = 0; r4 < 4; r4++) s[c3][r4] = INV_SBOX[s[c3][r4]];
    addRoundKey(round);
    if (round > 0) {
      // InvMixColumns
      for (var c4 = 0; c4 < 4; c4++) {
        var a0 = s[c4][0], a1 = s[c4][1], a2 = s[c4][2], a3 = s[c4][3];
        s[c4][0] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9);
        s[c4][1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13);
        s[c4][2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11);
        s[c4][3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14);
      }
    }
  }
  var out = [];
  for (var c5 = 0; c5 < 4; c5++) for (var r5 = 0; r5 < 4; r5++) out.push(s[c5][r5]);
  return out;
}
function base64ToBytes(str) {
  var ABC = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var s = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < s.length; i += 4) {
    var c0 = ABC.indexOf(s[i]), c1 = ABC.indexOf(s[i + 1]);
    var c2 = s[i + 2] === '=' || s[i + 2] === undefined ? -1 : ABC.indexOf(s[i + 2]);
    var c3 = s[i + 3] === '=' || s[i + 3] === undefined ? -1 : ABC.indexOf(s[i + 3]);
    out.push(((c0 << 2) | (c1 >> 4)) & 0xff);
    if (c2 >= 0) out.push(((c1 << 4) | (c2 >> 2)) & 0xff);
    if (c3 >= 0) out.push(((c2 << 6) | c3) & 0xff);
  }
  return out;
}
function bytesToUtf8(bytes) {
  var out = '', i = 0;
  while (i < bytes.length) {
    var b = bytes[i++];
    if (b < 0x80) { out += String.fromCharCode(b); }
    else if (b >= 0xc0 && b < 0xe0) { out += String.fromCharCode(((b & 31) << 6) | (bytes[i++] & 63)); }
    else if (b >= 0xe0 && b < 0xf0) {
      out += String.fromCharCode(((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
    } else {
      var cp = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
    }
  }
  return out;
}
function utf8Bytes(str) {
  var out = [];
  var t = String(str == null ? '' : str);
  for (var i = 0; i < t.length; i++) {
    var c = t.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}
function aesCbcDecryptB64(b64, keyStr, ivStr) {
  buildSbox();
  var data = base64ToBytes(b64);
  var key = utf8Bytes(keyStr), iv = utf8Bytes(ivStr);
  if (data.length % 16 !== 0 || data.length === 0) throw new Error('密文长度不对');
  var ks = expandKey(key);
  var prev = iv.slice(0, 16);
  var out = [];
  for (var off = 0; off < data.length; off += 16) {
    var block = data.slice(off, off + 16);
    var plain = aesDecryptBlock(block, ks);
    for (var i = 0; i < 16; i++) out.push(plain[i] ^ prev[i]);
    prev = block;
  }
  // 去掉 PKCS7 填充
  var pad = out[out.length - 1];
  if (pad > 0 && pad <= 16) out = out.slice(0, out.length - pad);
  return bytesToUtf8(out);
}

// ------------------------------------------------------------------ 列表解析
function parseCards(html) {
  var src = String(html || '');
  var items = [], seen = {};
  var chunks = src.split(/<a\s[^>]*href="\/details\/(\d+)\.html"/);
  for (var i = 1; i + 1 < chunks.length; i += 2) {
    var id = chunks[i];
    if (!id || seen[id]) continue;
    var block = String(chunks[i + 1] || '').slice(0, 3000);
    var img = /<img[^>]+src="([^"]+)"/i.exec(block);
    var title = /<div class="title">([\s\S]{0,120}?)<\/div>/i.exec(block);
    var tag = /<div class="tag[^"]*">([\s\S]{0,40}?)<\/div>/i.exec(block);
    var score = /<div class="score">([\d.]+)<\/div>/i.exec(block);
    var name = clean(title ? title[1] : '');
    if (!name) continue;
    var bits = [];
    if (tag) bits.push(clean(tag[1]));
    if (score) bits.push('评分 ' + score[1]);
    seen[id] = true;
    items.push({
      id: id,
      title: name,
      cover: img ? unescapeHtml(img[1]) : '',
      subtitle: bits.join(' · ')
    });
  }
  return items;
}

function parseDetail(html) {
  var src = String(html || '');
  var titleTag = /<title>([^<]*)<\/title>/i.exec(src);
  var title = titleTag ? clean(titleTag[1]).replace(/^[^《]*《([^》]+)》[\s\S]*$/, '$1').trim() : '';
  var cover = /<img[^>]+src="([^"]*upload\/vod[^"]*)"/i.exec(src);
  var intro = /<div class="info-intro">([\s\S]{0,4000}?)<\/div>/i.exec(src);
  var desc = intro ? clean(intro[1]).replace(/^简介：/, '') : '';
  var metaDesc = /<meta\s+name="description"\s+content="([^"]*)"/i.exec(src);
  if (!desc && metaDesc) desc = unescapeHtml(metaDesc[1]).trim();
  return {
    title: title,
    cover: cover ? unescapeHtml(cover[1]) : '',
    description: desc,
    lines: parseLines(src)
  };
}

// 线路标签：<a href="#playlist1" ...>高清线路Ⅳ</a>
function parseLineTabs(html) {
  var src = String(html || '');
  var tabs = [], re = /<a href="#playlist(\d+)"[^>]*>([^<]*)<\/a>/g, m;
  while ((m = re.exec(src)) !== null) {
    tabs.push({ index: Number(m[1]), title: clean(m[2]) || ('线路 ' + m[1]) });
  }
  return tabs;
}
// 分集：/vodplay/<id>-<line>-<ep>.html
function parseLines(html) {
  var src = String(html || '');
  var tabs = parseLineTabs(src);
  var titleOf = {};
  for (var t = 0; t < tabs.length; t++) titleOf[tabs[t].index] = tabs[t].title;
  var seen = {}, lines = {}, order = [];
  var re = /href="\/vodplay\/(\d+)-(\d+)-(\d+)\.html"[^>]*>([\s\S]{0,60}?)<\/a>/g, m;
  while ((m = re.exec(src)) !== null) {
    var line = Number(m[2]), ep = Number(m[3]);
    var key = line;
    if (!lines[key]) {
      lines[key] = [];
      order.push(line);
    }
    var dedup = line + '-' + ep;
    if (seen[dedup]) continue;
    seen[dedup] = true;
    lines[key].push({
      ep: ep,
      path: '/vodplay/' + m[1] + '-' + m[2] + '-' + m[3] + '.html',
      label: clean(m[4]) || ('第 ' + ep + ' 集')
    });
  }
  var out = [];
  order.sort(function (a, b) { return a - b; });
  for (var i = 0; i < order.length; i++) {
    var ln = order[i];
    lines[ln].sort(function (a, b) { return a.ep - b.ep; });
    out.push({ index: ln, title: titleOf[ln] || ('线路 ' + ln), episodes: lines[ln] });
  }
  return out;
}

// ------------------------------------------------------------------ 播放地址解析
// 播放页 → iframe 地址 → AES 解出 config → 真实 mp4/m3u8
async function resolvePlayPage(playPath) {
  var page = await get(playPath);
  if (!page) throw new Error('播放页打不开（可能已下架）');
  var m = /var player_aaaa=(\{[\s\S]*?\})<\/script>/.exec(page);
  if (!m) throw new Error('播放页里没有播放配置');
  var conf;
  try { conf = JSON.parse(m[1]); } catch (e) { throw new Error('播放配置解析失败'); }
  if (conf.encrypt && conf.encrypt !== 0) throw new Error('站点启用了加密播放（encrypt=' + conf.encrypt + '），本源暂不支持');
  var url = String(conf.url || '');
  if (!url) throw new Error('播放配置里没有地址');
  if (/\.(mp4|m3u8)(\?|$)/i.test(url)) return url; // 少数线路直接给直链
  // iframe 线路：再解一层
  var embed = await get(url, base() + '/');
  var rand = /var rand = "([^"]+)"/.exec(embed);
  var player = /var player = "([^"]+)"/.exec(embed);
  if (!rand || !player) {
    // 有些线路直接在 iframe 里写 m3u8/mp4
    var direct = /(https?:\\?\/\\?\/[^"'\s]+?\.(?:m3u8|mp4)[^"'\s]*)/i.exec(embed);
    if (direct) return direct[1].replace(/\\\//g, '/');
    throw new Error('这条线路没有可解析的地址');
  }
  var plain = aesCbcDecryptB64(player[1], PLAY_KEY, rand[1]);
  var cfg;
  try { cfg = JSON.parse(plain); } catch (e) { throw new Error('播放地址解密失败'); }
  var real = String(cfg.url || '');
  if (!/^https?:\/\//i.test(real)) throw new Error('解出的地址无效');
  return real;
}

// ------------------------------------------------------------------ 五入口
var LumeSource = {
  id: 'bahaotv_video',
  name: '八号影视',
  version: '1.0.1',
  category: 'video',
  contentCategory: 'movie',
  settingsApiVersion: 2,
  requiresSettings: ['commonSettings', 'settingsActions'],
  mirrors: MIRRORS,
  network: 'direct',
  icon: HOST + '/icon.png',
  commonSettings: [
    {
      key: 'playbackMode', title: '播放方式', type: 'select',
      options: [
        { value: 'auto', title: '自动（推荐）' },
        { value: 'direct', title: '直连优先' }
      ],
      default: 'auto'
    }
  ],
  settings: [
    {
      key: 'note',
      type: 'info',
      title: '站点说明',
      description: '八号影视（www.bhtv001.com；bahaotv.com 是同一台站的旧名，证书不匹配，优先用 bhtv001.com）。本源直接解出播放直链（站点用 AES-CBC 加密播放配置），支持电影/电视剧/动漫，含地区/类型/语言/年份/排序筛选与站内搜索；站点有多条线路时全部保留。实测无 VIP、无试看限制。'
    }
  ],

  async categories() {
    return CATS.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async filters() {
    // 三个栏目的筛选集不同，用「栏目+组」的形式暴露；list 里按同样规则还原。
    var groups = [];
    for (var i = 0; i < CATS.length; i++) {
      var cat = CATS[i].id, set = FILTER_SETS[cat];
      var catTitle = CATS[i].title;
      groups.push({
        key: cat + '.area', title: catTitle + ' · 地区', multiple: false,
        options: set.area.map(function (v) { return { id: v, title: v }; })
      });
      groups.push({
        key: cat + '.class', title: catTitle + ' · 类型', multiple: false,
        options: set.class.map(function (v) { return { id: v, title: v }; })
      });
      groups.push({
        key: cat + '.lang', title: catTitle + ' · 语言', multiple: false,
        options: set.lang.map(function (v) { return { id: v, title: v }; })
      });
    }
    groups.push({
      key: 'year', title: '年份', multiple: false,
      options: YEARS.map(function (v) { return { id: v, title: v }; })
    });
    groups.push({
      key: 'order', title: '排序', multiple: false,
      options: [
        { id: 'time', title: '最新' },
        { id: 'hits', title: '最热' },
        { id: 'score', title: '评分' }
      ]
    });
    return { groups: groups };
  },

  async home() {
    var html = await get('/');
    var items = parseCards(html);
    if (!items.length) return [];
    return [{ title: '最新推荐', items: items.slice(0, 24) }];
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var category = String(args.categoryId == null ? '' : args.categoryId).trim();
    var f = args.filters || {};

    if (keyword) {
      var found = parseCards(await get('/so.html?wd=' + enc(keyword)));
      return { items: found, hasMore: false };
    }

    var cat = 'movie';
    for (var i = 0; i < CATS.length; i++) {
      if (CATS[i].id === category) { cat = category; break; }
    }
    // 筛选键既支持 <cat>.area 也支持裸 area（裸键用于当前栏目）
    function pick(name) {
      var v = f[cat + '.' + name];
      if (v == null || v === '') v = f[name];
      return v == null ? '' : String(v).trim();
    }
    var area = pick('area'), klass = pick('class'), lang = pick('lang');
    var year = String(f.year == null ? '' : f.year).trim();
    var order = String(f.order == null ? '' : f.order).trim();

    // 11 段位：area-order-class-lang------year--page--
    var slots = ['', '', '', '', '', '', '', '', '', '', ''];
    if (area) slots[0] = area;
    if (order) slots[1] = order;
    if (klass) slots[2] = klass;
    if (lang) slots[3] = lang;
    if (page > 1) slots[7] = String(page);
    if (year) slots[10] = year;
    var path = '/vodshow/' + cat + '-' + slots.join('-') + '.html';

    var items = parseCards(await get(path));
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return null;
    var html = '';
    try { html = await get('/details/' + id + '.html'); } catch (e) { return null; }
    if (!html) return null;
    var info = parseDetail(html);
    if (!info.title) return null;
    var total = 0;
    for (var i = 0; i < info.lines.length; i++) total += info.lines[i].episodes.length;
    var bits = [];
    if (info.lines.length > 1) bits.push(info.lines.length + ' 条线路');
    if (total > 1) bits.push('共 ' + total + ' 集');
    bits.push('直连播放');
    return {
      id: id,
      title: info.title,
      cover: info.cover,
      subtitle: bits.join(' · '),
      description: info.description,
      tags: []
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!/^\d+$/.test(id)) return [];
    var html = await get('/details/' + id + '.html');
    if (!html) throw new Error('站点上没有这一条（可能已下架）');
    var info = parseDetail(html);
    if (!info.lines.length) throw new Error('这一条在站点上没有可播放的分集');
    var out = [];
    for (var i = 0; i < info.lines.length; i++) {
      var line = info.lines[i];
      for (var j = 0; j < line.episodes.length; j++) {
        var ep = line.episodes[j];
        // 多线路时把线路名带上，单线路时只显示集名
        var label = info.lines.length > 1 ? (line.title + ' · ' + ep.label) : ep.label;
        out.push({ id: ep.path, title: label });
      }
    }
    return out;
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.chapterId || '').trim();
    if (!/^\/vodplay\/\d+-\d+-\d+\.html$/.test(path)) {
      // 也允许直接传详情 id：取第一条线路第一集
      var id = String(args.id || '').trim();
      if (!/^\d+$/.test(id)) throw new Error('条目参数无效，请重新打开详情页');
      var html = await get('/details/' + id + '.html');
      var info = parseDetail(html);
      if (!info.lines.length || !info.lines[0].episodes.length) throw new Error('这一条没有可播放的分集');
      path = info.lines[0].episodes[0].path;
    }
    var url = await resolvePlayPage(path);
    if (!url) throw new Error('没有解出播放地址');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: base() + '/' }
    };
  }
};
