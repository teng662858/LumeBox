// LumeSource: {"id":"gztv5_video","name":"瓜子影视","version":"2.2.0","category":"video"}

// ⚠️ 接口边界（2026-10-08 实测，务必先读）：
//   PC 端 API **只提供固定 5 条的「最新」推送**（`/Index/latestVideo` 传
//   page / pageSize / t_id 都只回 5 条），**没有分页目录接口**——我按它的命名
//   风格探过 40+ 个候选路由（/Index/typeVideo、/Resource/GetVodList、
//   /Index/vodListByType…），全部回「不存在的路由」。
//   因此本脚本的取数策略是：
//     · 首页 = **每个一级分类一块**（各 5 条，实时抓）→ 一屏就能看到几十条；
//     · 分类列表 = 该分类的当前推送（5 条）+ 明确 hasMore=false，不假装能翻页；
//     · 搜索 = `/Search/GetList`（分页可用，这条是真的）。
//   想要「全量目录 + 翻页」需要站点 H5 那套 AES(`/gz`) 接口或直接解析网页 HTML，
//   两者都要先过站点的人机校验（App 侧已支持：失败页点【网页视图】过校验后，
//   本脚本的请求会自动带上会话 Cookie）。
//
// Verified live endpoints (plain JSON, no AES layer needed on /Pc/Resource/*):
//   POST /Pc/Index/latestVideo          {}                              -> {data:[vod...]}
//   POST /Pc/Index/latestVideoCategories {}                             -> {data:[category...]}
//   POST /Pc/Resource/GetVodInfo        {vod_id}                        -> {data:{vodInfo,recommendVod}}
//   POST /Pc/Resource/GetOnePlayList    {vod_id,pageSize,page:1}        -> {data:{total_vod_vurl,urls:[{name,url,...}]}}
//
// The encrypted `/gz` route layer (AES-CBC, key 181cc88340ae5b2b) is only used
// by the H5/other client and is not required for the PC endpoints above.
var API_URL = 'https://haiwaiapi.1fc8ab0.com/Pc';
var SITE_URL = 'https://gztv5.com';
var PAGE_SIZE = 24;

var LumeSource = {
  id: 'gztv5_video',
  name: '瓜子影视',
  version: '2.2.0',
  category: 'video',

  async categories() {
    var data = await this.__post('/Index/latestVideoCategories', {});
    var list = data && data.data;
    if (!Array.isArray(list)) list = [];
    var result = list.map(function (item) {
      return { id: String(item.id), title: String(item.name || item.id) };
    });
    if (!result.length) {
      result.push({ id: '0', title: '最新' });
    }
    return result;
  },

  /// 列表：传了分类就取**该分类**的当前推送（`t_id` 有效，实测按分类返回）。
  ///
  /// 注意 page > 1 时如实返回「没有更多」——PC 接口没有分页目录，宁可页面停住，
  /// 也不要假装翻页把同一批 5 条反复贴出来（那看起来像加载坏了）。
  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';
    // 筛选页（filters 契约）选中的分类经 argument.filters 传进来：优先用它。
    var picked = argument && argument.filters ? argument.filters.category : '';
    if (picked) category = String(picked);

    if (keyword) return await this.__search(keyword, page);
    if (page > 1) return { items: [], hasMore: false };

    var payload = {};
    if (category && category !== '0') payload.t_id = category;
    var data = await this.__post('/Index/latestVideo', payload);
    var list = data && data.data;
    if (!Array.isArray(list)) list = [];
    var items = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i] || {};
      if (category && category !== '0' && String(item.t_id) !== category) continue;
      items.push(this.__toItem(item));
    }
    return { items: items, hasMore: false };
  },

  /// 首页（可选契约，用户口径任务 3）：**每个一级分类一块**。
  ///
  /// 为什么这样做：PC 接口的推送是「每类 5 条」，单看一类像只有几个片子；
  /// 铺成横滑板块后一屏能同时看到十几个分类、几十上百条——这是这套接口能给出的
  /// 最全的首页形态。点某块的「更多」→ 带该分类 id 进分类列表（同一个 list()）。
  async home() {
    var categories = await this.categories();
    var boards = [];
    for (var i = 0; i < categories.length; i++) {
      var category = categories[i] || {};
      var id = category.id ? String(category.id) : '';
      if (!id || id === '0') continue;
      var fresh = await this.list({ categoryId: id, page: 1 });
      var items = fresh && fresh.items ? fresh.items : [];
      if (!items.length) continue;
      boards.push({
        title: String(category.title || id),
        moreUrl: id,
        items: items.slice(0, 12)
      });
    }
    return boards;
  },

  /// 筛选标签（可选契约，用户口径任务 1）：分类来自接口实时返回，不硬编码。
  async filters() {
    var categories = await this.categories();
    var options = [];
    for (var i = 0; i < categories.length; i++) {
      var item = categories[i] || {};
      if (item.id && String(item.id) !== '0') {
        options.push({ id: String(item.id), title: String(item.title || item.id) });
      }
    }
    if (!options.length) return [];
    return { groups: [{ id: 'category', title: '分类', options: options }] };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var data = await this.__post('/Resource/GetVodInfo', { vod_id: id });
    var info = data && data.data && data.data.vodInfo ? data.data.vodInfo : {};
    var recommend = data && data.data && Array.isArray(data.data.recommendVod) ? data.data.recommendVod : [];
    var related = recommend.map(this.__toItem, this);
    return {
      id: id,
      title: String(info.vod_name || id),
      cover: info.pic || info.vod_pic || '',
      description: this.__description(info),
      subtitle: info.vod_continu ? String(info.vod_continu) : '',
      tags: Array.isArray(info.videoTag) ? info.videoTag : [],
      related: related,
      extra: {
        year: info.vod_addtime || info.vod_year || '',
        area: info.vod_area || '',
        score: info.vod_scroe || ''
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var data = await this.__post('/Resource/GetOnePlayList', { vod_id: id, pageSize: 0, page: 1 });
    var payload = data && data.data ? data.data : {};
    var urls = Array.isArray(payload.urls) ? payload.urls : [];
    var chapters = [];
    for (var i = 0; i < urls.length; i++) {
      var entry = urls[i] || {};
      var name = String(entry.name || '').trim();
      chapters.push({
        id: String(entry.vurl_id != null ? entry.vurl_id : i + 1),
        title: name || ('第' + (i + 1) + '集')
      });
    }
    return chapters;
  },

  async content(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (!id) throw new Error('瓜子影视：缺少视频 ID');

    var data = await this.__post('/Resource/GetOnePlayList', { vod_id: id, pageSize: 0, page: 1 });
    var payload = data && data.data ? data.data : {};
    var urls = Array.isArray(payload.urls) ? payload.urls : [];
    if (!urls.length) throw new Error('瓜子影视：该视频没有可播放的剧集');

    var chosen = null;
    if (chapterId) {
      for (var i = 0; i < urls.length; i++) {
        if (String(urls[i].vurl_id) === chapterId) { chosen = urls[i]; break; }
      }
    }
    if (!chosen) chosen = urls[0];
    var url = chosen && chosen.url ? String(chosen.url) : '';
    if (!url) throw new Error('瓜子影视：该剧集没有播放地址');
    return {
      kind: 'video',
      url: url,
      headers: { 'Referer': SITE_URL + '/', 'User-Agent': 'Mozilla/5.0' }
    };
  },

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.vod_id != null) id = String(argument.vod_id);
    if (!id) throw new Error('瓜子影视：缺少视频 ID');
    return id;
  },

  __toItem(item) {
    item = item || {};
    var vertical = item.is_vertical === 1 || item.is_vertical === '1' ||
      item.is_vertical === true;
    var continuity = this.__continuity(item.vod_continu);
    return {
      id: String(item.vod_id != null ? item.vod_id : item.id),
      title: String(item.vod_name || item.vod_id || ''),
      cover: item.vod_pic || '',
      // 竖屏短剧（站点自报 is_vertical）：标出来，播放器侧也更好认。
      subtitle: vertical ? (continuity + ' · 竖屏') : continuity
    };
  },

  __continuity(value) {
    var text = String(value == null ? '' : value).trim();
    if (!text || text === '0') return '瓜子影视';
    if (text.indexOf('更新') >= 0 || text.indexOf('集') >= 0) return text;
    return '更新至 ' + text + ' 集';
  },

  __description(info) {
    var parts = [];
    if (info.vod_continu) parts.push(String(info.vod_continu));
    if (info.vod_scroe) parts.push('评分 ' + info.vod_scroe);
    if (info.vod_area) parts.push(String(info.vod_area));
    if (info.vod_addtime) parts.push(String(info.vod_addtime));
    return parts.join(' · ');
  },

  async __search(keyword, page) {
    var response = await this.__post('/Search/GetList', {
      keyword: keyword,
      wd: keyword,
      page: page,
      pageSize: PAGE_SIZE
    });
    var list = response && response.data;
    if (list && !Array.isArray(list)) list = list.list || list.data;
    if (!Array.isArray(list)) list = [];
    return { items: list.map(this.__toItem, this), hasMore: list.length >= PAGE_SIZE };
  },

  async __post(path, payload) {
    var response = await LumeSource.http.post(API_URL + path, JSON.stringify(payload), {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Referer': SITE_URL + '/'
      }
    });
    if (!response || response.status !== 200) {
      var status = response ? response.status : 0;
      var body = response && response.body ? String(response.body) : '';
      // Cloudflare 人机校验（用户口径 2.1.1）：抛固定标记，App 据此显示
      // 【重试】+【网页视图】两个出口（普通 HTTP 错误不抛这个标记）。
      if ((status === 403 || status === 503 || status === 429) &&
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated|checking your browser/i.test(body)) {
        throw new Error('NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP ' + status + '）');
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + path);
    }
    var parsed;
    try {
      parsed = JSON.parse(response.body || '{}');
    } catch (error) {
      throw new Error('瓜子影视返回的不是合法 JSON：' + path);
    }
    return parsed;
  }
};
