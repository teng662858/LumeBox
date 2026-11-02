// LumeSource: {"id":"akmh_video","name":"18ak漫画·视频","version":"1.1.0","category":"video","contentCategory":"adult","mirrors":["https://www.18akmanhua.com"],"network":"direct","icon":"https://www.18akmanhua.com/logo.png"}
// LumeRuntime: javascript
//
// 站点：18ak漫画 / 爱看漫画（https://www.18akmanhua.com，全站 18+，Vue3 SPA）
// 来源：从「暮色」App（com.look.mbox / avbox 1.0.1）的内置源里挖出来的站点及其协议。
//
// 一、协议（从前端 index-*.js 的 axios 拦截器还原 + 真实响应验证）
//   baseURL = /api；每个请求带
//     timestamp = parseInt(Date.now()/1000)
//     sign      = md5(timestamp + "api" + path + METHOD + "6F7A4DF7000C045C636B9123B11E4EC7").toLowerCase()
//   响应 200 时是 {"code":200,"data":{"suffix":"<6 hex>","data":"<base64>"}}：
//     key = "9a2d65b4a693ad0e40e5b156df25e406"（32 字节 → AES-256）
//     iv  = "9a62e6977b" + suffix（10 + 6 = 16 字节）
//     AES-CBC / PKCS7，base64 输入，解出来是 JSON
//
// 二、v1.1.0 改用宿主原生能力（不再手写纯 JS 加密）
//   沙箱里其实有原生 AES / 摘要：`LumeSource.tools.aes` / `tools.digest`（Dart 侧 pointycastle / crypto 包），
//   比在源里跑纯 JS 快一到两个数量级，源体积也从 20 KB 降到 8 KB：
//     · 签名   md5        → LumeSource.tools.digest('md5', text)
//     · 解密   AES-256-CBC → LumeSource.tools.aes({key,iv,data,mode:'CBC',encrypt:false})
//       （key/iv/data 都是 base64；返回 base64 明文，再 base64Decode 成 UTF-8 文本）
//     · btoa  做 key/iv 的 base64（桥接层已提供同步 atob/btoa）
//
// 三、接口
//   GET /api/videoLists?page=&size=15&type=   type 0=漫画改编(695) 1=真人(836) 2+=全部(1531)
//   GET /api/videoDetails?id=                 → 上面字段 + price/is_free/sales_num
//   GET /api/stacksCategories、/api/notices、/api/hotSearchBooks、/api/searchBooks?keyword=
//   size 服务端写死 15（传 20/50 都回 15），所以分页按 totalPage 判断。
//
// 四、付费（实测：只挡前端）
//   videoDetails 对 price>0 / is_free=0 的片照样下发 pay_url（静态相对路径），
//   base + pay_url 实测 200 + #EXTM3U（分片 010.ts / 011.ts…），不需要登录、不需要买。
//   preview_url 是 10 秒试看，只在 pay_url 缺失时兜底。
//
// 五、限制
//   · 视频没有站内搜索（/searchVideos、/search 都是 404；漫画才有 /searchBooks）。
//   · 漫画板块（/stacks、/books）参数还没摸全，本源只做「视频」。
//   · 站点换域名/IP 时改 mirrors[0]；签名密钥若变，源会抛「接口结构变了 / 响应解不开」。

var SITE = 'https://www.18akmanhua.com';
var SIGN_SECRET = '6F7A4DF7000C045C636B9123B11E4EC7';
var AES_KEY = '9a2d65b4a693ad0e40e5b156df25e406';
var AES_IV_PREFIX = '9a62e6977b';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 15;

function siteBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || SITE).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(text)) text = 'https://' + text;
  return text;
}

function clean(text) {
  return String(text == null ? '' : text).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function media(path) {
  var raw = String(path == null ? '' : path).trim();
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return siteBase() + (raw.charAt(0) === '/' ? '' : '/') + raw;
}

function durationText(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0));
  if (!total) return '';
  var h = Math.floor(total / 3600);
  var m = Math.floor((total % 3600) / 60);
  var s = total % 60;
  var mm = (m < 10 ? '0' : '') + m;
  var ss = (s < 10 ? '0' : '') + s;
  return h > 0 ? h + ':' + mm + ':' + ss : m + ':' + ss;
}

// ---------------- 接口（签名 + 原生 AES 解密） ----------------
async function api(path, query) {
  var root = siteBase();
  var ts = Math.floor(Date.now() / 1000);
  var sign = await LumeSource.tools.digest('md5', ts + 'api' + path + 'GET' + SIGN_SECRET);
  var url = root + '/api' + path + (query ? '?' + query : '');
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'application/json, text/plain, */*',
      timestamp: String(ts),
      sign: String(sign).toLowerCase(),
      Referer: root + '/',
      Origin: root,
    },
  });
  if (!reply || reply.status !== 200) {
    throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  }
  var text = reply.body ? String(reply.body) : '';
  var wallet;
  try {
    wallet = JSON.parse(text);
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  var envelope = wallet && wallet.data;
  if (!envelope || !envelope.data || !envelope.suffix) {
    throw new Error('接口结构变了：' + path + (wallet && wallet.message ? '（' + wallet.message + '）' : ''));
  }
  // 原生 AES-256-CBC：key/iv/data 传 base64，返回 base64 明文
  var plainB64 = await LumeSource.tools.aes({
    key: btoa(AES_KEY),
    iv: btoa(AES_IV_PREFIX + String(envelope.suffix)),
    data: String(envelope.data),
    mode: 'CBC',
    encrypt: false,
  });
  var plain = await LumeSource.tools.base64Decode(plainB64);
  try {
    return JSON.parse(plain);
  } catch (error) {
    throw new Error('响应解不开（站点换密钥了？）：' + path);
  }
}

function rowOf(v) {
  if (!v) return null;
  var id = String(v.id == null ? '' : v.id);
  if (!id) return null;
  var title = clean(v.title);
  if (!title) return null;
  var bits = [];
  if (Number(v.price) > 0 && !Number(v.is_free)) bits.push('金币 ' + v.price + '（接口直发播放地址）');
  if (v.duration) bits.push(durationText(v.duration));
  if (v.view_num) bits.push('浏览 ' + v.view_num);
  return { id: id, title: title, cover: media(v.image), subtitle: bits.join(' · ') };
}

var CATEGORIES = [
  { id: 'all', title: '全部视频', type: '2' },
  { id: 'comic', title: '漫画改编', type: '0' },
  { id: 'real', title: '真人', type: '1' },
];

function typeOf(categoryId) {
  var id = String(categoryId == null ? '' : categoryId);
  for (var i = 0; i < CATEGORIES.length; i++) if (CATEGORIES[i].id === id) return CATEGORIES[i].type;
  return '2';
}

var RECENT = [];
var RECENT_MAX = 400;

function remember(rows) {
  if (!rows || !rows.length) return;
  RECENT = rows.concat(RECENT).slice(0, RECENT_MAX);
}

// ---------------- 入口 ----------------
var LumeSource = {
  id: 'akmh_video',
  name: '18ak漫画·视频',
  version: '1.1.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://www.18akmanhua.com'],

  async home() {
    var boards = [];
    var plans = [
      { title: '最新视频', categoryId: 'all' },
      { title: '漫画改编', categoryId: 'comic' },
      { title: '真人', categoryId: 'real' },
    ];
    for (var i = 0; i < plans.length; i++) {
      var plan = plans[i];
      try {
        var data = await api('/videoLists', 'page=1&size=' + PAGE_SIZE + '&type=' + typeOf(plan.categoryId));
        var rows = [];
        var list = data && Array.isArray(data.list) ? data.list : [];
        for (var k = 0; k < list.length; k++) {
          var row = rowOf(list[k]);
          if (row) rows.push(row);
        }
        if (rows.length) {
          remember(rows);
          boards.push({ title: plan.title, moreUrl: plan.categoryId, items: rows.slice(0, 12) });
        }
      } catch (error) {
        if (i === 0) throw error;
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口签名或密钥可能变了');
    return boards;
  },

  async categories() {
    return CATEGORIES.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    var keyword = clean(a.keyword);
    if (keyword) throw new Error('这个站的视频没有站内搜索（只有漫画有 /searchBooks）');
    var categoryId = String(a.categoryId == null || a.categoryId === '' ? 'all' : a.categoryId);
    var data = await api('/videoLists', 'page=' + page + '&size=' + PAGE_SIZE + '&type=' + typeOf(categoryId));
    var rows = [];
    var list = data && Array.isArray(data.list) ? data.list : [];
    for (var i = 0; i < list.length; i++) {
      var row = rowOf(list[i]);
      if (row) rows.push(row);
    }
    remember(rows);
    var totalPage = Number(data && data.totalPage) || 0;
    var hasMore = totalPage ? page < totalPage : rows.length >= PAGE_SIZE;
    return { items: rows, hasMore: hasMore };
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var v = await api('/videoDetails', 'id=' + id);
    if (!v || v.id == null) return null;
    var row = rowOf(v);
    if (row) remember([row]);
    var desc = [];
    if (v.price != null) desc.push(Number(v.price) > 0 && !Number(v.is_free) ? '金币 ' + v.price + '（接口层不鉴权，播放地址直发）' : '免费');
    if (v.sales_num) desc.push('已售 ' + v.sales_num);
    if (v.view_num) desc.push('浏览 ' + v.view_num);
    if (v.duration) desc.push('时长 ' + durationText(v.duration));
    desc.push('来源：18ak漫画（' + siteBase() + '）');
    return {
      id: id,
      title: clean(v.title) || id,
      cover: media(v.image),
      subtitle: row ? row.subtitle : '',
      description: desc.join('\n'),
    };
  },

  async chapters(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return [];
    return [{ id: 'main', title: '正片' }];
  },

  async content(args) {
    var id = String((args && (args.id || args.chapterId)) || '').replace(/[^0-9]/g, '');
    if (!id) throw new Error('缺少视频 ID');
    var v = await api('/videoDetails', 'id=' + id);
    var url = media(v && v.pay_url ? v.pay_url : '');
    if (!url && v && v.preview_url) url = media(v.preview_url);
    if (!url) throw new Error('这条没有播放地址（详情里既没 pay_url 也没 preview_url）');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: siteBase() + '/' },
    };
  },
};
