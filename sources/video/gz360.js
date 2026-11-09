// LumeSource: {"id":"gz360_web_video","name":"瓜子影视（网页版）","version":"1.0.0","category":"video","contentCategory":"movie","network":"proxy","mirrors":["https://gz360.tv"],"icon":"https://gz360.tv/_nuxt/icons/icon_64x64.9e69b1.png","settings":[{"key":"siteNote","type":"info","title":"站点说明","description":"使用 gz360.tv 网页目录，游客可浏览和播放网页开放的选集。接口和播放线路已在代理网络下验证。"}]}
// The public Nuxt web client posts an AES-CBC hex envelope to its /Pc API.
const GZ360_SITE = 'https://gz360.tv';
const GZ360_API = 'https://haiwaiapi.1fc8ab0.com/Pc';
const GZ360_KEY = 'MTgxY2M4ODM0MGFlNWIyYg==';
const GZ360_IV = 'NDQyM2QxZTI3NzM0NzZjZQ==';
const GZ360_PAGE_SIZE = 24;
const GZ360_UA = 'Mozilla/5.0';

function gz360Site() {
  return String(LumeSource.config.domain || GZ360_SITE).replace(/\/+$/, '');
}

function gz360Headers() {
  return { 'User-Agent': GZ360_UA, Referer: gz360Site() + '/' };
}

function gz360Crypt(data, encrypt) {
  return LumeSource.tools.aes({
    key: GZ360_KEY, iv: GZ360_IV, data, mode: 'CBC', encrypt,
  });
}

async function gz360Request(path, payload = {}) {
  let params = {};
  if (Object.keys(payload).length) {
    const plaintext = await LumeSource.tools.base64Encode(JSON.stringify(payload));
    const bytes = atob(await gz360Crypt(plaintext, true));
    params = Array.from(bytes, byte => byte.charCodeAt(0).toString(16).padStart(2, '0')).join('');
  }
  const response = await LumeSource.http.post(GZ360_API + path, JSON.stringify({ params }), {
    headers: {
      ...gz360Headers(), Origin: gz360Site(), 'Content-Type': 'application/json',
    },
  });
  let result;
  try {
    result = JSON.parse(response.body);
  } catch (_) {
    throw new Error('瓜子影视接口返回了无效响应（HTTP ' + response.status + '）');
  }
  if (Number(result.code) === 404) return null;
  if (Number(result.code) === 300 && /资源不存在|已经下架/.test(result.msg || '')) return null;
  if (response.status !== 200) throw new Error('瓜子影视接口请求失败（HTTP ' + response.status + '）');
  if (Number(result.code) !== 200) throw new Error('瓜子影视：' + (result.msg || '请求失败'));
  if (typeof result.data !== 'string' || !result.data) return result.data;
  if (!/^(?:[0-9a-f]{2})+$/i.test(result.data)) throw new Error('瓜子影视接口返回了未知格式');
  const bytes = result.data.match(/../g).map(pair => String.fromCharCode(parseInt(pair, 16))).join('');
  const plaintext = await gz360Crypt(btoa(bytes), false);
  return JSON.parse(await LumeSource.tools.base64Decode(plaintext));
}

function gz360Item(row) {
  return {
    id: String(row.vod_id || ''),
    title: String(row.vod_name || '').trim(),
    cover: row.pic || row.vod_pic || '',
    coverHeaders: gz360Headers(),
    subtitle: [row.vod_year, row.vod_area, row.new_continue || row.vod_title].filter(Boolean).join(' · '),
  };
}

function gz360FilterGroup(data, id, title) {
  return {
    id, title,
    options: (Array.isArray(data[id]) ? data[id] : [])
      .filter(item => item.value != null && String(item.value) !== '0' && item.name)
      .map(item => ({ id: encodeURIComponent(String(item.value)), title: item.name })),
  };
}

function gz360FilterValue(value) {
  // The site accepts one option per group. Compound regions are encoded as one ID.
  return value ? decodeURIComponent(String(value).split(',')[0]) : 0;
}

async function gz360Episodes(id) {
  if (!/^\d+$/.test(String(id || ''))) return [];
  const data = await gz360Request('/Resource/GetOnePlayList', {
    vod_id: String(id), pageSize: 0, page: 1,
  });
  return (data && Array.isArray(data.urls) ? data.urls : [])
    .filter(row => row.vurl_id && ![true, 1, '1', 'true'].includes(row.isApp) && /^https?:\/\//i.test(row.url || ''));
}

var LumeSource = {
  async categories() {
    const data = await gz360Request('/Search/GetCondition');
    const labels = { 0: '全部', 1: '电影', 2: '电视剧', 3: '综艺', 4: '动漫', 64: '短剧' };
    return (data && Array.isArray(data.column) ? data.column : [])
      .filter(item => Object.prototype.hasOwnProperty.call(labels, item.value))
      .map(item => ({ id: String(item.value), title: labels[item.value] }));
  },

  async filters() {
    const data = await gz360Request('/Search/GetCondition') || {};
    return {
      groups: [
        gz360FilterGroup(data, 'area', '地区'),
        gz360FilterGroup(data, 'year', '年份'),
      ].filter(group => group.options.length),
    };
  },

  async list({ page, categoryId, keyword, filters = {} } = {}) {
    const currentPage = Math.max(1, Math.floor(Number(page) || 1));
    const data = await gz360Request('/Search/GetConditionList', {
      tid: Number(categoryId) || 0,
      area: gz360FilterValue(filters.area),
      year: gz360FilterValue(filters.year),
      sort: 'd_id',
      keywords: String(keyword || '').trim(),
      page: currentPage,
      pageSize: GZ360_PAGE_SIZE,
    }) || {};
    const rows = Array.isArray(data.list) ? data.list : [];
    const total = Number(data.total);
    return {
      items: rows.map(gz360Item).filter(item => item.id && item.title),
      hasMore: rows.length > 0 && (Number.isFinite(total)
        ? currentPage * GZ360_PAGE_SIZE < total
        : rows.length === GZ360_PAGE_SIZE),
    };
  },

  async detail({ id } = {}) {
    if (!/^\d+$/.test(String(id || ''))) return null;
    const data = await gz360Request('/Resource/GetVodInfo', { vod_id: String(id) });
    const row = data && data.vodInfo;
    if (!row || !row.vod_id) return null;
    return { ...gz360Item(row), description: row.vod_use_content || '' };
  },

  async chapters({ id } = {}) {
    const rows = await gz360Episodes(id);
    return rows.map(row => ({ id: String(row.vurl_id), title: String(row.name || '正片') }));
  },

  async content({ id, chapterId } = {}) {
    const rows = await gz360Episodes(id);
    const row = rows.find(item => String(item.vurl_id) === String(chapterId));
    if (!row) throw new Error('该选集暂无可用的网页播放线路');
    return { kind: 'video', url: row.url, headers: gz360Headers() };
  },
};
