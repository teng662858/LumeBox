// LumeBox 源脚本离线跑测工具（Node 侧，非 App 内运行）。
//
// 目的：把一份图源脚本（`// LumeSource: {...}` 单文件形态）在本机按照 App 的
// 沙箱桥接语义跑一遍，真实访问源站，验证 categories / list / detail / chapters /
// content 五个入口能不能出内容。**这是开发期自检工具，不参与 App 打包。**
//
// 与 App 内 `lib/core/js/source_bridge.dart` 对齐的语义：
//   - 全局 `LumeSource` 是桥接对象（含 http / fs / tools / config / storage …）；
//   - 脚本 `var LumeSource = { … }` 的赋值会被「吸收」进桥接对象，
//     **宿主能力（http / fs / tools / config …）保留**；
//   - `LumeSource.config` 是冻结只读快照。
//
// 用法：
//   node tools/lume-source-check.mjs <脚本路径> [--keyword 关键词] [--page 1]
//                                     [--json] [--call list,detail]
//                                     [--category <分类id>] [--filter <组>=<选项>]
//   node tools/lume-source-check.mjs sources/video/ysxq.js
//   node tools/lume-source-check.mjs sources/video/*.js --json   ← 批量
//
//   `--category` / `--filter` 用来验「分类 / 筛选切换是否真的换内容」：
//   分别跑两次，首条 id 相同就说明参数没被源用上（源约定第 3 条）。
//
// 退出码：0 = 全绿；1 = 有失败；2 = 用法错误。
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

// App 内置默认 UA（lib/core/net/lume_http.dart: defaultUserAgent）。
const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

// App 侧单次调用预算 3–5 秒；这里给到 25 秒只用于本机慢网，超时会给警告。
const CALL_TIMEOUT_MS = 25000;
const BUDGET_WARN_MS = 5000;

const CONTRACT = {
  categories: ['getCategories', 'getCategory', 'categories'],
  list: ['getList', 'list'],
  detail: ['getDetail', 'getBookInfo', 'detail'],
  chapters: ['getChapters', 'getChapterList', 'chapters'],
  content: ['getContent', 'getChapterContent', 'content'],
  home: ['getHome', 'getHomeContent', 'home'],
  filters: ['getFilters', 'getFilterGroups', 'filters'],
};

const RESERVED = new Set([
  'tools',
  'media',
  'session',
  'http',
  'fs',
  'web',
  'html',
  'storage',
  'config',
]);

// ------------------------------------------------------------------ 参数解析
function parseArgs(argv) {
  const out = { files: [], keyword: '', page: 1, json: false, calls: null, category: null, filters: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--keyword') out.keyword = argv[++i] ?? '';
    else if (arg === '--page') out.page = Number(argv[++i] ?? 1) || 1;
    else if (arg === '--json') out.json = true;
    else if (arg === '--call') out.calls = String(argv[++i] ?? '').split(',').filter(Boolean);
    else if (arg === '--category') out.category = String(argv[++i] ?? '');
    else if (arg === '--filter') {
      const raw = String(argv[++i] ?? '');
      const at = raw.indexOf('=');
      if (at <= 0) throw new Error('--filter 需要 <组>=<选项>，收到：' + raw);
      out.filters = { ...(out.filters || {}), [raw.slice(0, at)]: raw.slice(at + 1) };
    } else out.files.push(arg);
  }
  return out;
}

// --------------------------------------------------------------- 身份头解析
function parseIdentity(script) {
  const match = /^\s*\/\/\s*LumeSource:\s*(\{[\s\S]*?\})\s*$/m.exec(script);
  if (!match) return null;
  try {
    return JSON.parse(match[1]);
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------- 网络（宿主层）
function makeHttp(opts) {
  const { config, trace } = opts;
  const baseHeaders = {};
  if (opts.ua) baseHeaders['User-Agent'] = opts.ua;

  // 与 App 的 SiteSessionPool 对齐：按 origin 记住 Set-Cookie（中间 302 也要收），
  // 后续同源请求自动带上。用户显式给的 Cookie 头优先。
  const jar = new Map();
  const cookiesFor = (origin) => {
    const store = jar.get(origin);
    return store && store.size ? [...store].map(([k, v]) => `${k}=${v}`).join('; ') : '';
  };
  const absorbCookies = (origin, list) => {
    if (!list || !list.length) return;
    let store = jar.get(origin);
    if (!store) {
      store = new Map();
      jar.set(origin, store);
    }
    for (const raw of list) {
      const pair = String(raw).split(';')[0];
      const at = pair.indexOf('=');
      if (at <= 0) continue;
      const name = pair.slice(0, at).trim();
      const value = pair.slice(at + 1).trim();
      if (!name) continue;
      if (/max-age=0\b|expires=thu, 01 jan 1970/i.test(String(raw))) store.delete(name);
      else store.set(name, value);
    }
  };

  async function request(options) {
    const url = String(options?.url ?? '');
    if (!url) throw new Error('LumeSource.http.request 缺少 url');
    const method = String(options.method || 'GET').toUpperCase();
    const headers = { ...baseHeaders, ...(options.headers || {}) };
    const callerCookie = Object.keys(headers).some((k) => k.toLowerCase() === 'cookie');
    if (config.cookie && !callerCookie) {
      headers['Cookie'] = config.cookie;
    }
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CALL_TIMEOUT_MS - 500);
    let target = url;
    let verb = method;
    let payload = options.body == null ? undefined : String(options.body);
    let status = 0;
    let body = '';
    let bodyBase64 = null;
    let headersOut = {};
    let finalUrl = url;
    const setCookie = [];
    try {
      for (let hop = 0; hop <= 10; hop++) {
        const hopUrl = new URL(target);
        const hopHeaders = { ...headers };
        if (!callerCookie && !hopHeaders.Cookie) {
          const jarCookie = cookiesFor(hopUrl.origin);
          if (jarCookie) hopHeaders.Cookie = jarCookie;
        }
        const res = await fetch(target, {
          method: verb,
          headers: hopHeaders,
          body: verb === 'GET' || verb === 'HEAD' ? undefined : payload,
          redirect: 'manual',
          signal: controller.signal,
        });
        const hopCookies = res.headers.getSetCookie?.() ?? [];
        absorbCookies(hopUrl.origin, hopCookies);
        setCookie.push(...hopCookies);
        status = res.status;
        headersOut = Object.fromEntries(res.headers.entries());
        finalUrl = target;
        const location = res.headers.get('location');
        if (![301, 302, 303, 307, 308].includes(status) || !location) {
          // 与 App 侧一致：脚本传 {binary:true} 时额外回 bodyBase64（二进制接口用）。
          const bytes = Buffer.from(await res.arrayBuffer());
          body = bytes.toString('utf8');
          if (options.binary === true) bodyBase64 = bytes.toString('base64');
          break;
        }
        await res.arrayBuffer().catch(() => undefined);
        if (hop === 10) throw new Error('redirect_limit：重定向超过 10 次');
        const next = new URL(location, target);
        if (!['http:', 'https:'].includes(next.protocol)) throw new Error('redirect_scheme：不支持的跳转地址');
        if (status === 303) {
          verb = 'GET';
          payload = undefined;
        }
        target = next.toString();
      }
    } finally {
      clearTimeout(timer);
    }
    trace.push({ url, method, status, ms: Date.now() - started, bytes: body.length });
    return {
      url: finalUrl,
      status,
      headers: headersOut,
      body,
      ...(bodyBase64 == null ? {} : { bodyBase64 }),
      setCookie,
      text: () => body,
      json: () => JSON.parse(body),
      ok: status >= 200 && status < 300,
    };
  }

  return {
    request,
    get: (url, options) => request({ ...(options || {}), url, method: 'GET' }),
    post: (url, body, options) =>
      request({ ...(options || {}), url, method: 'POST', body: body == null ? '' : String(body) }),
  };
}

// ------------------------------------------------------- 其它宿主能力（桥）
function makeTools(fsStore) {
  return {
    run: async () => {
      throw new Error('harness: tools.run 未实现（App 侧为原生能力）');
    },
    digest: async (algorithm, data) => {
      const name = String(algorithm).toLowerCase().replace('-', '');
      if (!['md5', 'sha1', 'sha256', 'sha512'].includes(name)) {
        throw new Error('harness: 不支持的摘要算法 ' + algorithm);
      }
      return crypto.createHash(name).update(String(data), 'utf8').digest('hex');
    },
    // 与 App 侧 SourceTools 对齐：key/iv/data 是 base64，返回 base64
    aes: async (options) => {
      const o = options || {};
      const mode = String(o.mode || 'CBC').toUpperCase();
      const encrypt = o.encrypt === true;
      const key = Buffer.from(String(o.key || ''), 'base64');
      const iv = Buffer.from(String(o.iv || ''), 'base64');
      const input = Buffer.from(String(o.data || ''), 'base64');
      if (![16, 24, 32].includes(key.length)) throw new Error('harness: AES 密钥长度无效');
      const algo = 'aes-' + key.length * 8 + '-' + mode.toLowerCase();
      if (mode === 'GCM') {
        const cipher = crypto.createCipheriv(algo, key, iv, { authTagLength: 16 });
        if (encrypt) return Buffer.concat([cipher.update(input), cipher.final(), cipher.getAuthTag()]).toString('base64');
        cipher.setAuthTag(input.subarray(input.length - 16));
        return Buffer.concat([cipher.update(input.subarray(0, input.length - 16)), cipher.final()]).toString('base64');
      }
      if (mode === 'CTR') {
        const cipher = crypto.createCipheriv(algo, key, iv);
        return Buffer.concat([cipher.update(input), cipher.final()]).toString('base64');
      }
      if (mode === 'ECB') {
        const cipher = encrypt ? crypto.createCipheriv(algo, key, null) : crypto.createDecipheriv(algo, key, null);
        cipher.setAutoPadding(o.padding !== 'none');
        return Buffer.concat([cipher.update(input), cipher.final()]).toString('base64');
      }
      const cipher = encrypt ? crypto.createCipheriv(algo, key, iv) : crypto.createDecipheriv(algo, key, iv);
      cipher.setAutoPadding(o.padding !== 'none');
      return Buffer.concat([cipher.update(input), cipher.final()]).toString('base64');
    },
    hmac: async (options) => {
      const o = options || {};
      const algo = String(o.algorithm || 'sha256').toLowerCase();
      const key = o.keyEncoding === 'base64' ? Buffer.from(String(o.key || ''), 'base64') : Buffer.from(String(o.key || ''), 'utf8');
      const data = o.encoding === 'base64' ? Buffer.from(String(o.data || ''), 'base64') : Buffer.from(String(o.data || ''), 'utf8');
      return crypto.createHmac(algo, key).update(data).digest('hex');
    },
    xor: async (options) => {
      const o = options || {};
      const mask = o.keyEncoding === 'base64' ? Buffer.from(String(o.key || ''), 'base64') : Buffer.from(String(o.key || ''), 'utf8');
      if (!mask.length) throw new Error('harness: XOR 密钥为空');
      const data = o.encoding === 'base64' ? Buffer.from(String(o.data || ''), 'base64') : Buffer.from(String(o.data || ''), 'utf8');
      const out = Buffer.alloc(data.length);
      for (let i = 0; i < data.length; i++) out[i] = data[i] ^ mask[i % mask.length];
      return out.toString('base64');
    },
    rsa: async () => {
      throw new Error('harness: tools.rsa 未实现（App 侧为原生能力）');
    },
    inflate: async (data, raw) => {
      const input = Buffer.from(String(data || ''), 'base64');
      const out = raw ? zlib.inflateRawSync(input) : zlib.inflateSync(input);
      return out.toString('base64');
    },
    base64Encode: async (data) => Buffer.from(String(data), 'utf8').toString('base64'),
    base64Decode: async (data) => Buffer.from(String(data), 'base64').toString('utf8'),
    urlEncode: async (data) => encodeURIComponent(String(data)),
    urlDecode: async (data) => decodeURIComponent(String(data)),
  };
}

function makeFs() {
  const store = new Map();
  return {
    async writeText(file, text) {
      store.set(String(file), String(text));
      return true;
    },
    async readText(file) {
      return store.has(String(file)) ? store.get(String(file)) : null;
    },
    async exists(file) {
      return store.has(String(file));
    },
    async remove(file) {
      return store.delete(String(file));
    },
    async list() {
      return [...store.keys()];
    },
  };
}

// ------------------------------------------------------------------ 单源跑测
async function runSource(file, options) {
  const raw = fs.readFileSync(file, 'utf8');
  const identity = parseIdentity(raw) || {};
  const report = {
    file: path.relative(process.cwd(), file),
    id: identity.id ?? '',
    name: identity.name ?? '',
    category: identity.category ?? '',
    calls: {},
    ok: false,
  };

  const trace = [];
  const config = Object.freeze({
    domain: identity.mirrors?.[0] ?? '',
    mirrors: Object.freeze([...(identity.mirrors ?? [])]),
    mirrorIndex: 0,
    customDomain: '',
    account: '',
    password: '',
    cookie: '',
  });

  const fsApi = makeFs();
  const http = makeHttp({ config, trace, ua: DEFAULT_UA });
  const tools = makeTools();

  // 桥接对象：脚本可见的 LumeSource。
  const bridge = {
    http,
    fs: fsApi,
    tools,
    storage: {
      async get(key, fallback) {
        const store = fsApi.__store ?? null;
        const value = store ? store.get('storage:' + key) : undefined;
        return value === undefined ? (fallback ?? null) : value;
      },
      async set(key, value) {
        fsApi.__store = fsApi.__store ?? new Map();
        fsApi.__store.set('storage:' + key, value);
        return true;
      },
      async remove(key) {
        fsApi.__store?.delete('storage:' + key);
        return true;
      },
    },
    session: {
      async setUserAgent() {
        return true;
      },
    },
    media: {
      async parseM3u8() {
        throw new Error('harness: media.parseM3u8 未实现（App 侧为原生能力）');
      },
      async playlist() {
        throw new Error('harness: media.playlist 未实现（App 侧为原生能力）');
      },
    },
    web: {
      async render() {
        const error = new Error(
          'harness: web.render 需要 App 内的受限 WebKit，无法离线验证。' +
            '请改用 LumeSource.http + 正则解析（沙箱无 DOM，也是更稳的写法）。',
        );
        error.harnessUnsupported = true;
        throw error;
      },
      bridge: {
        async configure() {
          return true;
        },
        async request() {
          throw new Error('harness: web.bridge.request 未实现');
        },
      },
    },
    html: {
      async extract() {
        throw new Error('harness: html.extract 未实现（App 侧为原生能力）');
      },
    },
  };
  Object.defineProperty(bridge, 'config', {
    enumerable: true,
    configurable: false,
    get: () => config,
    set: () => {},
  });

  // 契约派发（与 source_bridge.dart 的 locate/call 同义：对象式优先落桥，
  // 也支持顶层函数 / 全局词法声明）。
  function locate(names, contractName) {
    for (const name of names) {
      if (typeof bridge[name] === 'function' && !bridge[name].__lumeDispatch) {
        return { fn: bridge[name], style: name === contractName ? 'object' : 'function' };
      }
    }
    for (const name of names) {
      const fn = sandbox[name];
      if (typeof fn === 'function') {
        return { fn, style: name === contractName ? 'object' : 'function' };
      }
    }
    return null;
  }

  function positional(name, argument) {
    switch (name) {
      case 'categories':
        return [];
      case 'list':
        return [argument.keyword || null, argument.page || 1, argument.categoryId || null];
      case 'detail':
      case 'chapters':
        return [argument.id];
      case 'content':
        return [argument.id, argument.chapterId];
      default:
        return [argument];
    }
  }

  async function call(name, argument) {
    const found = locate(CONTRACT[name], name);
    if (!found) throw new Error('源脚本没有实现 ' + name + ' 方法');
    if (found.style === 'object') return found.fn.call(bridge, argument);
    return found.fn.apply(bridge, positional(name, argument));
  }

  const sandbox = {
    console,
    TextEncoder,
    TextDecoder,
    URL,
    URLSearchParams,
    setTimeout,
    clearTimeout,
    fetch: (url, init) => http.request({ ...(init || {}), url }),
    atob: (v) => Buffer.from(String(v), 'base64').toString('binary'),
    btoa: (v) => Buffer.from(String(v), 'binary').toString('base64'),
    escape,
    unescape,
    AbortController,
    Buffer,
  };
  sandbox.globalThis = sandbox;
  sandbox.global = sandbox;
  vm.createContext(sandbox);

  // 全局 LumeSource：getter 返回桥，setter 走 absorb（保留宿主能力）。
  let bridgeProxy = bridge;
  Object.defineProperty(sandbox, 'LumeSource', {
    configurable: true,
    enumerable: true,
    get: () => bridgeProxy,
    set: (value) => {
      if (value === null || typeof value !== 'object') return;
      for (const key of Object.getOwnPropertyNames(value)) {
        if (RESERVED.has(key)) continue;
        try {
          Object.defineProperty(bridgeProxy, key, Object.getOwnPropertyDescriptor(value, key));
        } catch (_) {
          try {
            bridgeProxy[key] = value[key];
          } catch (_) {
            /* 只读属性忽略 */
          }
        }
      }
    },
  });

  let methods = [];
  try {
    vm.runInContext(raw, sandbox, { filename: path.basename(file), timeout: 4000 });
    methods = Object.keys(CONTRACT).filter((name) => locate(CONTRACT[name], name));
  } catch (error) {
    report.calls.import = { ok: false, error: describe(error) };
    report.trace = trace;
    return report;
  }
  report.methods = methods;
  if (!methods.length) {
    report.calls.import = { ok: false, error: '五个入口一个都没有实现，导入时会被拒绝' };
    report.trace = trace;
    return report;
  }

  const want = options.calls ?? ['home', 'filters', 'categories', 'list', 'detail', 'chapters', 'content'];
  const doCall = async (name, argument) => {
    if (!want.includes(name)) return null;
    if (!methods.includes(name)) {
      report.calls[name] = { ok: true, skipped: '源未实现该方法' };
      return null;
    }
    const started = Date.now();
    try {
      const value = await withTimeout(call(name, argument), CALL_TIMEOUT_MS, name);
      const ms = Date.now() - started;
      report.calls[name] = { ok: true, ms, ...summarize(name, value) };
      if (ms > BUDGET_WARN_MS) report.calls[name].slow = '超过 App 单次预算 ' + BUDGET_WARN_MS + 'ms';
      return value;
    } catch (error) {
      report.calls[name] = { ok: false, ms: Date.now() - started, error: describe(error) };
      return null;
    }
  };

  if (want.includes('home')) await doCall('home', {});
  if (want.includes('filters')) await doCall('filters', {});

  const first = await doCall('categories', {});
  report.categoryCount = Array.isArray(first) ? first.length : 0;
  const categoryId = options.category != null
    ? options.category
    : (Array.isArray(first) && first.length ? first[0].id : '');

  let items = null;
  const listArgument = { page: options.page, categoryId };
  if (options.filters) listArgument.filters = options.filters;
  const listResult = await doCall('list', listArgument);
  if (listResult && Array.isArray(listResult.items)) items = listResult.items;

  if (options.keyword) {
    const started = Date.now();
    try {
      const value = await withTimeout(
        call('list', { keyword: options.keyword, page: 1 }),
        CALL_TIMEOUT_MS,
        'search',
      );
      report.calls.search = { ok: true, ms: Date.now() - started, ...summarize('list', value) };
    } catch (error) {
      report.calls.search = { ok: false, error: describe(error) };
    }
  }

  const itemId = items?.[0]?.id ?? '';
  if (itemId) {
    const detail = await doCall('detail', { id: itemId });
    const chapterList = await doCall('chapters', { id: itemId });
    const chapterId =
      (Array.isArray(chapterList) && chapterList[0]?.id) ||
      (Array.isArray(detail?.chapters) && detail.chapters[0]?.id) ||
      '';
    if (chapterId) {
      const content = await doCall('content', { id: itemId, chapterId });
      if (content && content.kind === 'text') {
        // 小说正文没有可探活的地址：按正文字数判定（App 侧也只要求有正文）
        const body = typeof content.text === 'string' ? content.text.trim() : '';
        report.calls.playable = body.length
          ? { ok: true, url: '', text: body.length }
          : { ok: false, error: 'content 是 text 但正文为空：' + JSON.stringify(content).slice(0, 200) };
      } else if (content && (content.kind === 'video' || content.kind === 'audio' || content.kind === 'images')) {
        const url = content.url || (content.images && content.images[0]) || '';
        if (typeof url === 'string' && /^https?:\/\//i.test(url)) {
          report.calls.playable = { ok: true, url: url.slice(0, 160) };
          if (content.kind === 'video' || content.kind === 'audio') {
            const probe = await probeMedia(url, content.headers || {});
            report.calls.playable.probe = probe;
          }
        } else {
          report.calls.playable = {
            ok: false,
            error: 'content 没有给出绝对地址：' + JSON.stringify(content).slice(0, 200),
          };
        }
      }
    } else {
      report.calls.chapters = report.calls.chapters ?? {
        ok: false,
        error: '条目 ' + itemId + ' 没有章节，无法验证播放',
      };
    }
  } else if (listResult) {
    report.calls.list = { ...report.calls.list, ok: false, error: '列表为空，后续无法验证' };
  }

  report.trace = trace;
  report.ok = Object.entries(report.calls).every(([name, value]) => {
    if (name === 'playable') return value.ok && (!value.probe || value.probe.ok);
    return value.ok !== false;
  });
  return report;
}

// 播放地址探活：m3u8 取前 1KB 看是否 #EXTM3U；mp4 看状态码与 content-type。
// 只取开头一段：m3u8 / FLV 一眼能认出来，mp4 按源约定 206 就算通。整段下载会把
// 「110MB 的 mp4 直链」这种正常地址误判成超时（KKAV 就被这样误报过）。
// 直播流（flv / SSE）永远不会结束，所以改成流式读、攒够就主动断开，
// 否则 res.arrayBuffer() 一定挂到超时（直播盒子就是这样误报的）。
async function probeMedia(url, headers) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': DEFAULT_UA, Range: 'bytes=0-262143', ...headers },
      signal: controller.signal,
    });
    const type = res.headers.get('content-type') || '';
    const looksLive = /video\/x-flv|event-stream|octet-stream/i.test(type) || /\.flv(\?|$)/i.test(url);
    const limit = looksLive ? 8192 : 262144;
    const chunks = [];
    let total = 0;
    if (res.body) {
      const reader = res.body.getReader();
      while (total < limit) {
        const step = await reader.read();
        if (step.done) break;
        const piece = Buffer.from(step.value);
        chunks.push(piece);
        total += piece.length;
      }
      reader.cancel().catch(() => {});
    }
    const buffer = Buffer.concat(chunks);
    const head = buffer.subarray(0, 400).toString('utf8');
    const looksM3u8 = head.includes('#EXTM3U');
    const looksFlv = buffer.subarray(0, 3).toString('latin1') === 'FLV';
    return {
      ok:
        res.status >= 200 &&
        res.status < 400 &&
        (looksM3u8 || looksFlv || /video|audio|octet-stream|mp4|mpegurl/i.test(type)),
      status: res.status,
      type,
      bytes: buffer.length,
      live: looksLive,
      m3u8: looksM3u8,
      sample: head.slice(0, 80).replace(/\s+/g, ' '),
    };
  } catch (error) {
    return { ok: false, error: describe(error) };
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
}

function summarize(name, value) {
  if (value == null) return { sample: null };
  if (name === 'home') {
    const boards = Array.isArray(value) ? value : [];
    const total = boards.reduce((sum, board) => sum + (Array.isArray(board?.items) ? board.items.length : 0), 0);
    return {
      count: boards.length,
      items: total,
      sample: boards.slice(0, 3).map((board) => ({ title: board?.title ?? '', items: board?.items?.length ?? 0 })),
    };
  }
  if (name === 'categories') {
    return {
      count: Array.isArray(value) ? value.length : 0,
      sample: Array.isArray(value) ? value.slice(0, 3) : value,
    };
  }
  if (name === 'list') {
    const items = Array.isArray(value?.items) ? value.items : [];
    return {
      count: items.length,
      hasMore: value?.hasMore === true,
      sample: items.slice(0, 3).map((item) => ({
        id: String(item?.id ?? '').slice(0, 90),
        title: item?.title ?? '',
        cover: String(item?.cover ?? '').slice(0, 90),
      })),
    };
  }
  if (name === 'detail') {
    return {
      title: value?.title ?? '',
      cover: String(value?.cover ?? '').slice(0, 90),
      description: String(value?.description ?? '').slice(0, 60),
    };
  }
  if (name === 'chapters') {
    const rows = Array.isArray(value) ? value : (value?.chapters ?? []);
    return {
      count: rows.length,
      sample: rows.slice(0, 3).map((row) => ({ id: String(row?.id ?? '').slice(0, 90), title: row?.title ?? '' })),
    };
  }
  if (name === 'content') {
    return {
      kind: value?.kind ?? '',
      url: String(value?.url ?? '').slice(0, 120),
      images: Array.isArray(value?.images) ? value.images.length : 0,
      qualities: Array.isArray(value?.qualities) ? value.qualities.length : 0,
      headers: value?.headers ?? null,
    };
  }
  return { sample: JSON.stringify(value).slice(0, 200) };
}

function describe(error) {
  if (!error) return 'unknown';
  const name = error.name ? error.name + ': ' : '';
  const message = error.message ? error.message : String(error);
  return (name + message).slice(0, 400);
}

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_resolve, reject) =>
      setTimeout(() => reject(new Error('调用 ' + label + ' 超时（' + ms + 'ms）')), ms).unref?.(),
    ),
  ]);
}

// ---------------------------------------------------------------------- 入口
const options = parseArgs(process.argv.slice(2));
if (!options.files.length) {
  console.error('用法：node tools/lume-source-check.mjs <脚本路径…> [--keyword 词] [--page 1] [--json] [--call list,detail]');
  process.exit(2);
}

const reports = [];
for (const file of options.files) {
  if (!fs.existsSync(file)) {
    reports.push({ file, ok: false, calls: { read: { ok: false, error: '文件不存在' } } });
    continue;
  }
  const report = await runSource(file, options);
  reports.push(report);
  if (!options.json) {
    const flag = report.ok ? 'PASS' : 'FAIL';
    console.log(`\n=== [${flag}] ${report.name || report.id || report.file}  (${report.file})`);
    if (report.methods) console.log('    实现：' + report.methods.join(', '));
    for (const [name, value] of Object.entries(report.calls)) {
      const status = value.ok === false ? 'FAIL' : 'ok  ';
      const detail = value.error
        ? value.error
        : JSON.stringify(
            name === 'categories'
              ? { count: value.count, sample: value.sample }
              : value.sample !== undefined
              ? { count: value.count, hasMore: value.hasMore, sample: value.sample }
              : value,
          );
      console.log(`  - ${status} ${name}${value.ms ? ' (' + value.ms + 'ms)' : ''} ${detail.slice(0, 460)}`);
    }
    if (report.trace?.length) {
      const net = report.trace.map((row) => `${row.status} ${row.bytes}b ${row.ms}ms ${row.url.slice(0, 110)}`);
      console.log('    请求：\n      ' + net.slice(0, 12).join('\n      '));
    }
  }
}

if (options.json) console.log(JSON.stringify(reports, null, 2));
const failed = reports.filter((row) => !row.ok);
if (!options.json) {
  console.log(`\n合计 ${reports.length} 个源：通过 ${reports.length - failed.length}，失败 ${failed.length}`);
}
process.exit(failed.length ? 1 : 0);
