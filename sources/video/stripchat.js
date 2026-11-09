// LumeSource: {"id":"stripchat_live_video","name":"Stripchat 中文直播","version":"1.0.0","category":"video","contentCategory":"adult","network":"proxy","mirrors":["https://zh.stripchat.com","https://stripchat.com"],"icon":"https://zh.stripchat.com/favicon.ico","settings":[{"key":"siteNote","type":"info","title":"站点说明","description":"18+ 成人直播。默认浏览中文情侣分类，公开直播通过站方网页播放器打开。"}]}

const SC_HOME = 'https://zh.stripchat.com';
const SC_PAGE_SIZE = 24;
const SC_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36';

function scHome() {
  return String(LumeSource.config.domain || SC_HOME).replace(/\/+$/, '');
}

function scHeaders() {
  return { 'User-Agent': SC_UA, Referer: scHome() + '/' };
}

async function scApi(path, params = {}) {
  const query = Object.keys(params).map(key => key + '=' + encodeURIComponent(params[key])).join('&');
  const response = await LumeSource.http.get(scHome() + '/api/front' + path + (query ? '?' + query : ''), {
    headers: { ...scHeaders(), Accept: 'application/json, text/plain, */*' },
  });
  if (response.status === 404) return null;
  if (response.status !== 200) throw new Error('Stripchat 目录暂不可用（HTTP ' + response.status + '）');
  return JSON.parse(response.body);
}

function scPublic(model) {
  return model && model.isLive === true && model.status === 'public' && !model.isBlocked && !model.isDeleted;
}

function scItem(model) {
  return {
    id: model.id + ':' + model.username,
    title: model.username,
    cover: model.previewUrlThumbSmall || model.avatarUrl || '',
    coverHeaders: scHeaders(),
    subtitle: scPublic(model) ? '公开直播' : '当前无公开直播',
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
    return [{ id: 'chinese', title: '中文情侣' }, { id: 'couples', title: '全部情侣' }];
  },

  async list({ categoryId, page, keyword } = {}) {
    const offset = (Math.max(1, Math.floor(Number(page) || 1)) - 1) * SC_PAGE_SIZE;
    const query = String(keyword || '').trim();
    const params = { primaryTag: 'couples', limit: SC_PAGE_SIZE, offset };
    if (categoryId !== 'couples' && (categoryId || !query)) {
      params.filterGroupTags = '[["tagLanguageChinese"]]';
    }
    if (query) params.query = query;
    const data = await scApi(query ? '/v4/models/search/group/username' : '/models', params) || {};
    const rows = Array.isArray(data.models) ? data.models : [];
    const total = Number(query ? data.totalCount : data.filteredCount);
    return {
      items: rows.filter(model => model.id && model.username && scPublic(model)).map(scItem),
      hasMore: rows.length > 0 && (Number.isFinite(total)
        ? offset + rows.length < total
        : rows.length === SC_PAGE_SIZE),
    };
  },

  async detail({ id } = {}) {
    const model = await scModel(id);
    return model && model.id && model.username && !model.isDeleted && !model.isBlocked
      ? { ...scItem(model), description: 'Stripchat 网页直播间' }
      : null;
  },

  async chapters({ id } = {}) {
    return scPublic(await scModel(id)) ? [{ id: 'live', title: '进入直播间' }] : [];
  },

  async content({ id, chapterId } = {}) {
    const model = await scModel(id);
    if (chapterId !== 'live' || !scPublic(model) || !model.username) {
      throw new Error('该直播间当前没有公开直播');
    }
    return { kind: 'webplayer', pageUrl: scHome() + '/' + encodeURIComponent(model.username) };
  },
};
