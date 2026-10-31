// LumeSource: {"id":"yuxiu_video","name":"玉羞园","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://yhh.yxy881p.icu"],"network":"direct"}
// LumeRuntime: javascript
//
// 站点：玉羞园（https://yhh.yxy881p.icu）—— xvideos 镜像站：模板、播放器、缩略图全是 xvideos 原版，
// 视频文件直接落在 xvideos 的 CDN（mp4-cdn77 / hls-cdn77），**没有 VIP、没有登录、不需要破解**。
//
// 结构（xvideos 那套 SEO 路由，2026-10-27 实测）：
//   · 首页             /                        48 条/页（最新）
//   · 最新翻页         /new/{n}                 n = 页码-1（/new/1 = 第 2 页；/new 与 /new/0 都是 404）
//   · 最佳             /best、/best/{n}
//   · 中文字幕         /lang/chinese、/porn/{n}（/porn/0 也行）
//   · 分类             /c/{Slug}-{id}、/c/{Slug}-{id}/{n}   27 条/页
//   · 搜索             /?k=关键词&p={页码}      p 从 1 起
//   · 详情             /video.{eid}/{videoid}/0/{slug}，短链 /video.{eid}/{slug} 也行
//   · 两套卡片版式：首页是 <a href="/video…"><img data-src>，/best 与 /lang/chinese 是
//     <a class="thumb-link"> + <picture><source data-srcset> + <div class="title" title="…">，
//     解析按「class="thumb" 分块」同时兼容两者。
//   · 播放地址在详情页：html5player.setVideoUrlHigh/Low('…mp4?secure=…')，另有
//     https://hls-cdn77.xvideos-cdn.com/…/hls_low|high.m3u8 —— 两者都带时间戳 token，直连即 200。
//
// 实测（源站当前状态）：hls master 200 + application/vnd.apple.mpegurl（206 B）；
// mp4_sd 200 + video/mp4（单条 93,026,181 B 整片，可直下）。全站 18+。

var BASE_URL = 'https://yhh.yxy881p.icu';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var PAGE_SIZE = 27;
var NAV_TTL_MS = 6 * 3600 * 1000;
var DETAIL_TTL_MS = 10 * 60 * 1000;

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return (domain || BASE_URL).replace(/\/+$/, '');
}

async function readJson(file) {
  try {
    var raw = await LumeSource.fs.readText(file);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

async function writeJson(file, value) {
  try {
    await LumeSource.fs.writeText(file, JSON.stringify(value));
  } catch (error) {
    /* 缓存失败不影响主流程 */
  }
}

var ENTITIES = {
  '&amp;': '&', '&quot;': '"', '&#39;': "'", '&apos;': "'", '&nbsp;': ' ',
  '&comma;': ',', '&excl;': '!', '&period;': '.', '&quest;': '?', '&colon;': ':',
  '&semi;': ';', '&lpar;': '(', '&rpar;': ')', '&lsqb;': '[', '&rsqb;': ']',
  '&sol;': '/', '&vert;': '|', '&num;': '#', '&percnt;': '%', '&plus;': '+',
  '&minus;': '-', '&lowbar;': '_', '&ast;': '*', '&equals;': '=', '&commat;': '@',
  '&lt;': '<', '&gt;': '>', '&tilde;': '~', '&Hat;': '^', '&grave;': String.fromCharCode(96),
};

function clean(text) {
  var out = String(text == null ? '' : text).replace(/<[^>]+>/g, ' ');
  out = out.replace(/&[a-zA-Z]+;|&#\d+;/g, function (entity) {
    if (ENTITIES[entity]) return ENTITIES[entity];
    var num = /^&#(\d+);$/.exec(entity);
    if (num) return String.fromCharCode(Number(num[1]));
    return entity;
  });
  return out.replace(/\s+/g, ' ').trim();
}

async function fetchPage(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: base() + '/',
    },
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：玉羞园被 Cloudflare 挡住（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

// ---------------------------------------------------------------- 列表

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var blocks = text.split('class="thumb"');
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i];
    var hrefMatch = /href="(\/video\.[^"]+)"/.exec(block);
    if (!hrefMatch) continue;
    var path = hrefMatch[1];
    if (seen[path]) continue;

    var titleMatch = /class="title"[\s\S]{0,300}?title="([^"]{1,300})"/.exec(block)
      || /<img[^>]+alt="([^"]{1,300})"/.exec(block)
      || /<a[^>]+title="([^"]{1,300})"/.exec(block);
    var title = clean(titleMatch ? titleMatch[1] : '');
    if (!title || /^video$/i.test(title)) continue;

    var coverMatch = /data-src="(https:\/\/thumb[^"]+)"/.exec(block)
      || /data-srcset="(https:\/\/thumb[^"]+)"/.exec(block)
      || /data-mzl="(https:\/\/thumb[^"]+)"/.exec(block);
    var durMatch = /<span class="duration">([^<]{1,20})</.exec(block);
    var hdMatch = /class="video-hd-mark">([^<]{1,12})</.exec(block);

    seen[path] = true;
    var bits = [];
    if (hdMatch) bits.push(clean(hdMatch[1]));
    if (durMatch) bits.push(clean(durMatch[1]));
    items.push({
      id: path,
      title: title,
      cover: coverMatch ? String(coverMatch[1]) : '',
      subtitle: bits.join(' · '),
    });
  }
  return items;
}

function listPath(categoryId, page) {
  var n = Number(page) || 1;
  var deep = n - 1;
  if (categoryId === 'best') return deep <= 0 ? '/best' : '/best/' + deep;
  if (categoryId === 'chinese') return deep <= 0 ? '/lang/chinese' : '/porn/' + deep;
  if (/^cat:/.test(categoryId)) {
    var slug = categoryId.slice(4);
    return deep <= 0 ? '/c/' + slug : '/c/' + slug + '/' + deep;
  }
  return deep <= 0 ? '/' : '/new/' + deep;
}

async function navCategories() {
  var cached = await readJson('nav.json');
  if (cached && Array.isArray(cached.list) && cached.list.length && Date.now() - Number(cached.at) < NAV_TTL_MS) {
    return cached.list;
  }
  var html = await fetchPage('/');
  var list = [];
  var seen = {};
  var re = /<a\s+href="\/c\/([A-Za-z0-9_\-]+)"[^>]*>([\s\S]{0,80}?)<\/a>/g;
  var matched;
  while ((matched = re.exec(html)) !== null) {
    var slug = matched[1];
    var name = clean(matched[2]);
    if (!slug || !name || seen[slug]) continue;
    seen[slug] = true;
    list.push({ id: 'cat:' + slug, title: name });
  }
  if (list.length) await writeJson('nav.json', { at: Date.now(), list: list });
  return list;
}

// ---------------------------------------------------------------- 详情

async function detailData(path) {
  var key = 'c-' + String(path).replace(/[^a-z0-9]/gi, '_').slice(-40) + '.json';
  var cached = await readJson(key);
  if (cached && cached.at && Date.now() - Number(cached.at) < DETAIL_TTL_MS) return cached;

  var html = await fetchPage(path);
  var titleTag = clean((/<title>([^<]*)<\/title>/.exec(html) || [])[1] || '').replace(/\s*-\s*玉羞园[\s\S]*$/, '').trim();
  var hls = (html.match(/https:\/\/hls-cdn77\.xvideos-cdn\.com\/[^"'\s<>]+\.m3u8[^"'\s<>]*/) || [])[0] || '';
  var high = (html.match(/setVideoUrlHigh\(\s*['"]([^'"]+)/) || [])[1] || '';
  var low = (html.match(/setVideoUrlLow\(\s*['"]([^'"]+)/) || [])[1] || '';
  var pic = (html.match(/og:image"\s+content="([^"]+)"/) || [])[1] || '';
  var dur = clean((html.match(/<span class="duration">([^<]{1,20})</) || [])[1] || '');
  var hd = clean((html.match(/class="video-hd-mark">([^<]{1,12})</) || [])[1] || '');

  var data = {
    at: Date.now(),
    path: path,
    title: titleTag,
    cover: pic,
    hls: hls,
    mp4: high || low,
    duration: dur,
    quality: hd,
  };
  if (titleTag) await writeJson(key, data);
  return data;
}

var LumeSource = {
  id: 'yuxiu_video',
  name: '玉羞园',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  mirrors: ['https://yhh.yxy881p.icu'],

  async categories() {
    var list = [
      { id: 'new', title: '最新' },
      { id: 'best', title: '最佳' },
      { id: 'chinese', title: '中文字幕' },
    ];
    try {
      var nav = await navCategories();
      for (var i = 0; i < nav.length; i++) list.push(nav[i]);
    } catch (error) {
      /* 导航抓不到时至少还有三个入口 */
    }
    return list;
  },

  async home() {
    var boards = [];
    try {
      var latest = parseCards(await fetchPage('/'));
      if (latest.length) boards.push({ title: '最新', moreUrl: 'new', items: latest.slice(0, 12) });
    } catch (error) {
      /* 忽略 */
    }
    try {
      var best = parseCards(await fetchPage('/best'));
      if (best.length) boards.push({ title: '最佳', moreUrl: 'best', items: best.slice(0, 12) });
    } catch (error) {
      /* 忽略 */
    }
    try {
      var cn = parseCards(await fetchPage('/lang/chinese'));
      if (cn.length) boards.push({ title: '中文字幕', moreUrl: 'chinese', items: cn.slice(0, 12) });
    } catch (error) {
      /* 忽略 */
    }
    return boards;
  },

  async filters() {
    var options = [];
    try {
      var nav = await navCategories();
      for (var i = 0; i < nav.length; i++) options.push({ id: String(nav[i].id).replace('cat:', ''), title: nav[i].title });
    } catch (error) {
      /* 空筛选即可 */
    }
    return { groups: [{ id: 'category', title: '分类', options: options }] };
  },

  async list(argument) {
    var args = argument || {};
    var page = Number(args.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    if (filters.category) categoryId = 'cat:' + String(filters.category).trim();

    var html;
    if (keyword) html = await fetchPage('/?k=' + encodeURIComponent(keyword) + '&p=' + page);
    else html = await fetchPage(listPath(categoryId || 'new', page));

    var items = parseCards(html);
    return { items: items, hasMore: items.length >= PAGE_SIZE };
  },

  async detail(argument) {
    var path = String((argument && argument.id) || '').trim();
    if (!/^\/video\./.test(path)) return null;
    var data = null;
    try {
      data = await detailData(path);
    } catch (error) {
      return null;
    }
    if (!data || !data.title) return null;
    var bits = [];
    if (data.quality) bits.push(data.quality);
    if (data.duration) bits.push(data.duration);
    bits.push(data.hls ? 'HLS + MP4 直连' : 'MP4 直连');
    return {
      id: path,
      title: data.title,
      cover: data.cover,
      subtitle: bits.join(' · '),
      description: '源站：' + base() + path + '\n内容来自 xvideos 公共库（本站是镜像），媒体直连 xvideos CDN，无 VIP。',
    };
  },

  async chapters(argument) {
    var path = String((argument && argument.id) || '').trim();
    if (!/^\/video\./.test(path)) return [];
    return [{ id: 'video:' + path, title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var path = String(args.id || '').trim();
    if (!/^\/video\./.test(path)) throw new Error('缺少视频路径');
    var data = await detailData(path);
    if (!data || (!data.hls && !data.mp4)) throw new Error('这条没有可用播放地址（源站可能已下架）');
    return {
      kind: 'video',
      url: data.hls || data.mp4,
      headers: { Referer: base() + '/', 'User-Agent': UA },
      qualities: data.hls && data.mp4 ? [{ label: 'HLS', url: data.hls }, { label: 'MP4', url: data.mp4 }] : undefined,
    };
  },
};
