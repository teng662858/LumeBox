// LumeSource: {"id":"lao4j_video","name":"火力视频","version":"2.0.1","category":"video","contentCategory":"adult","mirrors":["http://web.lao4j.net"],"network":"direct","icon":"http://web.lao4j.net/img/favicon.ico","settings":[{"key":"account","type":"text","title":"账号（手机号，用于原生播放）","description":"站点的播放页要「登录 + 会员」两层。填自己的手机号与密码，本源会在本地登录拿 auth_code，再带上去取播放地址；账号不是会员时会给明确提示。留空则播放交给内嵌网页，在网页里自己登录。"},{"key":"password","type":"text","title":"密码","description":"与账号配套；只在本机登录时使用，不写日志。"},{"key":"cookie","type":"text","title":"登录 Cookie（可选，优先级最高）","description":"想跳过登录直接复用浏览器会话，就把 web.lao4j.net 的 auth_code=… 整段粘进来。"},{"key":"note","type":"info","title":"站点说明","description":"火力视频 / 舞艺吧（web.lao4j.net，ThinkPHP + 独立 API 主机）：擦边舞蹈、录屏、写真向短视频。列表与搜索由 81.70.213.11 / 107.148.42.248:83 上的 JSON 接口提供，匿名可取；但**播放页要求登录**（ajax.php?c=web&m=play 匿名一律返回「请登录后再操作！」，注册要手机号+短信验证码）。本源把播放交给 App 内嵌网页：在网页里用你自己的账号登录一次，之后点条目即可播放。封面直连 yimg3.huolient.com（YouTube 缩略图镜像），视频本体不在图片 CDN 上。"}]}
// LumeRuntime: javascript
//
// 站点：火力视频（http://web.lao4j.net）—— 舞艺吧系的舞蹈/擦边视频站。
// 后端是两台独立 API 主机（ThinkPHP），页面 ajax.php 只是壳，数据全走 JSON 接口：
//   最新播放  POST http://81.70.213.11/you_new_play/getList      {limit, page}            page 有效
//   频道列表  POST http://107.148.42.248:83/you_channel/getList {channel_id, continuation…}  用 params 链翻页
//   搜索      POST http://107.148.42.248:83/you_search/getList   {words}                  首屏 20 条，翻页要 token
//   播放页    GET  http://web.lao4j.net/ajax.php?c=web&m=play&video_id=<id>
//
// 关键结论（2026-11-02 实测）：
//   · 列表/封面/搜索全部匿名可用；标题是 HTML 实体（&#84;&#75;…），要解码；
//   · **播放必须登录**：抽 6 条覆盖不同频道，m=play 一律返回「请登录后再操作！」（1646 B 提示页，无任何媒体地址）；
//     注册页 reg.php 要 手机号 + 密码 + 短信验证码，登录页 login.php 只要 手机号 + 密码 —— 本源不代注册、不存账号，
//     播放页交给 App 内嵌网页，用户在网页里登录一次（webview 自己保 cookie）；
//   · 视频本体不在图片 CDN：/vi/<id>/video.mp4、play.m3u8、hls/index.m3u8 全 404/502，只有 maxresdefault.jpg 这类缩略图 200；
//   · video_id 是 11 位 YouTube ID、channel_id 是 UC 开头的 YouTube 频道 ID，站方把 YT 舞蹈视频镜像过来。
//
// 因此本源：list / detail / chapters / search 全部原生可用，content() 返回 webplayer（play 页）。
// 失效预案：API 主机换了就从 ajax.php 的页面 JS 里重新读接口主机；频道分页参数（continuation/itct/page_cl/checksum）变了要同步改。

var SITE = 'http://web.lao4j.net';
var API_PLAY = 'http://81.70.213.11';
var API_SEARCH = 'http://107.148.42.248:83';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 20;

var CATEGORIES = [
  { id: 'latest', title: '最新播放' },
  { id: 't2', title: '每日更新' }
];

var INDEX_CACHE = null;
var CHANNEL_STATE = { channel: '', pages: [], at: 0 };

function site() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var host = (domain || SITE).replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(host)) host = 'http://' + host;
  return host;
}

function headers() {
  return {
    'User-Agent': UA,
    'Accept': 'application/json, text/plain, */*',
    'Referer': site() + '/'
  };
}

async function postJson(url, body) {
  var reply = await LumeSource.http.post(url, body, {
    headers: Object.assign(headers(), { 'Content-Type': 'application/x-www-form-urlencoded' })
  });
  var status = reply ? reply.status : 0;
  if (status !== 200) throw new Error('接口打不开：HTTP ' + status + ' ' + url);
  var text = reply.body ? String(reply.body) : '';
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error('接口返回不是 JSON（可能换了域名）');
  }
}

async function getText(path) {
  var reply = await LumeSource.http.get(site() + path, { headers: headers() });
  var status = reply ? reply.status : 0;
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

function entity(text) {
  return String(text == null ? '' : text)
    .replace(/&#x([0-9a-f]+);/gi, function (_, hex) { return String.fromCharCode(parseInt(hex, 16)); })
    .replace(/&#(\d+);/g, function (_, dec) { return String.fromCharCode(Number(dec)); })
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function remember(row) {
  if (!INDEX_CACHE) INDEX_CACHE = {};
  INDEX_CACHE[row.id] = row;
}

function rowOfVideo(item) {
  var id = String(item.video_id || item.id || '');
  if (!id) return null;
  var row = {
    id: id,
    title: entity(item.title) || id,
    cover: String(item.pic || ''),
    channel: entity(item.channel_name),
    length: String(item.length || ''),
    time: entity(item.time || item.publish || '')
  };
  remember(row);
  return row;
}

function rowOfChannelVideo(item) {
  var id = String(item.id || item.video_id || '');
  if (!id) return null;
  var row = {
    id: id,
    title: entity(item.title) || id,
    cover: String(item.pic || ''),
    channel: entity(item.channel_name),
    length: String(item.length || ''),
    time: entity(item.publish || item.time || '')
  };
  remember(row);
  return row;
}

function toItem(row) {
  var bits = [];
  if (row.length) bits.push(row.length);
  if (row.channel) bits.push(row.channel);
  if (row.time) bits.push(row.time);
  return { id: row.id, title: row.title, cover: row.cover, subtitle: bits.join(' · ') };
}

/* ───────────── 频道分页（continuation 链） ───────────── */

function channelBody(channelId, params) {
  var p = params || {};
  var pairs = ['channel_id=' + encodeURIComponent(channelId)];
  ['continuation', 'itct', 'page_cl', 'checksum'].forEach(function (key) {
    if (p[key] !== undefined && p[key] !== null && p[key] !== '') pairs.push(key + '=' + encodeURIComponent(p[key]));
  });
  return pairs.join('&');
}

async function channelPage(channelId, page) {
  if (CHANNEL_STATE.channel !== channelId || Date.now() - CHANNEL_STATE.at > 5 * 60 * 1000) {
    CHANNEL_STATE = { channel: channelId, pages: [], at: Date.now() };
  }
  while (CHANNEL_STATE.pages.length < page) {
    var prev = CHANNEL_STATE.pages.length ? CHANNEL_STATE.pages[CHANNEL_STATE.pages.length - 1] : null;
    var body = channelBody(channelId, prev ? prev.params : null);
    var json = await postJson(API_SEARCH + '/you_channel/getList', body);
    if (Number(json.code) !== 0) throw new Error('频道接口返回 ' + json.code + '：' + (json.msg || ''));
    var payload = json.data || {};
    var list = payload.video_list || [];
    CHANNEL_STATE.pages.push({ params: payload.params || {}, list: list, isEnd: String(payload.is_end || '1') === '1' });
    if (!list.length) break;
  }
  var index = Math.max(0, page - 1);
  var entry = CHANNEL_STATE.pages[index] || { list: [], isEnd: true };
  return entry;
}


/* 从播放页里抠媒体地址：video/source 标签、m3u8/mp4 明文、常见播放器配置字段 */
function pickMedia(html) {
  var text = String(html || '');
  var patterns = [
    /<source[^>]+src=["']([^"']+\.(?:m3u8|mp4)[^"']*)["']/i,
    /<video[^>]+src=["']([^"']+\.(?:m3u8|mp4)[^"']*)["']/i,
    /["'](?:url|video_url|playUrl|play_url|m3u8|mp4|src)["']\s*[:=]\s*["']([^"']+\.(?:m3u8|mp4)[^"']*)["']/i,
    /(https?:\/\/[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*)/i,
    /(https?:\/\/[^"'\s<>\\]+\.mp4[^"'\s<>\\]*)/i,
    /(\/\/[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*)/i
  ];
  for (var i = 0; i < patterns.length; i++) {
    var matched = patterns[i].exec(text);
    if (!matched) continue;
    var url = String(matched[1] || '').replace(/\\\//g, '/').trim();
    if (!url) continue;
    if (url.indexOf('//') === 0) url = 'http:' + url;
    if (!/^https?:\/\//i.test(url)) continue;
    return url;
  }
  return '';
}


/* ───────────── 登录态 ───────────── */

var SESSION_KEY = 'lao4j.session';
var SESSION_TTL_MS = 6 * 3600 * 1000;

function configValue(key) {
  try {
    return String((LumeSource.config && LumeSource.config[key]) || '').trim();
  } catch (error) {
    return '';
  }
}

async function readSession() {
  try {
    var raw = await LumeSource.fs.readText(SESSION_KEY + '.json');
    if (!raw) return null;
    var parsed = JSON.parse(String(raw));
    if (!parsed || !parsed.auth || Date.now() - Number(parsed.at || 0) > SESSION_TTL_MS) return null;
    return parsed;
  } catch (error) {
    return null;
  }
}

async function writeSession(auth) {
  try {
    await LumeSource.fs.writeText(SESSION_KEY + '.json', JSON.stringify({ auth: auth, at: Date.now() }));
  } catch (error) {
    /* 缓存失败不影响本次调用 */
  }
}

async function clearSession() {
  try {
    await LumeSource.fs.writeText(SESSION_KEY + '.json', '');
  } catch (error) {
    /* 忽略 */
  }
}

/* 返回可直接放进 Cookie 头的字符串；没有登录条件时返回 '' */
async function sessionCookie() {
  var manual = configValue('cookie');
  if (manual) {
    return manual.indexOf('auth_code=') >= 0 ? manual : 'auth_code=' + encodeURIComponent(manual);
  }
  var account = configValue('account');
  var password = configValue('password');
  if (!account || !password) return '';
  var cached = await readSession();
  if (cached && cached.auth) return 'auth_code=' + encodeURIComponent(cached.auth);
  var json = await postJson(site() + '/ajax.php?c=web&m=doLogin', 'mobile=' + encodeURIComponent(account) + '&password=' + encodeURIComponent(password));
  var code = json && json.code === undefined ? 200 : Number(json && json.code);
  if (code !== 0 || !json.data || !json.data.auth_code) {
    throw new Error('账号登录失败：' + (String((json && json.msg) || '账号或密码不对')));
  }
  await writeSession(String(json.data.auth_code));
  return 'auth_code=' + encodeURIComponent(String(json.data.auth_code));
}

/* ───────────── 源对象 ───────────── */

var LumeSource = {
  id: 'lao4j_video',
  name: '火力视频',
  version: '2.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['http://web.lao4j.net'],

  async categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    return list;
  },

  async home() {
    var boards = [];
    try {
      var latest = await this.list({ page: 1, categoryId: 'latest' });
      if (latest.items.length) boards.push({ title: '最新播放', moreUrl: 'latest', items: latest.items.slice(0, 12) });
    } catch (error) { /* 单个板块失败不影响其它 */ }
    try {
      var daily = await this.list({ page: 1, categoryId: 't2' });
      if (daily.items.length) boards.push({ title: '每日更新', moreUrl: 't2', items: daily.items.slice(0, 12) });
    } catch (error) { /* 同上 */ }
    if (!boards.length) throw new Error('首页板块都没取到：接口主机可能换了，或站点需要网页验证');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var searchJson = await postJson(API_SEARCH + '/you_search/getList', 'words=' + encodeURIComponent(keyword));
      if (Number(searchJson.code) !== 0) throw new Error('搜索接口返回 ' + searchJson.code + '：' + (searchJson.msg || ''));
      var searchList = (searchJson.data && searchJson.data.video_list) || [];
      var hits = [];
      for (var s = 0; s < searchList.length; s++) {
        var sr = rowOfChannelVideo(searchList[s]);
        if (sr) hits.push(toItem(sr));
      }
      // 搜索翻页要 YouTube 的 continuation token，这里只给首屏
      return { items: hits, hasMore: false };
    }

    if (!categoryId) categoryId = 'latest';
    if (categoryId === 'latest') {
      var json = await postJson(API_PLAY + '/you_new_play/getList', 'limit=' + PAGE_SIZE + '&page=' + page);
      if (Number(json.code) !== 0) throw new Error('列表接口返回 ' + json.code + '：' + (json.msg || ''));
      var list = (json.data && json.data.list) || [];
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var row = rowOfVideo(list[i]);
        if (row) items.push(toItem(row));
      }
      return { items: items, hasMore: items.length >= PAGE_SIZE };
    }

    var entry = await channelPage(categoryId, page);
    var rows = [];
    for (var j = 0; j < entry.list.length; j++) {
      var cr = rowOfChannelVideo(entry.list[j]);
      if (cr) rows.push(toItem(cr));
    }
    return { items: rows, hasMore: rows.length > 0 && !entry.isEnd };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return null;
    var row = INDEX_CACHE ? INDEX_CACHE[id] : null;
    if (!row) {
      // 没有缓存（比如从历史记录直接进详情）：用播放页标题兜底
      var html = '';
      try { html = await getText('/ajax.php?c=web&m=play&video_id=' + encodeURIComponent(id)); } catch (error) { html = ''; }
      var titleMatch = /<title>([^<]{0,160})/.exec(html);
      var title = titleMatch ? entity(titleMatch[1]).replace(/^提示-/, '').replace(/-?火力视频$/, '').trim() : '';
      if (!title || /提示/.test(title)) title = id;
      row = { id: id, title: title, cover: '', channel: '', length: '', time: '' };
    }
    var bits = [];
    if (row.length) bits.push(row.length);
    if (row.channel) bits.push(row.channel);
    if (row.time) bits.push(row.time);
    return {
      id: row.id,
      title: row.title,
      cover: row.cover,
      subtitle: bits.join(' · '),
      tags: row.channel ? [row.channel] : [],
      description:
        '火力视频（' + site() + '）\n' +
        (row.channel ? '频道：' + row.channel + '\n' : '') +
        '播放需要登录：站点的播放页对匿名请求一律返回「请登录后再操作！」，注册要手机号+短信验证码。\n' +
        '点播放会打开站点的播放页，在网页里用你自己的账号登录一次即可（App 会保留该网页的登录态）。'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    return [{ id: id, title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var id = String(args.id || args.chapterId || '').trim();
    if (!id) throw new Error('缺少视频 ID');
    var pageUrl = site() + '/ajax.php?c=web&m=play&video_id=' + encodeURIComponent(id);
    var cookie = await sessionCookie();
    if (!cookie) {
      // 没有登录态：交给内嵌网页，用户自己在网页里登录
      return { kind: 'webplayer', pageUrl: pageUrl, headers: headers() };
    }
    var reply = await LumeSource.http.get(pageUrl, {
      headers: Object.assign(headers(), { Cookie: cookie })
    });
    var html = reply && reply.body ? String(reply.body) : '';
    if (/请登录后再操作/.test(html)) {
      await clearSession();
      throw new Error('登录态失效（账号密码或 Cookie 已过期），请到源设置里重新填写');
    }
    if (/请开通会员/.test(html)) {
      throw new Error('该账号已登录，但没有开通会员：站点播放页对非会员一律提示「请开通会员」（会员 29 元/1 个月起）。开通后本源可直接原生播放，不用改设置。');
    }
    var media = pickMedia(html);
    if (media) {
      return { kind: 'video', url: media, headers: { 'User-Agent': UA, Referer: site() + '/' } };
    }
    // 页面既没报权限也没抠到地址：结构可能变了，退回网页
    return { kind: 'webplayer', pageUrl: pageUrl, headers: headers() };
  }

};
