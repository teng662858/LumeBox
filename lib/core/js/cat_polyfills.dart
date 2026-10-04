/// 猫源沙箱的 Node 风格垫片（**只对猫源注入**，见 `LumeSourcePolyfills.forSection`）。
///
/// 补齐猫源脚本生态常见的运行环境：`process` / `Buffer` / 基础 `require` 模拟 /
/// `console` 补全 / 定时器补全。四条纪律（对齐任务书 1–4 条与宪法第 3、4 条）：
///
/// - **不引入真实 Node 运行时**：全部是纯 JS 垫片，没有原生依赖、没有新权限；
/// - **不暴露 node 的 fs / http**：`require` 只识别 `buffer` / `process` /
///   `console` / `timers` 四个无害内建；`fs` / `http` / `net` 等一律抛出可读
///   错误——网络与文件 IO 只能走宿主桥接层（`fetch` / `LumeBridge.invoke`）；
/// - **WASM 与 `.node` 原生模块不做兼容**：遇到即抛出友好错误
///   （`WebAssembly` 被替换为抛错存根，`require('x.node')` / `require('x.wasm')`
///   一律拒绝），错误文本带稳定的 `code = 'LUME_UNSUPPORTED'`；
/// - **幂等可重复**：上下文因超时或污染被销毁重建后，垫片随新上下文重新注入，
///   因此每个猫源实例（一个图源一个 JSContext）都拿到全新、互不共享的垫片状态。
library;

import 'sandbox/sandbox_polyfill.dart';

/// 猫源垫片集合（顺序即登记顺序，依赖由 [PolyfillRegistry] 解析）。
class CatPolyfills {
  const CatPolyfills._();

  static const List<SandboxPolyfill> all = <SandboxPolyfill>[
    CatUnsupportedGuardPolyfill(),
    CatConsolePolyfill(),
    CatTimersPolyfill(),
    CatProcessPolyfill(),
    CatBufferPolyfill(),
    CatRequirePolyfill(),
  ];
}

/// 边界处理：WASM / `.node` 原生模块的友好拒绝。
///
/// 提供统一的 `__lumeUnsupportedModule(name)`，并把 `WebAssembly` 换成抛错存根
/// ——「不做兼容」在脚本侧表现为可读错误，而不是静默失败或崩溃。
class CatUnsupportedGuardPolyfill implements SandboxPolyfill {
  const CatUnsupportedGuardPolyfill();

  @override
  String get id => 'lume.cat.unsupported';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  function unsupported(name, hint) {
    var error = new Error('猫源沙箱不支持「' + name + '」' + (hint ? '：' + hint : ''));
    error.code = 'LUME_UNSUPPORTED';
    return error;
  }

  globalThis.__lumeUnsupportedModule = function (name) {
    var id = String(name == null ? '' : name);
    if (/\.node$/i.test(id)) {
      return unsupported(id, '.node 原生模块不能在沙箱里加载');
    }
    if (/\.wasm$/i.test(id) || /(^|[\/_\-])wasm($|[\/_\-])/i.test(id)) {
      return unsupported(id, '沙箱不提供 WebAssembly');
    }
    if (/^(node:)?(fs|http|https|net|tls|dns|child_process|worker_threads|cluster|module|vm)(\/|$)/i.test(id)) {
      return unsupported(id, '网络与文件 IO 要经宿主桥接层（fetch / LumeBridge.invoke），沙箱不暴露 Node 的 fs / http');
    }
    return unsupported(id, '可用内建模块只有 buffer / process / console / timers');
  };

  function rejectWasm() {
    throw globalThis.__lumeUnsupportedModule('WebAssembly');
  }

  var wasmStub = {
    compile: rejectWasm,
    instantiate: rejectWasm,
    validate: rejectWasm,
    compileStreaming: rejectWasm,
    instantiateStreaming: rejectWasm,
    Module: function () { rejectWasm(); },
    Instance: function () { rejectWasm(); },
    Memory: function () { rejectWasm(); },
    Table: function () { rejectWasm(); },
    Global: function () { rejectWasm(); },
    RuntimeError: function () { rejectWasm(); },
    CompileError: function () { rejectWasm(); }
  };
  globalThis.WebAssembly = wasmStub;
})();
''';
}

/// `console` 补全：prelude 已提供 log / warn / error，这里补齐 info / debug /
/// trace / dir / assert 等常见方法。
class CatConsolePolyfill implements SandboxPolyfill {
  const CatConsolePolyfill();

  @override
  String get id => 'lume.cat.console';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  var target = globalThis.console;
  if (!target || typeof target.log !== 'function') return;

  function alias(name, source) {
    if (typeof target[name] === 'function') return;
    target[name] = function () { return target[source].apply(target, arguments); };
  }

  alias('info', 'log');
  alias('debug', 'log');
  alias('trace', 'warn');
  alias('dir', 'log');
  alias('log', 'log');

  if (typeof target.assert !== 'function') {
    target.assert = function (condition) {
      if (condition) return;
      var rest = Array.prototype.slice.call(arguments, 1);
      target.error.apply(target, rest.length ? rest : ['断言失败']);
    };
  }
})();
''';
}

/// 定时器补全：prelude 已有 setTimeout / clearTimeout（宿主计时），这里补齐
/// `setInterval / clearInterval / setImmediate / clearImmediate`，并让
/// `setTimeout` 支持 Node 的「附加参数」写法。
///
/// 实现纪律：每个 tick 都经 prelude 的 `setTimeout` 重新挂到宿主计时器上，
/// 因此依旧受沙箱的定时器数量上限与销毁时统一取消的约束（并发挂起的定时器
/// 不会超过上限；上下文销毁时宿主侧计时器一并撤销）。
class CatTimersPolyfill implements SandboxPolyfill {
  const CatTimersPolyfill();

  @override
  String get id => 'lume.cat.timers';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  var nativeSetTimeout = globalThis.setTimeout;
  var nativeClearTimeout = globalThis.clearTimeout;
  if (typeof nativeSetTimeout !== 'function') return;

  if (!globalThis.setTimeout.__lumeCatArgs) {
    var wrapped = function (fn, delay) {
      var args = Array.prototype.slice.call(arguments, 2);
      if (typeof fn !== 'function' || args.length === 0) {
        return nativeSetTimeout(fn, delay);
      }
      return nativeSetTimeout(function () { fn.apply(null, args); }, delay);
    };
    wrapped.__lumeCatArgs = true;
    globalThis.setTimeout = wrapped;
    globalThis.clearTimeout = nativeClearTimeout;
  }

  var intervals = {};
  var seq = 0;

  if (!globalThis.setInterval || !globalThis.setInterval.__lumeCat) {
    var setIntervalImpl = function (fn, delay) {
      var args = Array.prototype.slice.call(arguments, 2);
      var key = 'iv' + (seq++);
      var entry = { cancelled: false, timerId: null };
      intervals[key] = entry;

      function tick() {
        if (entry.cancelled) return;
        try {
          fn.apply(null, args);
        } catch (error) {
          if (globalThis.console && console.error) {
            console.error('setInterval 回调异常: ' + (error && error.message ? error.message : error));
          }
        }
        if (entry.cancelled) return;
        entry.timerId = globalThis.setTimeout(tick, delay);
      }

      entry.timerId = globalThis.setTimeout(tick, delay);
      return key;
    };
    setIntervalImpl.__lumeCat = true;
    globalThis.setInterval = setIntervalImpl;
  }

  if (!globalThis.clearInterval || !globalThis.clearInterval.__lumeCat) {
    var clearIntervalImpl = function (id) {
      var entry = intervals[id];
      if (!entry) return;
      entry.cancelled = true;
      if (entry.timerId !== null) globalThis.clearTimeout(entry.timerId);
      delete intervals[id];
    };
    clearIntervalImpl.__lumeCat = true;
    globalThis.clearInterval = clearIntervalImpl;
  }

  if (!globalThis.setImmediate || !globalThis.setImmediate.__lumeCat) {
    var setImmediateImpl = function (fn) {
      var args = Array.prototype.slice.call(arguments, 1);
      return globalThis.setTimeout(function () { fn.apply(null, args); }, 0);
    };
    setImmediateImpl.__lumeCat = true;
    globalThis.setImmediate = setImmediateImpl;
  }

  if (!globalThis.clearImmediate || !globalThis.clearImmediate.__lumeCat) {
    var clearImmediateImpl = function (id) { globalThis.clearTimeout(id); };
    clearImmediateImpl.__lumeCat = true;
    globalThis.clearImmediate = clearImmediateImpl;
  }
})();
''';
}

/// `process` 模拟（不假装是 Node：`version` 明确标成 lume 占位，
/// `versions.node` 不提供，脚本据此走兼容分支而不是误用 Node 能力）。
class CatProcessPolyfill implements SandboxPolyfill {
  const CatProcessPolyfill();

  @override
  String get id => 'lume.cat.process';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  if (globalThis.process && globalThis.process.__lumeCat) return;

  function unsupported(message) {
    var error = new Error(message);
    error.code = 'LUME_UNSUPPORTED';
    return error;
  }

  var env = {};
  try { Object.freeze(env); } catch (e) { /* 老引擎没有 freeze 也能用 */ }

  var process = {
    __lumeCat: true,
    // iOS 上的 Node 语义平台名是 darwin；沙箱不认识别的平台。
    platform: 'darwin',
    arch: 'arm64',
    env: env,
    argv: ['lume', 'cat-source'],
    // 不假装 Node 版本：脚本据此走兼容分支，而不是误用 Node 能力。
    version: 'v0.0.0-lume',
    versions: (function () { try { return Object.freeze({}); } catch (e) { return {}; } })(),
    pid: 0,
    cwd: function () { return '/'; },
    nextTick: function (fn) {
      var args = Array.prototype.slice.call(arguments, 1);
      Promise.resolve()
        .then(function () { fn.apply(null, args); })
        .catch(function (error) {
          if (globalThis.console && console.error) {
            console.error('process.nextTick 回调异常: ' + (error && error.message ? error.message : error));
          }
        });
    },
    on: function () { return process; },
    once: function () { return process; },
    off: function () { return process; },
    removeListener: function () { return process; },
    emit: function () { return false; },
    exit: function () { throw unsupported('猫源沙箱不支持 process.exit()'); },
    kill: function () { throw unsupported('猫源沙箱不支持 process.kill()'); },
    memoryUsage: function () { return { rss: 0, heapTotal: 0, heapUsed: 0 }; },
    hrtime: function (previous) {
      var now = Date.now();
      var seconds = Math.floor(now / 1000);
      var nanos = (now % 1000) * 1000000;
      if (previous) {
        seconds = seconds - previous[0];
        nanos = nanos - previous[1];
        if (nanos < 0) {
          seconds -= 1;
          nanos += 1000000000;
        }
      }
      return [seconds, nanos];
    }
  };

  globalThis.process = process;
})();
''';
}

/// `Buffer` 基础模拟：utf8 / base64 / hex / latin1 的编解码 + 常用静态与实例
/// 方法。全部纯 JS 实现——不经宿主、不需要原生能力（base64 是猫源脚本里最常
/// 用来处理密钥与图片的编码）。
class CatBufferPolyfill implements SandboxPolyfill {
  const CatBufferPolyfill();

  @override
  String get id => 'lume.cat.buffer';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  if (globalThis.Buffer && globalThis.Buffer.__lumeCat) return;

  function fail(message) {
    var error = new Error(message);
    error.code = 'LUME_UNSUPPORTED';
    return error;
  }

  function normalizeEncoding(encoding) {
    if (encoding === undefined || encoding === null) return 'utf8';
    var name = String(encoding).toLowerCase();
    if (name === 'utf8' || name === 'utf-8' || name === 'binary-utf8') return 'utf8';
    if (name === 'base64' || name === 'base64url') return 'base64';
    if (name === 'hex') return 'hex';
    if (name === 'latin1' || name === 'binary' || name === 'ascii') return 'latin1';
    return null;
  }

  // --------------------------------------------------------- 编解码（纯 JS）
  function utf8Encode(text) {
    var bytes = [];
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        var next = text.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        if (code >= 0xd800 && code <= 0xdfff) code = 0xfffd;
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return bytes;
  }

  function utf8Decode(bytes) {
    var text = '';
    var i = 0;
    while (i < bytes.length) {
      var first = bytes[i];
      var code = 0xfffd;
      var size = 1;
      if (first < 0x80) {
        code = first;
      } else if (first >= 0xc0 && first < 0xe0) {
        code = first & 0x1f;
        size = 2;
      } else if (first >= 0xe0 && first < 0xf0) {
        code = first & 0x0f;
        size = 3;
      } else if (first >= 0xf0 && first < 0xf8) {
        code = first & 0x07;
        size = 4;
      }

      var valid = true;
      for (var k = 1; k < size; k++) {
        if (i + k >= bytes.length || (bytes[i + k] & 0xc0) !== 0x80) {
          valid = false;
          break;
        }
        code = (code << 6) | (bytes[i + k] & 0x3f);
      }
      if (!valid || code > 0x10ffff) {
        code = 0xfffd;
        size = 1;
      }
      i += size;

      if (code > 0xffff) {
        var offset = code - 0x10000;
        text += String.fromCharCode(0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff));
      } else {
        text += String.fromCharCode(code);
      }
    }
    return text;
  }

  var BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function base64Encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i];
      var has1 = i + 1 < bytes.length;
      var has2 = i + 2 < bytes.length;
      var b1 = has1 ? bytes[i + 1] : 0;
      var b2 = has2 ? bytes[i + 2] : 0;
      out += BASE64[b0 >> 2];
      out += BASE64[((b0 & 3) << 4) | (b1 >> 4)];
      out += has1 ? BASE64[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += has2 ? BASE64[b2 & 63] : '=';
    }
    return out;
  }

  function base64Decode(text) {
    var clean = String(text).replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (clean.length % 4 !== 0) clean += '=';
    var bytes = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < clean.length; i++) {
      var ch = clean[i];
      if (ch === '=') break;
      var value = BASE64.indexOf(ch);
      if (value < 0) throw fail('Buffer 不认识的 base64 字符：' + ch);
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.push((buffer >> bits) & 0xff);
      }
    }
    return bytes;
  }

  function hexEncode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return out;
  }

  function hexDecode(text) {
    var clean = String(text).trim();
    if (clean.length % 2 !== 0) throw fail('hex 字符串长度必须是偶数');
    var bytes = [];
    for (var i = 0; i < clean.length; i += 2) {
      var pair = clean.substr(i, 2);
      if (!/^[0-9a-fA-F]{2}$/.test(pair)) throw fail('hex 字符串含非法字符：' + pair);
      bytes.push(parseInt(pair, 16));
    }
    return bytes;
  }

  function latin1Encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }

  function latin1Decode(text) {
    var bytes = [];
    for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i) & 0xff);
    return bytes;
  }

  function encodeString(text, encoding) {
    switch (encoding) {
      case 'utf8': return utf8Encode(text);
      case 'base64': return base64Decode(text);
      case 'hex': return hexDecode(text);
      case 'latin1': return latin1Decode(text);
      default: throw fail('Buffer 不支持的编码：' + encoding);
    }
  }

  function decodeToString(bytes, encoding) {
    switch (encoding) {
      case 'utf8': return utf8Decode(bytes);
      case 'base64': return base64Encode(bytes);
      case 'hex': return hexEncode(bytes);
      case 'latin1': return latin1Encode(bytes);
      default: throw fail('Buffer 不支持的编码：' + encoding);
    }
  }

  function toUint8Array(value, encoding) {
    if (value instanceof Uint8Array) return new Uint8Array(value);
    if (Array.isArray(value)) {
      var fromArray = new Uint8Array(value.length);
      for (var i = 0; i < value.length; i++) fromArray[i] = Number(value[i]) & 0xff;
      return fromArray;
    }
    if (typeof value === 'string') {
      var name = normalizeEncoding(encoding);
      if (name === null) throw fail('Buffer 不支持的编码：' + encoding);
      return new Uint8Array(encodeString(value, name));
    }
    if (value && typeof value === 'object' && typeof value.length === 'number') {
      return toUint8Array(Array.prototype.slice.call(value), encoding);
    }
    throw fail('Buffer.from 不支持的类型：' + typeof value);
  }

  function Buffer(value, encoding) {
    if (!(this instanceof Buffer)) return Buffer.from(value, encoding);
    this._b = toUint8Array(value, encoding);
  }

  function makeBuffer(bytes) {
    var buffer = new Buffer(bytes);
    if (typeof Proxy !== 'function') return buffer;
    return new Proxy(buffer, {
      get: function (target, key) {
        if (typeof key === 'string' && /^[0-9]+$/.test(key)) {
          var index = Number(key);
          return index < target._b.length ? target._b[index] : undefined;
        }
        return target[key];
      },
      set: function (target, key, value) {
        if (typeof key === 'string' && /^[0-9]+$/.test(key)) {
          var index = Number(key);
          if (index < target._b.length) target._b[index] = Number(value) & 0xff;
          return true;
        }
        target[key] = value;
        return true;
      }
    });
  }

  Object.defineProperty(Buffer.prototype, 'length', {
    get: function () { return this._b.length; },
    configurable: true
  });

  Buffer.prototype.toString = function (encoding, start, end) {
    var name = normalizeEncoding(encoding);
    if (name === null) throw fail('Buffer 不支持的编码：' + encoding);
    var bytes = this._b;
    var from = start === undefined || start === null ? 0 : Math.max(0, Number(start) | 0);
    var to = end === undefined || end === null ? bytes.length : Math.min(bytes.length, Number(end) | 0);
    if (to < from) to = from;
    return decodeToString(bytes.subarray(from, to), name);
  };

  Buffer.prototype.slice = function (start, end) {
    var bytes = this._b;
    var from = start === undefined || start === null ? 0 : Math.max(0, Number(start) | 0);
    var to = end === undefined || end === null ? bytes.length : Math.min(bytes.length, Number(end) | 0);
    if (to < from) to = from;
    return makeBuffer(bytes.subarray(from, to));
  };

  Buffer.prototype.equals = function (other) {
    if (!Buffer.isBuffer(other)) return false;
    var mine = this._b;
    var theirs = other._b;
    if (mine.length !== theirs.length) return false;
    for (var i = 0; i < mine.length; i++) {
      if (mine[i] !== theirs[i]) return false;
    }
    return true;
  };

  Buffer.prototype.toJSON = function () {
    return { type: 'Buffer', data: Array.prototype.slice.call(this._b) };
  };

  Buffer.__lumeCat = true;

  Buffer.from = function (value, encoding) {
    if (value instanceof Buffer) return makeBuffer(new Uint8Array(value._b));
    return makeBuffer(toUint8Array(value, encoding));
  };

  Buffer.alloc = function (size) {
    var length = Math.max(0, Number(size) | 0);
    return makeBuffer(new Uint8Array(length));
  };

  // 沙箱里没有内存池可复用：与 alloc 同语义（零填充），不会泄露旧内存。
  Buffer.allocUnsafe = function (size) { return Buffer.alloc(size); };

  Buffer.concat = function (list, totalLength) {
    var items = Array.isArray(list) ? list : [];
    var total = 0;
    var i;
    for (i = 0; i < items.length; i++) total += items[i]._b.length;
    var merged = new Uint8Array(totalLength === undefined || totalLength === null ? total : Math.max(0, Number(totalLength) | 0));
    var offset = 0;
    for (i = 0; i < items.length && offset < merged.length; i++) {
      var bytes = items[i]._b;
      var count = Math.min(bytes.length, merged.length - offset);
      merged.set(bytes.subarray(0, count), offset);
      offset += count;
    }
    return makeBuffer(merged);
  };

  Buffer.isBuffer = function (value) {
    if (value instanceof Buffer) return true;
    return !!(value && value._b instanceof Uint8Array && typeof value.toString === 'function' && value.toJSON && value.toJSON().type === 'Buffer');
  };

  Buffer.byteLength = function (value, encoding) {
    if (value instanceof Buffer) return value._b.length;
    if (typeof value === 'string') {
      var name = normalizeEncoding(encoding);
      if (name === null) throw fail('Buffer 不支持的编码：' + encoding);
      return encodeString(value, name).length;
    }
    if (value instanceof Uint8Array) return value.length;
    if (Array.isArray(value)) return value.length;
    throw fail('Buffer.byteLength 不支持的类型：' + typeof value);
  };

  globalThis.Buffer = Buffer;
})();
''';
}

/// 基础 `require` 模拟：只识别少数无害内建模块，其余一律给出友好错误。
///
/// 明确不做的事（任务书第 2、3 条）：不加载任何外置文件（没有文件系统）、
/// 不暴露 node 的 `fs` / `http`、不支持 `.node` 原生模块与 WASM。
class CatRequirePolyfill implements SandboxPolyfill {
  const CatRequirePolyfill();

  @override
  String get id => 'lume.cat.require';

  @override
  List<String> get requires => const <String>[
        'lume.cat.unsupported',
        'lume.cat.console',
        'lume.cat.timers',
        'lume.cat.process',
        'lume.cat.buffer',
      ];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.require === 'function' && globalThis.require.__lumeCat) return;

  var modules = {
    buffer: { Buffer: globalThis.Buffer },
    process: globalThis.process,
    console: globalThis.console,
    timers: {
      setTimeout: globalThis.setTimeout,
      clearTimeout: globalThis.clearTimeout,
      setInterval: globalThis.setInterval,
      clearInterval: globalThis.clearInterval,
      setImmediate: globalThis.setImmediate,
      clearImmediate: globalThis.clearImmediate
    }
  };

  var requireModule = function (name) {
    var id = String(name === undefined || name === null ? '' : name).trim();
    if (id.indexOf('node:') === 0) id = id.slice(5);
    if (Object.prototype.hasOwnProperty.call(modules, id)) return modules[id];
    throw globalThis.__lumeUnsupportedModule(id);
  };
  requireModule.__lumeCat = true;
  requireModule.resolve = function (name) { return String(name); };

  globalThis.require = requireModule;
  globalThis.module = { exports: {} };
  globalThis.exports = globalThis.module.exports;
})();
''';
}
