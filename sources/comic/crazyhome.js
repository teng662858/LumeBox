// LumeSource: {"id":"crazyhome_novel","name":"狂人之家书屋","version":"1.0.0","category":"comic","contentCategory":"adult","network":"direct","mirrors":["https://www.crazyhome2000.com"],"icon":"https://www.crazyhome2000.com/wp-content/uploads/2025/06/icon.jpg","settingsApiVersion":2,"settings":[{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 成人小说站（狂人之家书屋，WordPress 站）。一本书 = 一个站点标签，一章 = 一篇文章（常见一篇含数章，标题写成 63.22-63.29）。免登录、直连可开；小说章节站方本身不给封面，只有「AI美图共享」图集带封面。正文走站方 REST 接口，段落干净、无广告插入。"}]}
// LumeRuntime: javascript
//
// 站点：狂人之家书屋（www.crazyhome2000.com），WordPress + 阁楼主题的成人文学站。
// 2026-11-10 实测（本机直连 200，无需登录、没有 CF 人机页）：
//   · REST 全开：/wp-json/wp/v2/{posts,tags,categories}，返回干净 JSON。
//   · 书 = post_tag：一本书一个 tag（/tag/<书名>/，标签页按发布倒序分页）。
//     标签总数 8890（89 页 × 100），篇数前几名：系统帮我睡女人 171、赘婿的荣耀 165。
//   · 章 = post：一篇文章通常含几章（标题如「赘婿的荣耀 63.22-63.29」），
//     content.rendered 就是正文，开头有「书名作者：X」与卷/章行，中间无广告。
//   · 分类 10 个小说分类 + 「AI美图共享」图集（20 篇，正文是 <img>，图床 cool18.cc，
//     实测无 Referer 也 200 image/webp）。
//   · 小说章节没有 featured_media（featured_media=0），所以列表/详情不带封面；
//     图集帖有特色图（featured_media），用 /media?include= 批量换真地址。
//   · 站方页面（tag 页 5 页 / category 页 446 页）也能用，但 REST 更省请求、正文更干净，
//     本源统一走 REST。
//
// 站内 ID：t:<tagId>（书）；章节 ID 用 post id。分类 ID 用站点 category id。

var BASE = 'https://www.crazyhome2000.com';

var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

// 站点分类（/wp-json/wp/v2/categories 实测，按篇数从多到少）
var CATEGORIES = [
  { id: 'latest', title: '最新更新' },
  { id: 'all', title: '全部书库' },
  { id: '2', title: '都市生活' },
  { id: '159', title: '玄幻世界' },
  { id: '1', title: '红杏出墙' },
  { id: '80', title: '家庭伦理' },
  { id: '47', title: '暴虐世界' },
  { id: '317', title: '古风小说' },
  { id: '16', title: '校园师生' },
  { id: '258', title: '浪漫纯爱' },
  { id: '444', title: '摄心控制' },
  { id: '318', title: '乡村野趣' },
  { id: '8840', title: 'AI美图共享' },
];

var CATEGORY_NAMES = {
  '1': '红杏出墙',
  '2': '都市生活',
  '16': '校园师生',
  '47': '暴虐世界',
  '80': '家庭伦理',
  '159': '玄幻世界',
  '258': '浪漫纯爱',
  '317': '古风小说',
  '318': '乡村野趣',
  '444': '摄心控制',
  '8840': 'AI美图共享',
};

// 一本书最多抓 600 篇（6 页 × 100）；实测最大的书 171 篇。
var MAX_CHAPTER_PAGES = 6;

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE).replace(/\/+$/, '');
}

function apiBase() {
  return base() + '/wp-json/wp/v2';
}

function headers(accept) {
  return { 'User-Agent': UA, Accept: accept || 'application/json', Referer: base() + '/' };
}

function decode(value) {
  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  return String(value == null ? '' : value).replace(
    /&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi,
    function (raw, key) {
      if (key.charAt(0) !== '#') return entities[key.toLowerCase()] || raw;
      var code = key.charAt(1).toLowerCase() === 'x'
        ? parseInt(key.slice(2), 16)
        : Number(key.slice(1));
      return code <= 0x10ffff ? String.fromCodePoint(code) : raw;
    }
  );
}

function plain(html) {
  return decode(String(html || '').replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function totalPages(res) {
  var all = res.headers || {};
  var raw = all['x-wp-totalpages'] || all['X-WP-TotalPages'];
  var pages = Math.floor(Number(raw));
  return pages > 0 ? pages : 0;
}

async function api(path) {
  var res = await LumeSource.http.get(apiBase() + path, { headers: headers() });
  if (res.status === 403 || res.status === 429 || res.status === 503 || res.status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：狂人之家返回人机校验（HTTP ' + res.status + '），可在网页视图里过一次校验');
  }
  // WordPress 对「页码超过总页数」回 400（rest_post_invalid_page_number），
  // 这是正常翻到底，不是故障，按空页处理。
  if (res.status === 404 || res.status === 400) {
    return { status: res.status, data: null, headers: res.headers || {} };
  }
  if (res.status !== 200) {
    throw new Error('狂人之家接口不可用（HTTP ' + res.status + '），稍后重试或换镜像');
  }
  var data;
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    throw new Error('狂人之家接口返回的不是 JSON（HTTP ' + res.status + '，可能被运营商劫持）');
  }
  return { status: 200, data: data, headers: res.headers || {} };
}

function tagIdOf(raw) {
  var match = /^t:(\d+)$/.exec(String(raw == null ? '' : raw).trim());
  return match ? match[1] : '';
}

function bookItem(tag) {
  var count = Number(tag.count) || 0;
  return {
    id: 't:' + tag.id,
    title: plain(tag.name) || ('书 ' + tag.id),
    subtitle: count ? '共 ' + count + ' 篇' : undefined,
    mediaType: 'novel',
  };
}

// 分类/最新列表里一页文章可能来自十几本书，按 tag 去重后翻成书；
// 文章只给 tag id，书名再从 /tags?include= 一次补齐（30 个 id 一次请求）。
// 小说章节没有特色图；只有「AI美图共享」的帖有 featured_media，
// 所以封面用 /media?include= 批量换，正常分类不会多发请求。
async function postsToBooks(posts) {
  var order = [];
  var postByTag = {};
  var seen = {};
  var mediaIds = [];
  for (var i = 0; i < posts.length; i++) {
    var tags = posts[i].tags || [];
    if (!tags.length) continue;
    var tagId = String(tags[0]);
    if (seen[tagId]) continue;
    seen[tagId] = true;
    order.push(tagId);
    postByTag[tagId] = posts[i];
    if (Number(posts[i].featured_media) > 0) mediaIds.push(String(posts[i].featured_media));
  }
  if (!order.length) return [];

  var tagMap = await loadTags(order);
  var mediaMap = await loadMedia(mediaIds);
  var items = [];
  for (var k = 0; k < order.length; k++) {
    var id = order[k];
    var tag = tagMap[id];
    var post = postByTag[id];
    var fallback = stripChapterSuffix(plain(post.title && post.title.rendered));
    var item = tag
      ? bookItem(tag)
      : { id: 't:' + id, title: fallback || ('书 ' + id), mediaType: 'novel' };
    if (!item.title) item.title = fallback;
    var cover = mediaMap[String(post.featured_media)];
    if (cover) item.cover = cover;
    items.push(item);
  }
  return items;
}

function stripChapterSuffix(title) {
  return String(title || '')
    .replace(/[\s\u3000]+[0-9][0-9.．、\-–—\s]*$/, '')
    .replace(/[\s\u3000]+第[0-9一二三四五六七八九十百千]+[章节回][^\s]*$/, '')
    .trim();
}


async function loadTags(ids) {
  var map = {};
  if (!ids.length) return map;
  var res = await api('/tags?include=' + ids.join(',') + '&per_page=100&_fields=id,name,count');
  var list = res.data && res.data.length ? res.data : [];
  for (var i = 0; i < list.length; i++) map[String(list[i].id)] = list[i];
  return map;
}

async function loadMedia(ids) {
  var map = {};
  if (!ids.length) return map;
  var res = await api('/media?include=' + ids.join(',') + '&per_page=100&_fields=id,source_url');
  var list = res.data && res.data.length ? res.data : [];
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].source_url) map[String(list[i].id)] = String(list[i].source_url);
  }
  return map;
}

// 正文：content.rendered 里没有广告块，只有开头一个书签小部件的登录表单文案，
// 加上结尾偶尔出现的站方提示，按已知文案整行丢掉。
var JUNK_LINE = /^(用户名或邮箱地址|密码|记住我|显示更多搜索结果|将文章加入书签[\s\S]*|Please login to bookmark|Close|登录|找回密码)$/;

function paragraphs(html) {
  var text = String(html || '');
  var matched;
  var pattern = /<p[^>]*>([\s\S]*?)<\/p>/gi;
  var lines = [];
  while ((matched = pattern.exec(text)) !== null) {
    var line = plain(matched[1]);
    if (!line) continue;
    if (JUNK_LINE.test(line)) continue;
    if (/^Copyright\s*©/i.test(line)) continue;
    if (/只限年满18岁|只限年满十八岁/.test(line)) continue;
    if (/^警告[:：]/.test(line)) continue;
    lines.push(line);
  }
  return lines;
}

function contentImages(html) {
  var text = String(html || '');
  var pattern = /<img[^>]+src="([^"]+)"/gi;
  var seen = {};
  var images = [];
  var matched;
  while ((matched = pattern.exec(text)) !== null) {
    var url = decode(matched[1]).trim();
    if (!url || seen[url]) continue;
    if (/avatar|emoji|smiley|spinner/i.test(url)) continue;
    seen[url] = true;
    images.push(url);
  }
  return images;
}

function contentText(html) {
  var lines = paragraphs(html);
  // 首行是「书名 作者：X」，详情页已经显示过，整行丢掉。
  if (lines.length && /作者[:：]/.test(lines[0])) lines.shift();
  return lines.join('\n\n').trim();
}

function authorOf(html) {
  var match = /作者[:：]\s*([^\s<]{1,40})/.exec(plain(html));
  return match ? match[1].trim() : '';
}

var LumeSource = {
  categories() {
    return CATEGORIES.slice();
  },

  async home() {
    var hot = await api('/tags?orderby=count&order=desc&per_page=12&_fields=id,name,count');
    var latest = await api('/posts?per_page=24&orderby=date&order=desc&_fields=id,title,tags,featured_media');

    var sections = [];
    var hotList = hot.data && hot.data.length ? hot.data : [];
    if (hotList.length) {
      var items = [];
      for (var i = 0; i < hotList.length; i++) items.push(bookItem(hotList[i]));
      sections.push({ title: '热门书库', moreUrl: 'all', items: items });
    }
    var posts = latest.data && latest.data.length ? latest.data : [];
    if (posts.length) {
      var books = await postsToBooks(posts);
      if (books.length) sections.push({ title: '最新更新', moreUrl: 'latest', items: books });
    }
    if (!sections.length) throw new Error('狂人之家首页没解析出内容（站方可能改版）');
    return sections;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Math.floor(Number(args.page) || 1));
    var keyword = String(args.keyword || '').trim();
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();

    if (keyword) {
      var found = await api(
        '/tags?search=' + encodeURIComponent(keyword) +
        '&orderby=count&order=desc&per_page=24&page=' + page + '&_fields=id,name,count'
      );
      var tagList = found.data && found.data.length ? found.data : [];
      var items = [];
      for (var i = 0; i < tagList.length; i++) items.push(bookItem(tagList[i]));
      return { items: items, hasMore: totalPages(found) > page };
    }

    if (!categoryId || categoryId === 'all') {
      var library = await api(
        '/tags?orderby=count&order=desc&per_page=24&page=' + page + '&_fields=id,name,count'
      );
      var books = library.data && library.data.length ? library.data : [];
      var libraryItems = [];
      for (var k = 0; k < books.length; k++) libraryItems.push(bookItem(books[k]));
      return { items: libraryItems, hasMore: totalPages(library) > page };
    }

    // latest 走全站文章；其余按分类 id 过滤（分类 id 必须是数字，否则退回 latest）。
    var query = '/posts?orderby=date&order=desc&per_page=30&page=' + page +
      '&_fields=id,title,tags,featured_media';
    if (categoryId !== 'latest' && /^\d+$/.test(categoryId)) {
      query += '&categories=' + categoryId;
    }
    var feed = await api(query);
    var posts = feed.data && feed.data.length ? feed.data : [];
    var grouped = await postsToBooks(posts);
    if (!grouped.length && page === 1) {
      throw new Error('这个分类没解析出书（站方可能改版）：' + categoryId);
    }
    var pagesTotal = totalPages(feed);
    return {
      items: grouped,
      hasMore: pagesTotal ? pagesTotal > page : posts.length >= 30,
    };
  },

  async detail(argument) {
    var tagId = tagIdOf(argument && argument.id);
    if (!tagId) return null;

    var meta = await api('/tags/' + tagId + '?_fields=id,name,count,description');
    if (meta.status === 404 || !meta.data || !meta.data.id) return null;
    var tag = meta.data;
    var count = Number(tag.count) || 0;
    var title = plain(tag.name) || ('书 ' + tagId);

    // 取最近两篇：分类/作者都在文章里，但早期的篇没有「书名作者：X」这行，
    // 新篇几乎都有，所以从新往旧找两篇就够（每篇约 12–60 KB）。
    var recent = await api(
      '/posts?tags=' + tagId + '&per_page=2&orderby=date&order=desc&_fields=id,title,categories,content,featured_media'
    );
    var posts = recent.data && recent.data.length ? recent.data : [];
    var author = '';
    var category = '';
    var mediaId = '';
    for (var p = 0; p < posts.length; p++) {
      if (!mediaId && Number(posts[p].featured_media) > 0) mediaId = String(posts[p].featured_media);
      if (!author) author = authorOf(posts[p].content && posts[p].content.rendered);
      if (!category && posts[p].categories && posts[p].categories.length) {
        var names = [];
        for (var i = 0; i < posts[p].categories.length; i++) {
          var name = CATEGORY_NAMES[String(posts[p].categories[i])];
          if (name) names.push(name);
        }
        category = names.join(' / ');
      }
    }

    var lines = [];
    if (category) lines.push('分类：' + category);
    if (author) lines.push('作者：' + author);
    lines.push('共 ' + count + ' 篇（站点把几章合成一篇发布）');
    if (category === 'AI美图共享') lines.push('这是一组图集，打开章节看图片');
    lines.push('站点：狂人之家书屋（18+，免登录）');

    var subtitle = (category ? category + ' · ' : '') + '共 ' + count + ' 篇';
    var result = {
      id: 't:' + tagId,
      title: title,
      subtitle: subtitle,
      description: lines.join('\n'),
      mediaType: 'novel',
    };
    if (mediaId) {
      var mediaMap = await loadMedia([mediaId]);
      if (mediaMap[mediaId]) result.cover = mediaMap[mediaId];
    }
    return result;
  },

  async chapters(argument) {
    var tagId = tagIdOf(argument && argument.id);
    if (!tagId) return [];
    var meta = await api('/tags/' + tagId + '?_fields=id,name,count');
    if (meta.status === 404 || !meta.data || !meta.data.id) return [];
    var bookTitle = plain(meta.data.name);
    var count = Number(meta.data.count) || 0;

    var pages = count > 0 ? Math.ceil(count / 100) : 1;
    if (pages > MAX_CHAPTER_PAGES) pages = MAX_CHAPTER_PAGES;

    var list = [];
    var seen = {};
    for (var page = 1; page <= pages; page++) {
      var res = await api(
        '/posts?tags=' + tagId + '&per_page=100&page=' + page +
        '&orderby=date&order=asc&_fields=id,title'
      );
      var posts = res.data && res.data.length ? res.data : [];
      for (var i = 0; i < posts.length; i++) {
        var id = String(posts[i].id);
        if (seen[id]) continue;
        seen[id] = true;
        var title = plain(posts[i].title && posts[i].title.rendered);
        if (bookTitle && title.indexOf(bookTitle) === 0) {
          title = title.slice(bookTitle.length).replace(/^[\s·:：\-–—]+/, '').trim();
        }
        if (!title) title = '第 ' + (list.length + 1) + ' 篇';
        list.push({ id: id, title: title });
      }
      if (posts.length < 100) break;
    }
    return list;
  },

  async content(argument) {
    var args = argument || {};
    var tagId = tagIdOf(args.id);
    if (!tagId) throw new Error('缺少书籍 ID（应形如 t:<tagId>）');

    var chapterId = /^\d+$/.test(String(args.chapterId == null ? '' : args.chapterId))
      ? String(args.chapterId)
      : '';
    if (!chapterId) {
      var first = await this.chapters({ id: 't:' + tagId });
      if (!first.length) throw new Error('这本书没有章节');
      chapterId = first[0].id;
    }

    var res = await api('/posts/' + chapterId + '?_fields=id,title,content,categories,tags,link');
    if (res.status === 404 || !res.data || !res.data.id) throw new Error('这一篇不存在或已下架');
    var post = res.data;
    var html = post.content && post.content.rendered ? post.content.rendered : '';

    var images = contentImages(html);
    var text = contentText(html);
    if (images.length >= 3 && text.length < 200) {
      return { kind: 'images', images: images };
    }
    if (!text || text.length < 20) {
      if (images.length) return { kind: 'images', images: images };
      throw new Error('这一篇没解析出正文（可能被站方改了结构）');
    }
    return { kind: 'text', text: text };
  },
};
