// LumeSource: {"id":"p5mh_comic","name":"P5漫画","version":"1.0.0","category":"comic"}

// 站点：https://www3.6p5mh3.click （P5韩漫，服务端渲染 HTML，站点简称 p5mh）
//
// 结构（2026-10-08 实测直连可用，无需 Cookie/无需过验证）：
//   · 列表：`/booklist?page={n}`（分页从 1 开始）；也可叠加筛选
//     `/booklist?page={n}&area={a}&end={e}`（2026-10-08 实测：
//     area=1 韩国漫画可用、area=2 同「全部」、end=1 完结优选可用；
//     站点本身没有可见筛选条，只有详情页/首页的少量入口链接）。
//     条目在 `ul.mh-list > li > .mh-item`：
//     `a[href="/book/{id}"]` + title + 封面在 `p.mh-cover` 的 data-original。
//   · 搜索：`/search?keyword={关键词}`（结果同样在 `ul.mh-list`）。
//   · 详情：`/book/{id}`，标题 `h1`，封面 `img`（imgBridge 代理），
//     简介是 `p.content`，状态/地区/更新时间在 `p.tip`，章节在
//     `a[href^="/chapter/"]`（首个是「开始阅读」，按 href 去重）。
//   · 章节：`/chapter/{chapterId}`，图片是 `img.lazy[data-original]`（懒加载，
//     真实地址在 data-original，走 cfpic 的 imgBridge 代理，实测无 Referer 也能取）。
//     **一章可能分多页**：`?page=N`，用 `#nextPage` 是否存在判断要不要继续翻，
//     每页 15 张，逐页拼起来再返回。
//
// 图片地址已是绝对地址；相对地址仍统一用 __absolute 兜底。

var BASE_URL = 'https://www3.6p5mh3.click';
var PAGE_SIZE = 36;
var MAX_CHAPTER_PAGES = 20;

var LumeSource = {
  id: 'p5mh_comic',
  name: 'P5漫画',
  version: '1.0.0',
  category: 'comic',

  async categories() {
    return [
      { id: '', title: '全部' },
      { id: 'area-1', title: '韩国漫画' },
      { id: 'area-2', title: '其他地区' },
      { id: 'end-1', title: '完结优选' }
    ];
  },

  async home() {
    var boards = [];
    var latest = await this.list({ categoryId: '', page: 1 });
    if (latest && latest.items && latest.items.length) {
      boards.push({ title: '最近更新', moreUrl: '', items: latest.items.slice(0, 12) });
    }
    var done = await this.list({ categoryId: 'end-1', page: 1 });
    if (done && done.items && done.items.length) {
      boards.push({ title: '完结优选', moreUrl: 'end-1', items: done.items.slice(0, 12) });
    }
    return boards;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';

    var url;
    if (keyword) {
      url = BASE_URL + '/search?keyword=' + this.__encode(keyword) + (page > 1 ? '&page=' + page : '');
    } else {
      var query = this.__categoryQuery(category);
      url = BASE_URL + '/booklist?page=' + page + (query ? '&' + query : '');
    }
    var html = await this.__get(url);
    var items = this.__listItems(html);
    return { items: items, hasMore: this.__hasNextPage(html, page) };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var html = await this.__get(BASE_URL + '/book/' + encodeURIComponent(id));
    var title = this.__clean(this.__match(html, /<h1[^>]*>([\s\S]*?)<\/h1>/));
    if (!title) return null;
    var cover = this.__match(html, /class="mh-cover lazy"[^>]*data-original="([^"]+)"/);
    if (!cover) cover = this.__match(html, /<img[^>]+data-original="([^"]+)"/);
    var description = this.__clean(this.__match(html, /<p class="content"[^>]*>([\s\S]*?)<\/p>/));
    var alias = this.__clean(this.__match(html, /<p class="subtitle">别名[：:]([\s\S]*?)<\/p>/));
    var author = this.__clean(this.__match(html, /<p class="subtitle">作者[：:]([\s\S]*?)<\/p>/));
    var status = this.__clean(this.__match(html, /状态[：:]\s*<span>([\s\S]*?)<\/span>/));
    var area = this.__clean(this.__match(html, /地区[：:]\s*<a[^>]*>([\s\S]*?)<\/a>/));
    var updated = this.__clean(this.__match(html, /更新时间[：:]\s*([0-9\-]+)/));
    var tags = [];
    if (status) tags.push(status);
    if (area) tags.push(area);
    return {
      id: id,
      title: title,
      cover: this.__absolute(cover),
      subtitle: [author ? '作者：' + author : '', alias ? '别名：' + alias : ''].filter(function (t) { return t; }).join(' · '),
      description: description,
      tags: tags,
      extra: {
        author: author,
        alias: alias,
        status: status,
        area: area,
        updated: updated
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var html = await this.__get(BASE_URL + '/book/' + encodeURIComponent(id));
    var chapters = [];
    var seen = {};
    var pattern = /href="(\/chapter\/(\d+))"[^>]*>([\s\S]{0,40}?)<\/a>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var href = match[1];
      if (seen[href]) continue;
      seen[href] = true;
      var title = this.__clean(match[3]);
      if (!title || title.indexOf('开始阅读') >= 0) {
        title = '第' + (chapters.length + 1) + '话';
      }
      chapters.push({ id: href, title: title });
    }
    if (!chapters.length) throw new Error('P5漫画：该作品没有可阅读的章节');
    return chapters;
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!chapterId) throw new Error('P5漫画：缺少章节 ID（请先选择一话）');
    var path = chapterId.indexOf('http') === 0
      ? chapterId
      : this.__absolute(chapterId);

    var images = [];
    var seen = {};
    for (var page = 1; page <= MAX_CHAPTER_PAGES; page++) {
      var url = path + (page > 1 ? (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page : '');
      var html = await this.__get(url);
      var found = this.__images(html);
      for (var i = 0; i < found.length; i++) {
        if (!seen[found[i]]) { seen[found[i]] = true; images.push(found[i]); }
      }
      // 没有「下一页」就说明这一话结束了。
      if (!/id="nextPage"/.test(html) || !found.length) break;
    }
    if (!images.length) throw new Error('P5漫画：该话没有图片');
    return { kind: 'images', images: images };
  },

  // ---------------------------------------------------------------- 内部工具

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.bookId != null) id = String(argument.bookId);
    if (!id) throw new Error('P5漫画：缺少作品 ID');
    return id;
  },

  /// 分类 id 是 `area-N` / `end-N` / 空（全部），转成书单页的查询串。
  __categoryQuery(category) {
    var value = String(category || '');
    if (!value) return '';
    var parts = value.split('-');
    if (parts.length === 2 && (parts[0] === 'area' || parts[0] === 'end')) {
      return parts[0] + '=' + parts[1];
    }
    return '';
  },

  /// 列表条目。
  ///
  /// **站点改过版**（2026-10-08 实测）：旧的 `ul.mh-list > li > div.mh-item` 已经
  /// 全部消失，现在是 `ul.manga-list-2 > li > div.manga-list-2-cover > a[href=/book/id]`
  /// + 封面在 `img[data-original]`。这里两种都认（先新后旧），改版不再等于「一个条目
  /// 都解析不出来」（真机表现就是「暂无首页推荐内容」）。
  __listItems(html) {
    var items = [];
    var seen = {};
    var patterns = [
      /<div class="manga-list-2-cover">\s*<a href="(\/book\/(\d+))"[^>]*title="([^"]*)"[\s\S]*?data-original="([^"]*)"/g,
      /<li>\s*<div class="mh-item">\s*<a href="(\/book\/(\d+))" title="([^"]*)"[\s\S]*?data-original="([^"]*)"/g
    ];
    for (var p = 0; p < patterns.length; p++) {
      var match;
      while ((match = patterns[p].exec(html)) !== null) {
        var id = match[2];
        if (seen[id]) continue;
        seen[id] = true;
        items.push({
          id: id,
          title: this.__clean(match[3]),
          cover: this.__absolute(match[4]),
          subtitle: this.__itemSubtitle(html, match.index)
        });
      }
    }
    return items;
  },

  __itemSubtitle(html, from) {
    var tail = html.slice(from, from + 1400);
    // 新结构：条目里一般带「第 N 话」「更新 2026-10-08」这类文本（没有再留空）。
    var update = this.__clean(this.__match(tail, /(更新[^<]{0,18})</));
    if (update) return update;
    var count = this.__clean(this.__match(tail, /(第\s*\d+\s*[话章])/));
    if (count) return count;
    var state = this.__clean(this.__match(tail, /<span class="(?:mh-state|state)[^"]*">([^<]*)</));
    if (!state) state = this.__clean(this.__match(tail, /<em[^>]*>([^<]*(?:连载|完结)[^<]*)<\/em>/));
    return state;
  },

  __images(html) {
    var images = [];
    var pattern = /<img[^>]*class="[^"]*lazy[^"]*"[^>]*data-original="([^"]+)"/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var url = this.__absolute(match[1]);
      if (url) images.push(url);
    }
    return images;
  },

  /// 还有没有下一页。
  ///
  /// 列表页**没有** `#nextPage` 标记（那是章节页的），它把页码链接写成
  /// `/booklist?page=N`：窗口里只要出现比当前页大的号就说明还有。
  __hasNextPage(html, page) {
    var current = page > 0 ? page : 1;
    var pattern = /booklist\?page=(\d+)/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      if (Number(match[1]) > current) return true;
    }
    return /id="nextPage"|下一[页章]/.test(html);
  },

  /// 关键词按 UTF-8 百分号编码（沙箱无 encodeURIComponent 时也能用）。
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

  __absolute(url) {
    var text = String(url || '').trim();
    if (!text) return '';
    if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) return text;
    if (text.indexOf('//') === 0) return 'https:' + text;
    return BASE_URL + (text.charAt(0) === '/' ? text : '/' + text);
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
