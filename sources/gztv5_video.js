// LumeSource: {"id":"gztv5_video","name":"瓜子影视","version":"2.2.0","category":"video"}

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

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';

    if (page > 1) return { items: [], hasMore: false };

    if (keyword) {
      return await this.__search(keyword, page);
    }

    var data = await this.__post('/Index/latestVideo', {});
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
    return {
      id: String(item.vod_id != null ? item.vod_id : item.id),
      title: String(item.vod_name || item.vod_id || ''),
      cover: item.vod_pic || '',
      subtitle: this.__continuity(item.vod_continu)
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
