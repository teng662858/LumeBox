/// 猫源沙箱的**平台全局垫片**（只对猫源注入，见 `LumeSourcePolyfills.forSection`）。
///
/// 这一组补的是 Node ≥16 里属于「运行环境自带」的全局能力。真实猫源脚本（多为
/// Node 目标的打包产物）大量使用它们，而 QuickJS-NG 引擎本身不提供：
///
/// - `TextEncoder` / `TextDecoder`（utf-8 / utf-16le / latin1，纯 JS 编解码）；
/// - `URL` / `URLSearchParams`（WHATWG 的最小子集：拼接、解析、查询参数读写）；
/// - `structuredClone`（结构化深拷贝，支持环引用与常见内建类型）；
/// - `localStorage` / `sessionStorage`（**进程内**存储：上下文销毁即清空，不落盘）。
///
/// 全部是纯 JS，不认识宿主桥、不申请任何权限：能力边界没有任何变化，
/// 只是把「Node 里本来就有的东西」补齐。
library;

import 'sandbox/sandbox_polyfill.dart';

/// `TextEncoder` / `TextDecoder`：UTF-8 为主，另认 utf-16le 与 latin1。
///
/// 编解码内核直接复用 Buffer 垫片（同一套 utf8 / utf16le / latin1 实现），
/// 因此不重复造第二套编码器，两者行为天然一致。
class CatTextCodecPolyfill implements SandboxPolyfill {
  const CatTextCodecPolyfill();

  @override
  String get id => 'lume.cat.textcodec';

  @override
  List<String> get requires => const <String>['lume.cat.buffer'];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.TextEncoder !== 'function') {
    var TextEncoderImpl = function TextEncoder() {
      this.encoding = 'utf-8';
    };
    TextEncoderImpl.prototype.encode = function (input) {
      var text = input === undefined || input === null ? '' : String(input);
      var buffer = globalThis.Buffer.from(text, 'utf8');
      return new Uint8Array(buffer._b);
    };
    TextEncoderImpl.prototype.encodeInto = function (source, destination) {
      var bytes = this.encode(source);
      var count = Math.min(bytes.length, destination.length);
      destination.set(bytes.subarray(0, count));
      return { read: String(source === undefined || source === null ? '' : source).length, written: count };
    };
    globalThis.TextEncoder = TextEncoderImpl;
  }

  if (typeof globalThis.TextDecoder === 'function') return;

  var LABELS = {
    'utf-8': 'utf8', utf8: 'utf8', unicode11utf8: 'utf8', 'unicode-1-1-utf-8': 'utf8',
    'utf-16le': 'utf16le', utf16le: 'utf16le', ucs2: 'utf16le', 'ucs-2': 'utf16le',
    'iso-8859-1': 'latin1', latin1: 'latin1', 'windows-1252': 'latin1', ascii: 'latin1',
    binary: 'latin1'
  };

  var TextDecoderImpl = function TextDecoder(label, options) {
    var key = label === undefined || label === null ? 'utf-8' : String(label).toLowerCase();
    var encoding = LABELS[key];
    if (!encoding) {
      throw new RangeError('TextDecoder 不支持的编码：' + label + '（可用：utf-8 / utf-16le / latin1）');
    }
    this.encoding = encoding === 'utf8' ? 'utf-8' : (encoding === 'utf16le' ? 'utf-16le' : 'windows-1252');
    this.fatal = !!(options && options.fatal);
    this.ignoreBOM = !!(options && options.ignoreBOM);
  };

  TextDecoderImpl.prototype.decode = function (input) {
    if (input === undefined || input === null) return '';
    var bytes;
    // Buffer 实例是 Proxy 包装，先按 Buffer 认（字节在 `_b`）。
    if (globalThis.Buffer && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(input)) {
      bytes = input._b;
    } else if (input instanceof Uint8Array) {
      bytes = input;
    } else if (typeof ArrayBuffer === 'function' && input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (typeof ArrayBuffer === 'function' && ArrayBuffer.isView && ArrayBuffer.isView(input)) {
      bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    } else {
      throw new TypeError('TextDecoder.decode 只接受 ArrayBuffer 或 TypedArray');
    }
    var text = globalThis.Buffer.from(bytes).toString(this.encoding === 'windows-1252' ? 'latin1' : this.encoding);
    // 与 WHATWG 一致：ignoreBOM 为 false（默认）时吃掉开头的 BOM。
    if (!this.ignoreBOM && text.charCodeAt(0) === 0xfeff) return text.slice(1);
    return text;
  };

  globalThis.TextDecoder = TextDecoderImpl;
})();
''';
}

/// `URL` / `URLSearchParams`：WHATWG 的一个明确子集。
///
/// 支持：绝对地址解析、相对地址按 base 解析、点段折叠、查询参数的增删改查与
/// 序列化（`application/x-www-form-urlencoded` 规则：空格 → `+`）、
/// `url.searchParams` 与 `url.search` / `url.href` 的双向联动。
///
/// 明确不做（文档化偏差）：不做 IDN/punycode、不做完整百分号规范化、
/// 不实现 `URLPattern` 与 `URL.canParse` 之外的实验 API。
class CatUrlPolyfill implements SandboxPolyfill {
  const CatUrlPolyfill();

  @override
  String get id => 'lume.cat.url';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.URL === 'function' && typeof globalThis.URLSearchParams === 'function') return;

  // ------------------------------------------------ 百分号编解码（form-urlencoded）
  function encodeQuery(value) {
    return encodeURIComponent(String(value))
      .replace(/%20/g, '+')
      .replace(/[!'()*]/g, function (ch) { return '%' + ch.charCodeAt(0).toString(16).toUpperCase(); })
      .replace(/[~]/g, '%7E');
  }

  function decodeQuery(value) {
    var text = String(value).replace(/\+/g, ' ');
    try {
      return decodeURIComponent(text);
    } catch (error) {
      // 非法百分号序列：按字面量保留（与浏览器的容错解码一致）。
      return text;
    }
  }

  // ------------------------------------------------------------ URLSearchParams
  var URLSearchParamsImpl = function URLSearchParams(init) {
    this._list = [];
    if (init === undefined || init === null) return;
    if (typeof init === 'string') {
      var query = init.charAt(0) === '?' ? init.slice(1) : init;
      if (query.length === 0) return;
      var pairs = query.split('&');
      for (var i = 0; i < pairs.length; i++) {
        if (pairs[i].length === 0) continue;
        var eq = pairs[i].indexOf('=');
        var name = eq < 0 ? pairs[i] : pairs[i].slice(0, eq);
        var value = eq < 0 ? '' : pairs[i].slice(eq + 1);
        this._list.push([decodeQuery(name), decodeQuery(value)]);
      }
      return;
    }
    if (typeof init === 'object' && typeof init.length === 'number' && !init._list) {
      for (var k = 0; k < init.length; k++) {
        var entry = init[k];
        if (!entry) continue;
        this._list.push([String(entry[0]), String(entry[1])]);
      }
      return;
    }
    if (init && init._list) {
      for (var m = 0; m < init._list.length; m++) {
        this._list.push([init._list[m][0], init._list[m][1]]);
      }
      return;
    }
    if (typeof init === 'object') {
      var self = this;
      Object.keys(init).forEach(function (name) {
        self._list.push([name, String(init[name])]);
      });
    }
  };

  Object.defineProperty(URLSearchParamsImpl.prototype, 'size', {
    get: function () { return this._list.length; },
    configurable: true
  });

  URLSearchParamsImpl.prototype.append = function (name, value) {
    this._list.push([String(name), String(value)]);
    this._sync();
  };

  URLSearchParamsImpl.prototype.delete = function (name, value) {
    var key = String(name);
    var hasValue = arguments.length > 1;
    this._list = this._list.filter(function (entry) {
      if (entry[0] !== key) return true;
      return hasValue && entry[1] !== String(value);
    });
    this._sync();
  };

  URLSearchParamsImpl.prototype.get = function (name) {
    var key = String(name);
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] === key) return this._list[i][1];
    }
    return null;
  };

  URLSearchParamsImpl.prototype.getAll = function (name) {
    var key = String(name);
    var out = [];
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] === key) out.push(this._list[i][1]);
    }
    return out;
  };

  URLSearchParamsImpl.prototype.has = function (name, value) {
    var key = String(name);
    var hasValue = arguments.length > 1;
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] !== key) continue;
      if (!hasValue || this._list[i][1] === String(value)) return true;
    }
    return false;
  };

  URLSearchParamsImpl.prototype.set = function (name, value) {
    var key = String(name);
    var text = String(value);
    var replaced = false;
    var next = [];
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] !== key) {
        next.push(this._list[i]);
      } else if (!replaced) {
        next.push([key, text]);
        replaced = true;
      }
    }
    if (!replaced) next.push([key, text]);
    this._list = next;
    this._sync();
  };

  URLSearchParamsImpl.prototype.sort = function () {
    this._list.sort(function (a, b) {
      if (a[0] < b[0]) return -1;
      if (a[0] > b[0]) return 1;
      if (a[1] < b[1]) return -1;
      if (a[1] > b[1]) return 1;
      return 0;
    });
    this._sync();
  };

  URLSearchParamsImpl.prototype.toString = function () {
    var parts = [];
    for (var i = 0; i < this._list.length; i++) {
      parts.push(encodeQuery(this._list[i][0]) + '=' + encodeQuery(this._list[i][1]));
    }
    return parts.join('&');
  };

  URLSearchParamsImpl.prototype.forEach = function (callback, thisArg) {
    for (var i = 0; i < this._list.length; i++) {
      callback.call(thisArg, this._list[i][1], this._list[i][0], this);
    }
  };

  URLSearchParamsImpl.prototype.entries = function () {
    var list = this._list.slice();
    var index = 0;
    return {
      next: function () {
        if (index >= list.length) return { done: true, value: undefined };
        var entry = [list[index][0], list[index][1]];
        index++;
        return { done: false, value: entry };
      }
    };
  };
  URLSearchParamsImpl.prototype.keys = function () {
    var iterator = this.entries();
    return {
      next: function () {
        var step = iterator.next();
        return step.done ? step : { done: false, value: step.value[0] };
      }
    };
  };
  URLSearchParamsImpl.prototype.values = function () {
    var iterator = this.entries();
    return {
      next: function () {
        var step = iterator.next();
        return step.done ? step : { done: false, value: step.value[1] };
      }
    };
  };

  if (typeof Symbol === 'function' && Symbol.iterator) {
    URLSearchParamsImpl.prototype[Symbol.iterator] = URLSearchParamsImpl.prototype.entries;
  }

  /// 与 URL 联动：参数变化后把序列化结果写回 URL 的 search 段。
  URLSearchParamsImpl.prototype._sync = function () {
    var owner = this._owner;
    if (!owner) return;
    var query = this.toString();
    owner._search = query.length === 0 ? '' : '?' + query;
  };

  // ------------------------------------------------------------------------ URL
  var SPECIAL = { http: '80', https: '443', ws: '80', wss: '443', ftp: '21', file: null };

  function parseParts(input, base) {
    var text = String(input === undefined || input === null ? '' : input).trim();
    var parts = {
      scheme: '',
      authority: null,
      path: '',
      query: '',
      hash: ''
    };

    var hashIndex = text.indexOf('#');
    if (hashIndex >= 0) {
      parts.hash = text.slice(hashIndex);
      text = text.slice(0, hashIndex);
    }
    var queryIndex = text.indexOf('?');
    if (queryIndex >= 0) {
      parts.query = text.slice(queryIndex);
      text = text.slice(0, queryIndex);
    }

    var schemeMatch = /^([A-Za-z][A-Za-z0-9+.\-]*):/.exec(text);
    if (schemeMatch) {
      parts.scheme = schemeMatch[1].toLowerCase() + ':';
      var rest = text.slice(schemeMatch[0].length);
      if (rest.indexOf('//') === 0) {
        var slash = rest.slice(2).search(/[\/?#]/);
        var authority = slash < 0 ? rest.slice(2) : rest.slice(2, slash + 2);
        parts.authority = authority;
        parts.path = slash < 0 ? '' : rest.slice(slash + 2);
      } else {
        parts.path = rest;
      }
      return parts;
    }

    // 相对地址：必须有 base 才能解析。
    if (!base) return null;
    var baseParts = parseParts(base.href ? base.href : String(base), null);
    if (!baseParts) return null;
    parts.scheme = baseParts.scheme;
    parts.authority = baseParts.authority;
    if (text.length === 0) {
      parts.path = baseParts.path;
      parts.query = parts.query || baseParts.query;
      return parts;
    }
    if (text.indexOf('//') === 0) {
      var relSlash = text.slice(2).search(/[\/?#]/);
      parts.authority = relSlash < 0 ? text.slice(2) : text.slice(2, relSlash + 2);
      parts.path = relSlash < 0 ? '' : text.slice(relSlash + 2);
      return parts;
    }
    if (text.charAt(0) === '/') {
      parts.path = text;
      return parts;
    }
    // 目录合并：把 base 的最后一段换成相对路径，再折叠 . / ..
    var basePath = baseParts.path;
    var lastSlash = basePath.lastIndexOf('/');
    var directory = lastSlash < 0 ? '/' : basePath.slice(0, lastSlash + 1);
    parts.path = directory + text;
    return parts;
  }

  /// 折叠路径里的 . 与 ..（保留结尾的斜杠语义）。
  function normalizePath(path) {
    var trailingSlash = path.length > 1 && path.charAt(path.length - 1) === '/';
    var segments = path.split('/');
    var out = [];
    for (var i = 0; i < segments.length; i++) {
      var segment = segments[i];
      if (segment === '' ) continue;
      if (segment === '.') continue;
      if (segment === '..') {
        if (out.length > 1) out.pop();
        continue;
      }
      out.push(segment);
    }
    var normalized = '/' + out.join('/');
    if (trailingSlash && normalized !== '/') normalized += '/';
    return normalized;
  }

  var URLImpl = function URL(input, base) {
    if (!(this instanceof URLImpl)) {
      throw new TypeError("请用 new URL(...) 构造");
    }
    var parts = parseParts(input, base === undefined ? null : base);
    if (!parts || !parts.scheme) {
      throw new TypeError('URL 无法解析：' + input);
    }
    var special = Object.prototype.hasOwnProperty.call(SPECIAL, parts.scheme.slice(0, -1));
    this._scheme = parts.scheme;
    this._authority = parts.authority === null ? null : parts.authority;
    this._path = parts.path || (special && this._authority !== null ? '/' : parts.path);
    if (special && this._authority !== null) this._path = normalizePath(this._path || '/');
    this._search = parts.query || '';
    this._hash = parts.hash || '';
    this._params = null;
  };

  URLImpl.prototype._hostInfo = function () {
    var authority = this._authority;
    if (authority === null) {
      return { userinfo: '', host: '', hostname: '', port: '' };
    }
    var at = authority.lastIndexOf('@');
    var userinfo = at < 0 ? '' : authority.slice(0, at);
    var host = at < 0 ? authority : authority.slice(at + 1);
    var colon = host.lastIndexOf(':');
    var hostname = host;
    var port = '';
    if (colon > 0) {
      hostname = host.slice(0, colon);
      port = host.slice(colon + 1);
    }
    return { userinfo: userinfo, host: host, hostname: hostname, port: port };
  };

  Object.defineProperty(URLImpl.prototype, 'href', {
    get: function () { return this.toString(); },
    set: function (value) {
      var rebuilt = new URLImpl(String(value));
      this._scheme = rebuilt._scheme;
      this._authority = rebuilt._authority;
      this._path = rebuilt._path;
      this._search = rebuilt._search;
      this._hash = rebuilt._hash;
      this._params = null;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'protocol', {
    get: function () { return this._scheme; },
    set: function (value) {
      var text = String(value);
      this._scheme = text.charAt(text.length - 1) === ':' ? text.toLowerCase() : text.toLowerCase() + ':';
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'username', {
    get: function () { return this._hostInfo().userinfo.split(':')[0] || ''; },
    set: function (value) {
      var info = this._hostInfo();
      var password = info.userinfo.indexOf(':') >= 0 ? info.userinfo.slice(info.userinfo.indexOf(':')) : '';
      this._authority = String(value) + password + '@' + info.host;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'password', {
    get: function () {
      var info = this._hostInfo().userinfo;
      var colon = info.indexOf(':');
      return colon < 0 ? '' : info.slice(colon + 1);
    },
    set: function (value) {
      var info = this._hostInfo();
      var name = info.userinfo.split(':')[0] || '';
      this._authority = name + ':' + String(value) + '@' + info.host;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'host', {
    get: function () { return this._hostInfo().host; },
    set: function (value) {
      var info = this._hostInfo();
      this._authority = (info.userinfo ? info.userinfo + '@' : '') + String(value);
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'hostname', {
    get: function () { return this._hostInfo().hostname; },
    set: function (value) {
      var info = this._hostInfo();
      var host = String(value) + (info.port ? ':' + info.port : '');
      this._authority = (info.userinfo ? info.userinfo + '@' : '') + host;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'port', {
    get: function () {
      var info = this._hostInfo();
      var scheme = this._scheme.slice(0, -1);
      if (Object.prototype.hasOwnProperty.call(SPECIAL, scheme) && SPECIAL[scheme] === info.port) return '';
      return info.port;
    },
    set: function (value) {
      var info = this._hostInfo();
      var text = String(value);
      var host = text.length === 0 ? info.hostname : info.hostname + ':' + text;
      this._authority = (info.userinfo ? info.userinfo + '@' : '') + host;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'pathname', {
    get: function () { return this._path; },
    set: function (value) {
      var text = String(value);
      this._path = text.charAt(0) === '/' ? text : '/' + text;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'search', {
    get: function () {
      // 参数对象持有改动时以它为准（保持与 WHATWG 一致的联动语义）。
      if (this._params) {
        var query = this._params.toString();
        this._search = query.length === 0 ? '' : '?' + query;
      }
      return this._search;
    },
    set: function (value) {
      var text = String(value);
      if (text.length === 0) {
        this._search = '';
      } else {
        this._search = text.charAt(0) === '?' ? text : '?' + text;
      }
      this._params = null;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'hash', {
    get: function () { return this._hash; },
    set: function (value) {
      var text = String(value);
      this._hash = text.length === 0 ? '' : (text.charAt(0) === '#' ? text : '#' + text);
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'origin', {
    get: function () {
      if (this._authority === null) return 'null';
      return this._scheme + '//' + this._hostInfo().host;
    },
    configurable: true
  });

  Object.defineProperty(URLImpl.prototype, 'searchParams', {
    get: function () {
      if (!this._params) {
        this._params = new URLSearchParamsImpl(this._search);
        this._params._owner = this;
      }
      return this._params;
    },
    configurable: true
  });

  URLImpl.prototype.toString = function () {
    var out = this._scheme;
    if (this._authority !== null) out += '//' + this._authority;
    out += this._path;
    out += this.search;   // 走 getter：参数对象的改动会在这里同步
    out += this._hash;
    return out;
  };

  URLImpl.prototype.toJSON = function () { return this.toString(); };

  if (typeof globalThis.URLSearchParams !== 'function') {
    globalThis.URLSearchParams = URLSearchParamsImpl;
  }
  if (typeof globalThis.URL !== 'function') {
    globalThis.URL = URLImpl;
  }

  // ------------------------------------------------------ require('url') 模块面
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (!registry.url) {
    function queryToObject(params) {
      var out = {};
      params.forEach(function (value, name) {
        if (!Object.prototype.hasOwnProperty.call(out, name)) {
          out[name] = value;
        } else if (Array.isArray(out[name])) {
          out[name].push(value);
        } else {
          out[name] = [out[name], value];
        }
      });
      return out;
    }

    function objectToQuery(object) {
      var params = new globalThis.URLSearchParams();
      Object.keys(object || {}).forEach(function (name) {
        var value = object[name];
        if (Array.isArray(value)) {
          value.forEach(function (item) { params.append(name, item); });
        } else if (value !== undefined && value !== null) {
          params.append(name, value);
        }
      });
      return params.toString();
    }

    registry.url = {
      URL: globalThis.URL,
      URLSearchParams: globalThis.URLSearchParams,
      // 遗留 API（url.parse / url.format / url.resolve）：老打包产物还在用。
      parse: function (input, parseQueryString) {
        var text = String(input === undefined || input === null ? '' : input);
        var parsed;
        try {
          parsed = new globalThis.URL(text);
        } catch (error) {
          return {
            href: text, protocol: null, slashes: null, auth: null, host: null,
            port: null, hostname: null, hash: null, search: null, query: null,
            pathname: text, path: text, parseQueryString: !!parseQueryString
          };
        }
        var search = parsed.search;
        return {
          href: parsed.toString(),
          protocol: parsed.protocol,
          slashes: parsed.toString().indexOf(parsed.protocol + '//') === 0,
          auth: parsed.username ? parsed.username + (parsed.password ? ':' + parsed.password : '') : null,
          host: parsed.host || null,
          port: parsed.port || null,
          hostname: parsed.hostname || null,
          hash: parsed.hash || null,
          search: search || null,
          query: parseQueryString ? queryToObject(parsed.searchParams) : (search ? search.slice(1) : null),
          pathname: parsed.pathname,
          path: parsed.pathname + search,
          parseQueryString: !!parseQueryString
        };
      },
      format: function (urlObject) {
        if (typeof urlObject === 'string') return urlObject;
        if (!urlObject) return '';
        if (urlObject instanceof globalThis.URL) return urlObject.toString();
        var protocol = urlObject.protocol || '';
        var auth = urlObject.auth ? urlObject.auth + '@' : '';
        var host = urlObject.host ||
          ((urlObject.hostname || '') + (urlObject.port ? ':' + urlObject.port : ''));
        var pathname = urlObject.pathname || '';
        var search = urlObject.search || '';
        if (!search && urlObject.query) {
          search = '?' + (typeof urlObject.query === 'string' ? urlObject.query : objectToQuery(urlObject.query));
        }
        var hash = urlObject.hash || '';
        var slashes = urlObject.slashes !== undefined
          ? urlObject.slashes
          : /^(https?|ftp|ws|wss|file):$/.test(protocol);
        return protocol + (slashes ? '//' : '') + auth + host + pathname + search + hash;
      },
      resolve: function (from, to) {
        return new globalThis.URL(String(to === undefined ? '' : to), String(from === undefined ? '' : from)).toString();
      },
      pathToFileURL: function (path) {
        return new globalThis.URL('file://' + String(path === undefined ? '' : path));
      },
      fileURLToPath: function (url) {
        var parsed = url instanceof globalThis.URL ? url : new globalThis.URL(String(url));
        return parsed.pathname;
      }
    };
  }
})();
''';
}

/// `structuredClone`：结构化深拷贝。
///
/// 支持：基本类型、Array、普通对象、Map / Set、Date / RegExp、ArrayBuffer 与
/// 各类 TypedArray，以及环引用（用 seen 表登记）。函数、Symbol、类实例这类
/// 不可克隆的值抛出 `DataCloneError`（与 Node 一致，错误可读）。
class CatStructuredClonePolyfill implements SandboxPolyfill {
  const CatStructuredClonePolyfill();

  @override
  String get id => 'lume.cat.structuredclone';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.structuredClone === 'function') return;

  function DataCloneError(message) {
    var error = new Error(message);
    error.name = 'DataCloneError';
    return error;
  }

  function isPlainObject(value) {
    var prototype = Object.getPrototypeOf(value);
    return prototype === Object.prototype || prototype === null;
  }

  function cloneValue(value, seen) {
    if (value === null || typeof value !== 'object') {
      if (typeof value === 'function' || typeof value === 'symbol') {
        throw DataCloneError('structuredClone 不能克隆 ' + typeof value);
      }
      return value;
    }
    var existing = seen.get(value);
    if (existing !== undefined) return existing;

    if (Array.isArray(value)) {
      var array = [];
      seen.set(value, array);
      for (var i = 0; i < value.length; i++) {
        array[i] = cloneValue(value[i], seen);
      }
      return array;
    }

    if (value instanceof Date) return new Date(value.getTime());
    if (value instanceof RegExp) return new RegExp(value.source, value.flags);

    if (typeof ArrayBuffer === 'function') {
      if (value instanceof ArrayBuffer) return value.slice(0);
      if (ArrayBuffer.isView && ArrayBuffer.isView(value)) {
        var buffer = value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength);
        if (value instanceof DataView) return new DataView(buffer);
        if (globalThis.Buffer && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(value)) {
          return globalThis.Buffer.from(new Uint8Array(buffer));
        }
        return new value.constructor(buffer);
      }
    }

    if (value instanceof Map) {
      var map = new Map();
      seen.set(value, map);
      value.forEach(function (item, key) {
        map.set(cloneValue(key, seen), cloneValue(item, seen));
      });
      return map;
    }

    if (value instanceof Set) {
      var set = new Set();
      seen.set(value, set);
      value.forEach(function (item) {
        set.add(cloneValue(item, seen));
      });
      return set;
    }

    if (globalThis.Buffer && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(value)) {
      var copied = globalThis.Buffer.from(new Uint8Array(value._b));
      seen.set(value, copied);
      return copied;
    }

    if (isPlainObject(value)) {
      var target = {};
      seen.set(value, target);
      Object.keys(value).forEach(function (key) {
        target[key] = cloneValue(value[key], seen);
      });
      return target;
    }

    throw DataCloneError('structuredClone 不支持的克隆类型：' + (value.constructor && value.constructor.name ? value.constructor.name : 'Object'));
  }

  globalThis.structuredClone = function (value) {
    return cloneValue(value, new Map());
  };
})();
''';
}

/// `localStorage` / `sessionStorage`：**进程内**存储，不落盘。
///
/// 存在的理由：Node 打包产物里的第三方库常在初始化阶段探测 `localStorage`
/// 是否存在（探测不到就直接抛错）。这里给一个最小可用的内存实现，
/// 明确不承诺持久化：上下文被销毁重建（超时 / 污染）后内容清空，
/// 沙箱也依旧没有任何文件 IO —— 需要跨会话保存的脚本必须走宿主桥接层。
class CatStoragePolyfill implements SandboxPolyfill {
  const CatStoragePolyfill();

  @override
  String get id => 'lume.cat.storage';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  function createStorage() {
    var data = {};
    var storage = {
      get length() { return Object.keys(data).length; },
      key: function (index) {
        var keys = Object.keys(data);
        var i = Number(index);
        return i >= 0 && i < keys.length ? keys[i] : null;
      },
      getItem: function (key) {
        var name = String(key);
        return Object.prototype.hasOwnProperty.call(data, name) ? data[name] : null;
      },
      setItem: function (key, value) { data[String(key)] = String(value); },
      removeItem: function (key) { delete data[String(key)]; },
      clear: function () { data = {}; }
    };
    return storage;
  }

  if (typeof globalThis.localStorage === 'undefined') {
    globalThis.localStorage = createStorage();
  }
  if (typeof globalThis.sessionStorage === 'undefined') {
    globalThis.sessionStorage = createStorage();
  }
})();
''';
}
