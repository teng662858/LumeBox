// LumeSource: {"id":"xchina_novel","name":"xChina 小说","version":"1.0.0","category":"novel"}

// 站点：https://xchina.co （小黄书 xChina · 成人小说区）
//
// 重要：本站在 Cloudflare 后面，**列表页通常可直连**，但详情/正文页经常直接
// 返回 `403 + cf-mitigated: challenge`（浏览器校验页）。这种是“可复用 cookie 型”
// 挑战，App 会弹出内置网页视图让用户过一次校验、把 cf_clearance 之类 Cookie 存下来
// 复用，所以这里遇到就抛 `NEED_WEBVIEW_VERIFY`，交给上层触发网页视图。
// 站点需要代理才能访问（用户设备上已配置代理）。
//
// 结构（2026-10-08 实测，chrome131 指纹可通过）：
//   · 列表：`/fictions/{page}.html`（从 1 开始）。条目：
//     `div.item.fiction > a[href="/fiction/id-{hash}.html"]`，
//     标题在 `div.title`，简介 `div.brief`，封面 `style="background-image:url(...)"`。
//   · 分类（都是列表页）：
//     - 标签：`/fictions/tag-{n}.html`
//     - 作者/系列关键词：`/fictions/keyword-{name}.html`
//     - 按热度：`/fictions/sort-read/{p}.html`；按评论：`/fictions/sort-comment/{p}.html`
//     - 按篇幅：`/fictions/length-{1,2,3}/{p}.html`（短/中/长）
//   · 详情/目录页：`/fiction/id-{hash}.html`。有两种形态：
//     - 合集/长篇：有 `div.fiction-overview-chapters .chapter-container`，
//       每个章节是一个 `a[href="/fiction/id-{hash}.html"]`（各自独立页面），
//       标题在 `div.chapter-item`。
//     - 短篇：直接就是正文页（见下）。
//   · 正文页：`/fiction/id-{hash}.html`，正文在 `div.fiction-body`（多个 `<p>`）。
//
// id 约定：`series:{hash}`（目录页）/ `chapter:{hash}`（正文页）。列表项统一给
// `series:{hash}`；打开后如果发现其实是正文页，也能正常出内容。

var BASE_URL = 'https://xchina.co';
var PAGE_SIZE = 24;

var LumeSource = {
  id: 'xchina_novel',
  name: 'xChina 小说',
  version: '1.0.0',
  category: 'novel',

  async categories() {
    return [
      { id: '', title: '最新' },
      { id: 'sort-read', title: '按热度' },
      { id: 'sort-comment', title: '按评论' },
      { id: 'tag-1', title: '人妻女友' },
      { id: 'tag-2', title: '学生校园' },
      { id: 'tag-4', title: '都市生活' },
      { id: 'tag-102', title: '长篇连载' },
      { id: 'length-1', title: '短篇' },
      { id: 'length-3', title: '长篇' }
    ];
  },

  async home() {
    var boards = [];
    var latest = await this.list({ categoryId: '', page: 1 });
    if (latest && latest.items && latest.items.length) {
      boards.push({ title: '最新收录', moreUrl: '', items: latest.items.slice(0, 12) });
    }
    var hot = await this.list({ categoryId: 'sort-read', page: 1 });
    if (hot && hot.items && hot.items.length) {
      boards.push({ title: '热门阅读', moreUrl: 'sort-read', items: hot.items.slice(0, 12) });
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
      // 站内搜索是 `search.html?keyword=`（POST/GET 都行，这里走 GET + 列表兼容）。
      url = BASE_URL + '/search.html?keyword=' + this.__encode(keyword);
    } else {
      url = BASE_URL + '/' + this.__listPath(category, page);
    }
    var html = await this.__get(url);
    var items = this.__listItems(html);
    // 关键词搜索如果解析不到（可能是 JS 渲染），退回按作者/系列关键词目录页。
    if (keyword && !items.length) {
      var fallback = await this.__get(BASE_URL + '/fictions/keyword-' + this.__encode(keyword) + '.html');
      items = this.__listItems(fallback);
    }
    return { items: items, hasMore: this.__hasNextPage(html, page) };
  },

  async detail(argument) {
    var ref = this.__ref(argument);
    var html = await this.__get(BASE_URL + '/fiction/id-' + ref.hash + '.html');

    // 正文页（短篇）：直接给最小详情。
    if (!/fiction-overview-chapters|chapter-container/.test(html)) {
      var paragraphs = this.__paragraphs(html);
      var pageTitle = this.__clean(this.__match(html, /<div[^>]*class="[^"]*fiction-content[^"]*"[\s\S]*?<div[^>]*class="title"[^>]*>([\s\S]*?)<\/div>/));
      if (!pageTitle) pageTitle = this.__clean(this.__match(html, /<h1[^>]*class="[^"]*hero-title-item[^"]*"[^>]*>([\s\S]*?)<\/h1>/)).replace(/^《|》$/g, '');
      if (!paragraphs && !pageTitle) return null;
      return {
        id: 'chapter:' + ref.hash,
        title: pageTitle || ref.title || ref.hash,
        cover: '',
        subtitle: '',
        description: this.__excerpt(paragraphs)
      };
    }

    var title = this.__clean(this.__match(html, /<div[^>]*class="[^"]*fiction-overview-info-item title[^"]*"[^>]*>([\s\S]*?)<\/div>/));
    if (!title) title = this.__clean(this.__match(html, /<h1[^>]*class="[^"]*hero-title-item[^"]*"[^>]*>([\s\S]*?)<\/h1>/)).replace(/^《|》$/g, '');
    if (!title) return null;
    var cover = this.__match(html, /class="fiction-cover"[^>]*style="[^"]*url\(([^)]+)\)/);
    if (!cover) cover = this.__match(html, /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
    var author = this.__clean(this.__match(html, /作者[：:]\s*<a[^>]*>([\s\S]*?)<\/a>/));
    var series = this.__clean(this.__match(html, /系列[名]?[：:]\s*<a[^>]*>([\s\S]*?)<\/a>/));
    var wordCount = this.__clean(this.__match(html, /word-count[^>]*>字数[：:]\s*([^<]*)/));
    var chapterCount = this.__clean(this.__match(html, /chapter-count[^>]*>章节[数：:]*\s*([^<]*)/));
    var chapters = this.__htmlChapters(html);
    return {
      id: 'series:' + ref.hash,
      title: title,
      cover: this.__absolute(cover),
      subtitle: [author ? '作者：' + author : '', series ? '系列：' + series : ''].filter(function (t) { return t; }).join(' · '),
      description: [chapters.length ? '共 ' + chapters.length + ' 章' : '', wordCount].filter(function (t) { return t; }).join(' · '),
      tags: this.__tags(html),
      extra: { author: author, series: series, wordCount: wordCount, chapterCount: chapterCount }
    };
  },

  async chapters(argument) {
    var ref = this.__ref(argument);
    var html = await this.__get(BASE_URL + '/fiction/id-' + ref.hash + '.html');
    var chapters = this.__htmlChapters(html);
    if (chapters.length) {
      return chapters.map(function (item, index) {
        return { id: item.hash, title: item.title || ('第' + (index + 1) + '章') };
      });
    }
    // 短篇：整页就是一个正文，章节 id 用自身 hash。
    if (this.__paragraphs(html)) {
      return [{ id: ref.hash, title: ref.title || '正文' }];
    }
    throw new Error('xChina 小说：该作品没有可阅读的章节');
  },

  async content(argument) {
    var ref = this.__ref(argument);
    var index = argument && argument.chapterId != null ? String(argument.chapterId) : '';

    // chapterId 可能是「纯 hash」或「index」（列表来自 chapters() 时是 hash）。
    var hash = index || ref.hash;
    if (index && /^\d+$/.test(index) && index.length < 6) {
      // 纯序号：回到目录页按序号取对应章节 hash。
      var dir = await this.__get(BASE_URL + '/fiction/id-' + ref.hash + '.html');
      var list = this.__htmlChapters(dir);
      var at = Number(index);
      if (list[at]) hash = list[at].hash;
    }

    var html = await this.__get(BASE_URL + '/fiction/id-' + hash + '.html');
    var text = this.__paragraphs(html);
    if (!text) throw new Error('xChina 小说：该章节内容为空或需要网页视图校验');
    return { kind: 'text', text: text };
  },

  // ---------------------------------------------------------------- 内部工具

  /// id 归一化：`series:{hash}` / `chapter:{hash}` / 纯 hash / 纯 URL。
  __ref(argument) {
    var raw = '';
    if (argument && argument.id != null) raw = String(argument.id);
    else if (argument && argument.hash != null) raw = String(argument.hash);
    if (!raw) throw new Error('xChina 小说：缺少作品 ID');

    var hash = raw;
    if (hash.indexOf('series:') === 0) hash = hash.slice(7);
    else if (hash.indexOf('chapter:') === 0) hash = hash.slice(8);
    var at = hash.indexOf('/fiction/id-');
    if (at >= 0) {
      hash = hash.slice(at + '/fiction/id-'.length);
      hash = hash.replace(/\.html.*$/, '');
    }
    hash = hash.replace(/\.html.*$/, '');
    if (!hash) throw new Error('xChina 小说：作品 ID 无效');
    return { hash: hash, title: raw.indexOf('|') >= 0 ? raw.split('|')[1] : '' };
  },

  __listPath(category, page) {
    var value = String(category || '');
    var p = page > 0 ? page : 1;
    if (value === 'sort-read') return 'fictions/sort-read/' + p + '.html';
    if (value === 'sort-comment') return 'fictions/sort-comment/' + p + '.html';
    if (value.indexOf('tag-') === 0) return 'fictions/' + value + '/' + p + '.html';
    if (value.indexOf('length-') === 0) return 'fictions/' + value + '/' + p + '.html';
    return 'fictions/' + p + '.html';
  },

  __listItems(html) {
    var items = [];
    var seen = {};
    var pattern = /<div class="item fiction">([\s\S]*?)<div class="tags">/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var block = match[1];
      var hash = this.__match(block, /href="\/fiction\/id-([^".]+)\.html"/);
      if (!hash || seen[hash]) continue;
      seen[hash] = true;
      var title = this.__clean(this.__match(block, /<div class="title">[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/));
      title = title.replace(/^《|》$/g, '').trim();
      var brief = this.__clean(this.__match(block, /<div class="brief">([\s\S]*?)<\/div>/));
      var cover = this.__match(block, /background-image:\s*url\('?([^')]+)'?\)/);
      items.push({
        id: 'series:' + hash,
        title: title || hash,
        cover: this.__absolute(cover),
        subtitle: brief
      });
    }
    return items;
  },

  /// 目录页里的章节链接（合集/长篇）。
  __htmlChapters(html) {
    var chapters = [];
    var seen = {};
    var block = html;
    var at = html.indexOf('chapter-container');
    if (at >= 0) block = html.slice(at);
    var pattern = /<a href="\/fiction\/id-([^".]+)\.html">\s*<div class="chapter-item">([\s\S]*?)<\/div>/g;
    var match;
    while ((match = pattern.exec(block)) !== null) {
      var hash = match[1];
      if (seen[hash]) continue;
      seen[hash] = true;
      chapters.push({ hash: hash, title: this.__clean(match[2]) });
    }
    return chapters;
  },

  /// `div.fiction-body` → 纯文本（按 <p> 断行）。
  __paragraphs(html) {
    var body = this.__match(html, /<div[^>]*class="fiction-body"[^>]*>([\s\S]*?)<\/div>\s*<div/);
    if (!body) body = this.__match(html, /<div[^>]*class="fiction-body"[^>]*>([\s\S]*?)<\/div>/);
    if (!body) return '';
    var text = body.replace(/<\s*br\s*\/?>/gi, '\n').replace(/<\/\s*p\s*>/gi, '\n');
    text = this.__clean(text.replace(/<p[^>]*>/gi, '\n'));
    // 站点会在正文里插「推广」「赞助」之类；把明显广告行去掉。
    var lines = text.split('\n');
    var kept = [];
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/\s+/g, ' ').trim();
      if (!line) continue;
      if (/^(推广|广告|赞助|本章未完|请收藏|手机用户请|笔趣阁)/.test(line)) continue;
      kept.push(line);
    }
    return kept.join('\n').trim();
  },

  __tags(html) {
    var tags = [];
    var block = this.__match(html, /fiction-overview-info-item tags[^>]*>标签[：:]([\s\S]*?)<\/div>\s*<\/div>/);
    if (!block) block = this.__match(html, /item tags[^>]*>([\s\S]*?)<\/div>\s*<\/div>/);
    var pattern = /<div class="tag">([\s\S]*?)<\/div>/g;
    var match;
    while ((match = pattern.exec(block)) !== null) {
      var tag = this.__clean(match[1]);
      if (tag) tags.push(tag);
    }
    return tags;
  },

  __excerpt(text) {
    var line = String(text || '').split('\n')[0].replace(/\s+/g, ' ').trim();
    return line.length > 120 ? line.slice(0, 120) + '…' : line;
  },

  __hasNextPage(html, page) {
    // 分页控件里有比当前页更大的页码就说明还有。
    var pattern = /class="pager-num[^"]*"[^>]*>(\d+)</g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      if (Number(match[1]) > page) return true;
    }
    return false;
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
      headers: {
        'Referer': BASE_URL + '/',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      }
    });
    var status = response ? response.status : 0;
    var body = response && response.body ? String(response.body) : '';
    if (status !== 200) {
      if (status === 403 || status === 503 || status === 429 ||
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated|checking your browser|cf_chl_opt/i.test(body)) {
        throw new Error('NEED_WEBVIEW_VERIFY：xChina 需要网页视图过一次 Cloudflare 校验（HTTP ' + status + '）');
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + url);
    }
    if (/<title>\s*Just a moment/i.test(body)) {
      throw new Error('NEED_WEBVIEW_VERIFY：xChina 需要网页视图过一次 Cloudflare 校验');
    }
    return body;
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
