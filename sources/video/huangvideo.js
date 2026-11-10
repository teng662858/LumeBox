// LumeSource: {"id":"huangvideo_video","name":"黄视频","version":"1.0.0","category":"video","contentCategory":"adult","network":"direct","mirrors":["https://huang.video"],"icon":"https://huang.video/favicon.ico","settingsApiVersion":2,"requiresSettings":["settingsActions"],"settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开地址发布页","url":"https://18dh.pages.dev/","description":"站内「回家的路」公布的地址发布页；站点换域名时先看这里"},{"key":"publishPage2","type":"action","action":"openWebsite","title":"备用地址发布页","url":"https://daohang.pro/","description":"第二个地址发布页，同样收录本站"},{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 国产成人视频站（AI 短剧 / 糖心Vlog / 网红福利姬 / 探花 / PMV / ASMR），免登录、直连可看。播放是站方 HLS（720p），CDN 只认站点 Referer，源里已带上。"}]}
// LumeRuntime: javascript
//
// 站点：黄视频（huang.video），Rails 服务端渲染的国产成人视频站。
//
// 实测（2026-11-10）：
//   · 列表   /videos（24 条/页，?page=N）、/c/{shorts,tangxin,influencers,tanhua,pmv,asmr}
//            四档排序 ?sort=latest|popular|popular_24h|popular_7d，博主筛选 ?creator_id=N，
//            翻页链接带 rel="next"；分类页与排序实测首条互不相同。
//   · 搜索   /search?q=&sort=relevance|latest，结果分「短剧」（series，?series_page=N）与
//            「视频」（?page=N）两段，各自 24 条/页；源里两段一起取、按前缀区分。
//   · 卡片   <article id="video_ID"> / <article id="series_ID">：
//            首锚 aria-label=标题、img src=封面、badge=时长、卡片尾部 <p> 里是博主。
//   · 详情   /videos/ID：播放器 div 的 data-xg-player-source-value 直接给 master.m3u8，
//            poster 给封面；单集页还带整部剧的播放列表（/series/ID 与全部集数）。
//            /series/ID：h1#series-title + aspect-[2/3] 封面 + 「剧集」列表（全部集）。
//   · 播放   master.m3u8 与分片**只认站点 Referer**（无 Referer / 外站 Referer 都是 403），
//            所以 content() 带 Referer 头；实测 200 + #EXTM3U，720p 分片 200 video/mp2t。
//            封面/缩略图不需要 Referer，直连可取。
//   · 站内 ID 用复合串：v:视频ID / s:剧集ID，列表与选剧都按这个走。

var MIRRORS = ['https://huang.video'];
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

var CATEGORIES = [
  { id: 'all', title: '最新视频', path: '/videos' },
  { id: 'shorts', title: 'AI短剧', path: '/c/shorts' },
  { id: 'tangxin', title: '糖心Vlog', path: '/c/tangxin' },
  { id: 'influencers', title: '网红福利姬', path: '/c/influencers' },
  { id: 'tanhua', title: '探花大神', path: '/c/tanhua' },
  { id: 'pmv', title: 'PMV', path: '/c/pmv' },
  { id: 'asmr', title: 'ASMR', path: '/c/asmr' },
];

// 站方 <select name="sort"> 的取值与文案
var SORT_TITLES = {
  latest: '最新',
  popular: '最热门',
  popular_24h: '24h 最热',
  popular_7d: '7天最热',
};

function hvBase() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || MIRRORS[0]).replace(/\/+$/, '');
}

function hvHeaders(extra) {
  var headers = { 'User-Agent': UA, Referer: hvBase() + '/' };
  if (extra) {
    for (var key in extra) headers[key] = extra[key];
  }
  return headers;
}

async function hvGet(path) {
  var response = await LumeSource.http.get(hvBase() + path, {
    headers: hvHeaders({ Accept: 'text/html,application/xhtml+xml' }),
  });
  if (response.status === 403 || response.status === 503 || response.status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：黄视频返回人机校验（HTTP ' + response.status + '），可在网页视图里过一次校验');
  }
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('黄视频暂不可用（HTTP ' + response.status + '）');
  return response.body;
}

function hvText(value) {
  var entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', nbsp: ' ' };
  return String(value == null ? '' : value)
    .replace(/<[^>]*>/g, '')
    .replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, function (raw, key) {
      if (key.charAt(0) !== '#') return entities[key.toLowerCase()] || raw;
      var code = key.charAt(1).toLowerCase() === 'x'
        ? parseInt(key.slice(2), 16)
        : Number(key.slice(1));
      return code <= 0x10ffff ? String.fromCodePoint(code) : raw;
    })
    .replace(/\s+/g, ' ')
    .trim();
}

function hvSeconds(text) {
  var parts = String(text || '').trim().split(':');
  if (parts.length < 2 || parts.length > 3) return undefined;
  var seconds = 0;
  for (var i = 0; i < parts.length; i++) {
    if (!/^\d+$/.test(parts[i])) return undefined;
    seconds = seconds * 60 + Number(parts[i]);
  }
  return seconds;
}

function hvQuery(params) {
  var parts = [];
  for (var key in params) {
    if (!Object.prototype.hasOwnProperty.call(params, key)) continue;
    var value = params[key];
    if (value == null || value === '') continue;
    parts.push(key + '=' + encodeURIComponent(String(value)));
  }
  return parts.length ? '?' + parts.join('&') : '';
}

function hvParseId(raw) {
  var text = String(raw == null ? '' : raw).trim();
  var match = /^([vs]):(\d+)$/.exec(text);
  if (match) return { kind: match[1] === 's' ? 'series' : 'video', id: match[2] };
  if (/^\d+$/.test(text)) return { kind: 'video', id: text };
  return null;
}

function hvHasNext(html) {
  return /rel="next"/.test(String(html || ''));
}

// 列表页卡片：视频卡与短剧卡结构相同，用 article 上的 id 前缀区分。
function hvCards(html) {
  var text = String(html || '');
  var pattern = /<article[^>]*id="(video|series)_(\d+)"[^>]*>([\s\S]*?)<\/article>/g;
  var items = [];
  var seen = {};
  var matched;
  while ((matched = pattern.exec(text)) !== null) {
    var kind = matched[1];
    var numId = matched[2];
    var key = (kind === 'series' ? 's:' : 'v:') + numId;
    if (seen[key]) continue;
    seen[key] = true;

    var block = matched[3];
    var label = /aria-label="([^"]*)"/.exec(block);
    var heading = /<h3[^>]*>[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/.exec(block);
    var title = hvText(label ? label[1] : (heading ? heading[1] : ''));
    if (!title) continue;

    var cover = /<img[^>]*\ssrc="([^"]+)"/.exec(block);
    var badge = /class="badge[^"]*"[^>]*>([\s\S]*?)<\/span>/.exec(block);
    var durationText = badge ? hvText(badge[1]) : '';
    var creator = /<p class="truncate[^"]*">[\s\S]*?<a[^>]*>([\s\S]*?)<\/a>/.exec(block);

    items.push({
      id: key,
      title: title,
      cover: cover ? hvText(cover[1]) : undefined,
      subtitle: creator ? hvText(creator[1]) : undefined,
      duration: hvSeconds(durationText),
    });
  }
  return items;
}

function hvCategoryOf(categoryId) {
  var id = String(categoryId || 'all');
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i];
  }
  return CATEGORIES[0];
}

function hvSortOf(filters) {
  var raw = String((filters && filters.sort) || '').split(',')[0];
  return SORT_TITLES[raw] ? raw : 'latest';
}

function hvCreatorOf(filters) {
  var raw = String((filters && filters.creator) || '').split(',')[0];
  return /^\d+$/.test(raw) ? raw : '';
}

function hvFeatured(html) {
  var items = [];
  var pattern = /<article class="swiper-slide">([\s\S]*?)<\/article>/g;
  var matched;
  while ((matched = pattern.exec(String(html || ''))) !== null) {
    var block = matched[1];
    var href = /href="\/series\/(\d+)"/.exec(block);
    if (!href) continue;
    var title = /<h3[^>]*>([\s\S]*?)<\/h3>/.exec(block);
    var cover = /<img[^>]*\ssrc="([^"]+)"/.exec(block);
    var name = hvText(title ? title[1] : '');
    if (!name) continue;
    items.push({
      id: 's:' + href[1],
      title: name,
      cover: cover ? hvText(cover[1]) : undefined,
      subtitle: '精选短剧',
    });
  }
  return items;
}

function hvHomeSections(html) {
  var text = String(html || '');
  var sections = [];
  var featured = hvFeatured(text);
  if (featured.length) sections.push({ title: '精选推荐', items: featured });

  var pattern = /<section id="creator_category_\d+"[^>]*>([\s\S]*?)<\/section>/g;
  var matched;
  while ((matched = pattern.exec(text)) !== null) {
    var block = matched[1];
    var heading = /<h2[^>]*>([\s\S]*?)<\/h2>/.exec(block);
    var title = hvText(heading ? heading[1] : '');
    if (!title) continue;
    var more = /href="(\/c\/[^"]+)"[^>]*>\s*更多/.exec(block);
    var moreUrl;
    if (more) {
      for (var i = 0; i < CATEGORIES.length; i++) {
        if (CATEGORIES[i].path === more[1]) {
          moreUrl = CATEGORIES[i].id;
          break;
        }
      }
    }
    var items = hvCards(block);
    if (!items.length) continue;
    sections.push({ title: title, moreUrl: moreUrl, items: items });
  }
  return sections;
}

function hvSeriesMeta(html) {
  var count = /共\s*(\d+)\s*集/.exec(html);
  var views = /([\d,]+)\s*次观看/.exec(html);
  return {
    episodes: count ? Number(count[1]) : 0,
    views: views ? views[1] : '',
  };
}

function hvSeriesEpisodes(html) {
  var text = String(html || '');
  var start = text.indexOf('id="episodes-title"');
  if (start < 0) return [];
  var end = text.indexOf('</section>', start);
  var block = end > start ? text.slice(start, end) : text.slice(start);
  var pattern = /<a[^>]*href="\/videos\/(\d+)"[^>]*>([\s\S]*?)<\/a>/g;
  var items = [];
  var seen = {};
  var matched;
  while ((matched = pattern.exec(block)) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    seen[id] = true;
    var title = /<span class="font-semibold">([\s\S]*?)<\/span>/.exec(matched[2]);
    var duration = /<span class="text-sm[^"]*">([\s\S]*?)<\/span>/.exec(matched[2]);
    items.push({
      id: 'v:' + id,
      title: hvText(title ? title[1] : '第' + items.length + '集'),
      duration: hvSeconds(duration ? hvText(duration[1]) : ''),
    });
  }
  return items;
}

function hvPlaylist(html) {
  var text = String(html || '');
  var nav = /<nav[^>]*aria-label="[^"]*中的视频"[^>]*>([\s\S]*?)<\/nav>/.exec(text);
  if (!nav) return [];
  var pattern = /<a[^>]*href="\/videos\/(\d+)"[^>]*>([\s\S]*?)<\/a>/g;
  var items = [];
  var seen = {};
  var matched;
  while ((matched = pattern.exec(nav[1])) !== null) {
    var id = matched[1];
    if (seen[id]) continue;
    seen[id] = true;
    var title = /<span class="min-w-0 flex-1 truncate">([\s\S]*?)<\/span>/.exec(matched[2]);
    var duration = /<span class="shrink-0 tabular-nums[^"]*">([\s\S]*?)<\/span>/.exec(matched[2]);
    items.push({
      id: 'v:' + id,
      title: hvText(title ? title[1] : '第' + items.length + '集'),
      duration: hvSeconds(duration ? hvText(duration[1]) : ''),
    });
  }
  return items;
}

function hvVideoDetail(html, numId) {
  var text = String(html || '');
  var heading = /<h1[^>]*>([\s\S]*?)<\/h1>/.exec(text);
  var title = hvText(heading ? heading[1] : '');
  if (!title) return null;

  var poster = /data-xg-player-poster-value="([^"]*)"/.exec(text);
  var duration = /<span class="tabular-nums">(\d+:\d+(?::\d+)?)<\/span>/.exec(text);
  var creator = /href="\/creators\/[^"]*"[^>]*>([\s\S]*?)<\/a>/.exec(text);
  var views = /<span class="tabular-nums">([\d,]+)\s*次观看<\/span>/.exec(text);
  var intro = /id="video-description-title"[^>]*>[\s\S]*?<p class="mt-2[^"]*">([\s\S]*?)<\/p>/.exec(text);
  var published = /<time datetime="([^"]+)"/.exec(text);
  var series = /<h2 id="series-playlist-title"[^>]*>\s*<a[^>]*href="\/series\/(\d+)"[^>]*>([\s\S]*?)<\/a>/.exec(text);

  var lines = [];
  if (series) lines.push('所属剧集：' + hvText(series[2]));
  if (creator) lines.push('博主：' + hvText(creator[1]));
  if (duration) lines.push('时长：' + duration[1]);
  if (views) lines.push('观看：' + views[1]);
  if (published) lines.push('发布：' + published[1].slice(0, 10));
  if (intro) {
    var description = hvText(intro[1]);
    if (description) lines.push('', description);
  }

  return {
    id: 'v:' + numId,
    title: title,
    cover: poster ? hvText(poster[1]) : undefined,
    subtitle: (creator ? hvText(creator[1]) : '') + (duration ? ' · ' + duration[1] : ''),
    description: lines.join('\n'),
    mediaType: 'video',
  };
}

function hvSeriesDetail(html, numId) {
  var text = String(html || '');
  var heading = /<h1 id="series-title"[^>]*>([\s\S]*?)<\/h1>/.exec(text);
  var title = hvText(heading ? heading[1] : '');
  if (!title) return null;

  var cover = /class="aspect-\[2\/3\][\s\S]*?<img[^>]*\ssrc="([^"]+)"/.exec(text);
  var creator = /<nav[^>]*aria-label="面包屑导航"[\s\S]*?<a[^>]*href="\/creators\/[^"]*"[^>]*>([\s\S]*?)<\/a>/.exec(text);
  var meta = hvSeriesMeta(text);
  var updated = /<span>约?([^<]*?前更新)<\/span>/.exec(text);

  var lines = [];
  lines.push('剧集：共 ' + (meta.episodes || '若干') + ' 集');
  if (creator) lines.push('博主：' + hvText(creator[1]));
  if (meta.views) lines.push('观看：' + meta.views);
  if (updated) lines.push('更新：' + hvText(updated[1]));

  return {
    id: 's:' + numId,
    title: title,
    cover: cover ? hvText(cover[1]) : undefined,
    subtitle: '剧集 · 共 ' + (meta.episodes || '若干') + ' 集',
    description: lines.join('\n'),
    mediaType: 'video',
  };
}

var LumeSource = {
  categories() {
    var list = [];
    for (var i = 0; i < CATEGORIES.length; i++) {
      list.push({ id: CATEGORIES[i].id, title: CATEGORIES[i].title });
    }
    return list;
  },

  async home() {
    var html = await hvGet('/');
    if (html == null) throw new Error('黄视频首页打不开');
    var sections = hvHomeSections(html);
    if (!sections.length) throw new Error('黄视频首页没解析出内容（站方可能改版）');
    return sections;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Math.floor(Number(args.page) || 1));
    var keyword = String(args.keyword || '').trim();
    var filters = args.filters || {};
    var sort = hvSortOf(filters);
    var creator = hvCreatorOf(filters);

    if (keyword) {
      var searchSort = sort === 'latest' ? 'latest' : 'relevance';
      var searchPath = '/search' + hvQuery({
        q: keyword,
        sort: searchSort,
        page: page > 1 ? page : '',
        series_page: page > 1 ? page : '',
      });
      var searchHtml = await hvGet(searchPath);
      if (searchHtml == null) return { items: [], hasMore: false };
      var searchItems = hvCards(searchHtml);
      return {
        items: searchItems,
        hasMore: searchItems.length > 0 ? hvHasNext(searchHtml) : false,
      };
    }

    var category = hvCategoryOf(args.categoryId);
    var path = category.path + hvQuery({
      page: page > 1 ? page : '',
      sort: sort !== 'latest' ? sort : '',
      creator_id: creator,
    });
    var html = await hvGet(path);
    if (html == null) return { items: [], hasMore: false };
    var items = hvCards(html);
    if (!items.length && page === 1) {
      throw new Error('这个分类没解析出条目（' + category.title + '），站方可能改版');
    }
    return { items: items, hasMore: hvHasNext(html) };
  },

  async detail(argument) {
    var target = hvParseId(argument && argument.id);
    if (!target) return null;
    var html = await hvGet(target.kind === 'series' ? '/series/' + target.id : '/videos/' + target.id);
    if (html == null) return null;
    return target.kind === 'series'
      ? hvSeriesDetail(html, target.id)
      : hvVideoDetail(html, target.id);
  },

  async chapters(argument) {
    var target = hvParseId(argument && argument.id);
    if (!target) return [];

    if (target.kind === 'series') {
      var seriesHtml = await hvGet('/series/' + target.id);
      if (seriesHtml == null) return [];
      var episodes = hvSeriesEpisodes(seriesHtml);
      if (episodes.length) return episodes;
      var first = /class="btn btn-primary[^"]*"[^>]*href="\/videos\/(\d+)"/.exec(seriesHtml);
      return first ? [{ id: 'v:' + first[1], title: '第1集' }] : [];
    }

    var html = await hvGet('/videos/' + target.id);
    if (html == null) return [];
    var playlist = hvPlaylist(html);
    if (playlist.length) return playlist;
    return [{ id: 'v:' + target.id, title: '正片' }];
  },

  async content(argument) {
    var args = argument || {};
    var target = hvParseId(args.chapterId) || hvParseId(args.id);
    if (!target || target.kind !== 'video') throw new Error('这条内容不是可播放的视频');
    var html = await hvGet('/videos/' + target.id);
    if (html == null) throw new Error('视频不存在或已下架');
    var source = /data-xg-player-source-value="([^"]+)"/.exec(html);
    if (!source || !/^https?:\/\//.test(source[1])) {
      throw new Error('这条视频没有可播放地址（站方可能限制了播放）');
    }
    return {
      kind: 'video',
      url: hvText(source[1]),
      headers: { Referer: hvBase() + '/' },
    };
  },

  async filters() {
    var groups = [];
    var sortOptions = [];
    for (var key in SORT_TITLES) {
      if (!Object.prototype.hasOwnProperty.call(SORT_TITLES, key)) continue;
      sortOptions.push({ id: key, title: SORT_TITLES[key] });
    }

    var creators = [];
    try {
      var html = await hvGet('/videos');
      if (html != null) {
        var select = /<select name="sort"[\s\S]*?<\/select>/.exec(html);
        if (select) {
          var parsed = [];
          var optionPattern = /<option[^>]*value="([^"]+)"[^>]*>([^<]+)<\/option>/g;
          var option;
          while ((option = optionPattern.exec(select[0])) !== null) {
            if (SORT_TITLES[option[1]]) parsed.push({ id: option[1], title: hvText(option[2]) });
          }
          if (parsed.length) sortOptions = parsed;
        }

        var filterBlock = /id="creator-filter-options"[\s\S]*?<\/nav>/.exec(html);
        if (filterBlock) {
          var creatorPattern = /title="([^"]+)"\s+href="\/videos\?creator_id=(\d+)"/g;
          var creator;
          var seen = {};
          while ((creator = creatorPattern.exec(filterBlock[0])) !== null) {
            if (seen[creator[2]]) continue;
            seen[creator[2]] = true;
            creators.push({ id: creator[2], title: hvText(creator[1]) });
          }
        }
      }
    } catch (error) {
      // 站点被挡时仍给出站方固定的排序组，让用户至少能翻列表。
      creators = [];
    }

    groups.push({ id: 'sort', title: '排序', options: sortOptions });
    if (creators.length) {
      // 站方一次只认一个 creator_id，多选时取第一个。
      groups.push({ id: 'creator', title: '博主', options: creators });
    }
    return { groups: groups };
  },
};
