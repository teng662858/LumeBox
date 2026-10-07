// LumeSource: {"id":"luttt_video","name":"北觅影视","version":"1.0.0","category":"video"}

// 站点：https://v.luttt.com （苹果CMS 10 + conch/hl 模板，服务端渲染 HTML）
//
// 结构（2026-10-08 实测直连可用，无需 Cookie/无需过验证）：
//   · 分类：`/vodtype/{id}.html`；一级分类在首页导航里（电影/电视剧/…），
//     取不到就回退内置的常用几项。
//   · 列表：`/vodshow/{type1}--------{page}---.html`
//     （苹果CMS 的标准 URL 形态；page=1 时是 `/vodshow/{type1}-----------.html`）。
//     条目在 `ul.hl-vod-list > li.hl-list-item` 里：`a.hl-item-thumb`
//     带 href="/voddetail/{id}.html" + title + data-original（封面，懒加载占位）。
//   · 搜索：`/vodsearch/{关键词}----------{page}---.html`（关键词按 URL 编码）。
//   · 详情：`/voddetail/{id}.html`，标题 `h2.hl-dc-title`，封面在
//     `hl-dc-pic span.hl-item-thumb` 的 data-original，简介是 `meta[name=description]`，
//     选集在 `ul#hl-plays-list li a[href="/vodplay/{id}-{line}-{n}.html"]`。
//   · 播放：`/vodplay/{id}-{line}-{n}.html` 内联 `player_aaaa = {...}` JSON，
//     `url` 字段就是 m3u8 直链（m3u8 实测无 Referer 也能播，这里仍带上以防防盗链）。
//
// 相对地址全部用 __absolute 补齐；失败抛可读中文错误。

var BASE_URL = 'https://v.luttt.com';
var PAGE_SIZE = 36;

var LumeSource = {
  id: 'luttt_video',
  name: '北觅影视',
  version: '1.0.0',
  category: 'video',

  async categories() {
    var html = await this.__get(BASE_URL + '/');
    var items = this.__navCategories(html);
    if (!items.length) {
      items = [
        { id: '1', title: '电影' },
        { id: '2', title: '电视剧' },
        { id: '3', title: '综艺' },
        { id: '4', title: '动漫' }
      ];
    }
    return items;
  },

  async home() {
    var categories = await this.categories();
    var boards = [];
    for (var i = 0; i < categories.length && boards.length < 4; i++) {
      var category = categories[i] || {};
      var payload = await this.list({ categoryId: category.id, page: 1 });
      var items = payload && payload.items ? payload.items : [];
      if (!items.length) continue;
      boards.push({
        title: String(category.title || category.id),
        moreUrl: String(category.id),
        items: items.slice(0, 12)
      });
    }
    return boards;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '1';
    if (!category || category === 'all') category = '1';

    var html;
    if (keyword) {
      html = await this.__get(BASE_URL + '/vodsearch/' + this.__segment(keyword) + '----------' + page + '---.html');
    } else {
      // 苹果CMS 标准分页 URL：/vodshow/{type1}--------{page}---.html
      html = await this.__get(BASE_URL + '/vodshow/' + this.__segment(category) + '--------' + page + '---.html');
    }
    var items = this.__listItems(html);
    var hasMore = items.length >= PAGE_SIZE && this.__hasNextPage(html);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var html = await this.__get(BASE_URL + '/voddetail/' + encodeURIComponent(id) + '.html');
    var title = this.__clean(this.__match(html, /<h2[^>]*class="[^"]*hl-dc-title[^"]*"[^>]*>([\s\S]*?)<\/h2>/));
    if (!title) return null;
    var cover = this.__match(html, /class="hl-dc-pic"[\s\S]*?data-original="([^"]+)"/);
    if (!cover) cover = this.__match(html, /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/);
    var description = this.__clean(this.__match(html, /<meta[^>]+name="description"[^>]+content="([^"]*)"/));
    var fields = this.__fields(html);
    var tags = [];
    if (fields.type) tags = fields.type.split(/[\/,、]/).map(this.__clean, this).filter(function (t) { return t; });
    return {
      id: id,
      title: title || String(id),
      cover: this.__absolute(cover),
      subtitle: fields.note || '',
      description: description,
      tags: tags,
      extra: {
        year: fields.year || '',
        area: fields.area || '',
        actors: fields.actor || '',
        director: fields.director || '',
        status: fields.note || ''
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var html = await this.__get(BASE_URL + '/voddetail/' + encodeURIComponent(id) + '.html');
    var chapters = [];
    // 一条线路一个 <ul id="hl-plays-list">；多线路时同一集的链接会重复，按 href 去重。
    var pattern = /href="(\/vodplay\/[^"]+\.html)"[^>]*>([\s\S]{0,40}?)<\/a>/g;
    var seen = {};
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var href = match[1];
      if (seen[href]) continue;
      seen[href] = true;
      var title = this.__clean(match[2]);
      chapters.push({ id: href, title: title || ('第' + (chapters.length + 1) + '集') });
    }
    if (!chapters.length) throw new Error('北觅影视：该影片没有可播放的剧集');
    return chapters;
  },

  async content(argument) {
    var id = this.__id(argument);
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!chapterId) throw new Error('北觅影视：缺少剧集（请先选择一集）');

    var url = chapterId.indexOf('http') === 0
      ? chapterId
      : this.__absolute(chapterId);
    var html = await this.__get(url);

    var raw = this.__match(html, /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*<\/script>/);
    if (!raw) raw = this.__match(html, /player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;/);
    if (!raw) throw new Error('北觅影视：播放页没有找到播放数据');
    var parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw new Error('北觅影视：播放数据解析失败');
    }
    var playUrl = parsed && parsed.url ? String(parsed.url) : '';
    if (!playUrl) throw new Error('北觅影视：该剧集没有播放地址');
    return {
      kind: 'video',
      url: playUrl,
      headers: { 'Referer': BASE_URL + '/', 'User-Agent': 'Mozilla/5.0' }
    };
  },

  // ---------------------------------------------------------------- 内部工具

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.vodId != null) id = String(argument.vodId);
    if (!id) throw new Error('北觅影视：缺少视频 ID');
    return id;
  },

  /// 一级分类：首页导航 `ul.hl-menus` 里的 `/vodtype/{数字}.html`（排除子分类
  /// 的 `.hl-type-child` 块）。
  __navCategories(html) {
    var items = [];
    var seen = {};
    var pattern = /<li class="hl-menus-item">([\s\S]*?)<\/li>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var block = match[1];
      var href = this.__match(block, /href="\/vodtype\/(\d+)\.html"/);
      if (!href) continue;
      if (seen[href]) continue;
      seen[href] = true;
      var title = this.__clean(this.__match(block, /<span[^>]*>([\s\S]*?)<\/span>/));
      if (!title) title = '分类 ' + href;
      items.push({ id: href, title: title });
    }
    return items;
  },

  __listItems(html) {
    var items = [];
    var pattern = /<a class="hl-item-thumb hl-lazy" href="\/voddetail\/(\d+)\.html" title="([^"]*)"[\s\S]*?data-original="([^"]*)"/g;
    var match;
    var seen = {};
    while ((match = pattern.exec(html)) !== null) {
      var id = match[1];
      if (seen[id]) continue;
      seen[id] = true;
      items.push({
        id: id,
        title: this.__clean(match[2]),
        cover: this.__absolute(match[3]),
        subtitle: this.__remark(html, match.index)
      });
    }
    return items;
  },

  /// 备注（HD / 更新至第 N 集）：跟着条目后面的 `span.remarks` 走一小段找。
  __remark(html, from) {
    var tail = html.slice(from, from + 1400);
    var text = this.__clean(this.__match(tail, /class="hl-lc-1 remarks"[^>]*>([^<]*)</));
    var score = this.__clean(this.__match(tail, /class="hl-text-conch score"[^>]*>([^<]*)</));
    var parts = [];
    if (text) parts.push(text);
    if (score) parts.push('评分 ' + score);
    return parts.join(' · ');
  },

  /// 详情页的「影片信息」列表（片名/状态/主演/导演/年份/地区/类型/时长…）。
  ///
  /// 每个字段是一个 `<li><em>标签：</em>值</li>`，值可能是纯文本、`<span>` 或
  /// 一串 `<a>`（多值）。逐条取 `<li>` 再按标签名归类，比一条大正则稳。
  __fields(html) {
    var box = this.__match(html, /class="hl-vod-data[^"]*"[^>]*>([\s\S]*?)<\/ul>/);
    var fields = {};
    if (!box) return fields;
    var pattern = /<li[^>]*>([\s\S]*?)<\/li>/g;
    var match;
    while ((match = pattern.exec(box)) !== null) {
      var line = match[1];
      var label = this.__clean(this.__match(line, /<em[^>]*>([\s\S]*?)<\/em>/)).replace(/[：:]/g, '');
      if (!label) continue;
      // 值 = 去掉 em 之后的全部内容，再剥标签（多值用「/」连）。
      var rest = line.replace(/<em[^>]*>[\s\S]*?<\/em>/, '');
      var parts = [];
      var linkPattern = /<a[^>]*>([\s\S]*?)<\/a>/g;
      var link;
      while ((link = linkPattern.exec(rest)) !== null) {
        var text = this.__clean(link[1]);
        if (text) parts.push(text);
      }
      var value = parts.length ? parts.join('/') : this.__clean(rest);
      value = value.replace(/^[\/、,，\s]+|[\/、,，\s]+$/g, '').replace(/\s*\/\s*/g, '/');
      if (label.indexOf('状态') >= 0) fields.note = value;
      else if (label.indexOf('主演') >= 0) fields.actor = value;
      else if (label.indexOf('导演') >= 0) fields.director = value;
      else if (label.indexOf('年份') >= 0) fields.year = value;
      else if (label.indexOf('地区') >= 0) fields.area = value;
      else if (label.indexOf('类型') >= 0) fields.type = value;
    }
    return fields;
  },

  __hasNextPage(html) {
    return /下一页|hl-page-wrap/i.test(html);
  },

  /// URL 片段：关键词可能是中文，按 UTF-8 逐字节百分号编码（沙箱无 TextEncoder）。
  __segment(text) {
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
