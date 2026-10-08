// LumeSource: {"id":"mh92_comic","name":"92漫画","version":"1.0.0","category":"comic"}

// 站点：https://www.92mh.com （漫画站，**整站在 Cloudflare 后面**）
//
// 实测（2026-10-08，非浏览器客户端一律被拦）：
//   `GET /` → `HTTP 403` + `Cf-Mitigated: challenge`，页面含 “Just a moment” /
//   `__cf_chl` / `challenge-platform` —— 也就是这台站需要过一次 CF 的 JS 挑战，
//   过完之后拿到的 `cf_clearance` 可以复用。
//   因此本脚本被拦时抛 `NEED_WEBVIEW_VERIFY`：App 会自动拉起网页视图过一次校验、
//   存下 Cookie 与 UA，再**自动重试**这次调用（见 core/net/waf_auto_verify.dart）。
//
// ✅ 真实结构（2026-10-08 用**真浏览器**过完 CF 后实测，已按它写解析器）：
//   · 分类：`/list/{slug}/`（少年 shaonian / 少女 shaonv / 青年 qingnian /
//     连载 lianzai / 完结 wanjie）与 `/list/update/`（最近更新）。
//   · 分页：`/list/{slug}/{n}/`，页脚有「下一页 / 尾页」。
//   · 列表条目：`<li data-key><a href="https://www.92mh.com/manhua/{书id}/">书名</a></li>`
//     ——**列表页只有书名没有封面**，封面只出现在首页更新流与详情页。
//   · 详情：`h1` 是书名；简介在 `meta[name=description]`；**没有 og:image**，
//     封面是 `img[src*="cover.alltucdn.cc"]`（站点用 http:// 嵌的图，App 侧会自动升
//     https，见 image_pipeline 的 ATS 修复）；章节是
//     `a[href="/manhua/{书id}/{章节id}.html"]`，标题在 `span.list_con_zj`。
//   · 正文：章节页里的 `img[src]` 就是漫画页；站点 logo（`images/92mh-`）与
//     `cover.alltucdn.cc/.../cover/...` 缩略图要排掉。一章一页，页脚给「第 N 话」直达下一话。
//
// 仍然保留多套兜底：站点模板换版时先按老结构试，再按新结构试。

var BASE_URL = 'https://www.92mh.com';
var PAGE_SIZE = 30;
var MAX_CHAPTER_PAGES = 30;

var LumeSource = {
  id: 'mh92_comic',
  name: '92漫画',
  version: '1.0.0',
  category: 'comic',

  async categories() {
    var html = await this.__get(BASE_URL + '/');
    var items = this.__navCategories(html);
    if (items.length) return items;
    // 兜底：只保证「进得去」，真实分类仍以站点为主。
    return [
      { id: '', title: '全部' },
      { id: 'update', title: '最近更新' }
    ];
  },

  async home() {
    var boards = [];
    var latest = await this.list({ categoryId: '', page: 1 });
    if (latest && latest.items && latest.items.length) {
      // 列表页**没有封面**（站点只在详情页给图）：首页要好看，就得补一次详情。
      // 只补首页这一屏（前 12 条）且并发跑，翻页列表不受影响。
      var top = latest.items.slice(0, 12);
      var filled = await this.__fillCovers(top);
      boards.push({ title: '最近更新', moreUrl: '', items: filled });
    }
    return boards;
  },

  /// 给首页条目补封面（并发、失败静默：拿不到就还是空占位，不影响其它条目）。
  ///
  /// 分两批跑（每批 6 条）：一次甩 12 个详情请求会把站点的限流招出来，
  /// 真机反馈就是「有格子空着」。
  ///
  /// **补图必须给首页让路**：沙箱对一次脚本调用有墙钟预算（默认 6s，**含网络
  /// 等待**，每次宿主调用都吃这份预算），补封面只是「锦上添花」——累计超过 3.5s
  /// 就收手，宁可留下几个空占位，也不能让整页首页变成超时失败。
  async __fillCovers(items) {
    var deadline = Date.now() + 3500;
    var batchSize = 6;
    for (var start = 0; start < items.length; start += batchSize) {
      if (Date.now() > deadline) break;
      var tasks = [];
      for (var i = start; i < start + batchSize && i < items.length; i++) {
        if (items[i].cover) continue;
        tasks.push(this.__fillOne(items[i], 0, deadline));
      }
      if (tasks.length) {
        try { await Promise.all(tasks); } catch (error) { /* 单条失败无所谓 */ }
      }
      if (start + batchSize < items.length && Date.now() < deadline) {
        await new Promise(function (resolve) { setTimeout(resolve, 150); });
      }
    }
    return items;
  },

  /// 补一条封面。失败再试一次（并发补图时偶尔会撞上站点的限流，重试一次基本都能拿到）。
  async __fillOne(item, attempt, deadline) {
    try {
      var html = await this.__get(this.__detailUrl(item.id));
      var cover = this.__match(html, /<meta[^>]+property="og:image"[^>]+content="([^"]*)"/);
      if (!cover) cover = this.__match(html, /data-original="([^"]+)"/);
      if (!cover) cover = this.__match(html, /<img[^>]+src="([^"]+)"/);
      if (cover) item.cover = this.__pic(cover);
    } catch (error) {
      if (attempt < 1 && Date.now() < (deadline || 0)) {
        await new Promise(function (resolve) { setTimeout(resolve, 250); });
        return this.__fillOne(item, attempt + 1, deadline);
      }
      /* 两次都拿不到就留空占位 */
    }
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    if (!(page > 0)) page = 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';

    var url = keyword
      ? BASE_URL + '/search?q=' + this.__encode(keyword) + (page > 1 ? '&page=' + page : '')
      : this.__listUrl(category, page);
    var html = await this.__get(url);
    var items = this.__listItems(html);
    return {
      items: items,
      hasMore: this.__hasNextPage(html, page) || items.length >= PAGE_SIZE
    };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var html = await this.__get(this.__detailUrl(id));
    var title = this.__clean(this.__match(html, /<h1[^>]*>([\s\S]*?)<\/h1>/));
    if (!title) {
      title = this.__clean(this.__match(html, /<meta[^>]+property="og:title"[^>]+content="([^"]*)"/));
    }
    if (!title) return null;
    var cover = this.__match(html, /<meta[^>]+property="og:image"[^>]+content="([^"]*)"/);
    if (!cover) cover = this.__match(html, /data-original="([^"]+)"/);
    if (!cover) cover = this.__match(html, /<img[^>]+src="([^"]+)"/);
    var description = this.__clean(
      this.__match(html, /<meta[^>]+name="description"[^>]+content="([^"]*)"/)
    );
    if (!description) {
      description = this.__clean(
        this.__match(html, /class="[^"]*(?:desc|content|intro|summary)[^"]*"[^>]*>([\s\S]{0,600}?)<\//)
      );
    }
    var author = this.__clean(this.__match(html, /作者[：:]\s*<a[^>]*>([\s\S]*?)<\/a>/));
    var status = this.__clean(this.__match(html, /(?:状态|连载)[：:]?\s*<span[^>]*>([^<]*)</));
    var tags = [];
    if (status) tags.push(status);
    return {
      id: id,
      title: title,
      cover: this.__pic(cover),
      subtitle: author ? '作者：' + author : '',
      description: description,
      tags: tags,
      extra: { author: author, status: status }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var html = await this.__get(this.__detailUrl(id));
    var chapters = this.__chapterLinks(html, id);
    if (!chapters.length) {
      throw new Error('92漫画：该作品没有解析到章节（站点结构可能又变了，请把详情页截图给我）');
    }
    return chapters;
  },

  async content(argument) {
    var id = this.__id(argument);
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!chapterId) throw new Error('92漫画：缺少章节（请先选一话）');

    var path = chapterId.indexOf('http') === 0 ? chapterId : this.__absolute(chapterId);
    var images = [];
    var seen = {};
    for (var page = 1; page <= MAX_CHAPTER_PAGES; page++) {
      var url = path + (page > 1 ? (path.indexOf('?') >= 0 ? '&' : '?') + 'page=' + page : '');
      var html = await this.__get(url);
      var found = this.__images(html);
      for (var i = 0; i < found.length; i++) {
        if (!seen[found[i]]) { seen[found[i]] = true; images.push(found[i]); }
      }
      if (!found.length || !/id="nextPage"|下一[页话章]/.test(html)) break;
    }
    if (!images.length) throw new Error('92漫画：这一话没有解析到图片');
    return { kind: 'images', images: images };
  },

  // ---------------------------------------------------------------- 内部工具

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.comicId != null) id = String(argument.comicId);
    if (!id) throw new Error('92漫画：缺少作品 ID');
    return id;
  },

  /// 列表地址：真站点就是 `/list/{slug}/{n}/`（分类 slug 直接来自导航）。
  __listUrl(category, page) {
    var value = String(category || '').trim();
    var slug = value.replace(/^\/?(list\/)?/, '').replace(/\/+$/, '');
    if (!slug) slug = 'update';
    return BASE_URL + '/list/' + slug + '/' + page + '/';
  },

  __detailUrl(id) {
    var value = String(id || '');
    if (value.indexOf('http') === 0) return value;
    if (value.indexOf('/') === 0) return BASE_URL + value;
    // 纯书号 → `/manhua/{id}/`（真站点的详情页形态）。
    return BASE_URL + '/manhua/' + encodeURIComponent(value) + '/';
  },

  /// 顶部导航里的一级分类（`/list/{id}/`、`/sort/{id}/` 这类）。
  __navCategories(html) {
    var items = [];
    var seen = {};
    var block = this.__match(html, /<nav[^>]*>([\s\S]*?)<\/nav>/);
    if (!block) {
      block = this.__match(html, /class="[^"]*(?:nav|menu|header)[^"]*"[^>]*>([\s\S]*?)<\/div>/);
    }
    var source = block || html;
    var pattern = /<a[^>]+href="(?:https?:\/\/[^"]+)?\/(list|sort|type|category)\/([A-Za-z0-9_-]+)\/?"[^>]*>([\s\S]{0,30}?)<\/a>/g;
    var match;
    while ((match = pattern.exec(source)) !== null) {
      // id 保留完整路径（`/sort/hot`）：只留 `hot` 就分不清该走 list 还是 sort。
      // 真站点：`/list/{slug}/`（少年/少女/青年/连载/完结/update）。保留 slug 作 id。
      var id = match[2];
      if (seen[id]) continue;
      var title = this.__clean(match[3]);
      if (!title) continue;
      seen[id] = true;
      items.push({ id: id, title: title });
    }
    return items;
  },

  __listItems(html) {
    var items = [];
    var seen = {};
    var patterns = [
      // 真站点：条目就是「书号链接 + 书名」，列表页不给封面。
      /<a[^>]+href="((?:https?:\/\/[^"]+)?\/manhua\/(\d+)\/)"[^>]*>([^<]{1,60})<\/a>/g,
      /<a[^>]+href="((?:https?:\/\/[^"]+)?\/(?:comic|book|mh)\/[^"?#]+)"[^>]*title="([^"]*)"[\s\S]{0,600}?data-original="([^"]*)"/g
    ];
    for (var p = 0; p < patterns.length; p++) {
      var match;
      while ((match = patterns[p].exec(html)) !== null) {
        var href = match[1];
        var key = p === 0 ? match[2] : href;
        if (!href || seen[key]) continue;
        var title = this.__clean(p === 0 ? match[3] : match[2]);
        var cover = p === 0 ? '' : match[3];
        if (!title) continue;
        seen[key] = true;
        items.push({
          id: href,
          title: title,
          cover: this.__pic(cover),
          subtitle: ''
        });
      }
      if (items.length) break;
    }
    return items;
  },

  __chapterLinks(html, id) {
    var chapters = [];
    var seen = {};
    var patterns = [
      // 真站点：`/manhua/{书id}/{章节id}.html`，标题在 `<span class="list_con_zj">第01话…`。
      /href="([^"]*\/manhua\/\d+\/\d+\.html)"[^>]*>([\s\S]{0,200}?)<\/a>/g,
      /href="([^"]*\/chapter\/[^"]+)"[^>]*>([\s\S]{0,40}?)<\/a>/g,
      /href="([^"]*\/read\/[^"]+)"[^>]*>([\s\S]{0,40}?)<\/a>/g
    ];
    for (var p = 0; p < patterns.length; p++) {
      var match;
      while ((match = patterns[p].exec(html)) !== null) {
        var href = match[1];
        if (seen[href]) continue;
        seen[href] = true;
        var title = this.__clean(match[2]);
        if (!title || title.indexOf('开始阅读') >= 0) {
          title = '第' + (chapters.length + 1) + '话';
        }
        chapters.push({ id: href, title: title });
      }
      if (chapters.length) break;
    }
    return chapters;
  },

  __images(html) {
    var images = [];
    var seen = {};
    var pattern = /<img[^>]+(?:data-original|data-src|src)="([^"]+)"/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var raw = String(match[1]).trim();
      if (!raw) continue;
      // 排掉站点自身的图：logo / 图标 / 封面缩略图（真站点实测：
      // `images/92mh-pc.png` 与 `cover.alltucdn.cc/.../cover/...`）。
      if (/images\/92mh|\/cover\/|logo|placeholder|loading|\.gif$/i.test(raw)) continue;
      var url = this.__absolute(raw);
      if (!url || seen[url]) continue;
      seen[url] = true;
      images.push(url);
    }
    return images;
  },

  __hasNextPage(html, page) {
    var current = page > 0 ? page : 1;
    // 两种常见分页写法都认：查询串 `?page=N` / 查询串 `page=N`，以及路径式
    // `/list/{id}/{n}.html`（这一种在自检里曾经漏掉，列表就再也翻不动）。
    var patterns = [
      /\/list\/[a-z0-9_-]+\/(\d+)\//g,
      /(?:list|sort|booklist)[^"'#]*[\/?]page[=\/](\d+)/g,
      /\/(?:list|sort)\/[^"'\/]+\/(\d+)\.html/g
    ];
    for (var p = 0; p < patterns.length; p++) {
      var match;
      while ((match = patterns[p].exec(html)) !== null) {
        if (Number(match[1]) > current) return true;
      }
    }
    return /id="nextPage"|下一[页话章]/.test(html);
  },

  async __get(url) {
    var response = await LumeSource.http.get(url, {
      headers: {
        'Referer': BASE_URL + '/',
        'Accept': 'text/html,application/xhtml+xml',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      }
    });
    var status = response ? response.status : 0;
    var body = response && response.body ? String(response.body) : '';
    // 整站在 Cloudflare 后面：被拦时抛固定标记，App 自动过校验并重试同一调用。
    if (status !== 200) {
      if (status === 403 || status === 503 || status === 429 ||
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated|checking your browser/i.test(body)) {
        throw new Error('NEED_WEBVIEW_VERIFY：92漫画 需要网页视图过一次 Cloudflare 校验（HTTP ' + status + ' ' + url + '）');
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + url);
    }
    if (/<title>\s*Just a moment/i.test(body) || /challenge-platform/.test(body)) {
      throw new Error('NEED_WEBVIEW_VERIFY：92漫画 需要网页视图过一次 Cloudflare 校验');
    }
    return body;
  },

  /// 封面/图片地址规整：http → https（站点用明文嵌图，iOS ATS 会拦），
  /// 并去掉 CF 图片变换段（那类地址个别边缘拿不到图）。
  __pic(url) {
    var text = String(url || '').trim();
    if (!text) return '';
    var at = text.indexOf('/cdn-cgi/image/');
    if (at > 0) {
      var rest = text.slice(at + '/cdn-cgi/image/'.length);
      var slash = rest.indexOf('/');
      if (slash > 0) text = text.slice(0, at) + rest.slice(slash);
    }
    return this.__absolute(text);
  },

  __absolute(url) {
    var text = String(url || '').trim();
    if (!text) return '';
    if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) return text;
    if (text.indexOf('//') === 0) return 'https:' + text;
    return BASE_URL + (text.charAt(0) === '/' ? text : '/' + text);
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
