// LumeSource: {"id":"livebox_video","name":"直播盒子","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["http://api.hclyz.com:81","http://api.maiyoux.com:81","http://api.vipmisss.com:81"],"network":"direct","icon":"http://cdn.gcufbd.top/img/LOVE.jpg"}
// LumeRuntime: javascript
//
// 站点：直播盒子（来自「暮色」App 内置 live 模块；站方自带接口说明页 http://api.hclyz.com:81/）
// 全站成人直播聚合，**接口未加密、不走 HTTPS**，是这批站里最好接的一个。
//
// 一、接口（站方文档自己列的，2026-11-03 实测）
//   GET /mf/json.txt          → {"pingtai":[{title, address, xinimg, Number}]}  130 个平台
//   GET /mf/<address>         → {"zhubo":[{title, address, img}]}                该平台主播
//        address 是平台自己的文件名，例如 jsonkawayi.txt / jsonmihu.txt
//   主播的 address 是 **flv 直播流**：
//     http://<host>/live/cx_xxxxx.flv?wsSecret=<32hex>&wsTime=<秒级时间戳>
//     wsSecret/wsTime 是时效签名，所以每次播放都要重新拉一次列表，缓存地址会过期。
//   实测 flv：200 + video/x-flv + 3.2 MB（Range 请求直接回全量，不是 206）。
//
// 二、字段
//   平台：title 名称 / Number 主播数（字符串）/ xinimg 平台图 / address 文件名
//   主播：title 名称 / img 封面 / address flv 流
//
// 三、限制
//   · 130 个平台全铺到分类栏太长，本源按主播数取前 24 个热门平台；
//     想换别的平台，改「设置 → 追加平台」或在站点侧找对应 json 文件名。
//   · 只有直播，没有回放；主播下播后地址会失效（列表里就没了）。
//   · 站点是 http（无 TLS），部分网络会拦，镜像里放了两个备用域。

var SITE = 'http://api.hclyz.com:81';
var MIRRORS = ['http://api.hclyz.com:81', 'http://api.maiyoux.com:81', 'http://api.vipmisss.com:81'];
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var MAX_PLATFORMS = 24;

function siteBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return String(domain || SITE).replace(/\/+$/, '');
}

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

async function getJson(path) {
  var lastError = null;
  var bases = [siteBase()].concat(MIRRORS);
  for (var i = 0; i < bases.length; i++) {
    try {
      var reply = await LumeSource.http.get(bases[i] + path, {
        headers: { 'User-Agent': UA, Accept: 'application/json, */*', Referer: bases[i] + '/' },
      });
      if (reply && reply.status === 200 && reply.body) {
        var text = String(reply.body).trim();
        if (text.charAt(0) === '{' || text.charAt(0) === '[') return JSON.parse(text);
      }
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error('接口打不开：' + path + (lastError ? '（' + lastError.message + '）' : ''));
}

var PLATFORMS = null;

async function platforms() {
  if (PLATFORMS) return PLATFORMS;
  var data = await getJson('/mf/json.txt');
  var rows = data && Array.isArray(data.pingtai) ? data.pingtai : [];
  var list = [];
  for (var i = 0; i < rows.length; i++) {
    var p = rows[i];
    if (!p || !p.address || !clean(p.title)) continue;
    list.push({
      id: String(p.address),
      title: clean(p.title),
      cover: String(p.xinimg || ''),
      count: Number(p.Number) || 0,
    });
  }
  list.sort(function (a, b) { return b.count - a.count; });
  PLATFORMS = list;
  return list;
}

async function anchorsOf(platformId) {
  var data = await getJson('/mf/' + platformId);
  var rows = data && Array.isArray(data.zhubo) ? data.zhubo : [];
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var a = rows[i];
    if (!a || !a.address) continue;
    var title = clean(a.title) || ('主播 ' + (i + 1));
    out.push({
      id: platformId + '|' + String(a.address),
      title: title,
      cover: String(a.img || ''),
      subtitle: '直播中',
      play: String(a.address),
    });
  }
  return out;
}

var RECENT = {};
function remember(items) {
  for (var i = 0; i < items.length; i++) RECENT[items[i].id] = items[i];
}

// ---------------- 入口 ----------------
var LumeSource = {
  id: 'livebox_video',
  name: '直播盒子',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: MIRRORS,

  async categories() {
    var list = await platforms();
    return list.slice(0, MAX_PLATFORMS).map(function (p) {
      return { id: p.id, title: p.title + '（' + p.count + '）' };
    });
  },

  async home() {
    var list = await platforms();
    var boards = [];
    for (var i = 0; i < list.length && boards.length < 3; i++) {
      try {
        var items = await anchorsOf(list[i].id);
        if (!items.length) continue;
        remember(items);
        boards.push({ title: list[i].title, moreUrl: list[i].id, items: items.slice(0, 12) });
      } catch (error) {
        /* 单个平台挂掉不影响首页 */
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口可能换域名了');
    return boards;
  },

  async list(args) {
    var a = args || {};
    if (clean(a.keyword)) throw new Error('这个站只有平台和主播，没有搜索');
    var list = await platforms();
    var page = Math.max(1, Number(a.page) || 1);
    var categoryId = String(a.categoryId == null || a.categoryId === '' ? list[0].id : a.categoryId);
    var items = await anchorsOf(categoryId);
    remember(items);
    // 主播列表是整表下发，没有分页
    return { items: page === 1 ? items : [], hasMore: false };
  },

  async detail(args) {
    var id = String((args && args.id) || '');
    if (id.indexOf('|') <= 0) return null;
    var parts = id.split('|');
    var items = await anchorsOf(parts[0]);
    var hit = null;
    for (var i = 0; i < items.length; i++) if (items[i].id === id) hit = items[i];
    if (!hit) {
      var cached = RECENT[id];
      if (!cached) return null;
      hit = cached;
    }
    return {
      id: id,
      title: hit.title,
      cover: hit.cover,
      subtitle: '直播中',
      description: '平台：' + parts[0] + '\n类型：直播（flv）\n来源：直播盒子（' + siteBase() + '）',
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '');
    if (!id) return [];
    return [{ id: 'live', title: '直播' }];
  },

  async content(args) {
    var id = String((args && (args.id || args.chapterId)) || '');
    if (id.indexOf('|') <= 0) throw new Error('缺少条目 ID');
    var parts = id.split('|');
    var items = await anchorsOf(parts[0]);
    var hit = null;
    for (var i = 0; i < items.length; i++) if (items[i].id === id) hit = items[i];
    if (!hit) hit = RECENT[id];
    if (!hit || !hit.play) throw new Error('这个主播已经下播（列表里没有它了）');
    return {
      kind: 'video',
      url: hit.play,
      headers: { 'User-Agent': UA, Referer: siteBase() + '/' },
    };
  },
};
