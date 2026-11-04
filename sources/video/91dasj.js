// LumeSource: {"id":"91dasj_video","name":"91大事件","version":"1.0.0","category":"video","contentCategory":"adult","mirrors":["https://campus.ravwriau.cc","https://91dasj.com"],"network":"direct","icon":"https://campus.ravwriau.cc/favicon.ico"}
// LumeRuntime: javascript
//
// 站点：91大事件（Typecho + Mirages + tbxw/DPlayer 插件）。用户给的入口域是 campus.ravwriau.cc，
// 页面里的 canonical / og:url 指向官方主域 91dasj.com，两者同内容、都实测直连 200，所以做成一个源 + mirrors。
//
// 结构（2026-11-04 逐页实测）：
//   · 列表            /                          首页（最新混合）
//                     /page/{N}/                 往期内容（全站倒序，第 1 页 = 首页）
//                     /category/{slug}/         分类首页（12 个分类）
//                     /category/{slug}/{N}/     分类分页
//                     /tag/{词}/{N}/             标签分页（/tags.html 给了 300 个标签）
//                     /search/{词}/{N}/          站内搜索（真分页，实测「探花」共 12 页）
//   · 卡片            <a href="/archives/{pid}/"> + .post-card-title + loadBannerDirect('封面') + .post-card-category
//   · 详情            /archives/{pid}/          每个帖子 1–3 个 <div class="dplayer" data-config="{&quot;video&quot;:{&quot;url&quot;:…}}">
//   · 分页信息        「第 2 / 共 296 页」
//
// 播放：DPlayer 插件的 data-config 里就是原生 m3u8（`op.udhhzr.cn/videos5/{hash}/{hash}.m3u8?auth_key=…`），
// 与 91吃瓜（91cg1）同一套 CDN。实测清单 206 + #EXTM3U，不需要 Referer。
// 没有视频的帖子（少数纯图集）交给 App 的网页播放器打开原帖。
//
// 封面：pic.hdhwqx.cn 上的图是 **AES-128-CBC(PKCS7) 密文**（响应头还写 binary/octet-stream，
// 文件头 09 3d e3 b1），key/iv 与 91吃瓜同源（站点 zzz.js 的 decryptImage），交给 App 原生解密：
//   key=f5d965df75336270  iv=97b60394abc2fbe1（本机用 node crypto 解出真 JPEG：ffd8ffe0）。
//
// 分类 / 筛选 / 排序：
//   · 12 个分类全部实测出内容且首条互不相同；
//   · 「标签」做成筛选组（24 个常用标签，抽测都换内容）；站点标签页只吃单个词，
//     多选时取第一个（与源约定第 3 条一致）；
//   · 站点**没有排序参数**（Typecho 只有发布时间倒序；`?sort=`/`?order=` 实测被忽略），
//     所以本源不声明排序组，不放假选项。

var BASE_URL = 'https://campus.ravwriau.cc';
var UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
var POST_TTL_MS = 10 * 60 * 1000;
var PAGE_SIZE = 20;

var CATS = [
  { id: 'mrxl', title: '今日吃瓜' },
  { id: 'mldjh', title: '热门吃瓜' },
  { id: 'aifl', title: 'AI短剧' },
  { id: 'jchj', title: '每日大赛' },
  { id: 'qwys', title: '伦理猎奇' },
  { id: 'xyml', title: '学生校园' },
  { id: 'whmx', title: '网红吃瓜' },
  { id: 'whzq', title: '网黄吃瓜' },
  { id: 'rmbg', title: '反差女神' },
  { id: 'jxth', title: '探花大神' },
  { id: 'ldcz', title: 'AV动漫' },
  { id: 'tycg', title: '体育直播' }
];

var TAGS = [
  '吃瓜', '黑料', '口交', '后入', '巨乳', '反差', '网红', '推特',
  '剧情', '黑丝', '高颜值', '约炮', '白虎', '抖音', '反差婊', '内射',
  '调教', '无套', '自慰', '学生', '探花', '网黄', '女神', '合集'
];

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

// 站点把封面整张图做成 AES-CBC 密文（zzz.js decryptImage），交给 App 原生解密。
function coverHeaders() {
  return {
    Referer: base() + '/',
    'X-Lume-Image-Encoding': 'aes-cbc-pkcs7',
    'X-Lume-Image-Key': 'f5d965df75336270',
    'X-Lume-Image-IV': '97b60394abc2fbe1'
  };
}

async function readJson(file) {
  try {
    var raw = await LumeSource.fs.readText(file);
    if (!raw) return null;
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

async function writeJson(file, value) {
  try {
    await LumeSource.fs.writeText(file, JSON.stringify(value));
  } catch (error) {
    /* 缓存失败不影响主流程 */
  }
}

async function fetchHtml(path) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503) {
    throw new Error('NEED_WEBVIEW_VERIFY：91大事件触发了 Cloudflare 人机校验（HTTP ' + status + '）');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  return reply.body ? String(reply.body) : '';
}

function decodeEntities(text) {
  return String(text == null ? '' : text)
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return String(text == null ? '' : text)
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function oneLine(text) {
  return clean(text).replace(/\s+/g, ' ').trim();
}

// 卡片标题里挂着角标（「热搜 HOT」/「置顶」），详情 og:title 末尾挂站名，统一削掉
function tidyTitle(text) {
  return oneLine(text)
    .replace(/\s*(热搜\s*HOT|HOT|置顶|精华)\s*$/i, '')
    .replace(/\s*[-_|]\s*91大事件\s*$/, '')
    .trim();
}

function parseCards(html) {
  var text = String(html || '');
  var items = [];
  var seen = {};
  var re = /<a\s+href="\/archives\/(\d+)\/"/g;
  var marks = [];
  var matched;
  while ((matched = re.exec(text)) !== null) marks.push({ at: matched.index, pid: matched[1] });
  for (var i = 0; i < marks.length; i++) {
    var pid = marks[i].pid;
    if (seen[pid]) continue;
    var end = i + 1 < marks.length ? marks[i + 1].at : Math.min(text.length, marks[i].at + 6000);
    var block = text.slice(marks[i].at, end);
    // 只在「卡片块」里认标题：没有 .post-card 的链接（导航、猜你喜欢）跳过
    if (block.indexOf('post-card') < 0) continue;
    var titleMatch = /class="post-card-title"[^>]*>([\s\S]*?)<\/h2>/.exec(block);
    var title = tidyTitle(titleMatch ? titleMatch[1] : '');
    if (!title) continue;
    var coverMatch = /loadBannerDirect\('([^']+)'/.exec(block);
    var dateMatch = /datePublished"\s+content="([^"]+)"/.exec(block);
    var catsMatch = /class="post-card-category"[^>]*>([\s\S]*?)<\/span>/.exec(block);
    seen[pid] = true;
    items.push({
      id: pid,
      title: title,
      cover: absolute(coverMatch ? coverMatch[1] : ''),
      coverHeaders: coverHeaders(),
      subtitle: [
        catsMatch ? oneLine(catsMatch[1]) : '',
        dateMatch ? String(dateMatch[1]).slice(0, 10) : ''
      ].filter(Boolean).join(' · ')
    });
  }
  return items;
}

function pagerOf(html) {
  var matched = /第\s*(\d+)\s*\/\s*共\s*(\d+)\s*页/.exec(String(html || ''));
  if (!matched) return null;
  return { page: Number(matched[1]), total: Number(matched[2]) };
}

function pidOf(value) {
  var text = String(value == null ? '' : value).trim();
  var matched = /\/archives\/(\d+)/.exec(text) || /^(\d+)/.exec(text);
  return matched ? matched[1] : '';
}

function parseVideos(html) {
  var text = String(html || '');
  var out = [];
  var re = /<div class="dplayer"([\s\S]{0,4000}?)data-config="([\s\S]*?)"><\/div>/g;
  var matched;
  while ((matched = re.exec(text)) !== null) {
    var attrs = matched[1];
    var titleRaw = (attrs.match(/data-video_title="([^"]*)"/) || [])[1] || '';
    var config = decodeEntities(matched[2]);
    var urlMatch = /"video":\{"url":"([^"]+)"/.exec(config);
    var typeMatch = /"type":"([^"]+)"/.exec(config);
    var url = urlMatch ? String(urlMatch[1]).replace(/\\\//g, '/').replace(/\\u0026/g, '&') : '';
    if (!url) continue;
    out.push({
      url: url,
      type: typeMatch ? String(typeMatch[1]) : 'hls',
      title: oneLine(titleRaw)
    });
  }
  return out;
}

async function postData(pid) {
  var cacheFile = 'p-v1-' + pid + '.json';
  var cached = await readJson(cacheFile);
  if (cached && cached.at && Date.now() - Number(cached.at) < POST_TTL_MS) return cached;

  var html = await fetchHtml('/archives/' + pid + '/');
  var ogTitle = /<meta\s+property="og:title"\s+content="([^"]*)"/.exec(html);
  var h1 = /<h1[^>]*>([\s\S]{0,240}?)<\/h1>/.exec(html);
  var desc = /<meta\s+name="description"\s+content="([^"]*)"/.exec(html);
  var kw = /<meta\s+name="keywords"\s+content="([^"]*)"/.exec(html);
  var ogImage = /<meta\s+property="og:image"\s+content="([^"]*)"/.exec(html);
  var videos = parseVideos(html);
  var images = [];
  var imgRe = /data-xkrkllgl="([^"]+)"/g;
  var matched;
  while ((matched = imgRe.exec(html)) !== null) {
    var url = absolute(matched[1]);
    if (url) images.push(url);
  }
  var cover = images.length ? images[0] : (ogImage ? absolute(ogImage[1]) : '');

  var data = {
    at: Date.now(),
    id: pid,
    title: tidyTitle(ogTitle ? ogTitle[1] : (h1 ? h1[1] : '')),
    cover: cover,
    description: oneLine(desc ? desc[1] : ''),
    tags: oneLine(kw ? kw[1] : ''),
    imageCount: images.length,
    videos: videos
  };
  await writeJson(cacheFile, data);
  return data;
}

function listPath(page, categoryId, keyword, tag) {
  var suffix = page > 1 ? String(page) + '/' : '';
  if (keyword) return '/search/' + encodeURIComponent(keyword) + '/' + suffix;
  if (tag) return '/tag/' + encodeURIComponent(tag) + '/' + suffix;
  if (categoryId === 'archives') return page > 1 ? '/page/' + page + '/' : '/';
  if (categoryId) return '/category/' + String(categoryId) + '/' + suffix;
  return page > 1 ? '/page/' + page + '/' : '/';
}

var LumeSource = {
  id: '91dasj_video',
  name: '91大事件',
  version: '1.0.0',
  category: 'video',
  contentCategory: 'adult',
  network: 'direct',
  icon: 'https://campus.ravwriau.cc/favicon.ico',
  mirrors: ['https://campus.ravwriau.cc', 'https://91dasj.com'],

  async categories() {
    var list = [{ id: '', title: '最新' }];
    for (var i = 0; i < CATS.length; i++) list.push({ id: CATS[i].id, title: CATS[i].title });
    list.push({ id: 'archives', title: '往期内容' });
    return list;
  },

  async filters() {
    return {
      groups: [
        {
          id: 'tag',
          title: '标签',
          options: TAGS.map(function (word) {
            return { id: word, title: word };
          })
        }
      ]
    };
  },

  async home() {
    var boards = [];
    var latest = parseCards(await fetchHtml('/'));
    if (latest.length) boards.push({ title: '最新', moreUrl: '', items: latest.slice(0, 12) });
    var picks = ['热门吃瓜', '探花大神', '网黄吃瓜', '每日大赛'];
    for (var i = 0; i < picks.length; i++) {
      var cat = null;
      for (var k = 0; k < CATS.length; k++) {
        if (CATS[k].title === picks[i]) cat = CATS[k];
      }
      if (!cat) continue;
      try {
        var cards = parseCards(await fetchHtml(listPath(1, cat.id, '', ''))).slice(0, 12);
        if (cards.length) boards.push({ title: cat.title, moreUrl: cat.id, items: cards });
      } catch (error) {
        /* 单个分类失败不影响首页 */
      }
    }
    if (!boards.length) throw new Error('首页没解析出任何条目（站点模板可能改了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var page = Math.max(1, Number(args.page) || 1);
    var keyword = oneLine(args.keyword || '');
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var filters = args.filters || {};
    var tag = oneLine(filters.tag || '');
    if (tag && tag.indexOf(',') >= 0) tag = tag.split(',')[0].trim();

    var path = listPath(page, categoryId, keyword, tag);
    var html = await fetchHtml(path);
    var items = parseCards(html);
    var pager = pagerOf(html);
    var hasMore = pager ? page < pager.total : items.length >= PAGE_SIZE;
    if (!items.length) {
      if (keyword) return { items: [], hasMore: false };
      if (page === 1) throw new Error('这个分类没有取到条目（' + (categoryId || '最新') + '，站点模板可能改了）');
    }
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var pid = pidOf(argument && argument.id);
    if (!pid) return null;
    var data = await postData(pid);
    if (!data || !data.title) return null;
    var bits = [];
    bits.push(data.videos.length ? data.videos.length + ' 段视频' : '源站无原生视频');
    if (data.imageCount) bits.push(data.imageCount + ' 张配图');
    var description = data.description;
    if (data.tags) description += (description ? '\n\n' : '') + '标签：' + data.tags;
    return {
      id: pid,
      title: data.title,
      cover: data.cover || '',
      coverHeaders: coverHeaders(),
      subtitle: bits.join(' · '),
      description: description
    };
  },

  async chapters(argument) {
    var pid = pidOf(argument && argument.id);
    if (!pid) return [];
    var data = await postData(pid);
    if (!data) return [];
    if (!data.videos.length) {
      return [{ id: pid + ':0', title: '原帖（源站无原生视频）' }];
    }
    return data.videos.map(function (item, index) {
      // data-video_title 末尾挂着 3 位序号（…001），去掉更像标题
      var name = String(item.title || '').replace(/\d{3}$/, '').trim();
      return { id: pid + ':' + index, title: name || '片段 ' + (index + 1) };
    });
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var pid = pidOf(raw) || pidOf(args.id);
    var index = 0;
    var tail = /:(\d+)$/.exec(raw);
    if (tail) index = Number(tail[1]) || 0;
    if (!pid) throw new Error('缺少帖子 ID');
    var data = await postData(pid);
    if (!data) throw new Error('帖子打不开：' + base() + '/archives/' + pid + '/');
    var video = data.videos[index];
    if (video && video.url) {
      return {
        kind: 'video',
        url: video.url,
        headers: { Referer: base() + '/', 'User-Agent': UA }
      };
    }
    return {
      kind: 'webplayer',
      pageUrl: base() + '/archives/' + pid + '/',
      headers: { Referer: base() + '/', 'User-Agent': UA }
    };
  }
};
