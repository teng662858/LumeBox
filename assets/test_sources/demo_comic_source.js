// LumeSource: {"id":"demo-comic-html","name":"示例漫画源（HTML + JSON）","version":"1.0.0","category":"comic"}
//
// Lume Box 漫画板块示例源：列表页演示**没有 DOM 时怎么抓网页**（正则解析），
// 详情与章节走 JSON 接口，正文返回图片列表。
//
// 覆盖到的契约与能力：
//   categories()                        → [{id, title}]
//   list({categoryId?, keyword?, page})  → {items: [{id, title, cover?, subtitle?}], hasMore}
//   detail({id})                         → {id, title, cover?, subtitle?, description?}
//   chapters({id})                       → [{id, title}]
//   content({id, chapterId})             → {kind: 'images', images: [url, ...]}  ← 漫画返回图片列表
//
// 站点接口约定（示例站按这个形状返回即可）：
//   GET {BASE_URL}/page/list.html?page=1
//        HTML 里每条漫画形如：
//        <a class="item" href="/comic/12" data-id="12"><img src="/img/12.jpg" alt="标题"/></a>
//   GET {BASE_URL}/api/detail?id=<itemId>
//   GET {BASE_URL}/api/chapters?id=<itemId>
//   GET {BASE_URL}/api/content?id=<itemId>&chapterId=<chapterId>   → {images: [...]}
var BASE_URL = 'http://127.0.0.1:8080';

var LumeSource = {
  id: 'demo-comic-html',
  name: '示例漫画源（HTML + JSON）',
  version: '1.0.0',
  category: 'comic',

  async categories() {
    return [
      { id: 'all', title: '全部' },
      { id: 'ongoing', title: '连载中' },
      { id: 'completed', title: '已完结' }
    ];
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';
    var html = await this.__getText('/page/list.html?page=' + page);

    // 正则解析列表：沙箱里没有 DOM，抓网页靠「按结构切段 + 逐条取字段」。
    var items = [];
    var pattern = /<a class="item"[^>]*data-id="([^"]+)"[^>]*>[\s\S]*?<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[\s\S]*?<\/a>/g;
    var matched;
    while ((matched = pattern.exec(html)) !== null) {
      items.push({
        id: matched[1],
        title: matched[3],
        cover: this.__absolute(matched[2]),
        subtitle: '示例漫画 · 第 ' + page + ' 页'
          + (category ? ' · ' + category : '')
      });
    }
    if (items.length === 0) {
      throw new Error('列表页解析不到条目：/page/list.html（结构是否改过？）');
    }
    // 示例站固定两页；真实源按「有没有下一页」判断。
    return { items: items, hasMore: page < 2 };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var data = await this.__getJson('/api/detail?id=' + encodeURIComponent(id));
    if (!data || !data.item) return null;
    return data.item;
  },

  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var data = await this.__getJson('/api/chapters?id=' + encodeURIComponent(id));
    return data.chapters || [];
  },

  async content(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    var data = await this.__getJson(
      '/api/content?id=' + encodeURIComponent(id)
      + '&chapterId=' + encodeURIComponent(chapterId)
    );
    var images = (data && data.images) || [];
    if (images.length === 0) {
      throw new Error('该章没有图片（id=' + id + ' chapterId=' + chapterId + '）');
    }
    return { kind: 'images', images: images };
  },

  // 相对地址补全：HTML 抓下来的 src 常常是 /img/x.jpg。
  __absolute(url) {
    var value = String(url || '');
    if (!value) return '';
    if (value.indexOf('http://') === 0 || value.indexOf('https://') === 0) {
      return value;
    }
    return BASE_URL + (value.charAt(0) === '/' ? value : '/' + value);
  },

  async __getText(path) {
    var response = await LumeSource.http.get(BASE_URL + path);
    if (!response || response.status !== 200) {
      throw new Error('拉取失败：HTTP ' + (response ? response.status : 0) + ' ' + path);
    }
    return response.body || '';
  },

  async __getJson(path) {
    var text = await this.__getText(path);
    try {
      return JSON.parse(text || 'null');
    } catch (error) {
      throw new Error('返回的不是合法 JSON：' + path);
    }
  }
};
