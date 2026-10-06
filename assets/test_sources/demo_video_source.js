// LumeSource: {"id":"demo-video-json","name":"示例视频源（多线路 JSON）","version":"1.0.0","category":"video"}
//
// Lume Box 视频板块示例源：列表 / 详情 / 选集走 JSON 接口，正文返回**直链播放地址**。
//
// 覆盖到的契约与能力：
//   categories()                        → [{id, title}]
//   list({categoryId?, keyword?, page})  → {items: [{id, title, cover?, subtitle?}], hasMore}
//   detail({id})                         → {id, title, cover?, subtitle?, description?}
//   chapters({id})                       → [{id, title}]           ← 视频里就是「选集 / 线路」
//   content({id, chapterId})             → {kind: 'video', url, headers?}   ← 播放地址
//                                          headers 会随请求一起发给播放内核（防盗链用）
//   搜索：list 收到 keyword 时按关键词过滤（示例站提供了 /api/search）
//
// 站点接口约定（示例站按这个形状返回即可）：
//   GET {BASE_URL}/api/categories
//   GET {BASE_URL}/api/vod?page=1&category=
//   GET {BASE_URL}/api/vod-search?keyword=关键词&page=1
//   GET {BASE_URL}/api/detail?id=<itemId>
//   GET {BASE_URL}/api/chapters?id=<itemId>
//   GET {BASE_URL}/api/content?id=<itemId>&chapterId=<chapterId>
//       → {"url": "https://…/play.m3u8", "headers": {"Referer": "…"}}
var BASE_URL = 'http://127.0.0.1:8080';

var LumeSource = {
  id: 'demo-video-json',
  name: '示例视频源（多线路 JSON）',
  version: '1.0.0',
  category: 'video',

  async categories() {
    var data = await this.__getJson('/api/categories');
    return data.categories || [];
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var category = argument && argument.categoryId ? argument.categoryId : '';
    var keyword = argument && argument.keyword ? argument.keyword : '';
    var path;
    if (keyword) {
      path = '/api/vod-search?page=' + page
        + '&keyword=' + encodeURIComponent(keyword);
    } else {
      path = '/api/vod?page=' + page
        + (category ? '&category=' + encodeURIComponent(category) : '');
    }
    var data = await this.__getJson(path);
    return { items: data.items || [], hasMore: data.hasMore === true };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var data = await this.__getJson('/api/detail?id=' + encodeURIComponent(id));
    if (!data || !data.item) return null;
    return data.item;
  },

  // 选集列表：条目里的每一集对应一个「线路 + 集数」组合。
  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var data = await this.__getJson('/api/chapters?id=' + encodeURIComponent(id));
    return data.chapters || [];
  },

  // 播放地址：kind='video'；headers 可选，用来带 Referer 之类的防盗链头。
  async content(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    var data = await this.__getJson(
      '/api/content?id=' + encodeURIComponent(id)
      + '&chapterId=' + encodeURIComponent(chapterId)
    );
    if (!data || !data.url) {
      throw new Error('该集没有播放地址（id=' + id + ' chapterId=' + chapterId + '）');
    }
    var result = { kind: 'video', url: data.url };
    if (data.headers && typeof data.headers === 'object') {
      result.headers = data.headers;
    }
    return result;
  },

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
