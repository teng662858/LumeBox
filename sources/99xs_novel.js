// LumeSource: {"id":"99xs_novel","name":"CA情色小说","version":"2.1.0","category":"novel"}

var BASE_URL = 'https://99xs.sbs';

// 站点在根路径上有一道「点击『继续访问』」的拦截页：点一下会写 cookie
// `x-index-auth=authed` 再跳 /enter。列表页走 /enter 本身不受影响，
// 但**搜索走根路径**（`/?s=…`）会撞上它——实测不带这枚 cookie 时，
// 搜索返回的就是那张 2.4KB 的拦截页，一条结果都解析不出来。
// 因此所有请求统一带上它（这枚 cookie 就是站点自己让用户写的）。
//
// 另一个坑在封面之外的分类上：分类 slug 是**繁体**（亂倫小說），界面名是简体
// （乱伦小说），写死简体去拼地址会 404。分类因此改为从站点导航动态读（见 categories）。
var HEADERS = { 'Cookie': 'x-index-auth=authed' };

var LumeSource = {
  id: '99xs_novel',
  name: 'CA情色小说',
  version: '2.1.0',
  category: 'novel',

  /// 分类：**从站点导航里读**，不写死。
  ///
  /// 为什么必须动态读：站点的分类 slug 用的是**繁体**（`亂倫小說`），而界面上
  /// 显示的是**简体**（`乱伦小说`）。写死简体名去拼 URL 会 404——实测：
  /// 繁体（`%E4%BA%82…`）返回 200，简体（`%E4%B9%B1…`）返回 404；
  /// 而百分号转义的大小写**无所谓**（大小写两种都返回 200，我先前那次
  /// 「小写才行」的结论是同时改了字形与大小写得出的，不成立）。
  /// 这里直接用站点自己的 href 作为 id，从根上杜绝字形对不上。
  async categories() {
    var html = await this.__get(BASE_URL + '/enter');
    var pattern = /<a[^>]+href="(?:https:\/\/99xs\.sbs)?\/article\/category\/([^"]+)"[^>]*>([^<]{1,20})<\/a>/g;
    var result = [{ id: 'all', title: '全部' }];
    var seen = {};
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var slug = match[1];
      if (seen[slug]) continue;
      seen[slug] = true;
      var title = this.__clean(match[2]);
      if (!title) continue;
      // id 用**解码后**的 slug：列表里再 encodeURIComponent 一次就得到站点认的地址。
      result.push({ id: decodeURIComponent(slug), title: title });
    }
    return result;
  },

  /// 首页（可选契约，用户口径任务 3）：一个板块，条目实时抓。
  async home() {
    var first = await this.list({ categoryId: 'all', page: 1 });
    if (first && first.items && first.items.length) {
      return [{ title: '最新连载', moreUrl: 'all', items: first.items.slice(0, 12) }];
    }
    return [];
  },

  /// 筛选标签（可选契约，用户口径任务 1）：**实时从站点导航里读**分类，
  /// 不写死任何分类名（繁 / 简字形会漂，见 categories() 的说明）。
  async filters() {
    var categories = await this.categories();
    var options = [];
    for (var i = 0; i < categories.length; i++) {
      var item = categories[i] || {};
      if (item.id && item.id !== 'all') {
        options.push({ id: String(item.id), title: String(item.title || item.id) });
      }
    }
    if (!options.length) return [];
    return { groups: [{ id: 'category', title: '分类', options: options }] };
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';
    // 筛选页（filters 契约）选中的分类经 argument.filters 传进来：优先用它。
    var picked = argument && argument.filters ? argument.filters.category : '';
    if (picked) category = String(picked);
    var keyword = argument && argument.keyword ? String(argument.keyword) : '';
    var url = BASE_URL + '/enter';
    if (keyword) url = BASE_URL + '/?s=' + encodeURIComponent(keyword) + '&paged=' + page;
    else if (category && category !== 'all') url = BASE_URL + '/article/category/' + encodeURIComponent(category);
    if (page > 1 && !keyword) {
      url = category && category !== 'all'
        ? url.replace(/\/$/, '') + '/page/' + page
        : BASE_URL + '/page/' + page;
    }

    var html = await this.__get(url);
    var items = [];
    var pattern = /<article[^>]+id="post-(\d+)"[^>]*>[\s\S]*?<h[12][^>]*class="post-title[^\"]*"[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/article>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      items.push({ id: match[1], title: this.__clean(match[3]), subtitle: 'CA情色小说' });
    }
    return { items: items, hasMore: html.indexOf('nextpostslink') >= 0 || html.indexOf('下一页') >= 0 };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return null;
    var html = await this.__get(BASE_URL + '/article/' + encodeURIComponent(id));
    var title = this.__match(html, /<h1[^>]*class="post-title[^\"]*"[^>]*>([\s\S]*?)<\/h1>/);
    return { id: id, title: this.__clean(title || '未知标题'), subtitle: 'CA情色小说' };
  },

  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var html = await this.__get(BASE_URL + '/article/' + encodeURIComponent(id));
    var title = this.__match(html, /<h1[^>]*class="post-title[^\"]*"[^>]*>([\s\S]*?)<\/h1>/);
    var chapters = [{ id: id, title: '第 1 页' }];
    var pattern = /href="(?:https:\/\/99xs\.sbs)?\/article\/[^"/]+\/(\d+)"[^>]*>(?:[^<]*第\s*)?(\d+)[^<]*<\/a>/g;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      if (match[1] !== '1') chapters.push({ id: id + '/' + match[1], title: '第 ' + match[1] + ' 页' });
    }
    return chapters.length > 1 ? chapters : [{ id: id, title: this.__clean(title || '正文') }];
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    var parts = chapterId.split('/');
    var articleId = parts.shift() || (argument && argument.id ? String(argument.id) : '');
    var page = parts.length ? '/' + parts.join('/') : '';
    var html = await this.__get(BASE_URL + '/article/' + encodeURIComponent(articleId) + page);
    var block = this.__match(html, /<div class="entry themeform">([\s\S]*?)<nav class="pagination/);
    if (!block) throw new Error('无法提取正文：article/' + articleId + page);
    var paragraphs = [], pattern = /<p[^>]*>([\s\S]*?)<\/p>/g, match;
    while ((match = pattern.exec(block)) !== null) {
      var text = this.__clean(match[1]);
      if (text) paragraphs.push(text);
    }
    if (!paragraphs.length) throw new Error('正文为空：article/' + articleId + page);
    return { kind: 'text', text: paragraphs.join('\n\n') };
  },

  async __get(url) {
    var response = await LumeSource.http.get(url, { headers: HEADERS });
    if (!response || response.status !== 200) throw new Error('拉取失败：HTTP ' + (response ? response.status : 0));
    return response.body || '';
  },

  __match(text, pattern) {
    var match = pattern.exec(text);
    return match ? match[1] : '';
  },

  __clean(text) {
    return String(text || '').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#8211;|&#8212;/g, '-').replace(/&amp;/g, '&').trim();
  }
};
