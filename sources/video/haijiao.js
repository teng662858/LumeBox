// LumeSource: {"id":"haijiao_video","name":"海角 18+","version":"1.2.0","category":"video","contentCategory":"adult","mirrors":["https://www.haijiao.com","https://haijiao.com"],"network":"direct","icon":"https://www.haijiao.com/imgs/project/favicon.ico"}
//
// 站点：海角社区（https://www.haijiao.com/home，Vue2 SPA + /api JSON，2026-11-01 复测）
//
// ── 网络：2026-11-01 复测直连可开（/api/video-center/video/list 200、1.7s）；
//   2026-10-25 那会儿要代理，所以两边都能连的写法更稳 —— 直连失败时再到「源设置 → 网络」配代理。
//   www / 裸域都能开，优先 www（裸域同样 200）。
//
// ── 页面是空壳，数据全在 /api 下（从 /js/app.4074e6c8.js 里挖出来的）
//   分类树  GET  /api/video-center/category/list        → [{id,name,children:[…]}]（6 个分组）
//   列表    GET  /api/video-center/video/list?page=&limit=&sort=desc
//                &top_category_id={分组 id}&category_id={子类 id}&keyword={搜索词}
//            → {results:[…], page:{page,limit,total}}（实测 keyword 直接可用，total 会跟着变）
//   详情    GET  /api/video-center/video/detail?id={视频 id}
//   线路    GET  /api/topic/att/{attachment_id}         → [{name:'普通1 18+',url,VipLimit},…]
//   登录    POST /api/login/signin  {username, password}（实测不需要图形验证码：/api/captcha/isNeed → false）
//
// ── ⚠ 响应是「三重 Base64」，不是 AES
//   /js/app.4074e6c8.js 的 axios 响应拦截器对 `isEncrypted:true` 的包体做
//   JSON.parse(Base64.decode(Base64.decode(Base64.decode(data))))。
//   本源照这个语义实现（自带 base64 + UTF-8 解码：沙箱里没有 atob / Buffer）。
//
// ── 封面分两条管线（实测，别一概而论）
//   · cover_url 形如 /hjstore/video/…/566888.jpeg.txt → **去掉 .txt 就是 200 image/jpeg**，直接用；
//   · cover_url 形如 /hjstore/images/…_mini.jpg.txt   → 去掉 .txt 直链 **403**，.txt 本身是加密图
//     （站点前端用 v-lazyloadimg 指令现解），App 图片管线解不开 —— 这种不给封面，
//     宁可留空也不要在列表里刷一片破图。
//
// ── 播放地址：2026-11-01 用真账号把两条路都跑通了（结论按接口分开说，别再一概而论）
//   **A. 帖子（topic）里的视频：登录就够，不用买券** ✅ 原生可播
//       POST /api/attachment  {id:<附件id>, line:'', resource_id:<topicId>, resource_type:'topic'}
//       → 200 data.remoteUrl = https://ts10.hj260302818.top/hjstore/video/<日期>/<hash>/<附件id><tok>_i.m3u8
//       实测该 m3u8 200 + #EXTM3U、key 200（16 字节）、分片 200，App 原生 HLS 直接能放。
//       ★ 注意 line 必须传 ''（传 0 会回"请求错误"），resource_type 必须是 'topic'。
//   **B. 视频中心（video_center）的片子：服务端账务门禁** ❌ 拿不到
//       同一个接口传 resource_type:'video_center' → 200 但 message="当前用户无权播放该视频"
//       （登录 + 无券账号实测；GET /api/video/<id> 指的是另一张旧表，不是视频中心的 id）。
//       这条走网页播放，本源码不去绕站点账务。
//   **C. sleazyfork 上那些"海角破解脚本"的真相（拆包实证）**
//       ① 只处理 post/details 页面 —— 也就是上面的 A 路：它们只是把附件地址取出来换播放器；
//       ② 遇到"付费帖"它们并不破站，而是去 GitHub Gist 拉配置（svc + 一个 JWT 形式的 key），
//          再请求第三方解析站（实测配置里是 https://kittymao.xyz/api/hj/movieInfo?kthjau=<key>…）
//          拿别人的转码地址。那是外部盗链服务，key 会轮换、随时挂，还有广告/钓鱼风险，本源不接。
//
//   所以本源：
//     1) 元数据（分类 / 列表 / 搜索 / 详情 / 封面）匿名全部可用；
//     2) 帖子视频（条目 id = `t<topicId>`，分类「帖子视频」）：登录后走 A 路取真 m3u8，原生播放；
//        没登录就退回网页播放（/post/details?pid=…）；
//     3) 视频中心：先试 A 接口（B 路若放行就原生播），拿不到就 webplayer（/watch?id=…）；
//     4) 登录方式：账号密码填「源设置 → 账号登入」（POST /api/login/signin，不需要图形验证码），
//        或把浏览器 Cookie（含 token=、uid=）粘到「网络配置」。
//        注：Cookie 里可能同时存在别的域的同名 uid（例如广告域 ad.* 的 16 位十六进制 uid），
//        本源优先取**纯数字**的那个（海角的 uid 是数字），避免把广告 uid 当账号 id 发出去。
//     5) 网页播放页路由实测：/watch?id=<videoId>（c3 里 `$router.push({name:'videoWatch',query:{id}})`），
//        帖子详情页是 /post/details?pid=<topicId>。
//
// ── 未成年相关的分类/标签：分类树里「服装 → 学生」(#20)、「特色 → 校园」(#40) 属于未成年指向，
//   **不接进 categories / filters**，标题命中的条目在列表层直接剔除（见 BANNED）。
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
var DEFAULT_BASE = 'https://haijiao.com';
var PAGE_LIMIT = 20;

// 未成年指向的分类/标签/标题：一律不接、不展示。
var BANNED = /(萝莉|幼齿|幼女|未成年|少女|正太|学生|校园|初中|高中|小学|儿童|童颜|女童|祼童|童|loli|lolita|teen|child|underage|schoolgirl)/i;

function base() {
  var conf = typeof LumeSource !== 'undefined' && LumeSource.config ? LumeSource.config : null;
  return String((conf && conf.domain) || DEFAULT_BASE).replace(/\/+$/, '');
}

function config() {
  return (typeof LumeSource !== 'undefined' && LumeSource.config) || {};
}

/* ------------------------------- 编解码 ------------------------------- */
var B64CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function base64ToBytes(input) {
  var text = String(input == null ? '' : input).replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i);
    if (ch === '=') break;
    var value = B64CHARS.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var index = 0;
  while (index < bytes.length) {
    var first = bytes[index++];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      continue;
    }
    var extra = 0;
    var code = 0;
    if (first >= 0xc0 && first < 0xe0) {
      code = first & 0x1f;
      extra = 1;
    } else if (first >= 0xe0 && first < 0xf0) {
      code = first & 0x0f;
      extra = 2;
    } else if (first >= 0xf0) {
      code = first & 0x07;
      extra = 3;
    } else {
      out += String.fromCharCode(first);
      continue;
    }
    for (var step = 0; step < extra; step++) code = (code << 6) | (bytes[index + step] & 0x3f);
    index += extra;
    if (code > 0xffff) {
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

/// 三重 Base64 → 明文（连解三次，与站点拦截器一致）
function unsealB64(text) {
  var decoded = String(text == null ? '' : text);
  for (var round = 0; round < 3; round++) decoded = utf8Decode(base64ToBytes(decoded));
  return decoded;
}

function unseal(payload) {
  if (!payload || payload.isEncrypted !== true) return payload ? payload.data : null;
  var text = String(payload.data == null ? '' : payload.data);
  try {
    return JSON.parse(unsealB64(text));
  } catch (error) {
    return unsealB64(text);
  }
}

/* ------------------------------- 网络 ------------------------------- */
function headersFor(auth, referer) {
  var out = {
    'User-Agent': UA,
    'Accept-Language': 'zh-CN,zh;q=0.9',
    Accept: 'application/json, text/plain, */*',
    Referer: referer || base() + '/home',
    Origin: base(),
    pcVer: '2'
  };
  if (auth && auth.token) out['X-User-Token'] = String(auth.token);
  if (auth && auth.uid) out['X-User-Id'] = String(auth.uid);
  return out;
}

async function rawFetch(url, options) {
  var lastError = null;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      if (options && options.method === 'POST') {
        return await LumeSource.http.post(url, options.body, { headers: options.headers });
      }
      return await LumeSource.http.get(url, { headers: options ? options.headers : {} });
    } catch (error) {
      lastError = error;
      await new Promise(function (resolve) {
        setTimeout(resolve, 250);
      });
    }
  }
  var hint = lastError && lastError.message ? String(lastError.message) : '网络错误';
  throw new Error(
    '海角：连不上站点（' +
      hint +
      '）。本站直连不通，请在「源设置 → 网络」里给本源配置代理（如 http://127.0.0.1:7890）后重试'
  );
}

async function apiRequest(path, options) {
  var opt = options || {};
  var url = base() + '/api' + path;
  if (opt.params) {
    var pairs = [];
    for (var key in opt.params) {
      if (!Object.prototype.hasOwnProperty.call(opt.params, key)) continue;
      var value = opt.params[key];
      if (value === undefined || value === null || value === '') continue;
      pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
    }
    if (pairs.length) url += '?' + pairs.join('&');
  }
  var auth = opt.auth === undefined ? await currentAuth() : opt.auth;
  var headers = headersFor(auth, opt.referer);
  if (opt.body) headers['Content-Type'] = 'application/json;charset=UTF-8';
  var response = await rawFetch(url, {
    method: opt.body ? 'POST' : 'GET',
    body: opt.body ? JSON.stringify(opt.body) : null,
    headers: headers
  });
  var status = Number(response && response.status);
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：海角触发了人机校验（HTTP ' + status + '），请在网页视图里过一下校验，或给本源配置代理');
  }
  if (status !== 200) throw new Error('海角：接口返回 HTTP ' + status + '（' + path + '）');
  var body = String((response && response.body) || '').trim();
  if (body.charAt(0) !== '{') {
    throw new Error('海角：接口返回的不是 JSON（' + path + '），站点可能改版了');
  }
  var payload = null;
  try {
    payload = JSON.parse(body);
  } catch (error) {
    throw new Error('海角：接口 JSON 解析失败（' + path + '）');
  }
  return {
    code: Number(payload.errorCode),
    ok: payload.success === true,
    message: String(payload.message || ''),
    data: unseal(payload)
  };
}

/* ------------------------------- 登录态 ------------------------------- */
var AUTH_MEMORY = null;

function authFromCookie(cookieText) {
  var text = String(cookieText || '');
  if (!text) return null;
  var tokenMatch = /(?:^|;\s*)token=([^;]+)/i.exec(text);
  if (!tokenMatch) return null;
  // Cookie 里常有别的域的同名 uid（例：广告域 ad.* 写的 16 位十六进制）。
  // 海角自己的 uid 是纯数字，所以优先取纯数字那个，取不到才退回第一个。
  var allUids = [];
  var uidPattern = /(?:^|;\s*)uid=([^;]+)/gi;
  var hit;
  while ((hit = uidPattern.exec(text)) !== null) allUids.push(String(hit[1]).trim());
  if (!allUids.length) return null;
  var numeric = null;
  for (var index = 0; index < allUids.length; index++) {
    if (/^\d+$/.test(allUids[index])) {
      numeric = allUids[index];
      break;
    }
  }
  var uid = numeric || allUids[0];
  return { token: tokenMatch[1].trim(), uid: uid };
}

/// 登录态来源：Cookie（宿主注入的 config.cookie）> fs 缓存 > 账号密码换 token。
async function currentAuth() {
  if (AUTH_MEMORY) return AUTH_MEMORY;
  var fromCookie = authFromCookie(config().cookie);
  if (fromCookie) {
    AUTH_MEMORY = fromCookie;
    return AUTH_MEMORY;
  }
  try {
    var cached = await LumeSource.fs.readText('auth.json');
    if (cached) {
      var parsed = JSON.parse(cached);
      if (parsed && parsed.token && parsed.uid) {
        AUTH_MEMORY = { token: String(parsed.token), uid: String(parsed.uid) };
        return AUTH_MEMORY;
      }
    }
  } catch (error) {
    /* 缓存坏了就当没登录 */
  }
  return null;
}

/// 用「源设置 → 账号登入」里的账号密码换 token（/api/login/signin 不需要验证码）。
async function signIn() {
  var conf = config();
  if (!conf.account || !conf.password) return null;
  var reply = await apiRequest('/login/signin', {
    auth: null,
    referer: base() + '/login',
    body: { username: String(conf.account), password: String(conf.password) }
  });
  if (!reply.ok) {
    throw new Error('海角：登录失败（' + (reply.message || '账号或密码不对') + '），请到「源设置 → 账号登入」改一下');
  }
  var data = reply.data || {};
  var user = data.user || data.userInfo || {};
  var token = data.token || data.accessToken || data.access_token || '';
  var uid = data.uid || data.id || user.id || '';
  if (!token || !uid) throw new Error('海角：登录接口没返回 token/uid（站点可能改了登录协议）');
  AUTH_MEMORY = { token: String(token), uid: String(uid) };
  try {
    await LumeSource.fs.writeText('auth.json', JSON.stringify(AUTH_MEMORY));
  } catch (error) {
    /* 写不进缓存不影响本次播放 */
  }
  return AUTH_MEMORY;
}

/* ------------------------------- 数据整形 ------------------------------- */
function abs(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

/// 封面：只有 /hjstore/video/ 这条管线去掉 .txt 后是能直接取的原图；
/// /hjstore/images/ 的直链被 CDN 403（其 .txt 是加密图，App 解不开），这种留空。
function coverOf(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  var stripped = text.replace(/\.txt$/i, '');
  if (/\/hjstore\/video\//i.test(stripped)) return stripped;
  if (!/\.txt$/i.test(text)) return abs(text);
  return '';
}

function clock(seconds) {
  var total = Math.floor(Number(seconds) || 0);
  if (!total) return '';
  var hour = Math.floor(total / 3600);
  var minute = Math.floor((total % 3600) / 60);
  var second = total % 60;
  var pad = function (value) {
    return value < 10 ? '0' + value : String(value);
  };
  return hour ? hour + ':' + pad(minute) + ':' + pad(second) : minute + ':' + pad(second);
}

/// 列表条目。access_type：1 = 站点标为免费（但仍要登录才下发地址），其余要观影券/VIP。
function toItem(row) {
  if (!row || !row.id) return null;
  var title = String(row.title || '').trim();
  if (!title || BANNED.test(title)) return null;
  var bits = [];
  if (row.duration_seconds) bits.push(clock(row.duration_seconds));
  bits.push(row.access_type === 1 ? '免费(需登录)' : '需券/VIP');
  if (row.view_count) bits.push(row.view_count + ' 播放');
  return {
    id: String(row.id),
    title: title,
    cover: coverOf(row.cover_url),
    subtitle: bits.join(' · ')
  };
}

async function fetchList(page, limit, extra) {
  var params = { page: page, limit: limit, sort: 'desc' };
  if (extra) {
    for (var key in extra) {
      if (Object.prototype.hasOwnProperty.call(extra, key)) params[key] = extra[key];
    }
  }
  var reply = await apiRequest('/video-center/video/list', { params: params, referer: base() + '/video' });
  if (reply.code !== 0 || !reply.data) {
    throw new Error('海角：列表接口失败（' + (reply.message || 'errorCode ' + reply.code) + '）');
  }
  var rows = Array.isArray(reply.data.results) ? reply.data.results : [];
  var items = [];
  for (var i = 0; i < rows.length; i++) {
    var item = toItem(rows[i]);
    if (item) items.push(item);
  }
  var meta = reply.data.page || {};
  var total = Number(meta.total) || 0;
  return { items: items, hasMore: total > page * limit };
}

/* ------------------------------- 分类树 ------------------------------- */
var CATEGORY_MEMORY = null;

async function loadTree() {
  if (CATEGORY_MEMORY) return CATEGORY_MEMORY;
  var reply = await apiRequest('/video-center/category/list', { referer: base() + '/video' });
  if (reply.code !== 0 || !Array.isArray(reply.data)) {
    throw new Error('海角：分类接口失败（' + (reply.message || 'errorCode ' + reply.code) + '）');
  }
  var groups = [];
  for (var i = 0; i < reply.data.length; i++) {
    var group = reply.data[i] || {};
    if (!group.id || !group.name) continue;
    if (BANNED.test(String(group.name))) continue;
    var children = [];
    var raw = Array.isArray(group.children) ? group.children : [];
    for (var c = 0; c < raw.length; c++) {
      var child = raw[c] || {};
      if (!child.id || !child.name) continue;
      if (BANNED.test(String(child.name))) continue; // ← 「学生」「校园」在这里被挡掉
      children.push({ id: String(child.id), title: String(child.name), groupId: String(group.id) });
    }
    groups.push({ id: String(group.id), title: String(group.name), children: children });
  }
  CATEGORY_MEMORY = groups;
  return groups;
}

var DETAIL_MEMORY = {};

async function detailRow(videoId) {
  var key = String(videoId);
  if (DETAIL_MEMORY[key]) return DETAIL_MEMORY[key];
  var reply = await apiRequest('/video-center/video/detail', {
    params: { id: key },
    referer: base() + '/video/watch?videoid=' + key
  });
  if (reply.code !== 0 || !reply.data) {
    if (reply.code === 1) throw new Error('海角：视频详情需要登录（接口返回「' + (reply.message || '请先登录') + '」）');
    return null;
  }
  DETAIL_MEMORY[key] = reply.data;
  return reply.data;
}

/// 线路表：匿名能拿到线路名，但 url 全空（见文件头实证）。
async function fetchLines(attachmentId, videoId) {
  var reply = await apiRequest('/topic/att/' + encodeURIComponent(attachmentId), {
    referer: base() + '/video/watch?videoid=' + (videoId || '')
  });
  if (reply.code !== 0 || !Array.isArray(reply.data)) return [];
  var lines = [];
  for (var i = 0; i < reply.data.length; i++) {
    var line = reply.data[i] || {};
    lines.push({
      name: String(line.name || '线路 ' + (i + 1)),
      url: String(line.url || '').trim(),
      vip: Number(line.VipLimit) === 1
    });
  }
  return lines;
}

function playableLines(lines) {
  var played = [];
  for (var i = 0; i < lines.length; i++) {
    if (!/^https?:\/\//i.test(lines[i].url)) continue;
    played.push({ label: lines[i].name + (lines[i].vip ? '（VIP）' : ''), url: lines[i].url });
  }
  return played;
}

// ── 真正的取地址接口（2026-11-01 用真账号实测出来的）──
//   POST /api/attachment  {id:<附件 id>, line:'', resource_id:<帖子/视频 id>, resource_type:'topic'|'video_center'}
//   · resource_type:'topic' + 已登录 → 200 且 data.remoteUrl = https://ts10.hj…/<hash>/<附件id><token>_i.m3u8
//     （**登录就够，不用买券**；帖子正文里的视频走这条）——这就是那些"解锁脚本"真正用的接口。
//   · resource_type:'video_center' → 未购买/VIP 时 200 但 message="当前用户无权播放该视频"。这是站点账务，
//     源里如实退回网页播放，不绕。
//   line 传 '' 才会命中"普通1"；传 0 会回 "请求错误"。
async function fetchAttachmentUrl(attachmentId, resourceId, resourceType) {
  var id = Number(attachmentId);
  var owner = Number(resourceId);
  if (!id || !owner) return '';
  var auth = await currentAuth();
  if (!auth) auth = await signIn();
  if (!auth) return '';
  var reply = await apiRequest('/attachment', {
    auth: auth,
    referer: base() + '/home',
    body: { id: id, line: '', resource_id: owner, resource_type: resourceType }
  });
  if (!reply.ok) return '';
  var data = reply.data || {};
  return String(data.remoteUrl || '').trim();
}

// ── 论坛帖子（topic）：正文里的视频登录即可原生播放，所以单独接成一类条目 ──
var TOPIC_FEED = '/topic/node/topics?type=1&page=';

function topicVideoAttachment(row) {
  var list = row && Array.isArray(row.attachments) ? row.attachments : [];
  for (var i = 0; i < list.length; i++) {
    var att = list[i] || {};
    if (String(att.category || '') === 'video' && att.id) return att;
  }
  return null;
}

function topicToItem(row) {
  if (!row || !row.topicId) return null;
  var title = String(row.title || '').trim();
  if (!title || BANNED.test(title)) return null;
  var att = topicVideoAttachment(row);
  if (!att) return null; // 只有图文帖的先进来也没用，直接跳过
  var bits = [];
  if (row.node && row.node.name) bits.push(String(row.node.name));
  if (row.viewCount) bits.push(row.viewCount + ' 浏览');
  if (row.likeCount) bits.push(row.likeCount + ' 赞');
  return {
    id: 't' + row.topicId,
    title: title,
    cover: coverOf(att.coverUrl || ''),
    subtitle: bits.join(' · ')
  };
}

async function fetchTopicPage(page) {
  var reply = await apiRequest(TOPIC_FEED + page, { referer: base() + '/home' });
  if (reply.code !== 0 || !reply.data) {
    throw new Error('海角：帖子列表接口失败（' + (reply.message || 'errorCode ' + reply.code) + '）');
  }
  var rows = Array.isArray(reply.data.results) ? reply.data.results : [];
  var items = [];
  for (var i = 0; i < rows.length; i++) {
    var item = topicToItem(rows[i]);
    if (item) items.push(item);
  }
  var meta = reply.data.page || {};
  var total = Number(meta.total) || 0;
  return { items: items, hasMore: total > page * PAGE_LIMIT };
}

var TOPIC_MEMORY = {};

async function topicRow(topicId) {
  var key = String(topicId);
  if (TOPIC_MEMORY[key]) return TOPIC_MEMORY[key];
  var reply = await apiRequest('/topic/' + key, { referer: base() + '/home' });
  if (reply.code !== 0 || !reply.data) return null;
  TOPIC_MEMORY[key] = reply.data;
  return reply.data;
}

/// 帖子详情（t<topicId>）
async function topicDetail(topicId) {
  var row = await topicRow(topicId);
  if (!row) return null;
  var title = String(row.title || '').trim();
  if (!title) return null;
  var lines = [];
  if (row.node && row.node.name) lines.push('版块：' + String(row.node.name));
  if (row.user && row.user.nickname) lines.push('作者：' + String(row.user.nickname));
  if (row.createTime) lines.push('发布：' + String(row.createTime).slice(0, 16));
  var bits = [];
  if (row.viewCount) bits.push(row.viewCount + ' 浏览');
  if (row.commentCount) bits.push(row.commentCount + ' 评论');
  var tags = [];
  if (Array.isArray(row.tags)) {
    for (var i = 0; i < row.tags.length; i++) {
      var tag = row.tags[i];
      if (tag && tag.tagName && !BANNED.test(String(tag.tagName))) tags.push(String(tag.tagName));
    }
  }
  if (tags.length) lines.push('标签：' + tags.join(' / '));
  if (row.money_type) {
    lines.push('付费帖：money_type=' + row.money_type + '（帖子视频登录可播，正文内容按站点规则）');
  } else {
    lines.push('观看：帖子里的视频登录后可直接原生播放');
  }
  var text = String(row.content || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (text) lines.push(text.slice(0, 300));
  var att = topicVideoAttachment(row);
  return {
    id: 't' + String(topicId),
    title: title,
    cover: att ? coverOf(att.coverUrl || '') : '',
    subtitle: bits.join(' · '),
    description: lines.join('\n')
  };
}

/// 播放门禁的说明（详情页里给用户看；播放时改用网页视图，不再抛错）
function gateMessage() {
  return (
    '获取地址：视频中心的片子要不买券/开 VIP，服务端不会下发地址（POST /api/attachment 明确回' +
    '「当前用户无权播放该视频」），本源在这一步改走网页播放（/watch?id=…）。' +
    '想走原生地址：到「源设置 → 账号登入」填账号密码或粘 Cookie（含 token=、uid=）。' +
    '注：论坛帖子里的视频登录就够，不需要买券，本源会自动走原生播放。'
  );
}

var LumeSource = {
  id: 'haijiao_video',
  name: '海角',
  version: '1.2.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://www.haijiao.com', 'https://haijiao.com'],

  async categories() {
    var tree = await loadTree();
    var rows = [
      { id: 'topic_video', title: '帖子视频（登录可原生播）' },
      { id: 'feed_latest', title: '最新' },
      { id: 'feed_hot', title: '最热' }
    ];
    for (var i = 0; i < tree.length; i++) rows.push({ id: 'group_' + tree[i].id, title: tree[i].title });
    return rows;
  },

  async home() {
    var boards = [];
    var latest = await fetchList(1, PAGE_LIMIT, {});
    if (latest.items.length) boards.push({ title: '最新', moreUrl: 'feed_latest', items: latest.items.slice(0, 18) });
    // 第二块别再拿第 1 页充数（1.0.0 两块内容一模一样）：取第 2 页并与首屏去重。
    try {
      var seen = {};
      for (var index = 0; index < latest.items.length; index++) seen[latest.items[index].id] = true;
      var more = await fetchList(2, PAGE_LIMIT, {});
      var extra = [];
      for (var c = 0; c < more.items.length; c++) {
        if (!seen[more.items[c].id]) extra.push(more.items[c]);
      }
      if (extra.length) {
        boards.push({ title: '更多', moreUrl: 'feed_latest', items: extra.slice(0, 18) });
      }
    } catch (error) {
      /* 第二块挂了不影响首屏 */
    }
    // 第三块：论坛帖子里带视频的（登录后能直接原生播放，见文件头实证）
    try {
      var topics = await fetchTopicPage(1);
      if (topics.items.length) {
        boards.push({ title: '帖子视频', moreUrl: 'topic_video', items: topics.items.slice(0, 18) });
      }
    } catch (error) {
      /* 帖子流挂了不影响首屏 */
    }
    if (!boards.length) throw new Error('海角：首页没有解析出条目（站点可能改版，或网络被拦）');
    return boards;
  },

  /// 筛选：分类树原样给出去（学生 / 校园已过滤）
  async filters() {
    var tree = await loadTree();
    var groups = [];
    for (var i = 0; i < tree.length; i++) {
      if (!tree[i].children.length) continue;
      groups.push({ id: 'cat_' + tree[i].id, title: tree[i].title, options: tree[i].children });
    }
    return { groups: groups };
  },

  async list(argument) {
    var arg = argument || {};
    var page = Number(arg.page || 1) || 1;
    if (page < 1) page = 1;
    var keyword = arg.keyword ? String(arg.keyword).trim() : '';
    if (keyword) return fetchList(page, PAGE_LIMIT, { keyword: keyword });

    var categoryId = arg.categoryId ? String(arg.categoryId) : 'feed_latest';
    var picks = arg.filters && arg.filters.category ? String(arg.filters.category).split(',') : [];
    if (picks.length) categoryId = 'cat_' + picks[0];

    if (categoryId === 'feed_hot' || categoryId === 'feed_latest') return fetchList(page, PAGE_LIMIT, {});
    if (categoryId === 'topic_video') return fetchTopicPage(page);

    if (categoryId.indexOf('cat_') === 0) {
      var childId = categoryId.slice(4);
      var tree = await loadTree();
      var parent = null;
      for (var i = 0; i < tree.length; i++) {
        for (var c = 0; c < tree[i].children.length; c++) {
          if (tree[i].children[c].id === childId) parent = { groupId: tree[i].id, childId: childId };
        }
      }
      if (!parent) throw new Error('海角：本源不提供该分类（未接入未成年相关品类，或站点已下架该分类）');
      return fetchList(page, PAGE_LIMIT, { top_category_id: parent.groupId, category_id: parent.childId });
    }

    if (categoryId.indexOf('group_') === 0) {
      return fetchList(page, PAGE_LIMIT, { top_category_id: categoryId.slice(6) });
    }
    return fetchList(page, PAGE_LIMIT, {});
  },

  async detail(argument) {
    var raw = String((argument && argument.id) || '');
    if (/^t\d+$/i.test(raw)) return topicDetail(raw.slice(1));
    var id = raw.replace(/[^\d]/g, '');
    if (!id) return null;
    var row = await detailRow(id);
    if (!row) return null;
    var title = String(row.title || '').trim();
    if (!title) return null;
    var lines = [];
    if (row.category && row.category.name) lines.push('分类：' + row.category.name);
    if (row.author && row.author.nickname) lines.push('作者：' + row.author.nickname);
    if (row.duration_seconds) lines.push('时长：' + clock(row.duration_seconds));
    if (row.published_at) lines.push('发布：' + String(row.published_at).replace('T', ' ').slice(0, 16));
    if (Array.isArray(row.tags) && row.tags.length) {
      var names = [];
      for (var t = 0; t < row.tags.length; t++) {
        var tag = row.tags[t];
        if (tag && tag.name && !BANNED.test(String(tag.name))) names.push(String(tag.name));
      }
      if (names.length) lines.push('标签：' + names.join(' / '));
    }
    lines.push(
      row.access_type === 1
        ? '观看权限：站点标为免费（但仍需登录才下发地址）'
        : '观看权限：需观影券 / VIP（匿名与免费账号都拿不到地址）'
    );
    if (row.description) lines.push(String(row.description).slice(0, 300));
    if (!row.can_play) lines.push(gateMessage());
    var bits = [];
    if (row.duration_seconds) bits.push(clock(row.duration_seconds));
    if (row.view_count) bits.push(row.view_count + ' 播放');
    if (row.category && row.category.name) bits.push(String(row.category.name));
    return {
      id: id,
      title: title,
      cover: coverOf(row.cover_url),
      subtitle: bits.join(' · '),
      description: lines.join('\n')
    };
  },

  /// 「章节」= 播放线路（普通1 / 普通2 / VIP线路）。线路名匿名可见，地址要登录。
  async chapters(argument) {
    var raw = String((argument && argument.id) || '');
    if (/^t\d+$/i.test(raw)) return [{ id: '0', title: '正片' }];
    var id = raw.replace(/[^\d]/g, '');
    if (!id) return [];
    var row = await detailRow(id);
    if (!row || !row.attachment_id) return [];
    var lines = await fetchLines(row.attachment_id, id);
    if (!lines.length) return [{ id: '0', title: '播放' }];
    var rows = [];
    for (var i = 0; i < lines.length; i++) {
      rows.push({ id: String(i), title: lines[i].name + (lines[i].vip ? '（VIP）' : '') });
    }
    return rows;
  },

  async content(argument) {
    var arg = argument || {};
    var raw = String(arg.id || '');
    if (!raw) throw new Error('海角：缺少 id');

    // 帖子（t<topicId>）：登录就能拿到 m3u8，不需要买券
    if (/^t\d+$/i.test(raw)) {
      var topicId = raw.slice(1);
      var trow = await topicRow(topicId);
      if (!trow) throw new Error('海角：取不到帖子（' + topicId + '）');
      var att = topicVideoAttachment(trow);
      var topicPage = base() + '/post/details?pid=' + topicId;
      var topicUrl = att ? await fetchAttachmentUrl(att.id, topicId, 'topic') : '';
      if (topicUrl) {
        return {
          kind: 'video',
          url: topicUrl,
          headers: { Referer: topicPage, 'User-Agent': UA, Origin: base() }
        };
      }
      return {
        kind: 'webplayer',
        pageUrl: topicPage,
        headers: { Referer: base() + '/home', 'User-Agent': UA, Origin: base() },
        webPlayerOptions: {}
      };
    }

    var id = raw.replace(/[^\d]/g, '');
    if (!id) throw new Error('海角：缺少视频 id');
    var row = await detailRow(id);
    if (!row) throw new Error('海角：取不到视频详情（id ' + id + '）');
    if (!row.attachment_id) throw new Error('海角：这条没有视频附件（可能是图文帖）');

    // 第一优先：POST /api/attachment（真地址入口；video_center 要已购买/有权限）
    var direct = await fetchAttachmentUrl(row.attachment_id, id, 'video_center');
    if (direct) {
      var watchPage0 = base() + '/watch?id=' + id;
      return {
        kind: 'video',
        url: direct,
        headers: { Referer: watchPage0, 'User-Agent': UA, Origin: base() }
      };
    }

    // 第二优先：老的分线路表（有些片子从这里能拿到）
    var lines = await fetchLines(row.attachment_id, id);
    var played = playableLines(lines);
    if (!played.length) {
      var auth = await currentAuth();
      if (!auth) auth = await signIn();
      if (auth) {
        lines = await fetchLines(row.attachment_id, id);
        played = playableLines(lines);
      }
    }

    if (!played.length) {
      // 没权限（服务端明确回「当前用户无权播放该视频」）：不给假地址，转交网页视图
      return {
        kind: 'webplayer',
        pageUrl: base() + '/watch?id=' + id,
        headers: { Referer: base() + '/home', 'User-Agent': UA, Origin: base() },
        webPlayerOptions: {}
      };
    }

    var wants = String(arg.chapterId || '').trim();
    var picked = played[0];
    if (/^\d+$/.test(wants)) {
      var index = Number(wants);
      if (lines[index] && /^https?:\/\//i.test(lines[index].url)) {
        picked = { label: lines[index].name, url: lines[index].url };
      }
    }
    var watchPage = base() + '/video/watch?videoid=' + id;
    return {
      kind: 'video',
      url: picked.url,
      headers: { Referer: watchPage, 'User-Agent': UA, Origin: base() },
      qualities: played.length > 1 ? played : undefined
    };
  }
};
