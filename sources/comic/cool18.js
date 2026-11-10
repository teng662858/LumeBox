// LumeSource: {"id":"cool18_comic","name":"酷18","version":"1.0.2","category":"comic","contentCategory":"adult","contentTypes":["novel","photo","video"],"settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.cool18.com"],"network":"direct","icon":"https://www.cool18.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"酷18（cool18.com）综合成人论坛，本源收 9 个板块：禁忌书屋 / 情色趣闻 / 性趣论坛（文字小说）、性趣贴图 / 情色靓影 / 私房自拍 / 色色动漫 / 卡通漫画（图片）、成人影视（视频，需登录）。所有请求都带 Cookie isok=true 过年龄门。列表来自页面里的 const _PageData 数组（一页 150~260 帖）；排序走 act=hot（热门）/ act=gold（精华）；筛选走栏目搜索 act=threadsearch（keywords）。正文在 div#content-section 的 <pre> 里：文字帖按 <p></p>/<br> 折行，图片帖收集 img src（图床 img.xwbo.com 等，带 Referer）。 2026-11 起 色色动漫 / 成人影视 的帖子也要求登录：打开时用内嵌网页，登录一次即可看。文字板帖子本身没有配图，站方也不给缩略图，所以文字板没有封面；图片板封面由 App 按需读取帖子首图。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开站点首页","url":"https://www.cool18.com/index.php","description":"站点入口（年龄门点「进入」）"}]}
// LumeRuntime: javascript
//
// 站点：酷18（www.cool18.com），老式论坛 + 年龄门（Cookie isok=true）。
//
// 实测（2026-11-04）：
//   · 年龄门  /index.php 只有 1.3 KB 的提示页；带 Cookie isok=true（或 index.php?isok=true）才进站。
//   · 板块    9 个：bbs4 禁忌书屋 / bbs5 情色趣闻 / bj 性趣论坛 / bbs 性趣贴图 / bbs2 情色靓影 /
//             bbs6 私房自拍 / bbs7 色色动漫 / enter6 卡通漫画 / bbs3 成人影视
//   · 列表    /{板块}/index.php 页面里内联 `const _PageData = [{"tid","rootid","subject","username",
//             "dateline","size","country","type"},…]`（bbs4 232 条、bj 261 条、bbs 201 条）
//   · 排序    /{板块}/index.php?app=forum&act=hot（热门）、…&act=gold（精华）——服务端渲染的 <a> 列表
//   · 筛选    /{板块}/index.php?action=search&bbsdr={板块}&act=threadsearch&app=forum&keywords=xx&submit=查询
//   · 详情    /{板块}/index.php?app=forum&act=threadview&tid={tid}
//   · 正文    <div class="post-content"><div class="content-section" id="content-section"><pre> … </pre>
//             文字帖用 <p></p>/<br> 分段；图片帖是 <center><img src="https://img.xwbo.com/…"></center>
//   · 视频    bbs3 的正文是「需要登录」的提示（.login-container），登录后才给播放器。
//   · 2026-11-11 复测：bbs7 色色动漫也改成必须登录（正文只剩 .login-container）。
//             两个板块现在都返回 kind:'webplayer' 打开帖子页，用户在内嵌网页登录一次即可看，
//             不再直接抛错；图片板里没图的广告帖退回正文，避免整块被判坏。

var BASE_URL = 'https://www.cool18.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

var BOARDS = [
  { id: 'bbs4', title: '禁忌书屋', type: 'novel' },
  { id: 'bbs5', title: '情色趣闻', type: 'novel' },
  { id: 'bj', title: '性趣论坛', type: 'novel' },
  { id: 'bbs', title: '性趣贴图', type: 'photo' },
  { id: 'bbs2', title: '情色靓影', type: 'photo' },
  { id: 'bbs6', title: '私房自拍', type: 'photo' },
  { id: 'bbs7', title: '色色动漫', type: 'photo' },
  { id: 'enter6', title: '卡通漫画', type: 'photo' },
  { id: 'bbs3', title: '成人影视', type: 'video' }
];

var SORTS = [
  { id: 'latest', title: '最新' },
  { id: 'hot', title: '热门' },
  { id: 'gold', title: '精华' }
];

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
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

function headers() {
  return {
    'User-Agent': UA,
    Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    // 年龄门：不带这个 Cookie 只会拿到 1.3 KB 的提示页
    Cookie: 'isok=true'
  };
}

async function fetchHtml(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var h = headers();
  h.Referer = referer || base() + '/index.php';
  var reply = await LumeSource.http.get(url, { headers: h });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：酷18 返回 HTTP ' + status + '，可在网页视图里过一次校验');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  if (body.length < 2500 && /成人内容验证警示/.test(body)) {
    throw new Error('酷18 的年龄门没过：Cookie isok=true 没生效');
  }
  return body;
}

function boardOf(id) {
  var key = String(id == null ? '' : id).split(':')[0];
  for (var i = 0; i < BOARDS.length; i++) {
    if (BOARDS[i].id === key) return BOARDS[i];
  }
  return BOARDS[0];
}

// 列表条目按板块声明类型：图片板 → comic（图集阅读器），影视板 → video，
// 文字板 → novel。以前一律写 novel，图片板的条目会被当成小说打开。
function mediaTypeOf(board) {
  if (board && board.type === 'photo') return 'comic';
  if (board && board.type === 'video') return 'video';
  return 'novel';
}

function lazyCover(item) {
  if (!item || item.cover) return item;
  var match = /^([a-z0-9]+):(\d+)$/.exec(item.id);
  if (!match) return item;
  // 文字板（禁忌书屋/情色趣闻/性趣论坛）的帖子没有配图，站方也不提供缩略图，
  // 拉详情只会得到空封面；图片板用详情页首图做封面（App 按需解析，不拖慢列表）。
  // bbs7 已改成登录可见，封面页拿到的是登录框，拉详情没有意义，不挂封面。
  var photo = /^(bbs|bbs2|bbs6|enter6)$/.test(match[1]);
  if (!photo) return item;
  item.cover = base() + '/' + match[1] + '/index.php?app=forum&act=threadview&tid=' + match[2];
  item.coverHeaders = headers();
  item.coverHeaders['x-lume-image-page-selector'] = '#content-section img';
  return item;
}

function parsePageData(html) {
  var text = String(html || '');
  var matched = /const _PageData = (\[[\s\S]*?\]);/.exec(text);
  if (!matched) return [];
  var rows;
  try {
    rows = JSON.parse(matched[1]);
  } catch (error) {
    return [];
  }
  var boardHit = /var _dbname = '([^']+)'/.exec(text);
  var board = boardHit ? boardHit[1] : '';
  var out = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    if (!row || !row.tid || seen[row.tid]) continue;
    seen[row.tid] = true;
    var title = clean(String(row.subject || ''));
    if (!title) continue;
    var meta = [row.username || '', row.dateline || ''].filter(Boolean).join(' · ');
    out.push({
      id: (board || 'bbs4') + ':' + row.tid,
      title: title,
      cover: '',
      subtitle: meta,
      mediaType: mediaTypeOf(boardOf(board || 'bbs4'))
    });
  }
  return out.map(lazyCover);
}

function parseAnchors(html, board) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var re = /<a[^>]+href="[^"]*act=threadview&tid=(\d+)"[^>]*>([\s\S]{0,500}?)<\/a>/g;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var tid = hit[1];
    if (seen[tid]) continue;
    var raw = clean(hit[2]);
    if (!raw) continue;
    // 榜单条目形如「标题 - 作者 (12345 bytes) 2026/10/09 (70377 reads)」，只留标题
    var title = raw
      .replace(/\s*-\s*[^\s(]{1,24}\s*\(\d+\s*bytes\)[\s\S]*$/i, '')
      .replace(/\s*\(\d+\s*bytes\)[\s\S]*$/i, '')
      .replace(/\s*\(\d+\s*reads?\)\s*$/i, '')
      .trim();
    if (!title) title = raw;
    seen[tid] = true;
    out.push({ id: board + ':' + tid, title: title, cover: '', subtitle: '酷18 · ' + boardOf(board).title, mediaType: mediaTypeOf(boardOf(board)) });
  }
  return out.map(lazyCover);
}

function contentSection(html) {
  var text = String(html || '');
  var start = text.indexOf('id="content-section"');
  if (start < 0) start = text.indexOf('class="post-content"');
  if (start < 0) return '';
  var seg = text.slice(start);
  var end = seg.indexOf('</pre>');
  if (end > 0) return seg.slice(0, end);
  var ad = seg.indexOf('view_ad_incontent');
  if (ad > 0) return seg.slice(0, ad);
  return seg.slice(0, 400000);
}

function imagesOf(section) {
  var out = [];
  var seen = {};
  var re = /<img[^>]+src="([^"]+)"/gi;
  var hit;
  while ((hit = re.exec(section)) !== null) {
    var url = absolute(decodeEntities(hit[1]));
    if (!/^https?:\/\//i.test(url)) continue;
    if (/\/resource\/|\/pub_|logo|icon|avatar|blank\.gif|advert/i.test(url)) continue;
    if (seen[url]) continue;
    seen[url] = true;
    out.push(url);
  }
  return out;
}

function textOf(section) {
  var text = String(section || '')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<img[^>]*>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<p>\s*<\/p>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<\/div>/gi, '\n')
    .replace(/<[^>]+>/g, '');
  var lines = decodeEntities(text).split('\n');
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^[\s\u3000]+/, '').replace(/[\s\u3000]+$/, '');
    if (!line) continue;
    out.push(line);
  }
  return out.join('\n');
}

function parseSearch(html) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var re = /<a href="(?:https?:\/\/[^"\/]+)?\/([a-z0-9]+)\/index\.php\?app=forum&act=threadview&tid=(\d+)"[^>]*>([\s\S]{0,400}?)<\/a>/gi;
  var hit;
  while ((hit = re.exec(text)) !== null) {
    var board = hit[1].toLowerCase();
    var tid = hit[2];
    var key = board + ':' + tid;
    if (seen[key]) continue;
    var body = hit[3];
    // 搜索结果里第一段是【板块】，第二段才是标题
    var parts = [];
    var pieceRe = /<p[^>]*>([\s\S]*?)<\/p>/gi;
    var piece;
    while ((piece = pieceRe.exec(body)) !== null) {
      var value = clean(piece[1]);
      if (value) parts.push(value);
    }
    var title = parts.length > 1 ? parts[1] : clean(body);
    if (!title) continue;
    seen[key] = true;
    out.push({
      id: key,
      title: title,
      cover: '',
      subtitle: parts.length > 0 ? parts[0].replace(/^【|】$/g, '') : board,
      mediaType: mediaTypeOf(boardOf(board))
    });
  }
  return out.map(lazyCover);
}

// 热门榜：<tr><td class="rank-col">第N位</td><td class="title-col"><a href="…tid=NNN"> 标题 - 作者 (123 bytes) <i>日期</i> (123 reads) </td></tr>
function parseRank(html, board) {
  var text = String(html || '');
  var out = [];
  var seen = {};
  var blocks = text.split('<td class="title-col">');
  for (var i = 1; i < blocks.length; i++) {
    var seg = blocks[i].slice(0, 800);
    var tidHit = /tid=(\d+)/.exec(seg);
    if (!tidHit) continue;
    var tid = tidHit[1];
    if (seen[tid]) continue;
    var raw = clean(seg.split('</td>')[0]);
    raw = raw.replace(/\s*-\s*[^\s(]{1,24}\s*\(\d+\s*bytes\)[\s\S]*$/i, '');
    raw = raw.replace(/\s*\(\d+\s*bytes\)[\s\S]*$/i, '').replace(/\s*\(\d+\s*reads?\)\s*$/i, '').trim();
    if (!raw) continue;
    seen[tid] = true;
    out.push({ id: board + ':' + tid, title: raw, cover: '', subtitle: '酷18 · 热门', mediaType: mediaTypeOf(boardOf(board)) });
  }
  return out.map(lazyCover);
}

var LumeSource = {
  id: 'cool18_comic',
  name: '酷18',
  version: '1.0.2',
  category: 'comic',
  contentCategory: 'adult',
  contentTypes: ['novel', 'photo', 'video'],
  network: 'direct',
  icon: 'https://www.cool18.com/favicon.ico',
  mirrors: ['https://www.cool18.com'],

  async categories() {
    return BOARDS.map(function (board) {
      return { id: board.id, title: board.title };
    });
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
    // 首页放两个文字板 + 一个图片板：文字帖没有配图，全是文字板的话首页会一片占位图。
    var HOME_BOARDS = ['bbs4', 'bbs5', 'bbs2'];
    var boards = [];
    for (var i = 0; i < HOME_BOARDS.length && boards.length < 3; i++) {
      var board = boardOf(HOME_BOARDS[i]);
      var items = parsePageData(await fetchHtml('/' + board.id + '/index.php')).slice(0, 12);
      if (items.length) boards.push({ title: board.title, moreUrl: board.id, items: items });
    }
    if (!boards.length) throw new Error('首页没解析出条目（站点结构可能变了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var board = boardOf(args.categoryId);
    var keyword = String(args.keyword == null ? '' : args.keyword).trim();
    var sort = String((args.filters && args.filters.sort) || 'latest').trim();
    if (sort.indexOf(',') >= 0) sort = sort.split(',')[0].trim();

    if (keyword) {
      // 站内全成人区搜索：跨板块，结果带【板块】与【标题】
      var searchPath = '/search.php?keyword=' + encodeURIComponent(keyword) + '&sa=' + encodeURIComponent('全成人区搜索');
      var found = parseSearch(await fetchHtml(searchPath));
      if (found.length) return { items: found, hasMore: false };
      var localPath = '/' + board.id + '/index.php?action=search&bbsdr=' + board.id +
        '&act=threadsearch&app=forum&keywords=' + encodeURIComponent(keyword) + '&submit=' + encodeURIComponent('查询');
      var local = parseAnchors(await fetchHtml(localPath), board.id);
      return { items: local, hasMore: false };
    }

    if (sort === 'hot' || sort === 'gold') {
      var html = await fetchHtml('/' + board.id + '/index.php?app=forum&act=' + sort);
      var ranked = sort === 'hot' ? parseRank(html, board.id) : parseAnchors(html, board.id);
      ranked = ranked.map(function (item) {
        return {
          id: item.id,
          title: String(item.title || '').replace(/^[.\s·]+/, '').trim(),
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          subtitle: item.subtitle,
          mediaType: mediaTypeOf(board)
        };
      });
      if (!ranked.length) throw new Error('排行榜没解析出条目（' + board.title + ' / ' + sort + '）');
      return { items: ranked, hasMore: false };
    }

    var latest = parsePageData(await fetchHtml('/' + board.id + '/index.php'));
    if (!latest.length) throw new Error('这个板块没取到条目（' + board.title + '）');
    return { items: latest, hasMore: false };
  },

  async detail(argument) {
    var raw = String((argument && argument.id) || '');
    var parts = raw.split(':');
    var board = boardOf(raw);
    var tid = parts[1] || '';
    if (!tid) return null;
    var html = await fetchHtml('/' + board.id + '/index.php?app=forum&act=threadview&tid=' + tid);
    var titleHit = /<title>([\s\S]{0,200}?)<\/title>/i.exec(html);
    var title = clean(titleHit ? titleHit[1] : '')
      .replace(/\s*-\s*[^-]{0,16}\s*cool18[\s\S]*$/i, '')
      .replace(/\s*cool18[\s\S]*$/i, '')
      .trim();
    if (!title) return null;
    var section = contentSection(html);
    var images = imagesOf(section);
    var lines = ['板块：' + board.title];
    var author = /作者[:：]\s*([^\s<]{1,24})/.exec(section);
    if (author) lines.push('作者：' + author[1]);
    if (board.type === 'photo') lines.push('图片：' + images.length + ' 张');
    return {
      id: board.id + ':' + tid,
      title: title,
      cover: images[0] || '',
      coverHeaders: headers(),
      subtitle: board.title,
      description: lines.join('\n'),
      mediaType: mediaTypeOf(board)
    };
  },

  async chapters(argument) {
    var raw = String((argument && argument.id) || '');
    var board = boardOf(raw);
    var tid = raw.split(':')[1] || '';
    if (!tid) return [];
    return [{ id: board.id + ':' + tid + ':0', title: board.type === 'photo' ? '图集' : '正文' }];
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? args.chapterId : args.chapterId) || String(args.id || '');
    var parts = String(raw).split(':');
    var board = boardOf(raw);
    var tid = parts[1] || '';
    if (!tid) throw new Error('缺少帖子 ID（应形如 板块:tid）');

    var pagePath = '/' + board.id + '/index.php?app=forum&act=threadview&tid=' + tid;
    var html = await fetchHtml(pagePath);
    var section = contentSection(html);
    if (!section) throw new Error('这个帖子没有正文区（' + pagePath + '）');

    // 2026-11-11 实测：色色动漫（bbs7）和成人影视（bbs3）的帖子改成必须登录，
    // 正文区只剩登录框（.login-container）。这里不假装能播，交给网页视图：
    // 用户在内嵌网页登录一次（会话按源保留），之后帖子内容/播放器都能看。
    var gated = /login-container/i.test(html) || /请登录社区账户/.test(html);
    if (gated) {
      var pageUrl = absolute(pagePath);
      return {
        kind: 'webplayer',
        url: pageUrl,
        pageUrl: pageUrl,
        headers: { Referer: base() + '/index.php', 'User-Agent': UA }
      };
    }

    if (board.type === 'video') {
      var iframe = /<iframe[^>]+src="(https?:\/\/[^"]+)"/i.exec(section);
      if (iframe && !/ad\.|adv|parkvv|dtscout/i.test(iframe[1])) {
        return { kind: 'webplayer', url: absolute(iframe[1]), headers: { Referer: pagePath, 'User-Agent': UA } };
      }
      throw new Error('成人影视板块的播放页要求登录（站点在正文里放的是登录框），登录后才能在 App 里播放');
    }

    if (board.type === 'photo') {
      var images = imagesOf(section);
      if (!images.length) {
        // 广告帖/纯文字帖没有图：退回正文，别让整个板块看起来是坏的。
        var photoText = textOf(section);
        if (photoText && photoText.length >= 30) return { kind: 'text', text: photoText };
        throw new Error('这个帖子没解析到图片（' + pagePath + '）');
      }
      var imageHeaders = {};
      for (var i = 0; i < images.length; i++) {
        imageHeaders[images[i]] = { Referer: pagePath, 'User-Agent': UA };
      }
      return { kind: 'images', images: images, imageHeaders: imageHeaders };
    }

    var text = textOf(section);
    if (!text || text.length < 30) throw new Error('这个帖子没解析到正文（' + pagePath + '）');
    return { kind: 'text', text: text };
  }
};
