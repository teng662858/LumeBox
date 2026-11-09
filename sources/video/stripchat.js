// LumeSource: {"id":"stripchat_live_video","name":"Stripchat 中文直播","version":"1.2.0","category":"video","contentCategory":"adult","network":"proxy","mirrors":["https://zh.stripchat.com","https://stripchat.com"],"icon":"https://zh.stripchat.com/favicon.ico","settings":[{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 成人直播。合并四个公开直播目录，筛选取自官网分类页。封面用站方每秒快照（列表每 20 秒自动换一帧），角标标主播国籍；播放走站方网页播放器——站方对分片名做了 PSCH v2 改名，第三方播放器只能取到占位分片。"}]}

const SC_HOME = 'https://zh.stripchat.com';
const SC_PAGE_SIZE = 24;
const SC_SNAP_HOST = 'https://img.doppiocdn.net';
const SC_DIRECTORIES = [
  { id: 'girls', title: '女主播' },
  { id: 'couples', title: '情侣' },
  { id: 'men', title: '男主播' },
  { id: 'trans', title: '跨性别' },
];
const SC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';

/** 国籍代码 → 中文名。站方下发两字母 ISO 码（部分主播不填）。 */
const SC_COUNTRIES = {
  cn: '中国', tw: '台湾', hk: '香港', mo: '澳门', jp: '日本', kr: '韩国',
  vn: '越南', th: '泰国', ph: '菲律宾', id: '印尼', my: '马来西亚', sg: '新加坡',
  kh: '柬埔寨', la: '老挝', mm: '缅甸', bn: '文莱', mn: '蒙古', in: '印度',
  pk: '巴基斯坦', bd: '孟加拉', lk: '斯里兰卡', np: '尼泊尔', kz: '哈萨克',
  uz: '乌兹别克', kg: '吉尔吉斯', tj: '塔吉克', ge: '格鲁吉亚', am: '亚美尼亚',
  az: '阿塞拜疆', ru: '俄罗斯', ua: '乌克兰', by: '白俄', md: '摩尔多瓦',
  pl: '波兰', ro: '罗马尼亚', bg: '保加利亚', hu: '匈牙利', cz: '捷克',
  sk: '斯洛伐克', rs: '塞尔维亚', hr: '克罗地亚', si: '斯洛文尼亚', ee: '爱沙尼亚',
  lv: '拉脱维亚', lt: '立陶宛', de: '德国', at: '奥地利', ch: '瑞士',
  fr: '法国', be: '比利时', nl: '荷兰', lu: '卢森堡', gb: '英国',
  ie: '爱尔兰', es: '西班牙', pt: '葡萄牙', it: '意大利', gr: '希腊',
  tr: '土耳其', il: '以色列', lb: '黎巴嫩', jo: '约旦', sa: '沙特',
  ae: '阿联酋', qa: '卡塔尔', kw: '科威特', bh: '巴林', om: '阿曼',
  iq: '伊拉克', ir: '伊朗', eg: '埃及', ma: '摩洛哥', dz: '阿尔及利亚',
  tn: '突尼斯', ly: '利比亚', ng: '尼日利亚', gh: '加纳', ke: '肯尼亚',
  et: '埃塞俄比亚', za: '南非', sn: '塞内加尔', ci: '科特迪瓦', cm: '喀麦隆',
  us: '美国', ca: '加拿大', mx: '墨西哥', cu: '古巴', do: '多米尼加',
  gt: '危地马拉', hn: '洪都拉斯', sv: '萨尔瓦多', ni: '尼加拉瓜', cr: '哥斯达黎加',
  pa: '巴拿马', co: '哥伦比亚', ve: '委内瑞拉', ec: '厄瓜多尔', pe: '秘鲁',
  bo: '玻利维亚', cl: '智利', ar: '阿根廷', uy: '乌拉圭', py: '巴拉圭',
  br: '巴西', au: '澳洲', nz: '新西兰',
};

function scHome() {
  return String(LumeSource.config.domain || SC_HOME).replace(/\/+$/, '');
}

function scHeaders() {
  return { 'User-Agent': SC_UA, Referer: scHome() + '/' };
}

async function scApi(path, params = {}) {
  const query = Object.keys(params).map(key => key + '=' + encodeURIComponent(params[key])).join('&');
  const response = await LumeSource.http.get(scHome() + '/api/front' + path + (query ? '?' + query : ''), {
    headers: { ...scHeaders(), Accept: 'application/json, text/plain, */*', 'Cache-Control': 'no-cache' },
  });
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('Stripchat 目录暂不可用（HTTP ' + response.status + '）');
  return JSON.parse(response.body);
}

function scPublic(model) {
  return model && model.isLive === true && model.status === 'public' && !model.isBlocked && !model.isDeleted;
}

function scDirectories(categoryId) {
  if (categoryId === 'chinese') return ['couples'];
  return SC_DIRECTORIES.filter(directory => !categoryId || directory.id === categoryId)
    .map(directory => directory.id);
}

function scHtmlText(value) {
  const entities = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>' };
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt);/gi, (raw, key) => {
    if (key[0] !== '#') return entities[key] || raw;
    const code = key[1].toLowerCase() === 'x'
      ? parseInt(key.slice(2), 16)
      : Number(key.slice(1));
    return code <= 0x10ffff ? String.fromCodePoint(code) : raw;
  }).trim();
}

/** 国籍角标：国旗 emoji + 中文名；站方没填国家就不加角标（不猜）。 */
function scRegion(model) {
  const code = String(model.country || '').trim().toLowerCase();
  if (!/^[a-z]{2}$/.test(code)) return '';
  const name = SC_COUNTRIES[code] || code.toUpperCase();
  const flag = String.fromCodePoint(
    0x1f1e6 + code.charCodeAt(0) - 97,
    0x1f1e6 + code.charCodeAt(1) - 97,
  );
  return flag + ' ' + name;
}

/** 直播封面取站方快照：`/thumbs/<秒级时间戳>/<modelId>`，换一帧就是新地址。 */
function scLiveCover(model) {
  // 10 秒一档：App 每 20 秒刷新一次列表，每次都会落到新地址上，
  // 于是封面是「刚刚那一帧」而不是站方缓存的静态 preview。
  const bucket = Math.floor(Date.now() / 10000) * 10;
  return SC_SNAP_HOST + '/thumbs/' + bucket + '/' + model.id;
}

function scViewers(model) {
  const count = Number(model.viewersCount);
  if (!Number.isFinite(count) || count <= 0) return '';
  if (count >= 10000) return (count / 10000).toFixed(1) + ' 万人在看';
  return Math.round(count) + ' 人在看';
}

async function scFilterGroups(directory) {
  const response = await LumeSource.http.get(scHome() + '/tags/' + directory, {
    headers: { ...scHeaders(), Accept: 'text/html,application/xhtml+xml' },
  });
  if (response.status !== 200) throw new Error('Stripchat 分类标签暂不可用（HTTP ' + response.status + '）');
  const html = response.body;
  const state = /window\.__PRELOADED_STATE__\s*=\s*([\s\S]*?)<\/script>/i.exec(html);
  const relations = state && JSON.parse(state[1].trim().replace(/;$/, ''))
    .tagsConfig?.tagRelations?.relations?.[directory];
  if (!Array.isArray(relations)) throw new Error('Stripchat 分类页未返回标签映射');
  const tags = new Map();
  for (const [slug, tag] of relations) {
    if (typeof slug === 'string' && typeof tag === 'string') {
      tags.set(slug, tag);
    } else if (Number.isInteger(slug) && Number.isInteger(tag)) {
      const left = relations[slug];
      const right = relations[tag];
      if (typeof left?.[0] === 'string' && typeof right?.[0] === 'string') {
        tags.set(left[0] + '-' + right[0], left[1] + '+' + right[1]);
      }
    }
  }

  const groups = [];
  for (const block of html.split(/<div class="tags-category-group(?: [^"]*)?">/g).slice(1)) {
    const heading = /class="tags-category-group__header">([\s\S]*?)<\/div>/.exec(block);
    const sections = block.split(/<div class="tags-category\s+([^"]+)">/g);
    const mixed = block.includes('class="mixed-tags-group"');
    const addGroup = (id, title, body) => {
      const options = new Map();
      const links = /<a aria-label="([^"]*)" class="[^"]*\btags-category__tag\b[^"]*" href="\/([a-z]+)\/([a-z0-9-]+)"/g;
      let link;
      while ((link = links.exec(body))) {
        if (link[2] !== directory) continue;
        const tag = tags.get(link[3]);
        if (tag && !options.has(tag)) options.set(tag, { id: tag, title: scHtmlText(link[1]) });
      }
      if (options.size) groups.push({ id, title, options: Array.from(options.values()) });
    };
    if (mixed) {
      addGroup('mixed', '混合类别（单选）', block);
      continue;
    }
    for (let i = 1; i < sections.length; i += 2) {
      const group = /tags-category--(?!col\d+\b)([\w-]+)/.exec(sections[i]);
      if (!group) continue;
      const label = /class="tags-category__header">([^<]*)<\/div>/.exec(sections[i + 1]);
      const title = scHtmlText(label?.[1] || (heading?.[1] || '').replace(/<[^>]*>/g, '')) || group[1];
      addGroup(group[1], title, sections[i + 1]);
    }
  }
  if (!groups.length) throw new Error('Stripchat 分类页未返回可用标签');
  return groups;
}

function scFilterTags(categoryId, filters) {
  const groups = [];
  for (const [group, selection] of Object.entries(filters || {})) {
    const values = String(selection).split(',').filter(value => /^[a-z0-9]+(?:\+[a-z0-9]+)*$/i.test(value));
    if (!values.length) continue;
    if (group === 'mixed') {
      // The API accepts AND between groups, not OR between multiple pairs.
      for (const tag of values[0].split('+')) groups.push([tag]);
    } else {
      groups.push(values.filter(value => !value.includes('+')));
    }
  }
  if (categoryId === 'chinese') groups.push(['tagLanguageChinese']);
  return groups.filter(group => group.length);
}

function scItem(model) {
  const live = scPublic(model);
  const region = scRegion(model);
  const viewers = live ? scViewers(model) : '';
  const lines = [region, live ? '公开直播' : '当前无公开直播', viewers].filter(Boolean);
  return {
    id: model.id + ':' + model.username,
    title: model.username,
    // 直播用站方秒级快照（每轮列表都是新地址）；非公开直播退回头像。
    cover: live ? scLiveCover(model) : (model.avatarUrl || ''),
    subtitle: lines.join(' · '),
    mediaInfo: {
      liveCover: live,
      // 国籍角标由 App 画在封面左下角（见 docs/资料来源-c 契约的 coverLabel）。
      coverLabel: region || undefined,
    },
  };
}

async function scModel(id) {
  const match = /^(\d+):([a-z0-9_-]+)$/i.exec(String(id || ''));
  if (!match) return null;
  const response = await LumeSource.http.get(scHome() + '/' + match[2], {
    headers: { ...scHeaders(), Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' },
  });
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('直播间暂不可用（HTTP ' + response.status + '）');
  const state = /window\.__PRELOADED_STATE__\s*=\s*([\s\S]*?)<\/script>/i.exec(response.body);
  if (!state) throw new Error('直播间未返回公开的网页状态');
  const data = JSON.parse(state[1].trim().replace(/;$/, ''));
  const model = data.viewCam && data.viewCam.model;
  return model && String(model.id) === match[1] ? model : null;
}

var LumeSource = {
  categories() {
    return [...SC_DIRECTORIES, { id: 'chinese', title: '中文情侣' }];
  },

  async filters({ categoryId } = {}) {
    const batches = await Promise.all(scDirectories(categoryId).map(scFilterGroups));
    const groups = new Map();
    for (const batch of batches) {
      for (const group of batch) {
        if (!groups.has(group.id)) {
          groups.set(group.id, { id: group.id, title: group.title, options: new Map() });
        }
        for (const option of group.options) groups.get(group.id).options.set(option.id, option);
      }
    }
    return Array.from(groups.values(), group => ({ ...group, options: Array.from(group.options.values()) }));
  },

  async list({ categoryId, page, keyword, filters } = {}) {
    const directories = scDirectories(categoryId);
    if (!directories.length) return { items: [], hasMore: false };
    const limit = SC_PAGE_SIZE / directories.length;
    const offset = (Math.max(1, Math.floor(Number(page) || 1)) - 1) * limit;
    const query = String(keyword || '').trim();
    const tags = scFilterTags(categoryId, filters);
    const pages = await Promise.all(directories.map(async primaryTag => {
      const params = { primaryTag, limit, offset };
      if (tags.length) params.filterGroupTags = JSON.stringify(tags);
      if (query) params.query = query;
      const data = await scApi(query ? '/v4/models/search/group/username' : '/models', params);
      if (!Array.isArray(data?.models)) throw new Error('Stripchat 未返回直播目录');
      const total = Number(query ? data.totalCount : data.filteredCount);
      const rows = data.models.filter(model => !tags.length || !model.isRecommended);
      return {
        rows,
        hasMore: rows.length > 0 && (Number.isFinite(total)
          ? offset + rows.length < total
          : rows.length === limit),
      };
    }));
    const items = new Map();
    for (let i = 0; i < limit; i++) {
      for (const { rows } of pages) {
        const model = rows[i];
        if (model?.id && model.username && scPublic(model)) items.set(model.id, scItem(model));
      }
    }
    return { items: Array.from(items.values()), hasMore: pages.some(result => result.hasMore) };
  },

  async detail({ id } = {}) {
    const model = await scModel(id);
    if (!model || !model.id || !model.username || model.isDeleted || model.isBlocked) return null;
    return {
      ...scItem(model),
      description: [
        scRegion(model),
        'Stripchat 网页直播间',
        scPublic(model) ? scViewers(model) : '',
      ].filter(Boolean).join(' · '),
    };
  },

  async chapters({ id } = {}) {
    return scPublic(await scModel(id)) ? [{ id: 'live', title: '进入直播间' }] : [];
  },

  async content({ id, chapterId } = {}) {
    const model = await scModel(id);
    if (chapterId !== 'live' || !scPublic(model) || !model.username) {
      throw new Error('该直播间当前没有公开直播');
    }
    // 站方把直播分片名做了 PSCH v2 改名（播放列表里只有占位分片
    // `media.mp4`，真实名由站方播放器现算），第三方播放器取不到分片，
    // 所以这里走网页播放器，而不是返回一个播不出来的 m3u8。
    // 不带自定义头：网页播放器用 App 自己的 UA / 会话池，塞桌面 UA 会把站点
    // 推成桌面版布局。
    return {
      kind: 'webplayer',
      pageUrl: scHome() + '/' + encodeURIComponent(model.username),
    };
  },
};
