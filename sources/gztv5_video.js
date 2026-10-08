// LumeSource: {"id":"gztv5_video","name":"瓜子影视","version":"3.0.0","category":"video"}

// 站点：https://gztv5.com （Nuxt SPA + 独立 API 域名）
//
// 2026-10-08 用**真浏览器**（内置浏览器，站点本身没有 CF 挑战）实测到的接口面：
//   POST /Pc/Index/indexPid           {type:1,phone_type:3}    -> 分类树（pid / t_id / type / name）
//   POST /Pc/Search/GetConditionList  {area,year,sort,page,pageSize,keywords,tid,…}
//        -> {data:{total,list:[…]}}   **全量列表 + 翻页**
//   POST /Pc/Resource/GetVodInfo      {vod_id}    -> {data:{vodInfo,recommendVod}}      详情
//   POST /Pc/Resource/GetOnePlayList  {vod_id,pageSize:0,page:1}
//        -> {data:{total_vod_vurl,urls:[{name,url}]}}                                   剧集 / 播放地址
//
// ★ 这一版最重要的修正：**列表改用 `Search/GetConditionList`**。
//   上一版（2.2.0）的文件头写着「PC 接口只有固定 5 条、没有分页目录」——那是
//   因为我当时只在 `/Index/*` 与 `/Resource/*` 里找，**漏了 SPA 自己的 `/Search/*`**。
//   实测（真浏览器 + 明文 JSON）：
//     · 电影分类 total=**42960**、国产剧 23222、全站 147232 条；
//     · `page` / `pageSize` 翻页有效（第 1 页与第 2 页条目不同）；
//     · 关键词搜索也走它（「庆余年」-> 99 条）。
//   ⇒ 「只能显示几条」的问题就是这个接口没接上，现在接上了。
//
// 两个实测要点（踩过才写在这）：
//   1. **按 `tid` 过滤**（分类树里的 t_id）：传 `pid` 会被服务端忽略、返回全站。
//      少数只有 pid 没 t_id 的栏目退化成 `pid-<数字>` 标识，走 pid 参数。
//   2. 该接口对**明文 JSON** 就认（200）。SPA 自己那套 `{params:"<hex>"}` 是它的
//      前端包裹，服务端两套都收——脚本不需要复刻那段编码。
//
// 已知站点侧数据问题：少数条目（新片 / 会员向）`GetOnePlayList` 返回 0 条线路，
// 脚本如实报「没有可播放的线路」，不编地址。

var BASE_URL = 'https://gztv5.com';
var API_URL = 'https://haiwaiapi.1fc8ab0.com/Pc';
var PAGE_SIZE = 30;

var LumeSource = {
  id: 'gztv5_video',
  name: '瓜子影视',
  version: '3.0.0',
  category: 'video',

  async categories() {
    var data = await this.__post('/Index/indexPid', { type: 1, phone_type: 3 });
    var raw = data && data.data ? data.data : [];
    // id 用 `all` 而不是空串：分类解析会跳过没有 id 的项（实测掉了「全部」）。
    var items = [{ id: 'all', title: '全部' }];
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i] || {};
      var title = String(item.name || '').trim();
      if (!title) continue;
      // 只有 video / recommend 这两类能出片（game / discover 不是片库）。
      if (item.type && item.type !== 'video' && item.type !== 'recommend') continue;
      var tid = item.t_id != null ? String(item.t_id) : '';
      var key = tid !== '' && tid !== '0' ? tid : ('pid-' + String(item.pid));
      if (key === '') continue;
      items.push({ id: key, title: title });
    }
    return items;
  },

  async home() {
    var boards = [];
    var categories = await this.categories();
    for (var i = 0; i < categories.length && boards.length < 4; i++) {
      var category = categories[i];
      if (!category.id || category.id === 'all') continue; // 「全部」不单独成块
      var payload = await this.list({ categoryId: category.id, page: 1 });
      var items = payload && payload.items ? payload.items : [];
      if (!items.length) continue;
      boards.push({
        title: String(category.title),
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
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';
    // 筛选页（filters 契约）选中的分类经 argument.filters 传进来：优先用它。
    var picked = argument && argument.filters ? argument.filters.category : '';
    if (picked) category = String(picked);

    var body = {
      area: 0,
      year: 0,
      sort: 'd_id',
      page: page,
      pageSize: PAGE_SIZE,
      keywords: keyword
    };
    if (category === 'all' || !category) {
      // 全部：不带任何筛选（服务端按全站返回）。
    } else if (category.indexOf('pid-') === 0) {
      body.pid = Number(category.slice(4));
    } else if (/^\d+$/.test(category)) {
      body.tid = Number(category);
    }

    var data = await this.__post('/Search/GetConditionList', body);
    var payload = data && data.data ? data.data : {};
    var raw = payload.list ? payload.list : [];
    var items = [];
    for (var i = 0; i < raw.length; i++) {
      items.push(this.__toItem(raw[i]));
    }
    var total = payload.total != null ? Number(payload.total) : 0;
    // 「还有没有下一页」由 **total** 说话（这个 API 的 total 是准的：电影 42960、
    // 国产剧 23222）。拿不到 total 时才退回「本页是否满页」的保守判断——
    // 只看满页会把「最后一页恰好 30 条」误判成还能翻，也会把不足 30 条的
    // 末页当成没有下一页。
    var hasMore = total > 0 ? (page * PAGE_SIZE < total) : (raw.length >= PAGE_SIZE);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var data = await this.__post('/Resource/GetVodInfo', { vod_id: id });
    var info = data && data.data && data.data.vodInfo ? data.data.vodInfo : {};
    if (!info.vod_name && !info.vod_id) return null;
    var tags = [];
    var rawTags = info.videoTag ? info.videoTag : [];
    for (var i = 0; i < rawTags.length; i++) {
      var tag = String(rawTags[i] || '').trim();
      if (tag && tags.indexOf(tag) < 0) tags.push(tag);
    }
    return {
      id: String(info.vod_id || id),
      title: String(info.vod_name || id),
      cover: this.__pic(info.pic || info.vod_pic || ''),
      subtitle: [this.__continuityText(info), info.vod_scroe ? ('评分 ' + info.vod_scroe) : '']
        .filter(function (t) { return !!t; }).join(' · '),
      description: String(info.vod_use_content || info.vod_douban_name || ''),
      tags: tags,
      extra: {
        year: info.vod_year || info.vod_addtime || '',
        area: info.vod_area || '',
        actor: info.vod_actor || '',
        director: info.vod_director || '',
        score: info.vod_scroe || ''
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    var raw = await this.__playList(id);
    var chapters = [];
    for (var i = 0; i < raw.length; i++) {
      var entry = raw[i] || {};
      if (!entry.url) continue;
      var title = String(entry.name || '').trim();
      chapters.push({
        id: String(i),
        title: title || ('第' + (chapters.length + 1) + '集')
      });
    }
    if (!chapters.length) {
      throw new Error('瓜子影视：该作品没有可播放的线路（新片 / 会员向条目常为 0 条）');
    }
    return chapters;
  },

  async content(argument) {
    var id = this.__id(argument);
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    var raw = await this.__playList(id);
    if (!raw.length) throw new Error('瓜子影视：该作品没有可播放的线路');

    var chosen = null;
    var index = Number(chapterId);
    if (chapterId && /^\d+$/.test(chapterId) && index >= 0 && index < raw.length) {
      chosen = raw[index];
    }
    if (!chosen || !chosen.url) {
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] && raw[i].url) { chosen = raw[i]; break; }
      }
    }
    var url = chosen && chosen.url ? String(chosen.url) : '';
    if (!url) throw new Error('瓜子影视：该集没有播放地址');
    return {
      kind: 'video',
      url: url,
      headers: { 'Referer': BASE_URL + '/', 'User-Agent': 'Mozilla/5.0' }
    };
  },

  // ---------------------------------------------------------------- 内部工具

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.vod_id != null) id = String(argument.vod_id);
    if (!id) throw new Error('瓜子影视：缺少影片 ID');
    return id;
  },

  /// 剧集线路（详情与正文共用一份）。
  ///
  /// **带记忆**：播放器打开时会连着问 chapters() 与 content()，两处都要这份线路。
  /// 不记忆就是两次网络往返，真机感受就是「点开播放器要等一下才起播」。
  /// 缓存只活在这一次数据源实例里（换源 / 重开即失效），不会拿到过期地址。
  async __playList(id) {
    var cache = this.__playCache || (this.__playCache = {});
    if (cache[id]) return cache[id];
    var data = await this.__post('/Resource/GetOnePlayList', {
      vod_id: id,
      pageSize: 0,
      page: 1
    });
    var payload = data && data.data ? data.data : {};
    var urls = payload.urls ? payload.urls : [];
    cache[id] = urls;
    return urls;
  },

  /// 「更新至 N 集 / 全 N 集」：连载进度比评分更有用，放最前面。
  __continuityText(info) {
    info = info || {};
    var continuity = info.vod_continu ? String(info.vod_continu) : '';
    var total = info.vod_total ? String(info.vod_total) : (info.d_total ? String(info.d_total) : '');
    if (continuity && continuity !== '0') {
      return total && total !== '0' ? ('更新至 ' + continuity + ' 集') : ('更新至 ' + continuity);
    }
    if (total && total !== '0') return '全 ' + total + ' 集';
    return '';
  },

  /// 封面地址规整。
  ///
  /// 接口给的是 Cloudflare 图片变换地址：
  /// `https://img2.ms39pn.com/cdn-cgi/image/quality=80,height=260/upload/vod/…webp`。
  /// 真机反馈「首页没有封面」，而同一个文件**去掉变换段**（`…/upload/vod/…webp`）
  /// 实测稳定 200（image/webp，Flutter 直接能解）。变换段那种 URL 依赖 CDN 的
  /// 按需处理，个别边缘/并发下会拿不到图——这里统一退回原图地址，更稳。
  __pic(url) {
    var text = String(url || '').trim();
    if (!text) return '';
    var marker = '/cdn-cgi/image/';
    var at = text.indexOf(marker);
    if (at > 0) {
      var rest = text.slice(at + marker.length);
      var slash = rest.indexOf('/');
      if (slash > 0) return text.slice(0, at) + rest.slice(slash);
    }
    return text;
  },

  __toItem(item) {
    item = item || {};
    var parts = [];
    if (item.vod_area) parts.push(String(item.vod_area));
    if (item.vod_year) parts.push(String(item.vod_year));
    if (item.vod_scroe) parts.push('评分 ' + item.vod_scroe);
    var progress = this.__continuityText({ vod_continu: item.vod_continu, d_total: item.d_total });
    if (progress) parts.unshift(progress);
    return {
      id: String(item.vod_id != null ? item.vod_id : (item.id != null ? item.id : '')),
      title: String(item.vod_name || item.vod_id || ''),
      cover: this.__pic(item.vod_pic),
      subtitle: parts.filter(function (t) { return !!t; }).join(' · ')
    };
  },

  async __post(path, body) {
    // 桥的签名是 post(url, body, opts)：body 是**第二个位置参数**（塞进 opts 会变成
    // 空 body，服务端按「路由不存在」回 404——这条踩过一次，别再改回去）。
    var options = {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Referer': BASE_URL + '/'
      }
    };
    var payload = JSON.stringify(body || {});
    var response = await LumeSource.http.post(API_URL + path, payload, options);
    var status = response ? response.status : 0;
    // 404 重试一次：实测该 API 在多节点 CDN 后面，个别边缘节点会对**合法路由**
    // 回 404（浏览器 / curl 同一 URL 却是 200）。这些都是只读查询，重试安全。
    if (status === 404) {
      await new Promise(function (resolve) { setTimeout(resolve, 600); });
      response = await LumeSource.http.post(API_URL + path, payload, options);
      status = response ? response.status : 0;
    }
    var text = response && response.body ? String(response.body) : '';
    if (status !== 200) {
      // 站点偶发也走 CF：按统一标记抛，App 会自动过校验并重试这次调用。
      if (status === 403 || status === 503 || status === 429 ||
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated/i.test(text)) {
        throw new Error('NEED_WEBVIEW_VERIFY：瓜子影视 需要网页视图过一次 Cloudflare 校验（HTTP ' + status + '）');
      }
      throw new Error('瓜子影视：接口 HTTP ' + status + ' ' + path);
    }
    try {
      return JSON.parse(text);
    } catch (error) {
      throw new Error('瓜子影视：接口返回的不是合法 JSON（' + path + '）');
    }
  }
};
