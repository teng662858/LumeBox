/* LumeBox adapters for the public MusicFree and LX custom-source contracts. */
(function (g) {
  'use strict';
  const builtin = g.require;
  function requireMusic(name) {
    if (name === 'axios') return axios;
    if (Object.prototype.hasOwnProperty.call(g.__lumeMusicVendors, name)) return g.__lumeMusicVendors[name];
    if (/^(node:)?(buffer|crypto|events|util|url|zlib)$/.test(name)) return builtin(name);
    throw new Error('音乐插件需要尚未支持的模块：' + name);
  }
  async function request(config) {
    config = config || {};
    let url = /^https?:\/\//.test(config.url || '') ? config.url : (config.baseURL || '') + (config.url || '');
    if (config.params) {
      const query = Object.keys(config.params).filter(k => config.params[k] != null)
        .map(k => encodeURIComponent(k) + '=' + encodeURIComponent(config.params[k])).join('&');
      url += (url.includes('?') ? '&' : '?') + query;
    }
    const headers = Object.assign({}, config.headers);
    let body = config.data == null ? config.body : config.data;
    if (config.form) {
      body = Object.keys(config.form).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(config.form[k])).join('&');
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    } else if (body != null && typeof body === 'object' && !ArrayBuffer.isView(body)) {
      body = JSON.stringify(body);
      if (!Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = 'application/json';
    }
    const resp = await fetch(url, {method: config.method || 'GET', headers, body,
      signal: config.signal, timeout: config.timeout});
    let data;
    if (config.responseType === 'arraybuffer') data = await resp.arrayBuffer();
    else {
      data = await resp.text();
      if (config.responseType !== 'text') { try { data = JSON.parse(data); } catch (_) {} }
    }
    const result = {data, status: resp.status, statusText: resp.statusText || '',
      headers: typeof resp.headers.entries === 'function' ? Object.fromEntries(resp.headers.entries()) : resp.headers,
      config};
    if (!(config.validateStatus || (s => s >= 200 && s < 300))(resp.status)) {
      const error = new Error('HTTP ' + resp.status); error.response = result; throw error;
    }
    return result;
  }
  function makeAxios(defaults) {
    const client = (url, config) => {
      const overrides = typeof url === 'string' ? Object.assign({}, config, {url}) : url || {};
      return request(Object.assign({}, defaults, overrides, {headers: Object.assign({}, defaults.headers, overrides.headers)}));
    };
    client.request = client;
    for (const method of ['get', 'delete', 'head', 'options']) client[method] = (url, config) => client(url, Object.assign({}, config, {method}));
    for (const method of ['post', 'put', 'patch']) client[method] = (url, data, config) => client(url, Object.assign({}, config, {method, data}));
    client.create = options => makeAxios(Object.assign({}, defaults, options));
    client.defaults = defaults || {}; client.default = client;
    client.isAxiosError = error => !!(error && error.response);
    return client;
  }
  const axios = makeAxios({});
  g.__lumeMusicLoad = function (script, protocol, id) {
    let plugin, description, handler, ready;
    const variables = {};
    if (protocol === 'musicFree') {
      const module = {exports: {}};
      new Function('require', 'module', 'exports', 'env', script)(requireMusic, module, module.exports,
        {getUserVariables: () => Object.assign({}, variables), os: 'ios'});
      plugin = module.exports.default || module.exports;
      if (!plugin || !plugin.platform || typeof plugin.getMediaSource !== 'function') throw new Error('不是有效的 MusicFree 插件：缺少 platform / getMediaSource');
      description = {name: String(plugin.platform), version: String(plugin.version || ''),
        primaryKey: plugin.primaryKey || ['id'],
        capabilities: ['search', 'getLyric', 'importMusicSheet', 'getAlbumInfo', 'getMusicSheetInfo'].filter(k => typeof plugin[k] === 'function'),
        variables: plugin.userVariables || [], platforms: {}};
      ready = Promise.resolve();
    } else {
      const info = {id, rawScript: script};
      for (const field of ['name', 'version', 'author', 'description', 'homepage']) {
        const found = script.match(new RegExp('@' + field + '\\s+([^\\r\\n*]+)')); info[field] = found ? found[1].trim() : '';
      }
      let initialized;
      ready = new Promise(resolve => { initialized = resolve; });
      const crypto = builtin('crypto');
      g.lx = {
        version: '2.0.0', env: 'mobile', currentScriptInfo: info,
        EVENT_NAMES: {inited: 'inited', request: 'request', updateAlert: 'updateAlert'},
        on(event, callback) { if (event === 'request') handler = callback; },
        send(event, data) {
          if (event === 'inited') {
            const platforms = {};
            for (const [key, value] of Object.entries(data.sources || {})) {
              if (['kw', 'kg', 'tx', 'wy', 'mg', 'local'].includes(key) && (value.actions || []).includes('musicUrl')) platforms[key] = value.qualitys || [];
            }
            if (!Object.keys(platforms).length) throw new Error('LX 音源没有声明 musicUrl 能力');
            description = {name: info.name || 'LX 音源', version: info.version, platforms, capabilities: ['musicUrl'], variables: []};
            initialized();
          }
        },
        request(url, options, callback) {
          let cancelled = false;
          request(Object.assign({}, options, {url, validateStatus: () => true})).then(
            r => { if (!cancelled) callback(null, {statusCode: r.status, headers: r.headers, body: r.data}, r.data); },
            e => { if (!cancelled) callback(e, null, null); });
          return () => { cancelled = true; };
        },
        utils: {
          buffer: {from: (...args) => Buffer.from(...args), bufToString: (buf, format) => Buffer.from(buf).toString(format)},
          crypto: {
            md5: value => crypto.createHash('md5').update(value).digest('hex'),
            randomBytes: size => crypto.randomBytes(size),
            aesEncrypt(buffer, mode, key, iv) { const cipher = crypto.createCipheriv(mode, key, iv); return Buffer.concat([cipher.update(buffer), cipher.final()]); },
            rsaEncrypt(buffer, key) { return crypto.publicEncrypt({key, padding: 1}, buffer); }
          },
          zlib: {
            inflate: buffer => Promise.resolve(builtin('zlib').inflateSync(buffer)),
            deflate: buffer => Promise.resolve(Buffer.from(g.__lumeMusicVendors.pako.deflate(buffer)))
          }
        }
      };
      new Function('require', script)(requireMusic);
    }
    LumeSource.music = async function (args) {
      await ready;
      if (args.method === 'describe') {
        if (protocol === 'lx' && typeof handler !== 'function') throw new Error('LX 音源没有注册 request 回调');
        return description;
      }
      for (const key of Object.keys(variables)) delete variables[key];
      Object.assign(variables, args.variables || {});
      if (protocol === 'lx') {
        if (args.method !== 'media' && args.method !== 'lyric') throw new Error('LX 标准脚本不提供歌曲搜索接口');
        return handler({source: args.platform, action: args.method === 'media' ? 'musicUrl' : 'lyric',
          info: {type: args.platform === 'local' ? null : args.quality, musicInfo: args.track}});
      }
      if (args.method === 'search') return plugin.search(args.query, args.page || 1, 'music');
      if (args.method === 'media') return plugin.getMediaSource(args.track, args.quality || 'standard');
      if (args.method === 'lyric') return plugin.getLyric ? plugin.getLyric(args.track) : null;
      if (args.method === 'importSheet' && plugin.importMusicSheet) return plugin.importMusicSheet(args.url);
      throw new Error('音源不支持：' + args.method);
    };
  };
})(globalThis);
