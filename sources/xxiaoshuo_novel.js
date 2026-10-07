// LumeSource: {"id":"xxiaoshuo_novel","name":"X小说","version":"1.0.0","category":"novel"}

// 站点：https://book.xn--x-ny6am91b6ug0se.com （X小说.com，服务端渲染 HTML，Cloudflare 前置）
//
// 结构（2026-10-08 实测直连可用；列表/正文都不需要过验证，若被 CF 拦则抛
// NEED_WEBVIEW_VERIFY，用 App 内置网页视图过一次校验即可）：
//   · 列表：`/books/page/{n}`（从 1 开始）；分类 `/category/{id}/page/{n}`。
//     条目在 `ul` 的 `li.book-item` 里，有两种形态：
//       - 单篇作品：`a[href="/read/{bookId}/{chapterId}"]`（直接就是正文页）；
//       - 连载作品：`a[href="/book/{bookId}"]`。
//     本脚本统一把 id 记成 `read:{bookId}:{chapterId}` 或 `book:{bookId}`，
//     详情/章节据此分派，避免只看 `/book` 而漏掉大量单篇。
//   · 搜索：`/search?q={关键词}&page={n}`。
//   · 详情：`/book/{bookId}`，标题 `h1.book-heading`，副标题 `p.book-description`，
//     章节在 `ul.chapter-grid a[href="/read/{bookId}/{chapterId}"]`。
//   · 正文：`/read/{bookId}/{chapterId}`，正文在 `div.reader-body#bookcontent`，
//     正文里有站点注入的 `<span class="brand-mark">` 广告句，读的时候剥掉。
//
// 单篇作品的 detail/chapters 直接由列表页信息 + 正文页拼出来（没有独立详情页）。

var BASE_URL = 'https://book.xn--x-ny6am91b6ug0se.com';
var PAGE_SIZE = 20;

var LumeSource = {
  id: 'xxiaoshuo_novel',
  name: 'X小说',
  version: '1.0.0',
  category: 'novel',

  async categories() {
    return [
      { id: 'books', title: '全部小说' },
      { id: 'category-1', title: '短篇情色' },
      { id: 'category-2', title: '长篇情色' },
      { id: 'category-3', title: '人妻美妇' },
      { id: 'category-8', title: '都市小说' },
      { id: 'category-11', title: '奇幻小说' },
      { id: 'category-23', title: '粗野性交' },
      { id: 'category-48', title: '学生校园' }
    ];
  },

  async home() {
    var boards = [];
    var latest = await this.list({ categoryId: 'books', page: 1 });
    if (latest && latest.items && latest.items.length) {
      boards.push({ title: '最新收录', moreUrl: 'books', items: latest.items.slice(0, 12) });
    }
    var series = await this.list({ categoryId: 'category-2', page: 1 });
    if (series && series.items && series.items.length) {
      boards.push({ title: '长篇情色', moreUrl: 'category-2', items: series.items.slice(0, 12) });
    }
    return boards;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : 'books';

    var url;
    if (keyword) {
      url = BASE_URL + '/search?q=' + this.__encode(keyword) + (page > 1 ? '&page=' + page : '');
    } else {
      url = BASE_URL + this.__listPath(category, page);
    }
    var html = await this.__get(url);
    var items = this.__listItems(html);
    return { items: items, hasMore: this.__hasNextPage(html) };
  },

  async detail(argument) {
    var ref = this.__ref(argument);
    if (ref.kind === 'read') {
      // 单篇：没有独立详情页，用正文页与列表页信息拼一个最小详情。
      var read = await this.__get(BASE_URL + ref.path);
      var meta = this.__readMeta(read);
      var body = this.__body(read);
      return {
        id: this.__encodeRef(ref),
        title: meta.title || String(ref.chapterId),
        cover: '',
        subtitle: meta.book || '',
        description: this.__excerpt(body)
      };
    }

    var html = await this.__get(BASE_URL + '/book/' + encodeURIComponent(ref.bookId));
    var title = this.__clean(this.__match(html, /<h1[^>]*class="[^"]*book-heading[^"]*"[^>]*>([\s\S]*?)<\/h1>/));
    if (!title) title = this.__clean(this.__match(html, /<h1[^>]*>([\s\S]*?)<\/h1>/));
    if (!title) return null;
    var subtitle = this.__clean(this.__match(html, /<p[^>]*class="[^"]*book-description[^"]*"[^>]*>([\s\S]*?)<\/p>/));
    subtitle = subtitle.replace(/章节目录/g, '').replace(/^[·\s]+|[·\s]+$/g, '').trim();
    var chapters = this.__chapterLinks(html);
    return {
      id: this.__encodeRef(ref),
      title: title,
      cover: '',
      subtitle: subtitle,
      description: chapters.length ? ('共 ' + chapters.length + ' 章' + (subtitle ? ' · ' + subtitle : '')) : subtitle
    };
  },

  async chapters(argument) {
    var ref = this.__ref(argument);
    if (ref.kind === 'read') {
      return [{ id: String(ref.chapterId), title: ref.title || '正文' }];
    }
    var html = await this.__get(BASE_URL + '/book/' + encodeURIComponent(ref.bookId));
    var chapters = this.__chapterLinks(html);
    if (!chapters.length) throw new Error('X小说：该作品没有可阅读的章节');
    return chapters.map(function (item, index) {
      var title = item.title || '';
      if (!title || title.indexOf('开始阅读') >= 0 || title.indexOf('章节目录') >= 0) {
        title = '第' + (index + 1) + '章';
      }
      return { id: String(item.chapterId), title: title };
    });
  },

  async content(argument) {
    var ref = this.__ref(argument);
    var chapterId = argument && argument.chapterId != null ? String(argument.chapterId) : '';
    if (chapterId.indexOf('/') >= 0) {
      // 兼容旧式整路径 chapterId。
      var pieces = chapterId.split('/');
      ref.kind = 'read';
      ref.bookId = pieces[0];
      chapterId = pieces[1];
    }
    if (!chapterId) chapterId = String(ref.chapterId || '');
    if (!chapterId) throw new Error('X小说：缺少章节 ID（请先选择一章）');

    var url = BASE_URL + '/read/' + encodeURIComponent(ref.bookId) + '/' + encodeURIComponent(chapterId);
    var html = await this.__get(url);
    var text = this.__body(html);
    if (!text) throw new Error('X小说：该章节内容为空');
    return { kind: 'text', text: text };
  },

  /// 从正文页 HTML 里取 `#bookcontent` 并转成纯文本。
  __body(html) {
    var body = this.__match(html, /<div[^>]*class="[^"]*reader-body[^"]*"[^>]*id="bookcontent"[^>]*>([\s\S]*?)<\/div>/);
    if (!body) body = this.__match(html, /<div[^>]*id="bookcontent"[^>]*>([\s\S]*?)<\/div>/);
    if (!body) return '';
    return this.__text(body);
  },

  // ---------------------------------------------------------------- 内部工具

  /// 归一化 id：`book:{bookId}` 或 `read:{bookId}:{chapterId}`。
  __ref(argument) {
    var raw = '';
    if (argument && argument.id != null) raw = String(argument.id);
    else if (argument && argument.bookId != null) raw = 'book:' + String(argument.bookId);
    if (!raw) throw new Error('X小说：缺少作品 ID');

    if (raw.indexOf('book:') === 0) {
      return { kind: 'book', bookId: raw.slice(5), path: '', chapterId: '', title: '' };
    }
    if (raw.indexOf('read:') === 0) {
      var pieces = raw.slice(5).split(':');
      return {
        kind: 'read',
        bookId: pieces[0] || '',
        chapterId: pieces[1] || '',
        path: '/read/' + pieces[0] + '/' + pieces[1],
        title: argument && argument.title ? String(argument.title) : ''
      };
    }
    // 纯 bookId。
    return { kind: 'book', bookId: raw, path: '', chapterId: '', title: '' };
  },

  __encodeRef(ref) {
    if (ref.kind === 'read') return 'read:' + ref.bookId + ':' + ref.chapterId;
    return 'book:' + ref.bookId;
  },

  __listPath(category, page) {
    var value = String(category || 'books');
    var base;
    if (value.indexOf('category-') === 0) base = '/category/' + value.slice(9);
    else base = '/books';
    // 第 1 页就是列表本身；`/page/1` 会被 301 回列表根。
    return page > 1 ? base + '/page/' + page : base;
  },

  __listItems(html) {
    var items = [];
    var seen = {};
    var pattern = /<li class="book-item">([\s\S]*?)<\/li>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var block = match[1];
      var readMatch = /href="\/read\/([0-9a-f]+)\/(\d+)"/.exec(block);
      var bookMatch = /href="\/book\/([0-9a-f]+)"/.exec(block);
      var title = this.__clean(this.__match(block, /<h2>\s*<a[^>]*>([\s\S]*?)<\/a>/));
      if (!title) title = this.__clean(this.__match(block, /<a[^>]+title="([^"]*)"/));
      var meta = this.__clean(this.__match(block, /<p class="book-meta">([\s\S]*?)<\/p>/));
      var count = this.__match(block, /<span>([^<]*?)(?:话|章)[^<]*<\/span>/);

      var id;
      if (bookMatch) id = 'book:' + bookMatch[1];
      else if (readMatch) id = 'read:' + readMatch[1] + ':' + readMatch[2];
      else continue;
      if (seen[id]) continue;
      seen[id] = true;
      items.push({
        id: id,
        title: title || id,
        cover: '',
        subtitle: count ? count + ' 章' : meta
      });
    }
    return items;
  },

  __chapterLinks(html) {
    var chapters = [];
    var seen = {};
    var pattern = /href="\/read\/([0-9a-f]+)\/(\d+)"[^>]*>([\s\S]{0,60}?)<\/a>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var key = match[1] + ':' + match[2];
      if (seen[key]) continue;
      seen[key] = true;
      chapters.push({
        bookId: match[1],
        chapterId: match[2],
        title: this.__clean(match[3])
      });
    }
    return chapters;
  },

  /// 正文页里的书名/标题/简介（read 页面里一个内联 JSON）。
  __readMeta(html) {
    var meta = {};
    var json = this.__match(html, /\{"book":"[^"]*"[\s\S]*?\}/);
    if (json) {
      try {
        var parsed = JSON.parse(json);
        meta.book = String(parsed.book || '');
        meta.chapter = String(parsed.chapter || '');
        meta.title = String(parsed.chapterTitle || parsed.title || '');
      } catch (error) { /* 解析不了就算了 */ }
    }
    if (!meta.title) {
      meta.title = this.__clean(this.__match(html, /<h1[^>]*class="[^"]*reader-heading[^"]*"[^>]*>([\s\S]*?)<\/h1>/));
    }
    if (!meta.book) {
      meta.book = this.__clean(this.__match(html, /<p[^>]*class="[^"]*reader-work[^"]*"[^>]*>([\s\S]*?)<\/p>/));
    }
    return meta;
  },

  /// 正文 → 纯文本：按 <p>/<br> 断行，剥掉站点注入的 brand-mark 广告 span。
  __text(html) {
    var text = String(html || '');
    text = text.replace(/<span[^>]*class="[^"]*brand-mark[^"]*"[^>]*>[\s\S]*?<\/span>/gi, '');
    text = text.replace(/<\s*br\s*\/?>/gi, '\n');
    text = text.replace(/<\/\s*p\s*>/gi, '\n');
    text = text.replace(/<[^>]+>/g, '');
    text = text
      .replace(/&nbsp;/g, ' ')
      .replace(/&hellip;/g, '…')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>');
    text = text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    // 去掉文末站点的「下集…」引导句（单独一行）。
    text = text.replace(/\n?\s*[（(]?\s*(下集[预]?告?|下一页|下一章)\s*[)）]?\s*…?\s*$/, '');
    return text.trim();
  },

  __excerpt(text) {
    var line = String(text || '').split('\n')[0].replace(/\s+/g, ' ').trim();
    return line.length > 120 ? line.slice(0, 120) + '…' : line;
  },

  __hasNextPage(html) {
    return /rel="next"|下一[页章]/i.test(html);
  },

  __encode(text) {
    var str = String(text);
    var out = '';
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code < 0x80) {
        if (/[A-Za-z0-9\-_.~]/.test(str.charAt(i))) out += str.charAt(i);
        else out += '%' + ('0' + code.toString(16)).slice(-2).toUpperCase();
      } else {
        var bytes = this.__utf8(str.charAt(i));
        for (var j = 0; j < bytes.length; j++) {
          out += '%' + ('0' + bytes[j].toString(16)).slice(-2).toUpperCase();
        }
      }
    }
    return out;
  },

  __utf8(text) {
    var str = String(text);
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code < 0x80) bytes.push(code);
      else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      else bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
    return bytes;
  },

  async __get(url) {
    var response = await LumeSource.http.get(url, {
      headers: { 'Referer': BASE_URL + '/' }
    });
    if (!response || response.status !== 200) {
      var status = response ? response.status : 0;
      var body = response && response.body ? String(response.body) : '';
      if ((status === 403 || status === 503 || status === 429) &&
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated|checking your browser/i.test(body)) {
        throw new Error('NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP ' + status + '）');
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + url);
    }
    return response.body || '';
  },

  __match(text, pattern) {
    var match = pattern.exec(text);
    if (!match || match[1] == null) return '';
    return String(match[1]).trim();
  },

  __clean(text) {
    return String(text || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&hellip;/g, '…')
      .replace(/\s+/g, ' ')
      .trim();
  }
};
