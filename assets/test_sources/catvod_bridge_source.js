// LumeSource: {"id":"catvod-bridge","name":"自建聚合服务桥接（CatVod/TVBox）","version":"1.0.0","category":"cat"}
//
// ============================================================================
// 这是什么
// ============================================================================
//
// **远端 Node 代理模式的薄壳源**（架构文档「降级备选：远端 Node 代理模式」）。
//
// 有一类猫源订阅**不是图源脚本**，而是「自建聚合服务端」的打包产物：
// 自带 HTTP 服务端、监听端口、内部挂着几十上百个站点适配器（如 CatVodSpiderios）。
// 这类包在 iOS 上装不了——沙箱没有端口、没有进程、没有 DNS（文档明令禁止），
// **补垫片也跑不起来**。
//
// 但它在**电脑 / NAS 上跑得很好**。于是文档给出的出路是：服务跑在电脑上，
// App 侧用一个薄壳脚本经宿主网络层转发过去。本文件就是那个薄壳。
//
// ============================================================================
// 怎么用（三步）
// ============================================================================
//
// 1. 在电脑 / NAS 上启动那个服务端包（`node index.js` 之类），记下它的地址，
//    形如 `http://192.168.1.5:9988`（手机与它要在同一局域网）。
// 2. 把下面的 BASE_URL 改成那个地址，然后导入本脚本到**猫源**板块。
// 3. 打开猫源 → 选分类（站点 · 栏目）→ 列表 / 搜索 / 详情 / 选集 / 播放。
//
// 站点与栏目清单由本脚本自动从服务端读出（`/full-config` + 各站点 `/home`），
// **不用手写**：服务端有多少站点，这里就有多少。
//
// ============================================================================
// 能力边界（如实说明）
// ============================================================================
//
// - **只转发，不解析**：所有抓取都由你电脑上那个服务端做（它才是真正的爬虫）。
//   本脚本只做三件事：把 App 的调用翻成它的 HTTP 接口、把返回翻成 App 契约、
//   把错误翻成人话。
// - **网盘类站点需要登录**：这类站点的播放地址来自夸克 / 百度 / 115 等网盘，
//   必须先在**服务端的配置中心**里登录对应网盘账号，play 才拿得到地址。
//   没登录时服务端会返回 500，本脚本会如实提示「去服务端配置中心登录」，
//   而不是含糊地报一句失败。
// - **首次加载要拉各站点的栏目**：站点清单是一次请求，栏目要逐站点取（结果
//   缓存 10 分钟，之后秒开）。站点很多时首次会慢一些，属正常。
// - **服务端必须可达**：手机与电脑要在同一局域网；服务端没开、地址写错、
//   被防火墙挡住，都会在页面上给出可读提示。
//
// 安全提醒：这等于把「抓取」放在你自己的设备上，App 只当遥控器。
// 服务端与 App 之间的流量在局域网内明文传输，别把它暴露到公网。
var BASE_URL = 'http://192.168.1.5:9988';

// 站点与栏目清单的缓存时长（毫秒）：这套清单很少变，没必要每次进页面都拉。
var SITES_TTL = 10 * 60 * 1000;

// 每次调用最多解析几个站点的栏目（见 __catalog 的说明）。
// 真实服务端有 90+ 站点，逐个取栏目既超沙箱预算也没必要——分批渐进，
// 每次进页面补齐一批，几次之后整份清单就齐了。
var CLASS_BATCH = 6;

// 搜索用哪个站点：服务端的 search 是「按站点」的，必须挑一个。
// 留空 = 优先用当前分类所属的站点；没有分类时用清单里第一个可搜索的站点。
// 想固定搜索来源就填站点 key（如 'wogg'）。
var SEARCH_SITE = '';

var LumeSource = {
  id: 'catvod-bridge',
  name: '自建聚合服务桥接（CatVod/TVBox）',
  version: '1.0.0',
  // 板块自报：猫源。导入其他板块会被解析阶段直接拒绝。
  category: 'cat',

  // ------------------------------------------------------------------ 请求

  /// 统一请求：POST JSON，非 2xx 抛可读错误。
  ///
  /// 网络层失败（服务端没开 / 地址错 / 局域网不通）会**拒绝**这个 Promise，
  /// 因此必须在这里接住——否则用户看到的是沙箱一句笼统的「调用超时」，
  /// 而不是「连不上自建服务、去确认地址」这句能行动的话。
  async __post(path, body) {
    var response;
    try {
      response = await LumeSource.http.post(
        BASE_URL + path,
        JSON.stringify(body || {}),
        { headers: { 'Content-Type': 'application/json' } }
      );
    } catch (error) {
      throw new Error(this.__explain(path, 0, String(error || '')));
    }
    return this.__parse(path, response);
  },

  async __get(path) {
    // 先做一次「快失败」可达性探测，再发真正的 GET。
    //
    // 为什么需要：宿主网络层对 GET 这类幂等请求会自动重试（默认 3 次 + 退避），
    // 服务端没开时整条链路要 7–8 秒才抛错——而沙箱的单次调用预算是 4 秒，
    // 于是**沙箱先超时**，用户看到的是笼统的「调用超时」，不是下面那句
    // 「连不上自建服务、去确认地址」。POST 不参与重试，连不上时约 2 秒即返回，
    // 因此拿它当探测：探测能拿到**任何**响应（哪怕是 404）都说明服务是活的。
    await this.__probe();
    var response;
    try {
      response = await LumeSource.http.get(BASE_URL + path);
    } catch (error) {
      throw new Error(this.__explain(path, 0, String(error || '')));
    }
    return this.__parse(path, response);
  },

  /// 可达性探测：POST 一个必然存在的路径。
  ///
  /// 用 POST 是因为它**不重试**（宿主网络层只对幂等方法退避重试），
  /// 因此服务端没开时能在预算内快速失败。响应状态不参与判断——能收到响应
  /// 就说明「地址对、服务活着」；收不到（抛异常）才是真的连不上。
  async __probe() {
    try {
      await LumeSource.http.post(BASE_URL + '/health', '{}');
    } catch (error) {
      throw new Error(this.__explain('/health', 0, String(error || '')));
    }
  },

  __parse(path, response) {
    var status = response ? response.status : 0;
    var text = (response && response.body) || '';
    if (status < 200 || status >= 300) {
      throw new Error(this.__explain(path, status, text));
    }
    if (!text) return {};
    try {
      return JSON.parse(text);
    } catch (error) {
      throw new Error('服务端返回的不是合法 JSON（' + path + '）：'
        + String(text).slice(0, 120));
    }
  },

  /// 把失败翻成人话：用户看到的是「该怎么办」，不是一句 statusCode。
  __explain(path, status, body) {
    var detail = String(body || '').replace(/\s+/g, ' ').slice(0, 160);
    if (status === 0) {
      return '连不上自建服务（' + BASE_URL + '）：'
        + '确认服务端已启动、地址写对、手机与电脑在同一局域网，且防火墙放行该端口。'
        + (detail ? '（' + detail + '）' : '');
    }
    if (status === 500 && detail.indexOf('not valid JSON') >= 0) {
      return '服务端处理失败（' + path + '）：多为网盘类站点尚未登录。'
        + '请打开服务端的配置中心登录对应网盘账号后重试。';
    }
    if (status === 404) {
      return '服务端没有这个接口（' + path + '）：'
        + '确认它确实是 CatVod / TVBox 系的自建聚合服务端（本脚本按该协议转发）。';
    }
    return '服务端返回 HTTP ' + status + '（' + path + '）'
      + (detail ? '：' + detail : '');
  },

  // -------------------------------------------------------------- 站点清单

  /// 站点清单（`/full-config`，一次请求）+ 已解析出来的栏目，带缓存。
  ///
  /// **本函数只保证站点清单就位，不主动解析任何站点的栏目**——栏目按需解析
  /// （见 [__classesFor]）。这一点是性能上的硬要求：真实服务端有 90+ 站点，
  /// 每个站点的 `/home` 要 0.4–0.9 秒；若在每次调用里都补一批，列表页（还要再
  /// 发一次 category 请求）会直接撞穿沙箱 4 秒的单次预算。
  ///
  /// 结果形状：`[{key, name, api, searchable, classes:[{id, name}]}]`
  /// `classes` 为空表示「该站点的栏目还没解析过」。
  async __catalog() {
    var cached = await LumeSource.fs.readText('cache/catalog.json');
    if (cached) {
      try {
        var parsed = JSON.parse(String(cached));
        if (parsed && parsed.at && Date.now() - parsed.at < SITES_TTL
            && parsed.sites && parsed.sites.length) {
          return parsed.sites;
        }
      } catch (error) {
        // 缓存坏了就重新拉：不因为一份坏缓存让图源不可用。
      }
    }

    var config = await this.__get('/full-config');
    var raw = (config && config.video && config.video.sites) || [];
    var sites = [];
    for (var i = 0; i < raw.length; i++) {
      var site = raw[i];
      if (!site || !site.key || !site.api) continue;
      if (site.enable === false) continue;
      sites.push({
        key: String(site.key),
        name: String(site.name || site.key),
        api: String(site.api),
        searchable: site.searchable === 1 || site.searchable === true,
        classes: []
      });
    }
    if (sites.length === 0) {
      throw new Error('服务端没有返回任何可用站点：'
        + '确认它已加载站点配置（/full-config 的 video.sites 为空）。');
    }
    await this.__saveCatalog(sites);
    return sites;
  },

  async __saveCatalog(sites) {
    await LumeSource.fs.writeText(
      'cache/catalog.json',
      JSON.stringify({ at: Date.now(), sites: sites })
    );
  },

  /// 取某个站点的栏目，并**写回缓存**（下次不再请求）。
  ///
  /// 失败时返回空数组而不抛错：单个站点改版不该让整个分类列表不可用。
  async __classesFor(site) {
    if (site.classes && site.classes.length > 0) return site.classes;
    var classes = [];
    try {
      classes = await this.__classesOf(site.api);
    } catch (error) {
      return [];
    }
    if (classes.length > 0) {
      site.classes = classes;
      // 写回：把这次解析结果持久化，避免下次进页面重复请求。
      try {
        var sites = await this.__catalog();
        for (var i = 0; i < sites.length; i++) {
          if (sites[i].key === site.key) sites[i].classes = classes;
        }
        await this.__saveCatalog(sites);
      } catch (error) {
        // 写缓存失败不影响本次结果。
      }
    }
    return classes;
  },

  /// 取一个站点的栏目清单（`/home` 的 `class`）。
  async __classesOf(api) {
    var home = await this.__post(api + '/home', {});
    var raw = (home && home.class) || [];
    var classes = [];
    for (var i = 0; i < raw.length; i++) {
      var item = raw[i];
      if (!item || item.type_id === undefined || item.type_id === null) continue;
      classes.push({
        id: String(item.type_id),
        name: String(item.type_name || item.type_id)
      });
    }
    return classes;
  },

  async __site(key) {
    var sites = await this.__catalog();
    for (var i = 0; i < sites.length; i++) {
      if (sites[i].key === key) return sites[i];
    }
    throw new Error('站点不存在或已从服务端移除：' + key
      + '（重新进一次本图源可刷新站点清单）');
  },

  // ------------------------------------------------------------------ 契约

  /// 分类 = 「站点 · 栏目」。
  ///
  /// 为什么要拼两层：服务端是「站点 → 栏目 → 分页列表」三级结构，而 App 契约
  /// 只有「分类 → 分页列表」两级。把两层拼成一个 id（`站点key|栏目id`）既保住
  /// 了服务端的真实分页，又不用改任何上层代码。
  ///
  /// **栏目是按需解析的，且每次只解析 [CLASS_BATCH] 个站点**：真实服务端有 90+
  /// 站点、每个 `/home` 要 0.4–0.9 秒，一次全解析会撞穿沙箱 4 秒的单次预算。
  /// 已解析的站点直接出「站点 · 栏目」条目，未解析的先用「站点」占位——点进去
  /// 时（[list]）会解析它的栏目并取第一个。因此**任何站点都能立刻点进去**，
  /// 多进几次页面后整份清单自然补齐（结果落缓存，10 分钟内不再请求）。
  async categories() {
    var sites = await this.__catalog();
    var budget = CLASS_BATCH;
    for (var i = 0; i < sites.length && budget > 0; i++) {
      if (sites[i].classes && sites[i].classes.length > 0) continue;
      budget--;
      await this.__classesFor(sites[i]);
    }

    var result = [];
    for (var s = 0; s < sites.length; s++) {
      var site = sites[s];
      if (!site.classes || site.classes.length === 0) {
        result.push({ id: site.key + '|', title: site.name });
        continue;
      }
      for (var c = 0; c < site.classes.length; c++) {
        result.push({
          id: site.key + '|' + site.classes[c].id,
          title: site.name + ' · ' + site.classes[c].name
        });
      }
    }
    return result;
  },

  /// 列表：分类浏览与搜索共用这一入口。
  async list(argument) {
    var options = argument && typeof argument === 'object' ? argument : {};
    var page = options.page ? Number(options.page) : 1;
    var keyword = options.keyword ? String(options.keyword) : '';
    var categoryId = options.categoryId ? String(options.categoryId) : '';

    if (keyword) return this.__search(keyword, page, categoryId);

    if (!categoryId || categoryId.indexOf('|') < 0) {
      throw new Error('请先在上方选择一个分类（站点 · 栏目）。');
    }
    var parts = categoryId.split('|');
    var site = await this.__site(parts[0]);
    var typeId = parts[1];
    // 空栏目（该站点的栏目还没解析过）：解析它，取第一个栏目。
    if (!typeId) {
      var classes = await this.__classesFor(site);
      if (!classes || classes.length === 0) {
        throw new Error('站点「' + site.name + '」没有可用栏目：'
          + '它可能在服务端未就绪或已改版，换一个站点试试。');
      }
      typeId = classes[0].id;
    }

    var data = await this.__post(site.api + '/category', { id: typeId, page: page });
    return {
      items: this.__toItems(site.key, data && data.list),
      hasMore: this.__hasMore(data, page)
    };
  },

  /// 搜索：服务端的 search 是「按站点」的，因此必须挑一个站点。
  async __search(keyword, page, categoryId) {
    var siteKey = '';
    if (categoryId && categoryId.indexOf('|') >= 0) siteKey = categoryId.split('|')[0];
    if (!siteKey) siteKey = SEARCH_SITE;
    if (!siteKey) {
      var sites = await this.__catalog();
      for (var i = 0; i < sites.length; i++) {
        if (sites[i].searchable) { siteKey = sites[i].key; break; }
      }
      if (!siteKey) siteKey = sites[0].key;
    }
    var site = await this.__site(siteKey);
    var data = await this.__post(site.api + '/search', { wd: keyword, page: page });
    return {
      items: this.__toItems(site.key, data && data.list),
      hasMore: this.__hasMore(data, page)
    };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return null;
    var split = this.__splitItemId(id);
    var site = await this.__site(split.site);
    var data = await this.__post(site.api + '/detail', { id: split.vodId });
    var item = ((data && data.list) || [])[0];
    if (!item) return null;
    return {
      id: id,
      title: String(item.vod_name || split.vodId),
      cover: item.vod_pic ? String(item.vod_pic) : '',
      subtitle: String(item.vod_remarks || ''),
      description: String(item.vod_content || item.vod_blurb || '')
    };
  },

  /// 章节 = 线路 × 剧集。
  ///
  /// 服务端把线路与剧集压在两个 `$$$` 分隔的字符串里：
  ///   vod_play_from: `夸克原画$$$夸克极速`
  ///   vod_play_url : `集名1$集id1#集名2$集id2$$$另一条线路的…`
  /// 两组按下标对齐。这里摊平成一维章节列表（id 里带上线路下标与剧集 id），
  /// 用户看到的标题是「线路 · 集名」——与其它视频源的选集体验一致。
  async chapters(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return [];
    var split = this.__splitItemId(id);
    var site = await this.__site(split.site);
    var data = await this.__post(site.api + '/detail', { id: split.vodId });
    var item = ((data && data.list) || [])[0];
    if (!item) return [];
    return this.__parseChapters(item.vod_play_from, item.vod_play_url);
  },

  /// 播放地址：调服务端的 play，把结果翻成视频契约。
  async content(argument) {
    var options = argument && typeof argument === 'object' ? argument : {};
    var id = options.id ? String(options.id) : '';
    var chapterId = options.chapterId ? String(options.chapterId) : '';
    if (!id || !chapterId) {
      throw new Error('缺少作品或剧集参数，无法取播放地址。');
    }
    var split = this.__splitItemId(id);
    var chapter = this.__splitChapterId(chapterId);
    var site = await this.__site(split.site);

    // play 要的是线路**名**（不是下标），因此先取一次详情把名字查出来。
    var data = await this.__post(site.api + '/detail', { id: split.vodId });
    var item = ((data && data.list) || [])[0];
    if (!item) throw new Error('服务端没有返回该作品的详情，无法播放。');
    var froms = String(item.vod_play_from || '').split('$$$');
    var flag = froms[chapter.line];
    if (!flag) {
      throw new Error('该线路已不存在（服务端可能更新过资源），请返回重新选集。');
    }

    var play = await this.__post(site.api + '/play', {
      id: split.vodId,
      flag: flag,
      ep: chapter.episode
    });
    var url = this.__playUrl(play);
    if (!url) {
      throw new Error('服务端没有给出播放地址（可能是网盘未登录或该集已失效）。');
    }
    return { kind: 'video', url: url };
  },

  // ------------------------------------------------------------ 解析小工具

  /// 条目 id 里要带站点：服务端是「一个站点一套内容」，id 不带站点就没法回查。
  __joinItemId(siteKey, vodId) {
    return siteKey + '@' + String(vodId);
  },

  __splitItemId(id) {
    var at = String(id).indexOf('@');
    if (at < 0) {
      throw new Error('条目 id 形状不对（应为 站点@作品id）：' + id
        + '。请刷新列表后重试。');
    }
    return { site: String(id).slice(0, at), vodId: String(id).slice(at + 1) };
  },

  __joinChapterId(line, episode) {
    return String(line) + '@' + String(episode);
  },

  __splitChapterId(chapterId) {
    var at = String(chapterId).indexOf('@');
    if (at < 0) return { line: 0, episode: String(chapterId) };
    return {
      line: Number(String(chapterId).slice(0, at)) || 0,
      episode: String(chapterId).slice(at + 1)
    };
  },

  __toItems(siteKey, list) {
    var items = [];
    if (!list || !list.length) return items;
    for (var i = 0; i < list.length; i++) {
      var row = list[i];
      if (!row) continue;
      var vodId = row.vod_id;
      if (vodId === undefined || vodId === null || String(vodId) === '') continue;
      items.push({
        id: this.__joinItemId(siteKey, vodId),
        title: String(row.vod_name || vodId),
        cover: row.vod_pic ? String(row.vod_pic) : '',
        subtitle: String(row.vod_remarks || '')
      });
    }
    return items;
  },

  __hasMore(data, page) {
    if (!data) return false;
    var count = Number(data.pagecount || 0);
    if (!count) return false;
    return Number(page) < count;
  },

  __parseChapters(playFrom, playUrl) {
    var result = [];
    var froms = String(playFrom || '').split('$$$');
    var groups = String(playUrl || '').split('$$$');
    for (var line = 0; line < groups.length; line++) {
      var lineName = froms[line] ? String(froms[line]).trim() : ('线路' + (line + 1));
      var episodes = groups[line] ? String(groups[line]).split('#') : [];
      for (var e = 0; e < episodes.length; e++) {
        var raw = episodes[e];
        if (!raw) continue;
        var sep = raw.lastIndexOf('$');
        var name = sep >= 0 ? raw.slice(0, sep) : raw;
        var episodeId = sep >= 0 ? raw.slice(sep + 1) : raw;
        if (!episodeId) continue;
        result.push({
          id: this.__joinChapterId(line, episodeId),
          title: lineName + ' · ' + String(name || ('第' + (e + 1) + '集'))
        });
      }
    }
    return result;
  },

  /// 从 play 的返回里挖出地址：不同服务端版本字段名不一样，逐个试。
  __playUrl(play) {
    if (!play) return '';
    if (typeof play === 'string') return play;
    var candidates = [play.url, play.playUrl, play.play_url, play.jx, play.msg];
    for (var i = 0; i < candidates.length; i++) {
      var value = candidates[i];
      if (typeof value === 'string' && value.indexOf('http') === 0) return value;
    }
    var data = play.data;
    if (data) {
      var nested = [data.url, data.playUrl, data.play_url];
      for (var n = 0; n < nested.length; n++) {
        var item = nested[n];
        if (typeof item === 'string' && item.indexOf('http') === 0) return item;
      }
    }
    return '';
  }
};
