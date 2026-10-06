// LumeSource: {"id":"demo-novel-json","name":"示例小说源（JSON 接口）","version":"1.0.0","category":"novel"}
//
// Lume Box 小说板块示例源：把 BASE_URL 指向你自己的测试站点即可跑通整条链路。
//
// 覆盖到的契约与能力（可当模板照抄）：
//   categories()                         → [{id, title}]
//   list({categoryId?, keyword?, page})   → {items: [{id, title, cover?, subtitle?}], hasMore}
//   detail({id})                          → {id, title, cover?, subtitle?, description?}
//   chapters({id})                        → [{id, title}]
//   content({id, chapterId})              → {kind: 'text', text}   ← 小说返回纯文本
//   网络：LumeSource.http.get(url) → {status, headers, body, text(), json()}
//         所有请求都经宿主网络层发出（并发限制、UA / 代理、退避重试都在那一层）；
//   沙盒存储：LumeSource.fs.readText / writeText —— 按**图源**隔离的进程内存储，
//         用来做「目录缓存」这类跨调用复用（重启应用即清空）。
//
// 站点接口约定（示例站按这个形状返回即可，字段名与上面契约一致）：
//   GET {BASE_URL}/api/categories
//   GET {BASE_URL}/api/list?page=1&category=&keyword=
//   GET {BASE_URL}/api/detail?id=<itemId>
//   GET {BASE_URL}/api/chapters?id=<itemId>
//   GET {BASE_URL}/api/content?id=<itemId>&chapterId=<chapterId>
var BASE_URL = 'http://127.0.0.1:8080';

var LumeSource = {
  id: 'demo-novel-json',
  name: '示例小说源（JSON 接口）',
  version: '1.0.0',
  // 板块自报：导入到别的板块会被解析阶段直接拒绝（四套图源列表互不通用）。
  category: 'novel',

  // 目录缓存键：同一份内容不必每次进页面都去请求。
  CACHE_KEY: 'cache/categories.json',

  async categories() {
    var cached = await LumeSource.fs.readText(this.CACHE_KEY);
    if (cached) {
      // 有缓存就直接用；真实源可以在这里加时间戳，过期再刷新。
      return JSON.parse(String(cached));
    }
    var data = await this.__getJson('/api/categories');
    var list = data.categories || [];
    await LumeSource.fs.writeText(this.CACHE_KEY, JSON.stringify(list));
    return list;
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var category = argument && argument.categoryId ? argument.categoryId : '';
    var keyword = argument && argument.keyword ? argument.keyword : '';
    var query = '/api/list?page=' + page
      + (category ? '&category=' + encodeURIComponent(category) : '')
      + (keyword ? '&keyword=' + encodeURIComponent(keyword) : '');
    var data = await this.__getJson(query);
    return {
      items: data.items || [],
      hasMore: data.hasMore === true
    };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return null;
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
    // 小说板块返回纯文本；拿不到正文时如实报错，方便排查。
    if (!data || typeof data.text !== 'string') {
      throw new Error('该章没有正文（id=' + id + ' chapterId=' + chapterId + '）');
    }
    return { kind: 'text', text: data.text };
  },

  // 统一的取 JSON 小工具：非 200 与坏 JSON 都抛可读错误（上层会原样展示）。
  async __getJson(path) {
    var response = await LumeSource.http.get(BASE_URL + path);
    if (!response || response.status !== 200) {
      throw new Error('拉取失败：HTTP ' + (response ? response.status : 0) + ' ' + path);
    }
    try {
      return JSON.parse(response.body || 'null');
    } catch (error) {
      throw new Error('返回的不是合法 JSON：' + path);
    }
  }
};
