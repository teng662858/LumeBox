// LumeSource: {"id":"daniao5_comic","name":"大鸟禁漫","version":"2.0.0","category":"comic"}

var BASE_URL = 'https://daniao5.com';

var LumeSource = {
  id: 'daniao5_comic',
  name: '大鸟禁漫',
  version: '2.0.0',
  category: 'comic',

  async categories() {
    return [{ id: 'new', title: '最新更新' }, { id: 'rank', title: '排行榜' }];
  },

  /// 首页（可选契约，用户口径任务 3）：多板块模式——每块一行横向滑动。
  ///
  /// 标题由本脚本给出（App 不硬编码）；`moreUrl` 是「更多」的标识，用户在首页点
  /// 「更多」时 App 会带着它回头调 `list({categoryId: 'moreUrl'})`——这里直接复用
  /// 本站自己的分类 id（`new` / `rank`），所以「更多」进来就是同一个列表的分页。
  async home() {
    var boards = [];
    var fresh = await this.list({ categoryId: 'new', page: 1 });
    if (fresh && fresh.items && fresh.items.length) {
      boards.push({ title: '最新更新', moreUrl: 'new', items: fresh.items.slice(0, 12) });
    }
    var rank = await this.list({ categoryId: 'rank', page: 1 });
    if (rank && rank.items && rank.items.length) {
      boards.push({ title: '排行榜', moreUrl: 'rank', items: rank.items.slice(0, 12) });
    }
    return boards;
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var category = argument && argument.categoryId ? String(argument.categoryId) : 'new';
    var path = category === 'rank' ? '/manga-rank' : '/new-manga';
    var url = BASE_URL + path + (page > 1 ? '?page=' + page : '');
    var html = await this.__get(url);
    var items = [], pattern = /<a\s+class="(?:wbalist_thumb|vodlist_thumb)[^"]*"\s+href="\/manga-detail\/(\d+)"\s+title="([^"]+)"[^>]*?(?:style="background-image:url\(([^)]+)\)"|data-original="([^"]+)")/g, match;
    while ((match = pattern.exec(html)) !== null) {
      items.push({ id: match[1], title: match[2], cover: this.__absolute(match[3] || match[4]), subtitle: '大鸟禁漫' });
    }
    if (category === 'rank' && !items.length) {
      // 排行榜的详情链接没有统一的属性顺序：带封面的条目通常是
      // `title` 在 `href` 前，后续条目还可能没有 `title` 属性或封面。
      // 按锚点块解析可以同时覆盖这几种页面写法，避免把属性顺序当成协议。
      var rankPattern = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
      while ((match = rankPattern.exec(html)) !== null) {
        var attributes = match[1];
        var block = match[2];
        var idMatch = /\bhref\s*=\s*["']\/manga-detail\/(\d+)["']/i.exec(attributes);
        if (!idMatch) continue;

        var title = this.__match(attributes, /\btitle\s*=\s*["']([^"']*)["']/i);
        if (!title) {
          title = this.__match(block, /<h[1-6]\b[^>]*class\s*=\s*["'][^"']*\btitle\b[^"']*["'][^>]*>([\s\S]*?)<\/h[1-6]>/i);
        }
        if (!title) {
          // 简化条目把标题作为锚点的直接文本，并把名次 / 热门标记放在 span 中。
          var textBlock = block
            .replace(/<span\b[^>]*class\s*=\s*["'][^"']*\bpart_nums\b[^"']*["'][^>]*>[\s\S]*?<\/span>/gi, '')
            .replace(/<span\b[^>]*class\s*=\s*["'][^"']*\brenqi\b[^"']*["'][^>]*>[\s\S]*?<\/span>/gi, '');
          title = this.__clean(textBlock);
        }
        title = this.__clean(title);
        if (!title) continue;

        var cover = this.__match(block, /\bdata-original\s*=\s*["']([^"']+)["']/i);
        items.push({ id: idMatch[1], title: title, cover: this.__absolute(cover), subtitle: '大鸟禁漫' });
      }
    }
    return { items: items, hasMore: /(?:class="[^"]*(?:next|下一页)[^"]*"|下一页)/.test(html) };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var html = await this.__get(BASE_URL + '/manga-detail/' + encodeURIComponent(id));
    var title = this.__match(html, /<h1[^>]*class="title"[^>]*>([\s\S]*?)<\/h1>/);
    var cover = this.__match(html, /class="vodlist_thumb[^>]+data-original="([^"]+)"/);
    var description = this.__match(html, /<li[^>]*>[\s\S]*?<span[^>]*>简介：<\/span>([\s\S]*?)<\/li>/);
    return { id: id, title: this.__clean(title || '未知标题'), cover: this.__absolute(cover), subtitle: '大鸟禁漫', description: this.__clean(description) };
  },

  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var html = await this.__get(BASE_URL + '/manga-detail/' + encodeURIComponent(id));
    var chapters = [], pattern = /<li>\s*<a\s+href="(\/manga-read\/\d+\/[^" ]+)"[^>]*>([^<]+)<\/a>\s*<\/li>/g, match;
    while ((match = pattern.exec(html)) !== null) chapters.push({ id: match[1], title: match[2].trim() });
    return chapters;
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    var url = chapterId.indexOf('http') === 0 ? chapterId : BASE_URL + chapterId;
    var html = await this.__get(url);
    var images = [], pattern = /<img[^>]+data-src="([^"]+)"[^>]*>/g, match;
    while ((match = pattern.exec(html)) !== null) images.push(this.__absolute(match[1]));
    if (!images.length) throw new Error('该章节没有图片：' + chapterId);
    return { kind: 'images', images: images };
  },

  async __get(url) {
    var response = await LumeSource.http.get(url);
    if (!response || response.status !== 200) throw new Error('拉取失败：HTTP ' + (response ? response.status : 0));
    return response.body || '';
  },

  __absolute(url) {
    url = String(url || '').trim();
    if (!url) return '';
    if (url.indexOf('http://') === 0 || url.indexOf('https://') === 0) return url;
    return BASE_URL + (url.charAt(0) === '/' ? url : '/' + url);
  },

  __match(text, pattern) {
    var match = pattern.exec(text);
    return match ? match[1].trim() : '';
  },

  __clean(text) {
    return String(text || '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
  }
};
