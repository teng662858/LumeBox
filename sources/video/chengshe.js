// LumeSource: {"id":"chengshe_video","name":"橙涩视频","version":"2.1.1","category":"video","contentCategory":"adult","mirrors":["https://6s9b2f4hkmbh.xyz"],"network":"direct","icon":"https://6s9b2f4hkmbh.xyz/favicon.ico","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页","url":"https://8if2pvzp.cc","description":"站点换域名时先看这里（离线页里还有备用地址与邮箱）"},{"key":"note","type":"info","title":"站点说明","description":"橙涩视频（6s9b2f4hkmbh.xyz，Vue3 SPA + Cloudflare）：接口在独立 API 域（30 个 .cc 短链的 /api/sys/findLive 自发现）；请求参数 AES-CBC（key = iv = 毫秒时间戳 + 000），响应用 token 第 3-18 位倒序做 key 解。首次访问用 POST /user/tryLogin {deviceId} 自动拿游客 token，无需注册。VIP/金币片（price 5-9）接口层不鉴权：详情照发 videoUrl，拼 CDN 直接播——实测含 VIP 片 12/12 200 + #EXTM3U，HLS 是标准 AES-128（index.key 可取）。v2.0.0 增加短剧板块与站内搜索（/video/findVideoByTag 按标签命中）。"}]}
// LumeRuntime: javascript
//
// 站点：橙涩视频（入口 https://6s9b2f4hkmbh.xyz，随机域名，会换）。
//
// 一、协议（2026-11-02 用 Tabbit 抓真实请求逐字段还原）
//   线路发现  GET https://<line 域名>/ 或 /api/sys/findLive
//             → {"status":"success","result":"https://qtrvqim.xxxx.cc/","pool":"…"}
//   健康检查  GET <api>/api/sys/findLive     → {"code":200,"data":{"client":"mobile","pt":"CS"}}
//   匿名登录  POST <api>/api/user/tryLogin {"deviceId":"app_…"}（**不带 permissions 头**）
//             → 明文 JSON {userId,token,…}；同一个 deviceId 反复调用是同一个号
//   分类      GET  <api>/api/video/findClassifyList
//   排行榜    GET  <api>/api/video/findRankList        （只有一页 30 条）
//   分类视频  POST <api>/api/video/findClassifyVideos {page,pageSize,classifyId}
//   标签搜索  POST <api>/api/video/findVideoByTag     {page,pageSize,tagTitles:[kw]}
//   详情      GET  <api>/api/video/findVideoById      {videoId} → videoUrl / access / canWatch / price
//   短剧分类  GET  <api>/api/videoSerial/findClassify
//   短剧列表  GET  <api>/api/videoSerial/findListByClass {page,pageSize,classifyId}
//   短剧详情  GET  <api>/api/videoSerial/findDetail   {serialId} → videoUrl / epList / videoNum
//   域名池    GET  <api>/api/sys/findDomain → imageCdn / mp4Cdn / videoCdnList
//
// 二、加密（前端 fetch 拦截器原样复刻）
//   请求：t = 13 位毫秒时间戳；key = iv = t + "000"（16 字节）；AES-128-CBC/PKCS7；Base64
//         头另带 t、s = md5(t.slice(3,9))、app=cs、vn=2.6.0、deviceid、permissions=token
//   响应：{"code":200,"encData":"…"}，解密 key = iv = token.slice(2,18) 反转后的 16 字符
//
// 三、VIP / 金币挡在哪层（2026-11-02 实测：只挡前端）
//   · 详情返回 canWatch:false、reasonType:2/3，但 **videoUrl 照样下发**（相对路径 …/hls/x.m3u8）；
//     前端点播放才弹 VipInterceptionAlert，接口没有任何服务端鉴权。
//   · CDN 主机来自 /api/sys/findDomain → data.imageCdn[].domain
//     （当前 https://pic.tbem.org / https://pic.tqonth.com；mp4Cdn 的 play.* 反而 403）。
//   · 实测抽 12 条（其中 8 条 price>0 的 VIP 片）：CDN + videoUrl 12/12 200 + #EXTM3U，
//     分片 200（单段 3.4 MB）；HLS 为标准 AES-128（#EXT-X-KEY:METHOD=AES-128,URI="index.key"），
//     index.key 200 + 16 字节。
//   · 短剧 findDetail 同样给 canWatch:true + videoUrl（整部一条播放列表）；
//     epList 只是前端分集，epNum 传了不影响返回 → 本源按「全集」一集处理。
//   · 老线路 /api/dec/m3u/ios/access.m3u8?encData=… 仍然可用，放在 CDN 直连失败时兜底。
//
// 四、限制
//   · 全站 18+；封面/CDN 的 Content-Type 是伪装过的 text/base64.jpg，内容是正常图片。
//   · 站内搜索是「按标签命中」（tagTitles=[关键词]），不是全文搜索。
//   · 排行榜没有翻页；分类「精选」(classifyId 14) 接口返回空，本源不列（不拿别的分类顶替）。
//   · 换域名时的替换点：SEEDS（短链池）、FALLBACK_API、IMG_CDN。

var SEEDS = [
  'https://18rrqswd.cc', 'https://wby3n4sn.cc', 'https://646jlp2d.cc', 'https://k56y3zzo.cc',
  'https://22oix9a5.cc', 'https://etigpe44.cc', 'https://12180rah.cc', 'https://fbm4kbea.cc',
  'https://gtihydob.cc', 'https://xro89231.cc', 'https://c5hs0mhd.cc', 'https://uu61lo11.cc',
  'https://fg6jn3j7.cc', 'https://djetrr1v.cc', 'https://dqhdp64b.cc', 'https://b603pe32.cc',
  'https://6ys7yxf5.cc', 'https://zriiiylx.cc', 'https://iygrso11.cc', 'https://dk0cp4p7.cc',
  'https://xb20l848.cc', 'https://w6i0l6vj.cc', 'https://802ivhl2.cc', 'https://32bfqtjy.cc',
  'https://z3m5278f.cc', 'https://q79jtf5d.cc', 'https://vlstzf9z.cc', 'https://5m76d0ji.cc',
  'https://rszoiokv.cc', 'https://4e608owo.cc'
];
var FALLBACK_API = ['https://qtrvqim.p04x0hyl.cc', 'https://qtrvqim.47svemtl.cc'];
var IMG_CDN = ['https://pic.tbem.org', 'https://pic.tqonth.com'];
var SITE = 'https://6s9b2f4hkmbh.xyz';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var CACHE_KEY_API = 'chengshe.api';
var CACHE_KEY_TOKEN = 'chengshe.token';
var CACHE_KEY_CATS = 'chengshe.cats2';
var SERIAL_CLASSIFY = 17;
// 实测返回空数组的分类（「精选」14），列出来只会给用户一个空页
var EMPTY_CLASSIFY = { 14: true };
var PAGE_SIZE = 20;

var state = { api: '', token: '', deviceId: '' };
var known = {};
var CATS = [];

function cfg(k) {
  var c = LumeSource.config && LumeSource.config.commonSettings ? LumeSource.config.commonSettings : {};
  return c && c[k] !== undefined ? c[k] : undefined;
}
// 桥接的 storage.get/set 是异步的（返回 Promise），必须 await
async function st(k) {
  try { return LumeSource.storage ? await LumeSource.storage.get(k) : null; } catch (e) { return null; }
}
async function stSet(k, v) {
  try { if (LumeSource.storage) await LumeSource.storage.set(k, v); } catch (e) {}
}
function customDomain() {
  var d = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  return d ? d.replace(/\/+$/, '') : '';
}
async function deviceId() {
  if (state.deviceId) return state.deviceId;
  var saved = await st('chengshe.dev');
  if (saved) { state.deviceId = String(saved); return state.deviceId; }
  var hex = '';
  for (var i = 0; i < 32; i++) hex += '0123456789abcdef'.charAt(Math.floor(Math.random() * 16));
  var id = hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-4' + hex.slice(13, 16) + '-a' + hex.slice(17, 20) + '-' + hex.slice(20, 32);
  state.deviceId = id;
  await stSet('chengshe.dev', id);
  return id;
}

// ---------------------------------------------------------------- HTTP 封装
// 注意：桥接的 http.post 签名是 post(url, body, options)，body 在第二位；这里统一走 http.request。
async function httpPost(url, headers, body) {
  if (LumeSource.http.request) {
    return await LumeSource.http.request({ url: url, method: 'POST', headers: headers || {}, body: body });
  }
  return await LumeSource.http.post(url, body, { headers: headers || {} });
}

async function probeApi(candidate) {
  var base = String(candidate || '').replace(/\/+$/, '').replace(/\/api$/, '');
  if (!base) return '';
  try {
    var res = await LumeSource.http.get(base + '/api/sys/findLive', { headers: { 'User-Agent': UA } });
    if (res && res.status === 200 && String(res.body || '').indexOf('"code":200') >= 0) return base;
  } catch (e) {}
  return '';
}

async function resolveApi() {
  if (state.api) return state.api;
  var custom = customDomain();
  if (custom) {
    var ok = await probeApi(custom);
    if (ok) { state.api = ok; return ok; }
  }
  var cached = await st(CACHE_KEY_API);
  if (cached) {
    var c = await probeApi(String(cached));
    if (c) { state.api = c; return c; }
  }
  for (var i = 0; i < SEEDS.length; i++) {
    try {
      var res = await LumeSource.http.get(SEEDS[i] + '/api/sys/findLive', { headers: { 'User-Agent': UA } });
      var txt = String((res && res.body) || '');
      if (txt.indexOf('"result"') < 0) continue;
      var m = /"result"\s*:\s*"([^"]+)"/.exec(txt);
      var pool = /"pool"\s*:\s*"([^"]+)"/.exec(txt);
      var cands = [];
      if (m && m[1]) cands.push(m[1]);
      if (pool && pool[1]) pool[1].split(',').forEach(function (u) { if (u) cands.push(u); });
      for (var k = 0; k < cands.length; k++) {
        var api = await probeApi(cands[k]);
        if (api) { state.api = api; await stSet(CACHE_KEY_API, api); return api; }
      }
    } catch (e) {}
  }
  for (var j = 0; j < FALLBACK_API.length; j++) {
    var f = await probeApi(FALLBACK_API[j]);
    if (f) { state.api = f; await stSet(CACHE_KEY_API, f); return f; }
  }
  throw new Error('线路全部不可用：line 分发接口没给出可用的 API 域名，稍后重试或换镜像');
}

function apiBase() { return (customDomain() || state.api || FALLBACK_API[0]).replace(/\/+$/, ''); }

// ---------------------------------------------------------------- 请求/解密
function ticket() {
  var t = String(Date.now());
  return { t: t, s: md5Hex(t.slice(3, 9)) };
}

async function apiHeaders(t, s) {
  var h = {
    'User-Agent': UA, app: 'cs', vn: '2.6.0', deviceid: await deviceId(),
    Origin: SITE, Referer: SITE + '/',
    Accept: 'application/json, text/plain, */*'
  };
  if (t) h.t = t;
  if (s) h.s = s;
  if (state.token) h.permissions = state.token;
  return h;
}

function responseSalt() {
  var tok = state.token || '';
  if (tok.length <= 18) return '';
  return tok.slice(2, 18).split('').reverse().join('');
}

function decryptEnvelope(text) {
  var raw = String(text || '').trim();
  if (!raw) throw new Error('接口空响应');
  if (raw.charAt(0) !== '{' && raw.charAt(0) !== '[') throw new Error('接口返回非 JSON（可能被拦截）');
  var j;
  try { j = JSON.parse(raw); } catch (e) { throw new Error('接口 JSON 解析失败'); }
  if (!j || j.encData === undefined) return j;
  var salt = responseSalt();
  if (!salt) throw new Error('缺少登录态，无法解密响应');
  var json = aesCbcDecryptUtf8(String(j.encData), salt);
  try { return JSON.parse(json); } catch (e) { throw new Error('响应解密后不是 JSON'); }
}

async function apiGet(path, params) {
  await ensureToken();
  var api = await resolveApi();
  var tk = ticket();
  var enc = aesCbcEncryptB64(JSON.stringify(params || {}), tk.t + '000');
  var url = api + path + '?encData=' + encodeURIComponent(enc) + '&_timestamp=' + Date.now();
  var res = await LumeSource.http.get(url, { headers: await apiHeaders(tk.t, tk.s) });
  if (!res || res.status === 0) throw new Error('接口没有响应');
  if (res.status === 403) throw new Error('站点 403：请求被拦，稍后再试或换镜像');
  var data = decryptEnvelope(res.body);
  if (data && data.code !== undefined && Number(data.code) !== 200) {
    if (Number(data.code) === 1001 || Number(data.code) === 302 || Number(data.code) === 301) {
      await stSet(CACHE_KEY_TOKEN, '');
      state.token = '';
      throw new Error('登录态失效（' + data.code + '），已清缓存，重试即可');
    }
    throw new Error('接口返回 ' + data.code + (data.msg ? '：' + data.msg : ''));
  }
  return data;
}

async function apiPost(path, body) {
  await ensureToken();
  var api = await resolveApi();
  var tk = ticket();
  var payload = JSON.stringify({ encData: aesCbcEncryptB64(JSON.stringify(body || {}), tk.t + '000') });
  var h = await apiHeaders(tk.t, tk.s);
  h['Content-Type'] = 'application/json';
  var res = await httpPost(api + path, h, payload);
  if (!res || res.status === 0) throw new Error('接口没有响应');
  if (res.status === 403) throw new Error('站点 403：请求被拦，稍后再试或换镜像');
  if (res.status >= 400 && String(res.body || '').charAt(0) === '{' && String(res.body).indexOf('encData') < 0) {
    var err = JSON.parse(String(res.body));
    throw new Error('接口 HTTP ' + res.status + (err && err.error ? '：' + err.error : ''));
  }
  var data = decryptEnvelope(res.body);
  if (data && data.code !== undefined && Number(data.code) !== 200) {
    throw new Error('接口返回 ' + data.code + (data.msg ? '：' + data.msg : ''));
  }
  return data;
}

// 匿名注册（明文响应）：拿 token，缓存 7 天
async function ensureToken() {
  if (state.token) return state.token;
  var cached = await st(CACHE_KEY_TOKEN);
  if (cached) { state.token = String(cached); return state.token; }
  var api = await resolveApi();
  var tk = ticket();
  var body = JSON.stringify({ encData: aesCbcEncryptB64(JSON.stringify({ deviceId: await deviceId() }), tk.t + '000') });
  var h = await apiHeaders(tk.t, tk.s);
  h['Content-Type'] = 'application/json';
  // 首次登录取 token 时不能带 permissions 头：带了空值服务端会直接返回空 body
  delete h.permissions;
  var res = await httpPost(api + '/api/user/tryLogin', h, body);
  if (!res || res.status !== 200) throw new Error('匿名登录失败（HTTP ' + (res && res.status) + '）');
  var j;
  try { j = JSON.parse(String(res.body)); } catch (e) { throw new Error('登录响应解析失败'); }
  var tok = j && j.data ? String(j.data.token || '') : '';
  if (!tok) throw new Error('登录没有拿到 token');
  state.token = tok;
  await stSet(CACHE_KEY_TOKEN, tok);
  return tok;
}

// ---------------------------------------------------------------- 数据映射
function s(v) { return v === undefined || v === null ? '' : String(v); }
function imgUrl(p) {
  var x = s(p);
  if (!x) return '';
  if (/^https?:\/\//.test(x)) return x;
  return IMG_CDN[0] + (x.charAt(0) === '/' ? '' : '/') + x;
}
function coverOf(v) {
  if (!v) return '';
  var sources = [];
  if (v.coverImg) sources.push(v.coverImg);
  if (v.verticalImg) sources.push(v.verticalImg);
  for (var i = 0; i < sources.length; i++) {
    // 视频是 [{coverImg}] 数组，短剧是 {coverImg,width,height} 单对象
    var item = Array.isArray(sources[i]) ? sources[i][0] : sources[i];
    var path = item ? s(item.coverImg) : '';
    if (path) return imgUrl(path);
  }
  return '';
}
function durationText(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0));
  var hour = Math.floor(total / 3600);
  var minute = Math.floor((total % 3600) / 60);
  var second = total % 60;
  var mm = (minute < 10 ? '0' : '') + minute;
  var ss = (second < 10 ? '0' : '') + second;
  return hour > 0 ? hour + ':' + mm + ':' + ss : minute + ':' + ss;
}
function rowOf(v) {
  var id = s(v && v.videoId);
  if (!id) return null;
  var title = s(v.title).trim();
  if (!title) return null;
  var bits = [];
  if (Number(v.price) > 0) bits.push('金币 ' + v.price + '（VIP 可直接播）');
  if (Number(v.playTime) > 0) bits.push(durationText(v.playTime));
  if (v.nickName) bits.push(s(v.nickName));
  if (v.tagTitles && v.tagTitles.length) bits.push(v.tagTitles.slice(0, 2).join(' '));
  return { id: id, title: title, cover: coverOf(v), subtitle: bits.join(' · ') };
}
function serialRowOf(v) {
  var id = s(v && v.serialId);
  if (!id) return null;
  var title = s(v.name).trim();
  if (!title) return null;
  var bits = [];
  if (Number(v.price) > 0) bits.push('金币 ' + v.price + '（VIP 可直接播）');
  if (v.videoNum) bits.push('共 ' + v.videoNum + ' 集');
  if (v.tags && v.tags.length) bits.push(v.tags.slice(0, 2).join(' '));
  return { id: 's' + id, title: title, cover: coverOf(v), subtitle: bits.join(' · ') };
}
function itemsOf(data) {
  if (Array.isArray(data)) return data;
  if (data && Array.isArray(data.data)) return data.data;
  if (data && Array.isArray(data.list)) return data.list;
  return [];
}

// ---------------------------------------------------------------- 分类
async function loadCats() {
  if (CATS.length) return CATS;
  var cached = await st(CACHE_KEY_CATS);
  if (cached) {
    try {
      var arr = JSON.parse(String(cached));
      if (arr && arr.length) { CATS = arr; return CATS; }
    } catch (e) {}
  }
  var out = [];
  var seen = {};
  function absorb(data, isVip) {
    itemsOf(data).forEach(function (c) {
      if (!c || c.classifyId === undefined) return;
      var title = s(c.classifyTitle).trim();
      if (!title) return;
      // 短剧（type 4）走 videoSerial 接口，不在分类视频里
      if (Number(c.classifyId) === SERIAL_CLASSIFY) return;
      if (EMPTY_CLASSIFY[Number(c.classifyId)]) return;
      var id = 'c' + c.classifyId;
      if (seen[id]) return;
      seen[id] = true;
      // 暗网板块：页面是 findClassifyList({needVip:true})，未开「永久至尊」时只显示解锁页，
      // 但分类接口和分类视频接口都不鉴权，视频照样能取到播放地址。
      out.push({ id: id, title: isVip ? '暗网 · ' + title : title, classifyId: Number(c.classifyId) });
    });
  }
  absorb(await apiGet('/api/video/findClassifyList', {}), false);
  try {
    absorb(await apiGet('/api/video/findClassifyList', { needVip: true }), true);
  } catch (e) {
    /* 暗网分类拿不到时至少还有普通分类 */
  }
  if (!out.length) throw new Error('分类接口没有解析到分类');
  CATS = out;
  await stSet(CACHE_KEY_CATS, JSON.stringify(out));
  return out;
}

async function listRanked(page, pageSize) {
  var data = await apiGet('/api/video/findRankList', { page: page, pageSize: pageSize });
  var rows = [];
  itemsOf(data).forEach(function (v) { var r = rowOf(v); if (r) rows.push(r); });
  return rows;
}

async function listClassify(cid, page, pageSize) {
  var data = await apiPost('/api/video/findClassifyVideos', { classifyId: cid, page: page, pageSize: pageSize });
  var rows = [];
  itemsOf(data).forEach(function (v) { var r = rowOf(v); if (r) rows.push(r); });
  return rows;
}

async function listSerials(page, pageSize) {
  var data = await apiGet('/api/videoSerial/findListByClass', { classifyId: SERIAL_CLASSIFY, page: page, pageSize: pageSize });
  var rows = [];
  itemsOf(data).forEach(function (v) { var r = serialRowOf(v); if (r) rows.push(r); });
  return rows;
}

async function listByKeyword(keyword, page, pageSize) {
  var data = await apiPost('/api/video/findVideoByTag', { tagTitles: [keyword], page: page, pageSize: pageSize });
  var rows = [];
  itemsOf(data).forEach(function (v) { var r = rowOf(v); if (r) rows.push(r); });
  return rows;
}

async function fetchVideo(videoId) {
  var d = await apiGet('/api/video/findVideoById', { videoId: Number(videoId) || videoId });
  var v = d && d.data ? d.data : d;
  if (!v || (v.videoId === undefined && !v.title)) return null;
  return v;
}

async function fetchSerial(serialId) {
  var d = await apiGet('/api/videoSerial/findDetail', { serialId: Number(serialId) || serialId });
  var v = d && d.data ? d.data : d;
  if (!v || v.serialId === undefined) return null;
  return v;
}

var LumeSource = {
  id: 'chengshe_video',
  name: '橙涩视频',
  version: '2.1.1',
  category: 'video',
  contentCategory: 'adult',

  async categories() {
    var cats = [];
    try { cats = await loadCats(); } catch (e) { cats = []; }
    var list = [{ id: 'hot', title: '排行榜' }, { id: 'serial', title: '橙涩短剧' }];
    for (var i = 0; i < cats.length; i++) list.push({ id: cats[i].id, title: cats[i].title });
    return list;
  },

  async home() {
    var boards = [];
    try {
      var rank = await listRanked(1, 12);
      if (rank.length) boards.push({ title: '排行榜', moreUrl: 'hot', items: rank.slice(0, 12) });
    } catch (e) {}
    try {
      var serials = await listSerials(1, 12);
      if (serials.length) boards.push({ title: '橙涩短剧', moreUrl: 'serial', items: serials.slice(0, 12) });
    } catch (e) {}
    try {
      var hot = await listClassify(15, 1, 12);
      if (hot.length) boards.push({ title: '热门', moreUrl: 'c15', items: hot.slice(0, 12) });
    } catch (e) {}
    if (!boards.length) {
      throw new Error('首页板块都没取到：可能是线路或游客登录失效，重试或换镜像');
    }
    return boards;
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    var pageSize = Number(cfg('pageSize')) || PAGE_SIZE;
    var keyword = s(a.keyword).trim();
    var cat = s(a.categoryId) || 'hot';

    if (keyword) {
      var hits = await listByKeyword(keyword, page, pageSize);
      return { items: hits, hasMore: hits.length >= pageSize };
    }
    if (cat === 'hot') {
      var rank = page > 1 ? [] : await listRanked(1, pageSize > 30 ? 30 : pageSize);
      return { items: rank, hasMore: false };
    }
    if (cat === 'serial') {
      var serials = await listSerials(page, pageSize);
      return { items: serials, hasMore: serials.length >= pageSize };
    }
    if (cat.indexOf('c') === 0) {
      var rows = await listClassify(Number(cat.slice(1)), page, pageSize);
      return { items: rows, hasMore: rows.length >= pageSize };
    }
    throw new Error('未知分类：' + cat);
  },

  async detail(args) {
    var id = s(args && args.id).trim();
    if (!id) return null;
    if (id.charAt(0) === 's') {
      var serial = await fetchSerial(id.slice(1));
      if (!serial) return null;
      var bits = [];
      if (Number(serial.price) > 0) bits.push('金币 ' + serial.price + '（VIP 已可直接播）');
      if (serial.videoNum) bits.push('共 ' + serial.videoNum + ' 集');
      var tags = (serial.tags || []).filter(Boolean).map(String);
      return {
        id: 's' + serial.serialId,
        title: s(serial.name) || '未命名短剧',
        cover: coverOf(serial),
        subtitle: bits.join(' · '),
        tags: tags,
        description:
          '橙涩短剧（' + SITE + '）\n' +
          'canWatch=' + s(serial.canWatch) + '，payType=' + s(serial.payType) + '，price=' + s(serial.price) + '\n' +
          (tags.length ? '标签：' + tags.join('・') + '\n' : '') +
          '接口直接下发整部播放列表，不再需要买券；本源按「全集」一集处理。'
      };
    }
    var v = await fetchVideo(id);
    if (!v) return null;
    if (v.videoUrl) known[id] = { url: s(v.videoUrl), access: s(v.access), title: s(v.title) };
    var list = (v.tagTitles || []).filter(Boolean).map(String);
    var desc = [];
    desc.push('canWatch=' + s(v.canWatch) + '，reasonType=' + s(v.reasonType) + '，price=' + s(v.price));
    if (v.nickName) desc.push('作者：' + s(v.nickName));
    if (list.length) desc.push('标签：' + list.join('・'));
    if (v.fakeWatchTimes) desc.push('播放：' + s(v.fakeWatchTimes));
    return {
      id: id,
      title: s(v.title) || id,
      cover: coverOf(v),
      subtitle: rowOf(v) ? rowOf(v).subtitle : '',
      description: desc.join('\n'),
      tags: list
    };
  },

  async chapters(args) {
    var id = s(args && args.id).trim();
    if (!id) return [];
    if (id.charAt(0) === 's') {
      var count = 1;
      try {
        var serial = await fetchSerial(id.slice(1));
        if (serial && Number(serial.videoNum) > 0) count = Number(serial.videoNum);
      } catch (e) {}
      return [{ id: id, title: '全集（共 ' + count + ' 集）' }];
    }
    var v = null;
    try { v = await fetchVideo(id); } catch (e) { v = null; }
    if (!v) return [{ id: id, title: '正片' }];
    var title = '正片';
    if (Number(v.playTime) > 0) title += ' · ' + durationText(v.playTime);
    return [{ id: id, title: title }];
  },

  async content(args) {
    var id = s(args && (args.id || args.chapterId)).trim();
    if (!id) throw new Error('缺少条目 ID');

    var videoUrl = '';
    var access = '';
    if (id.charAt(0) === 's') {
      var serial = await fetchSerial(id.slice(1));
      if (!serial) throw new Error('短剧详情取不到（可能已下架）');
      videoUrl = s(serial.videoUrl);
    } else {
      var row = known[id];
      if (!row || !row.url) {
        var v = await fetchVideo(id);
        if (!v) throw new Error('视频详情取不到（可能已下架）');
        row = { url: s(v.videoUrl), access: s(v.access) };
        known[id] = row;
      }
      videoUrl = row.url;
      access = row.access;
    }

    // 首选：CDN 直连 videoUrl（实测 VIP 片同样 200 + #EXTM3U）
    if (videoUrl) {
      var base = videoUrl.charAt(0) === '/' ? IMG_CDN[0] + videoUrl : videoUrl;
      return {
        kind: 'video',
        url: base,
        headers: { 'User-Agent': UA, Referer: SITE + '/' }
      };
    }
    // 兜底：老线路 /api/dec/m3u/ios/access.m3u8（需要详情里的 access）
    if (!access) throw new Error('这条没有播放地址：接口既没给 videoUrl 也没给 access');
    var api = await resolveApi();
    var tk = ticket();
    var enc = aesCbcEncryptB64(JSON.stringify({ access: access, path: videoUrl, id: '' }), tk.t + '000');
    var url = api + '/api/dec/m3u/ios/access.m3u8?encData=' + encodeURIComponent(enc) +
      '&t=' + tk.t + '&s=' + tk.s + '&_timestamp=' + Date.now();
    var h = await apiHeaders(tk.t, tk.s);
    h.Referer = SITE + '/';
    return { kind: 'video', url: url, headers: h };
  }
};

// ---------------------------------------------------------------- 纯 JS：MD5
function utf8Bytes(text) {
  var out = [], str = String(text == null ? '' : text);
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      var low = str.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        i++;
        var pt = 0x10000 + ((c - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (pt >> 18), 0x80 | ((pt >> 12) & 0x3f), 0x80 | ((pt >> 6) & 0x3f), 0x80 | (pt & 0x3f));
        continue;
      }
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return out;
}

function md5Hex(input) {
  function add32(a, b) { return (a + b) & 0xffffffff; }
  function rol(v, s2) { return (v << s2) | (v >>> (32 - s2)); }
  var bytes = utf8Bytes(String(input == null ? '' : input));
  var bitLen = bytes.length * 8;
  var pad = bytes.slice();
  pad.push(0x80);
  while (pad.length % 64 !== 56) pad.push(0);
  var hi = Math.floor(bitLen / 4294967296), lo = bitLen >>> 0;
  pad.push(lo & 0xff, (lo >>> 8) & 0xff, (lo >>> 16) & 0xff, (lo >>> 24) & 0xff);
  pad.push(hi & 0xff, (hi >>> 8) & 0xff, (hi >>> 16) & 0xff, (hi >>> 24) & 0xff);
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  var S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
  var K = [];
  for (var k = 0; k < 64; k++) K[k] = Math.floor(Math.abs(Math.sin(k + 1)) * 4294967296) >>> 0;
  for (var off = 0; off < pad.length; off += 64) {
    var m = [];
    for (var w = 0; w < 16; w++) {
      m[w] = (pad[off + w * 4] | (pad[off + w * 4 + 1] << 8) | (pad[off + w * 4 + 2] << 16) | (pad[off + w * 4 + 3] << 24)) >>> 0;
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (var i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D; D = C; C = B;
      B = add32(B, rol(add32(add32(A, F & 0xffffffff), add32(K[i], m[g])), S[i]));
      A = tmp;
    }
    a0 = add32(a0, A); b0 = add32(b0, B); c0 = add32(c0, C); d0 = add32(d0, D);
  }
  function hx(v) {
    var o = '';
    for (var j = 0; j < 4; j++) o += ('0' + ((v >>> (j * 8)) & 0xff).toString(16)).slice(-2);
    return o;
  }
  return hx(a0) + hx(b0) + hx(c0) + hx(d0);
}

// ---------------------------------------------------------------- 纯 JS：AES-128-CBC + Base64
var SBOX_HEX = '637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b27509832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cfd0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdbe0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9ee1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16';
var INV_SBOX_HEX = '52096ad53036a538bf40a39e81f3d7fb7ce339829b2fff87348e4344c4dee9cb547b9432a6c2233dee4c950b42fac34e082ea16628d924b2765ba2496d8bd12572f8f66486689816d4a45ccc5d65b6926c704850fdedb9da5e154657a78d9d8490d8ab008cbcd30af7e45805b8b34506d02c1e8fca3f0f02c1afbd0301138a6b3a9111414f67dcea97f2cfcef0b4e67396ac7422e7ad3585e2f937e81c75df6e47f11a711d29c5896fb7620eaa18be1bfc563e4bc6d279209adbc0fe78cd5af41fdda8338807c731b11210592780ec5f60517fa919b54a0d2de57a9f93c99cefa0e03b4dae2af5b0c8ebbb3c83539961172b047eba77d626e169146355210c7d';

function hexToBytes2(hex) {
  var out = [];
  for (var i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}
var SBOX = hexToBytes2(SBOX_HEX);
var INV_SBOX = hexToBytes2(INV_SBOX_HEX);
var MUL = (function () {
  var m = { mul2: [], mul3: [], mul9: [], mul11: [], mul13: [], mul14: [] };
  for (var i = 0; i < 256; i++) {
    var x = i;
    var x2 = ((x << 1) ^ (x & 0x80 ? 0x1b : 0)) & 0xff;
    var x4 = ((x2 << 1) ^ (x2 & 0x80 ? 0x1b : 0)) & 0xff;
    var x8 = ((x4 << 1) ^ (x4 & 0x80 ? 0x1b : 0)) & 0xff;
    m.mul2[i] = x2; m.mul3[i] = (x2 ^ x) & 0xff;
    m.mul9[i] = (x8 ^ x) & 0xff; m.mul11[i] = (x8 ^ x2 ^ x) & 0xff;
    m.mul13[i] = (x8 ^ x4 ^ x) & 0xff; m.mul14[i] = (x8 ^ x4 ^ x2) & 0xff;
  }
  return m;
})();

function expandKey128(keyBytes) {
  var nk = 4, nr = 10, w = [];
  for (var i = 0; i < nk; i++) w.push(keyBytes.slice(4 * i, 4 * i + 4));
  var rcon = 1;
  for (var j = nk; j < 4 * (nr + 1); j++) {
    var t = w[j - 1].slice();
    if (j % nk === 0) {
      t = [SBOX[t[1]] ^ rcon, SBOX[t[2]], SBOX[t[3]], SBOX[t[0]]];
      rcon = MUL.mul2[rcon];
    }
    w.push([w[j - nk][0] ^ t[0], w[j - nk][1] ^ t[1], w[j - nk][2] ^ t[2], w[j - nk][3] ^ t[3]]);
  }
  return { w: w, nr: nr };
}
function keyBytesOf(str) {
  var out = utf8Bytes(str);
  var key = [], i;
  for (i = 0; i < 16; i++) key.push(i < out.length ? out[i] : 0);
  return key;
}
function addRoundKey(stateArr, ks, round) {
  for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) stateArr[4 * c + r] ^= ks.w[round * 4 + c][r];
}
function subBytes(stateArr) { for (var i = 0; i < 16; i++) stateArr[i] = SBOX[stateArr[i]]; }
function invSubBytes(stateArr) { for (var i = 0; i < 16; i++) stateArr[i] = INV_SBOX[stateArr[i]]; }
function shiftRows(stateArr) {
  var t = stateArr.slice();
  for (var r = 1; r < 4; r++) for (var c = 0; c < 4; c++) stateArr[4 * c + r] = t[4 * ((c + r) % 4) + r];
}
function invShiftRows(stateArr) {
  var t = stateArr.slice();
  for (var r = 1; r < 4; r++) for (var c = 0; c < 4; c++) stateArr[4 * c + r] = t[4 * ((c - r + 4) % 4) + r];
}
function mixColumns(stateArr) {
  for (var c = 0; c < 4; c++) {
    var a0 = stateArr[4 * c], a1 = stateArr[4 * c + 1], a2 = stateArr[4 * c + 2], a3 = stateArr[4 * c + 3];
    stateArr[4 * c] = MUL.mul2[a0] ^ MUL.mul3[a1] ^ a2 ^ a3;
    stateArr[4 * c + 1] = a0 ^ MUL.mul2[a1] ^ MUL.mul3[a2] ^ a3;
    stateArr[4 * c + 2] = a0 ^ a1 ^ MUL.mul2[a2] ^ MUL.mul3[a3];
    stateArr[4 * c + 3] = MUL.mul3[a0] ^ a1 ^ a2 ^ MUL.mul2[a3];
  }
}
function invMixColumns(stateArr) {
  for (var c = 0; c < 4; c++) {
    var a0 = stateArr[4 * c], a1 = stateArr[4 * c + 1], a2 = stateArr[4 * c + 2], a3 = stateArr[4 * c + 3];
    stateArr[4 * c] = MUL.mul14[a0] ^ MUL.mul11[a1] ^ MUL.mul13[a2] ^ MUL.mul9[a3];
    stateArr[4 * c + 1] = MUL.mul9[a0] ^ MUL.mul14[a1] ^ MUL.mul11[a2] ^ MUL.mul13[a3];
    stateArr[4 * c + 2] = MUL.mul13[a0] ^ MUL.mul9[a1] ^ MUL.mul14[a2] ^ MUL.mul11[a3];
    stateArr[4 * c + 3] = MUL.mul11[a0] ^ MUL.mul13[a1] ^ MUL.mul9[a2] ^ MUL.mul14[a3];
  }
}
function encryptBlock(block, ks) {
  var st8 = block.slice();
  addRoundKey(st8, ks, 0);
  for (var round = 1; round < ks.nr; round++) {
    subBytes(st8); shiftRows(st8); mixColumns(st8); addRoundKey(st8, ks, round);
  }
  subBytes(st8); shiftRows(st8); addRoundKey(st8, ks, ks.nr);
  return st8;
}
function decryptBlock(block, ks) {
  var st8 = block.slice();
  addRoundKey(st8, ks, ks.nr);
  for (var round = ks.nr - 1; round >= 1; round--) {
    invShiftRows(st8); invSubBytes(st8); addRoundKey(st8, ks, round); invMixColumns(st8);
  }
  invShiftRows(st8); invSubBytes(st8); addRoundKey(st8, ks, 0);
  return st8;
}
function pkcs7Pad(bytes) {
  var n = 16 - (bytes.length % 16);
  var out = bytes.slice();
  for (var i = 0; i < n; i++) out.push(n);
  return out;
}
function pkcs7Unpad(bytes) {
  if (!bytes.length) return bytes;
  var n = bytes[bytes.length - 1];
  if (n < 1 || n > 16 || n > bytes.length) return bytes;
  return bytes.slice(0, bytes.length - n);
}
function base64Encode(bytes) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    out += chars.charAt(b0 >> 2);
    out += chars.charAt(((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4));
    out += b1 === undefined ? '=' : chars.charAt(((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6));
    out += b2 === undefined ? '=' : chars.charAt(b2 & 63);
  }
  return out;
}
function base64Decode(str) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  // 保留 '=' 让 indexOf 返回 -1，尾部填充才不会多解出字节
  var clean = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < clean.length; i += 4) {
    var c0 = chars.indexOf(clean.charAt(i));
    var c1 = chars.indexOf(clean.charAt(i + 1));
    var c2 = chars.indexOf(clean.charAt(i + 2));
    var c3 = chars.indexOf(clean.charAt(i + 3));
    out.push((c0 << 2) | (c1 >> 4));
    if (c2 >= 0) out.push(((c1 & 15) << 4) | (c2 >> 2));
    if (c3 >= 0) out.push(((c2 & 3) << 6) | c3);
  }
  return out;
}
function bytesToUtf8(bytes) {
  var out = '', i = 0;
  while (i < bytes.length) {
    var b = bytes[i++];
    if (b < 0x80) out += String.fromCharCode(b);
    else if (b < 0xe0) out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
    else if (b < 0xf0) out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    else {
      var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

function aesCbcEncryptB64(plainText, keyStr) {
  var ks = expandKey128(keyBytesOf(keyStr));
  var iv = keyBytesOf(keyStr);
  var data = pkcs7Pad(utf8Bytes(plainText));
  var prev = iv.slice();
  var out = [];
  for (var off = 0; off < data.length; off += 16) {
    var block = [];
    for (var i = 0; i < 16; i++) block.push(data[off + i] ^ prev[i]);
    var enc = encryptBlock(block, ks);
    for (var j = 0; j < 16; j++) out.push(enc[j]);
    prev = enc;
  }
  return base64Encode(out);
}

function aesCbcDecryptUtf8(b64, keyStr) {
  var ks = expandKey128(keyBytesOf(keyStr));
  var iv = keyBytesOf(keyStr);
  var data = base64Decode(b64);
  var prev = iv.slice();
  var out = [];
  for (var off = 0; off < data.length; off += 16) {
    var block = [];
    for (var i = 0; i < 16; i++) block.push(data[off + i]);
    var dec = decryptBlock(block, ks);
    for (var j = 0; j < 16; j++) out.push(dec[j] ^ prev[j]);
    prev = block;
  }
  return bytesToUtf8(pkcs7Unpad(out));
}
