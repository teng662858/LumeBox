// LumeSource: {"id":"seyoumanhua_comic","name":"色友漫画","version":"1.0.0","category":"comic"}
//
// 站点：https://seyoumanhua.com（MacCMS 系，WAP 模板）
//
// 抓取口径（全部对**实时页面**核过，不是照着模板猜的）：
//   分类索引   GET /index.php/category/                        20 条/页，翻页 /index.php/category/page/N
//   分类列表   GET /index.php/category/list/<id>[/page/N]      分类 id 见 categories()
//   搜索       GET /index.php/search/index[/N]?keyword=…       注意：模板里的 /search.php 在这个域名上是 404，
//                                                              真正能用的是这条 index.php 路由
//   详情       GET /index.php/comic/<slug>                     og:title / og:image
//   章节       GET /index.php/comic/<slug>                     li.catalog_ceil 里的 <p class="name">
//   正文       GET /index.php/chapter/<id>                     div.comic_chapter_content 里的 img（data-original）
//
// 两个必须照做的站点怪癖（都是实测出来的，写错了就整页抓不到）：
//   1. **章节顺序**：站点把「最新一话」钉在目录首位（本轮实测：第22話 排在第1話 前面），
//      照原样读下来，阅读器「下一章」会从第21話 直接跳到第24話、把钉住的那话跳过。
//      因此这里**按标题里的编号重排**（见 __sortChapters），解析不出编号的条目
//      （例如「休刊公告」）保留原相对顺序放到末尾。
//   2. **图片走 https**：站点源码里混着 http:// 的图片地址，而 iOS 默认禁止明文
//      请求（ATS），原样返回等于图全裂。CDN 同一路径 https 可访问（实测同图同大小），
//      因此统一升级协议。
var BASE_URL = 'https://seyoumanhua.com';

var LumeSource = {
  id: 'seyoumanhua_comic',
  name: '色友漫画',
  version: '1.0.0',
  category: 'comic',

  async categories() {
    // 取自站点分类索引页（id 是站点自己的数字 id）。
    return [
      { id: 'all', title: '全部' },
      { id: '5', title: '都市' },
      { id: '6', title: '恋爱' },
      { id: '35', title: '出版漫画' },
      { id: '8', title: '校园' },
      { id: '9', title: '萝莉' },
      { id: '12', title: '正太' },
      { id: '13', title: '淫荡' },
      { id: '17', title: '正妹' },
      { id: '18', title: '肉慾' },
      { id: '19', title: '狗血劇' },
      { id: '20', title: '浪漫' },
      { id: '21', title: '大尺度' },
      { id: '22', title: '有夫之婦' },
      { id: '23', title: '女大生' },
      { id: '24', title: '同居' },
      { id: '25', title: '巨乳' },
      { id: '26', title: '調教' },
      { id: '27', title: '动作' },
      { id: '28', title: '不倫' },
      { id: '29', title: '耽美' },
      { id: '30', title: '好友' },
      { id: '31', title: '校園' },
      { id: '32', title: '3D' },
      { id: '33', title: '後宮' },
      { id: '34', title: '日漫' }
    ];
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';

    var url;
    if (keyword) {
      var query = '?keyword=' + encodeURIComponent(keyword);
      url = page > 1
        ? BASE_URL + '/index.php/search/index/' + page + query
        : BASE_URL + '/index.php/search/index' + query;
    } else if (category && category !== 'all') {
      url = BASE_URL + '/index.php/category/list/' + encodeURIComponent(category);
      if (page > 1) url += '/page/' + page;
    } else {
      url = BASE_URL + '/index.php/category/';
      if (page > 1) url += 'page/' + page;
    }

    var html = await this.__get(url);
    var items = this.__items(html);
    return { items: items, hasMore: this.__hasNext(html, page) };
  },

  async detail(argument) {
    var id = this.__id(argument);
    if (!id) return null;
    var html = await this.__get(BASE_URL + '/index.php/comic/' + encodeURIComponent(id));
    var title = this.__meta(html, 'og:title') || this.__match(html, /<title>([\s\S]*?)<\/title>/);
    title = this.__clean(String(title || id).split(' - ')[0]);
    return {
      id: id,
      title: title || id,
      cover: this.__upgrade(this.__meta(html, 'og:image') || ''),
      subtitle: this.__meta(html, 'og:author') || '',
      description: this.__clean(this.__meta(html, 'description') || '')
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    if (!id) return [];
    var html = await this.__get(BASE_URL + '/index.php/comic/' + encodeURIComponent(id));
    // 只认目录条目（li.catalog_ceil）：页面顶部那条「最新一话 / 开始阅读」不算目录。
    var pattern = /<a[^>]+href="(?:https:\/\/seyoumanhua\.com)?\/index\.php\/chapter\/(\d+)"[^>]*>\s*<li class="catalog_ceil">[\s\S]*?<p class="name">([\s\S]*?)<\/p>/g;
    var chapters = [];
    var seen = {};
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var chapterId = match[1];
      if (seen[chapterId]) continue;
      seen[chapterId] = true;
      chapters.push({ id: chapterId, title: this.__clean(match[2]) });
    }
    return this.__sortChapters(chapters);
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!chapterId) throw new Error('色友漫画：缺少章节 id');
    var html = await this.__get(BASE_URL + '/index.php/chapter/' + encodeURIComponent(chapterId));
    var images = [];
    // 每张图各自包在一个 .comic_chapter_content 里；data-original 是懒加载的原图，
    // src 通常同时被写成了同一个地址，取到哪个用哪个。
    var pattern = /<div class="comic_chapter_content">[\s\S]*?<img[^>]*?(?:data-original|src)="([^"]+)"/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var url = this.__upgrade(match[1]);
      if (url) images.push(url);
    }
    if (!images.length) throw new Error('色友漫画：这一章没有解析到图片（站点结构可能变了）');
    return { kind: 'images', images: images };
  },

  // ------------------------------------------------------------------ 内部

  /// 目录排序：见文件头的「站点怪癖 1」。
  ///
  /// 解析得出的键是 `[系列, 编号]`：正传 0、外傳/外传 1、最終話 视为该系列的最后。
  /// **只要有一条解析不出来就整体退回站点顺序**——不做半吊子排序（宁可顺序差一点，
  /// 也不要因为一条意外标题把整本书打乱）。
  __sortChapters(chapters) {
    var keyed = [];
    var loose = [];
    for (var i = 0; i < chapters.length; i++) {
      var key = this.__chapterKey(chapters[i].title);
      if (!key) {
        loose.push(chapters[i]);
        continue;
      }
      keyed.push({ order: key, item: chapters[i] });
    }
    if (loose.length && keyed.length === 0) return chapters;
    keyed.sort(function (a, b) {
      if (a.order[0] !== b.order[0]) return a.order[0] - b.order[0];
      return a.order[1] - b.order[1];
    });
    var sorted = keyed.map(function (entry) { return entry.item; });
    return sorted.concat(loose);
  },

  /// 从标题里读编号；读不出返回 null。
  __chapterKey(title) {
    var text = String(title || '').trim();
    var match = /^(外傳|外传)?第\s*(\d+)\s*[話话]/.exec(text);
    if (match) return [match[1] ? 1 : 0, Number(match[2])];
    if (text.indexOf('最終話') >= 0 || text.indexOf('最终话') >= 0) return [1, 1000000];
    return null;
  },

  /// 列表条目：分类页 / 搜索页 / 分类索引页共用同一套标记。
  __items(html) {
    var pattern = /<div class="comic_cover_container">\s*<a[^>]+href="(?:https:\/\/seyoumanhua\.com)?\/index\.php\/comic\/([a-z0-9_-]+)"[^>]*>\s*<div class="comic_cover[^"]*"[^>]*data-original="([^"]*)"[\s\S]*?<div class="comic_cover_title">([\s\S]*?)<\/div>/g;
    var items = [];
    var match;
    while ((match = pattern.exec(html)) !== null) {
      items.push({
        id: match[1],
        title: this.__clean(match[3]),
        cover: this.__upgrade(match[2]),
        subtitle: ''
      });
    }
    return items;
  },

  /// 还有下一页吗：站点翻页链接写成 `…/page/<N>`（分类）或 `…/index/<N>`（搜索），
  /// 两种都以「出现下一页的号码」为准。
  __hasNext(html, page) {
    var next = page + 1;
    return html.indexOf('/page/' + next) >= 0 || html.indexOf('/index/' + next) >= 0;
  },

  __id(argument) {
    var id = argument && argument.id ? String(argument.id).trim() : '';
    return id;
  },

  async __get(url) {
    var response = await LumeSource.http.get(url);
    if (!response || response.status !== 200) {
      throw new Error('拉取失败：HTTP ' + (response ? response.status : 0) + ' ' + url);
    }
    return response.body || '';
  },

  /// 读 meta 内容（og:title / og:image / description 都走它）。
  __meta(html, name) {
    var pattern = new RegExp('<meta[^>]*(?:property|name)="' + name + '"[^>]*content="([^"]*)"');
    var match = pattern.exec(html);
    if (match) return match[1];
    // 属性顺序反过来（content 在前）也要认。
    pattern = new RegExp('<meta[^>]*content="([^"]*)"[^>]*(?:property|name)="' + name + '"');
    match = pattern.exec(html);
    return match ? match[1] : '';
  },

  __match(text, pattern) {
    var match = pattern.exec(text);
    return match ? match[1] : '';
  },

  /// 图片地址统一升级到 https（见文件头的「站点怪癖 2」）。
  __upgrade(url) {
    var text = String(url || '').trim();
    if (!text) return '';
    if (text.indexOf('http://') === 0) return 'https://' + text.slice(7);
    if (text.indexOf('//') === 0) return 'https:' + text;
    return text;
  },

  __clean(text) {
    return String(text == null ? '' : text)
      .replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/g, ' ')
      .replace(/&quot;/g, '"')
      .replace(/&#8211;|&#8212;/g, '-')
      .replace(/&amp;/g, '&')
      .replace(/\s+/g, ' ')
      .trim();
  }
};
