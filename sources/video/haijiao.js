// LumeSource: {"id":"haijiao_video","name":"海角 18+","version":"1.1.0","category":"video","contentCategory":"adult","mirrors":["https://www.haijiao.com","https://haijiao.com"],"network":"direct","icon":"https://www.haijiao.com/imgs/project/favicon.ico"}
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
// ── 播放地址：**匿名拿不到，服务端硬门禁**（本源最大的已知限制，如实记账）
//   实测证据（2026-10-25，代理下多轮复现）：
//     · GET /api/topic/att/{att} 匿名 → 200，返回 3 条线路（普通1 / 普通2 / VIP线路），
//       但 **url 字段全是空字符串**；
//     · POST /api/attachment {id, resource_id, resource_type:'video_center', line} 匿名 →
//       {"errorCode":1}（拦截器里 1 = ErrorNotLogin）；
//     · 站点标成免费（access_type=1）的片子也一样：detail 里 can_play=false、is_unlocked=false，url 仍为空；
//     · 拿猜出来的直链撞 CDN（…/<hash>/49.m3u8、index.m3u8、加 .txt 后缀…）全部 404；
//     · 页面是纯 SPA，没有 SSR / og:video 可蹭（/homepage/video/{id} 回的还是同一个空壳）。
//   结论：**海角的播放地址不是「登录就有」，登录之后还要「解锁」**。
//   2026-10-25 用真实登录态（浏览器登录后导出的 token + uid=17761204）实测：
//     · GET /api/topic/att/{attachment_id}  带着 X-User-Token / X-User-Id / Cookie → 200，
//       但 3 条线路（普通1 / 普通2 / VIP线路）的 `url` **仍然全为空**（逐层 base64 解出来确认过）；
//     · 详情行里带 `is_unlocked` / `can_play` 两个字段 —— 说明还差一步 `POST /api/attachment`
//       的解锁动作（观影券 / VIP / 花积分），那是站点账务，本源不去绕、不代刷。
//   所以本源：
//     1) 元数据（分类 / 列表 / 搜索 / 详情 / 封面 / 线路名）匿名全部可用；
//     2) content 拿不到地址时**改走网页播放**（kind:'webplayer' → /watch?id=<id>，登录/解锁后
//        在 App 的网页视图里直接看），不再是一句干巴巴的报错；
//     3) 支持登录：账号密码填「源设置 → 账号登入」，或把浏览器 Cookie（含 token=、uid=）
//        粘到「网络配置」，本源用 /api/login/signin 换 token 并带 X-User-Token / X-User-Id 重取地址。
//        ——登录只解决「身份」，片子本身还要「解锁」，那一步本源不做。
//        注：Cookie 里可能同时存在别的域的同名 uid（例如广告域 ad.* 的 16 位十六进制 uid），
//        本源优先取**纯数字**的那个（海角的 uid 是数字），避免把广告 uid 当账号 id 发出去。
//     4) 站点 HLS 的 EXT-X-KEY 密钥在播放器里还要过一层 wasm（同名 .jpg 参与计算，
//        play 页 `jquery_key`），**这点没能验证**（拿不到一条真实地址）；如果哪天解锁后拿到地址却
//        解不出画面，大概率是这个原因，不是解析错了。
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

/// 播放门禁的说明（详情页里给用户看；播放时改用网页视图，不再抛错）
function gateMessage() {
  return (
    '获取地址：匿名请求 /api/topic/att/{id} 只回线路名、url 为空（实测 2026-11-01 复现），' +
    '连标称免费的片也是 can_play=false；本源在这一步改走网页播放（/watch?id=…），' +
    '登录/观影券解锁后在网页视图里直接看。想走原生地址：到「源设置 → 账号登入」填账号密码，' +
    '或把浏览器 Cookie（含 token=、uid=）粘进「网络配置」。'
  );
}

var LumeSource = {
  id: 'haijiao_video',
  name: '海角',
  version: '1.1.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://www.haijiao.com', 'https://haijiao.com'],

  async categories() {
    var tree = await loadTree();
    var rows = [
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
    var id = String((argument && argument.id) || '').replace(/[^\d]/g, '');
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
    var id = String((argument && argument.id) || '').replace(/[^\d]/g, '');
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
    var id = String(arg.id || '').replace(/[^\d]/g, '');
    if (!id) throw new Error('海角：缺少视频 id');
    var row = await detailRow(id);
    if (!row) throw new Error('海角：取不到视频详情（id ' + id + '）');
    if (!row.attachment_id) throw new Error('海角：这条没有视频附件（可能是图文帖）');

    var lines = await fetchLines(row.attachment_id, id);
    var played = playableLines(lines);

    // 匿名拿不到地址时，如果配了账号/Cookie，就用登录态再试一次
    if (!played.length) {
      var auth = await currentAuth();
      if (!auth) auth = await signIn();
      if (auth) {
        lines = await fetchLines(row.attachment_id, id);
        played = playableLines(lines);
      }
    }

    if (!played.length) {
      // 匿名 / 未解锁：不给假地址，也不只报错 —— 转交 App 的网页视图，
      // 用户在站内登录（或买券）后自己点播放，播放器/HLS 密钥全由站点自己处理。
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
