// LumeSource: {"id":"kpdz_video","name":"看片视频","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://sm-api.wieuc.com"],"network":"direct","icon":"https://hm-static.wieuc.com/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：看片视频（KPDZ.APP；落地页 kpdz.app 两层跳板 → hgfgn.432703.lifestyle:8283）
// 来源：从「暮色」App（com.look.mbox）的内置站 kpsp 挖出来的站与协议。
//
// 一、跳板链（换域时按这个顺序找）
//   https://kpdz.app → (base64 跳转) → https://poioiygcff.761745.coupons:8283 →
//   (decode 跳转) → https://hgfgn.432703.lifestyle:8283/home?channel=Onerun5-032-43
//   真正的内容接口在独立的 API 域：**https://sm-api.wieuc.com**，媒体 CDN 在 **https://hm-img.hdstfb.com**。
//
// 二、响应加密：标准 Fernet（Python），前端用 crypto-js 实现
//   响应体是 {"x-data":"gAAAAA…"}：
//     1. base64url 解码 → [version(0x80)][timestamp(8)][iv(16)][ciphertext][hmac(32)]
//     2. key = "NyGRG56A8i5J2JMqh7da83r2MMfgbM7Ppw1aCF8YnAY="（32 字节）
//        signingKey = key[0:16]，encryptionKey = key[16:32]
//     3. HMAC-SHA256(signingKey, token[:-32]) 应等于 token[-32:]（本源跳过校验，直接解）
//     4. AES-128-CBC 解 ciphertext（iv 取上面的 iv，PKCS7）
//   key 是从前端 chunk main~31743c5a.890db582.js 里翻出来的（crypto-js 的 AES + pako 都在 vendor 里）。
//
// 三、接口（都在 sm-api.wieuc.com，全部 GET，带 site_id=4）
//   /api/vod/tag_group?page=1&per_page=1000&site_id=4   分类组（63 组，含组内标签）
//   /api/vod/tag?page=1&per_page=1000&site_id=4         标签（6000+ 个）
//   /api/vod/video?count=&page=&per_page=&tag=&site_id=4  列表（tag 可用逗号多选）
//   /api/vod/video/<id>                                 详情
//   列表项字段：id/name/pic/play_url(m3u8)/preview_play_url/is_paid/price/duration/tag[]
//
// 四、播放
//   play_url 是站内相对路径（/videos3/202611/02/xxx/index.m3u8），拼 CDN 前缀即得：
//   https://hm-img.hdstfb.com + play_url → 实测 200 + application/vnd.apple.mpegurl（85 KB）
//   封面：https://hm-img.hdstfb.com + pic → 200（Content-Type 是 application/x-image）
//   is_paid=0/price=0 的片直接可播；VIP 片接口照样下发 play_url（实测未拦）。
//
// 五、限制
//   · 分类组有 63 个，本源把「全部/搜索」以外的常用组做成分类，组内标签做成 filters；
//   · 组与标签是多对多，本源用「组内第一个标签」当该分类的入口（足以筛出内容）；
//   · 排序：接口没有明显的 sort 参数（试过 sort/order 都被忽略），按站点默认（发布时间）。

var API = 'https://sm-api.wieuc.com';
var CDN = 'https://hm-img.hdstfb.com';
var REF = 'https://hgfgn.432703.lifestyle:8283/';
var FERNET_KEY = 'NyGRG56A8i5J2JMqh7da83r2MMfgbM7Ppw1aCF8YnAY=';
var UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
var PAGE_SIZE = 24;
var SITE_ID = 4;
var CAT_TTL = 6 * 3600 * 1000;

function apiBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? String(LumeSource.config.domain) : '';
  var text = String(domain || API).replace(/\/+$/, '');
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
  return CDN + (raw.charAt(0) === '/' ? '' : '/') + raw;
}

// ---- base64url / 字节工具（沙箱没有 Buffer） ----
var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function b64ToBytes(text) {
  var s = String(text || '').replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i);
    if (ch === '=') break;
    var v = B64.indexOf(ch);
    if (v < 0) continue;
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function bytesToB64(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i];
    var b1 = bytes[i + 1];
    var b2 = bytes[i + 2];
    out += B64.charAt(b0 >> 2);
    out += B64.charAt(((b0 & 3) << 4) | (b1 === undefined ? 0 : b1 >> 4));
    out += b1 === undefined ? '=' : B64.charAt(((b1 & 15) << 2) | (b2 === undefined ? 0 : b2 >> 2));
    out += b2 === undefined ? '=' : B64.charAt(b2 & 63);
  }
  return out;
}

function latin1(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 0xff);
  return out;
}

function utf8Bytes(text) {
  var s = String(text == null ? '' : text);
  var out = [];
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c >= 0xd800 && c <= 0xdbff) {
      var low = s.charCodeAt(++i);
      var cp = 0x10000 + (((c & 0x3ff) << 10) | (low & 0x3ff));
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var c = bytes[i++];
    if (c < 0x80) out += String.fromCharCode(c);
    else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f));
    else if (c < 0xf0) out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    else {
      var cp = (((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f)) - 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

async function fernetDecrypt(token) {
  var raw = b64ToBytes(token);
  if (raw.length < 57 || raw[0] !== 0x80) throw new Error('不是 Fernet 密文');
  var key = b64ToBytes(FERNET_KEY);
  var iv = raw.slice(9, 25);
  var ciphertext = raw.slice(25, raw.length - 32);
  var plainB64 = await LumeSource.tools.aes({
    key: btoa(latin1(key.slice(16, 32))),
    iv: btoa(latin1(iv)),
    data: btoa(latin1(ciphertext)),
    mode: 'CBC',
    encrypt: false,
  });
  return utf8Decode(b64ToBytes(plainB64));
}

async function api(path) {
  var root = apiBase();
  var reply = await LumeSource.http.get(root + path, {
    headers: {
      'User-Agent': UA,
      Accept: 'application/json, text/plain, */*',
      Referer: REF,
      Origin: REF.replace(/\/+$/, ''),
    },
  });
  if (!reply || reply.status !== 200) {
    throw new Error('接口打不开：HTTP ' + (reply ? reply.status : 0) + '（' + path + '）');
  }
  var text = String(reply.body || '');
  var wallet;
  try {
    wallet = JSON.parse(text);
  } catch (error) {
    throw new Error('接口返回不是 JSON：' + path);
  }
  if (wallet && wallet['x-data']) {
    var plain = await fernetDecrypt(String(wallet['x-data']));
    try {
      return JSON.parse(plain);
    } catch (error) {
      throw new Error('Fernet 解不开（换 key 了？）：' + path);
    }
  }
  return wallet;
}

function rowOf(v) {
  if (!v) return null;
  var id = String(v.id == null ? '' : v.id);
  var title = clean(v.name || v.title);
  if (!id || !title) return null;
  var bits = [];
  if (Number(v.is_paid) > 0 || Number(v.price) > 0) bits.push('VIP');
  if (v.hits) bits.push('播放 ' + v.hits);
  var tags = (v.tag || []).map(function (t) { return clean(t.name); }).filter(Boolean);
  if (tags.length) bits.push(tags.slice(0, 2).join(' '));
  return { id: id, title: title, cover: media(v.pic), subtitle: bits.join(' · ') };
}

// ---- 分类（从 tag_group 动态取，缓存 6 小时） ----
var CATS = null;

async function loadCategories() {
  if (CATS) return CATS;
  var cacheKey = 'kpdz.cats';
  try {
    var saved = await LumeSource.storage.get(cacheKey);
    if (saved) {
      var parsed = JSON.parse(String(saved));
      if (parsed && parsed.at && Date.now() - parsed.at < CAT_TTL && parsed.list && parsed.list.length) {
        CATS = parsed.list;
        return CATS;
      }
    }
  } catch (error) {
    /* 缓存读失败就现算 */
  }
  var data = await api('/api/vod/tag_group?page=1&per_page=1000&site_id=' + SITE_ID);
  var groups = (data && data.data && data.data.items) || [];
  var out = [{ id: 'all', title: '全部', tag: '' }];
  var seen = {};
  for (var i = 0; i < groups.length; i++) {
    var g = groups[i];
    var name = clean(g.name);
    if (!name || name === '全部' || name === '搜索') continue;
    var tags = g.tag || [];
    var tagId = tags.length && tags[0].id != null ? String(tags[0].id) : '';
    // 没有标签的组点进去会是空的，直接不收（「全部」已经单独排第一）
    if (!tagId) continue;
    var key = 'g' + g.id;
    if (seen[key]) continue;
    seen[key] = true;
    out.push({ id: key, title: name, tag: tagId });
    if (out.length >= 40) break;
  }
  out[0].tag = '';
  CATS = out;
  try {
    await LumeSource.storage.set(cacheKey, JSON.stringify({ at: Date.now(), list: out }));
  } catch (error) {
    /* 忽略缓存写失败 */
  }
  return out;
}

function categoryOf(id) {
  var key = String(id == null || id === '' ? 'all' : id);
  if (!CATS) return { id: 'all', title: '全部', tag: '' };
  for (var i = 0; i < CATS.length; i++) if (CATS[i].id === key) return CATS[i];
  return CATS[0];
}

var RECENT = {};
function remember(rows) {
  for (var i = 0; i < rows.length; i++) RECENT[rows[i].id] = rows[i];
}

// ---------------- 入口 ----------------
var LumeSource = {
  id: 'kpdz_video',
  name: '看片视频',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://sm-api.wieuc.com'],

  async categories() {
    var list = await loadCategories();
    return list.map(function (c) { return { id: c.id, title: c.title }; });
  },

  async home() {
    var list = await loadCategories();
    var boards = [];
    var plans = list.slice(0, 4);
    if (!plans.length) plans = [{ id: 'all', title: '全部', tag: '' }];
    for (var i = 0; i < plans.length; i++) {
      var cat = plans[i];
      try {
        var q = '/api/vod/video?count=false&page=1&per_page=12&site_id=' + SITE_ID + (cat.tag ? '&tag=' + encodeURIComponent(cat.tag) : '');
        var data = await api(q);
        var items = (data && data.data && data.data.items) || [];
        var rows = [];
        for (var k = 0; k < items.length; k++) {
          var row = rowOf(items[k]);
          if (row) rows.push(row);
        }
        if (rows.length) {
          remember(rows);
          boards.push({ title: cat.title, moreUrl: cat.id, items: rows.slice(0, 12) });
        }
      } catch (error) {
        if (i === 0) throw error;
      }
    }
    if (!boards.length) throw new Error('首页板块都没取到：接口或 Fernet key 可能变了');
    return boards;
  },

  async list(args) {
    var a = args || {};
    var page = Math.max(1, Number(a.page) || 1);
    var keyword = clean(a.keyword);
    var filters = a.filters || {};
    var tag = '';
    if (keyword) {
      tag = keyword;
    } else if (filters.tag) {
      tag = String(filters.tag);
    } else {
      if (!CATS) await loadCategories();
      tag = categoryOf(a.categoryId).tag || '';
    }
    var q = '/api/vod/video?count=true&page=' + page + '&per_page=' + PAGE_SIZE + '&site_id=' + SITE_ID +
      (tag ? '&tag=' + encodeURIComponent(tag) : '');
    var data = await api(q);
    var box = (data && data.data) || {};
    var items = box.items || box.list || [];
    var rows = [];
    for (var i = 0; i < items.length; i++) {
      var row = rowOf(items[i]);
      if (row) rows.push(row);
    }
    remember(rows);
    var total = Number(box.total || box.count || 0);
    var hasMore = total ? page * PAGE_SIZE < total : rows.length >= PAGE_SIZE;
    return { items: rows, hasMore: hasMore };
  },

  async filters() {
    try {
      var data = await api('/api/vod/tag?page=1&per_page=400&site_id=' + SITE_ID);
      var items = (data && data.data && data.data.items) || [];
      var options = [];
      for (var i = 0; i < items.length && options.length < 60; i++) {
        var t = items[i];
        if (!t || t.id == null) continue;
        var name = clean(t.name);
        if (!name) continue;
        options.push({ id: String(t.id), title: name });
      }
      if (!options.length) return [];
      return [{ id: 'tag', title: '标签', multiple: true, options: options }];
    } catch (error) {
      return [];
    }
  },

  async detail(args) {
    var id = String((args && args.id) || '').replace(/[^0-9]/g, '');
    if (!id) return null;
    var data = await api('/api/vod/video/' + id);
    var d = (data && data.data) || null;
    if (!d) return null;
    var row = rowOf(d);
    if (row) remember([row]);
    var tags = (d.tag || []).map(function (t) { return clean(t.name); }).filter(Boolean);
    var desc = [];
    if (d.hits) desc.push('播放 ' + d.hits);
    if (d.likes_count) desc.push('点赞 ' + d.likes_count);
    if (d.score) desc.push('评分 ' + d.score);
    if (Number(d.is_paid) > 0 || Number(d.price) > 0) desc.push('VIP（接口层未拦，照样下发播放地址）');
    if (tags.length) desc.push('标签 ' + tags.join('・'));
    if (d.description) desc.push('', clean(d.description));
    return {
      id: id,
      title: clean(d.name) || id,
      cover: media(d.pic),
      subtitle: tags.slice(0, 3).join(' · '),
      description: desc.join('\n'),
      tags: tags,
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
    var data = await api('/api/vod/video/' + id);
    var d = (data && data.data) || {};
    var url = media(d.play_url || '');
    if (!url) throw new Error('这条没有播放地址（详情里没给 play_url）');
    return {
      kind: 'video',
      url: url,
      headers: { 'User-Agent': UA, Referer: REF },
    };
  },
};
