// LumeSource: {"id":"mycall_video","name":"草榴小说视频","version":"1.0.1","category":"video","contentCategory":"adult","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://mycall.biz"],"network":"direct","icon":"https://mycall.biz/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"草榴小说视频（mycall.biz，综合站，全站 18+）：小说 /threadlist?group=RecentThread|PopularThread|HotThread（7 个分类：诱骗/改编/变身/乱伦/古典情色/武侠/玄幻）、视频 /category/6095467d69deb6073dc6d6d7?sort=recent|popular|like、图片 /images?sort=…；搜索 /search?type=all|novel|video&q=。帖子 /thread/{id}：小说按 ?chapter=N 翻（body 上写总章数），视频走 /api/v1/video/thread/{id}/play → manifest/master.m3u8，图集在 data-gallery-preview。全站列表都是单页 24 条，没有翻页参数（page=/p= 实测被忽略），所以本源不打分页；正文/视频/图集都免登录。⚠ 站点会弹 exoclick/magsrv 广告，源里只取 HTML 与接口，不加载广告脚本。"}],"contentTypes":["video","photo","novel"]}
// LumeRuntime: javascript
//
// 站点：草榴小说视频（mycall.biz，综合站：小说 + 视频 + 图集，全站 18+）
//
// 结构（2026-11-04 实测）：
//   · 小说频道    /threadlist?group=RecentThread（最新）/ PopularThread（最多浏览）/ HotThread（最多点赞）
//                 分类 /threadlist?group=RecentThread&category={id}：
//                   诱骗系列 5fb8bbbc… / 改编系列 5fb8bbe9… / 变身系列 5fb8bc01… / 乱伦系列 5fb90c57…
//                   古典情色 6035c3db… / 武侠系列 6039a27f… / 玄幻系列 603a6b8b…
//   · 视频频道    /category/6095467d69deb6073dc6d6d7?sort=recent|popular|like
//   · 图片频道    /images?sort=recent|popular|like
//   · 搜索        /search?type=all|novel|video&sort=recent&q={词}（单页 24 条）
//   · 列表卡片    两种版式：
//                   图文卡 <article><a class="cp-catalog-cover" href="/thread/{id}"><img src="/imagespcrope/360/480/…">
//                          <h2><a href="/thread/{id}">【小说】标题</a></h2><p>日期 · 浏览 · 赞</p>
//                   图集卡 <a href="/thread/{id}"><img src="/imagespcrope/480/480/…">
//                          <strong class="cp-image-title">【色图】标题</strong><small>浏览 赞</small></a>
//   · 帖子详情    <body class="… novel-reader | video-watch-page | image-viewer-page"
//                        data-thread-id / data-chapter / data-total-chapters / data-novel-title>
//   · 小说正文    /thread/{id}?chapter=N（1 基，共 data-total-chapters 章）→ #chapter-content .novel-chapter-content
//   · 视频播放    前端 player24.min.js 请求 GET /api/v1/video/{source}/{id}/play
//                 → {"source":{"manifestURL":"/api/v1/video/thread/{id}/manifest/master.m3u8"}, …}
//                 实测 manifest 200 + #EXTM3U（2312 B，VOD），不需要 Referer/登录
//   · 图集        .image-gallery 里每个按钮带 data-gallery-preview="/imagesph/960/{hash}.jpg"，
//                 data-gallery-src 只是去掉扩展名的原图路径；本源取 960 预览图（实测 200，54 KB）
//
// 限制：全站列表都是**单页 24 条**（`page=` / `p=` 实测被忽略，页面上也没有翻页控件），
// 所以 hasMore 恒为 false，翻页靠换排序/分类；正文、视频、图集都不需要登录；小说帖子页面没有封面图。

var BASE_URL = 'https://mycall.biz';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var VIDEO_CATEGORY = '6095467d69deb6073dc6d6d7';

var NOVEL_CATS = [
  { id: '5fb8bbbc068a27793bc9ffa6', title: '诱骗系列' },
  { id: '5fb8bbe9068a27793bc9ffa8', title: '改编系列' },
  { id: '5fb8bc01068a27793bc9ffa9', title: '变身系列' },
  { id: '5fb90c57b0e6db1417e9db56', title: '乱伦系列' },
  { id: '6035c3db28af0c745c8dacf7', title: '古典情色' },
  { id: '6039a27f14b96af9203a37be', title: '武侠系列' },
  { id: '603a6b8bd7ae819370238344', title: '玄幻系列' }
];

var SORTS = [
  { id: 'recent', title: '最新' },
  { id: 'popular', title: '最多浏览' },
  { id: 'like', title: '最多点赞' }
];

var GROUPS = { recent: 'RecentThread', popular: 'PopularThread', like: 'HotThread' };

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

function decodeEntities(text) {
  return String(text == null ? '' : text)
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&middot;/g, '·')
    .replace(/&hellip;/g, '…')
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function oneLine(text) {
  return clean(text);
}

async function fetchHtml(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: referer || base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：草榴小说视频触发了人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

function threadIdOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/thread\/([0-9a-f]{16,})/i.exec(text) || /^([0-9a-f]{16,})/i.exec(text);
  return matched ? matched[1] : '';
}

function mediaTypeOfTitle(title) {
  var text = String(title || '');
  if (text.indexOf('【小说】') >= 0 || text.indexOf('【情色小说】') >= 0) return 'novel';
  if (text.indexOf('【色图】') >= 0 || text.indexOf('【图片】') >= 0) return 'comic';
  return 'video';
}

// 两种列表版式一起处理：图文卡（小说/视频）与图集卡（图片频道）
function parseItems(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};

  var cardRe = /<article[\s\S]{0,2400}?<\/article>/g;
  var card;
  while ((card = cardRe.exec(text)) !== null) {
    var block = card[0];
    var link = /href="\/thread\/([0-9a-f]+)"/i.exec(block);
    var titleHit = /<h2><a href="\/thread\/[0-9a-f]+">([\s\S]*?)<\/a><\/h2>/i.exec(block);
    if (!link || !titleHit) continue;
    var id = link[1];
    if (seen[id]) continue;
    var title = oneLine(titleHit[1]);
    if (!title) continue;
    var cover = /<img[^>]*src="(\/images[a-z]*\/[^"]+)"/i.exec(block)
      || /<img[^>]*src="(\/images[^"]+)"/i.exec(block);
    var views = /fa-eye"><\/i>\s*([0-9]+)/i.exec(block);
    var likes = /fa-heart-o"><\/i>\s*([0-9]+)/i.exec(block);
    var date = /([0-9]{4}\/[0-9]{2}\/[0-9]{2})/.exec(block);
    seen[id] = true;
    items.push({
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: [date ? date[1] : '', views ? views[1] + ' 浏览' : '', likes ? likes[1] + ' 赞' : '']
        .filter(Boolean).join(' · '),
      mediaType: mediaTypeOfTitle(title)
    });
  }

  var imgRe = /<a href="\/thread\/([0-9a-f]+)"><img[^>]*src="(\/images[a-z]*\/[^"]+)"[^>]*>[\s\S]{0,400}?<strong class="cp-image-title">([\s\S]*?)<\/strong>/gi;
  var hit;
  while ((hit = imgRe.exec(text)) !== null) {
    var iid = hit[1];
    if (seen[iid]) continue;
    var ititle = oneLine(hit[3]);
    if (!ititle) continue;
    seen[iid] = true;
    items.push({
      id: iid,
      title: ititle,
      cover: absolute(hit[2]),
      subtitle: '图集',
      mediaType: 'comic'
    });
  }
  return items;
}

function channelPath(categoryId, sort) {
  var id = categoryId || 'novel-all';
  var sortId = GROUPS[sort] ? sort : 'recent';
  if (id === 'video') return '/category/' + VIDEO_CATEGORY + '?sort=' + sortId;
  if (id === 'images') return '/images?sort=' + sortId;
  // 小说：排序筛选控制 group（最新/最多浏览/最多点赞），分类只决定 category
  var group = GROUPS[sortId];
  if (/^cat-/.test(id)) return '/threadlist?group=' + group + '&category=' + id.slice(4);
  return '/threadlist?group=' + group;
}

function threadKind(html) {
  var body = /<body[^>]*>/i.exec(String(html || ''));
  var attrs = body ? body[0] : '';
  if (attrs.indexOf('novel-reader') >= 0) return 'novel';
  if (attrs.indexOf('image-viewer-page') >= 0) return 'images';
  return 'video';
}

function novelChapterText(html) {
  var text = String(html || '');
  var start = text.indexOf('novel-chapter-content');
  if (start < 0) start = text.indexOf('id="chapter-content"');
  if (start < 0) return '';
  var end = text.indexOf('</article>', start);
  var seg = end > start ? text.slice(start, end) : text.slice(start);
  seg = seg
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  var lines = decodeEntities(seg).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
    if (!line || line === '>' || line === '">') continue;
    out.push(line);
  }
  return out.join('\n');
}

function galleryImages(html) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var re = /data-gallery-preview="(\/images[a-z]*\/[0-9]+\/[^"]+)"/gi;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var url = absolute(hit[1]);
    if (!url || seen[url]) continue;
    seen[url] = true;
    out.push(url);
  }
  if (!out.length) {
    var re2 = /data-gallery-src="(\/imagesp\/[^"]+)"/gi;
    while ((hit = re2.exec(text)) !== null) {
      var u2 = absolute(hit[1] + '.jpg');
      if (!seen[u2]) {
        seen[u2] = true;
        out.push(u2);
      }
    }
  }
  return out;
}

var LumeSource = {
  id: 'mycall_video',
  name: '草榴小说视频',
  version: '1.0.1',
  category: 'video',
  contentCategory: 'adult',
  network: 'direct',
  icon: 'https://mycall.biz/favicon.ico',
  mirrors: ['https://mycall.biz'],

  async categories() {
    var list = [{ id: 'novel-all', title: '全部小说' }];
    for (var i = 0; i < NOVEL_CATS.length; i++) {
      list.push({ id: 'cat-' + NOVEL_CATS[i].id, title: NOVEL_CATS[i].title });
    }
    list.push({ id: 'video', title: '视频' });
    list.push({ id: 'images', title: '图片' });
    return list;
  },

  async filters() {
    return {
      groups: [
        {
          id: 'sort',
          title: '排序',
          options: SORTS.map(function (item) {
            return { id: item.id, title: item.title };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    var novel = parseItems(await fetchHtml('/threadlist?group=RecentThread')).slice(0, 12);
    if (novel.length) boards.push({ title: '最新小说', moreUrl: 'novel-all', items: novel });
    try {
      var video = parseItems(await fetchHtml('/category/' + VIDEO_CATEGORY + '?sort=recent')).slice(0, 12);
      if (video.length) boards.push({ title: '最新视频', moreUrl: 'video', items: video });
    } catch (error) {
      /* 视频频道失败不影响首页 */
    }
    try {
      var pics = parseItems(await fetchHtml('/images?sort=recent')).slice(0, 12);
      if (pics.length) boards.push({ title: '最新图片', moreUrl: 'images', items: pics });
    } catch (error) {
      /* 图片频道失败不影响首页 */
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var sort = String(filters.sort || 'recent').trim();
    if (sort.indexOf(',') >= 0) sort = sort.split(',')[0].trim();

    var path;
    if (keyword) {
      var type = 'all';
      if (categoryId === 'images') type = 'image';
      else if (categoryId === 'video') type = 'video';
      else if (/^novel-|^cat-/.test(categoryId)) type = 'novel';
      path = '/search?type=' + type + '&sort=recent&q=' + encodeURIComponent(keyword);
    } else {
      path = channelPath(categoryId, sort);
    }

    var html = await fetchHtml(path);
    var items = parseItems(html);
    if (!items.length && keyword) return { items: [], hasMore: false };
    if (!items.length && page === 1) {
      throw new Error('这个栏目没有取到条目（' + path + '，站点模板可能改了）');
    }
    // 站点所有列表都是单页 24 条，没有翻页参数
    return { items: items, hasMore: false };
  },

  async detail(argument) {
    var id = threadIdOf(argument && argument.id);
    if (!id) return null;
    var html = await fetchHtml('/thread/' + id + '/');
    if (!html) return null;
    var kind = threadKind(html);
    var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/i.exec(html);
    var bodyTitle = /data-novel-title="([^"]*)"/i.exec(html);
    var h1 = /<h1[^>]*>([\s\S]{0,300}?)<\/h1>/i.exec(html);
    var titleTag = /<title>([^<]*)<\/title>/i.exec(html);
    var title = '';
    if (ogTitle && oneLine(ogTitle[1])) title = oneLine(ogTitle[1]);
    if (!title && bodyTitle && oneLine(bodyTitle[1])) title = oneLine(bodyTitle[1]);
    if (!title && h1 && oneLine(h1[1])) title = oneLine(h1[1]);
    if (!title && titleTag) title = oneLine(titleTag[1]);
    if (!title) return null;
    title = title.replace(/^草榴小说视频[-—]\s*/, '');
    var cover = /<meta\s+property="og:image"\s+content="([^"]+)"/i.exec(html);
    var views = /fa-eye"><\/i>\s*([0-9]+)/i.exec(html);
    var likes = /fa-heart-o"><\/i>\s*([0-9]+)/i.exec(html);
    var date = /([0-9]{4}\/[0-9]{2}\/[0-9]{2})/.exec(html);
    var chapters = /data-total-chapters="([0-9]+)"/i.exec(html);
    var lines = [];
    lines.push('类型：' + (kind === 'novel' ? '小说' : kind === 'images' ? '图集' : '视频'));
    if (chapters) lines.push('章数：' + chapters[1]);
    if (views) lines.push('浏览：' + views[1]);
    if (likes) lines.push('点赞：' + likes[1]);
    if (date) lines.push('发布：' + date[1]);
    return {
      id: id,
      title: title,
      cover: cover ? absolute(cover[1]) : '',
      subtitle: [kind === 'novel' ? '小说' : kind === 'images' ? '图集' : '视频', date ? date[1] : '']
        .filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: kind === 'novel' ? 'novel' : kind === 'images' ? 'comic' : 'video'
    };
  },

  async chapters(argument) {
    var id = threadIdOf(argument && argument.id);
    if (!id) return [];
    var html = await fetchHtml('/thread/' + id + '/');
    var kind = threadKind(html);
    if (kind === 'novel') {
      var totalHit = /data-total-chapters="([0-9]+)"/i.exec(html);
      var total = totalHit ? Number(totalHit[1]) : 1;
      if (!total || total < 1) total = 1;
      total = Math.min(total, 2000);
      var out = [];
      for (var i = 1; i <= total; i++) out.push({ id: id + ':chapter:' + i, title: '第 ' + i + ' 章' });
      return out;
    }
    if (kind === 'images') {
      var count = galleryImages(html).length;
      return [{ id: id + ':images:1', title: count ? '图集（' + count + ' 张）' : '图集' }];
    }
    return [{ id: id + ':video:1', title: '正片（HLS）' }];
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var tid = threadIdOf(raw) || threadIdOf(args.id);
    if (!tid) throw new Error('缺少帖子 ID');
    var kind = 'video';
    var index = 1;
    var matched = /:([a-z]+):(\d+)$/i.exec(raw);
    if (matched) {
      kind = matched[1];
      index = Number(matched[2]) || 1;
    }

    if (kind === 'chapter') {
      var html = await fetchHtml('/thread/' + tid + '?chapter=' + index);
      var text = novelChapterText(html);
      if (!text.trim()) throw new Error('这一章正文是空的（第 ' + index + ' 章）');
      return { kind: 'text', title: '第 ' + index + ' 章', text: text };
    }

    if (kind === 'images') {
      var page = await fetchHtml('/thread/' + tid + '/');
      var images = galleryImages(page);
      if (!images.length) throw new Error('这个帖子没有解析到图片');
      return { kind: 'images', images: images, headers: { Referer: base() + '/' } };
    }

    // 视频：player24.min.js 的接口 GET /api/v1/video/{source}/{id}/play
    var reply = await LumeSource.http.get(base() + '/api/v1/video/thread/' + tid + '/play', {
      headers: {
        'User-Agent': UA,
        Accept: 'application/json',
        Referer: base() + '/thread/' + tid,
        Origin: base()
      }
    });
    var status = reply ? reply.status : 0;
    if (status !== 200) throw new Error('播放信息接口打不开：HTTP ' + status);
    var payload = null;
    try {
      payload = JSON.parse(String(reply.body || ''));
    } catch (error) {
      payload = null;
    }
    var manifest = payload && payload.source && payload.source.manifestURL ? String(payload.source.manifestURL) : '';
    if (!manifest) throw new Error('播放信息里没有 manifestURL（站点接口可能改了）');
    return {
      kind: 'video',
      url: absolute(manifest),
      headers: { Referer: base() + '/thread/' + tid, 'User-Agent': UA }
    };
  }
};
