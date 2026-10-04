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

import 'cat_node_extras.dart';
import 'cat_node_modules.dart';
import 'cat_web_polyfills.dart';
import 'sandbox/sandbox_polyfill.dart';

/// 猫源垫片集合（顺序即登记顺序，依赖由 [PolyfillRegistry] 解析）。
///
/// 分三层：
/// - 边界与基础环境（本文件）：WASM/.node 拒绝、console、定时器、process、Buffer；
/// - 平台全局（`cat_web_polyfills.dart`）：TextEncoder/TextDecoder、URL、
///   structuredClone、localStorage/sessionStorage；
/// - Node 模块（`cat_node_modules.dart` + `cat_node_extras.dart`）：crypto /
///   events / path / util / assert / stream / http（桥接宿主网络）/ fs（内存盘）/
///   os / url / zlib（解压）/ tty / async_hooks / diagnostics_channel /
///   perf_hooks / module / timers-promises。
///
/// `require` 最后注入：它按名引用前面这些模块。
class CatPolyfills {
  const CatPolyfills._();

  static const List<SandboxPolyfill> all = <SandboxPolyfill>[
    CatUnsupportedGuardPolyfill(),
    CatConsolePolyfill(),
    CatTimersPolyfill(),
    CatProcessPolyfill(),
    CatBufferPolyfill(),
    CatTextCodecPolyfill(),
    CatUrlPolyfill(),
    CatStructuredClonePolyfill(),
    CatStoragePolyfill(),
    CatCryptoPolyfill(),
    CatEventsPolyfill(),
    CatPathPolyfill(),
    CatUtilPolyfill(),
    CatAssertPolyfill(),
    CatStreamPolyfill(),
    CatHttpPolyfill(),
    CatFsPolyfill(),
    CatOsPolyfill(),
    CatZlibPolyfill(),
    CatTtyPolyfill(),
    CatAsyncHooksPolyfill(),
    CatDiagnosticsChannelPolyfill(),
    CatPerfHooksPolyfill(),
    CatTimersPromisesPolyfill(),
    CatModulePolyfill(),
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
    if (/^(node:)?(net|tls|dns|child_process|worker_threads|cluster|vm|diagnostics_channel|async_hooks|perf_hooks|v8)(\/|$)/i.test(id)) {
      return unsupported(id, '沙箱不提供进程、线程与底层网络：网络请求走 fetch（宿主桥接层）');
    }
    if (/^(node:)?(zlib|readline|repl|inspector|http2|dgram|v8)(\/|$)/i.test(id)) {
      return unsupported(id, '沙箱暂未内置该模块（已内置：buffer / process / console / timers / crypto / events / path / util / assert / stream / http / https / fs（内存盘）/ os / url / timers/promises）');
    }
    return unsupported(id, '可用内建模块：buffer / process / console / timers / crypto / events / path / util / assert / stream / http / https / fs（内存盘）/ os / url / timers/promises');
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
    if (name === 'utf16le' || name === 'utf-16le' || name === 'ucs2' || name === 'ucs-2') return 'utf16le';
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

  // Node 的 utf16le：按 JS 的 UTF-16 码元逐个写出（代理对天然是 4 字节），
  // 解码时忽略结尾落单的半字符（与 Node 一致）。
  function utf16leEncode(text) {
    var bytes = [];
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      bytes.push(code & 0xff, (code >> 8) & 0xff);
    }
    return bytes;
  }

  function utf16leDecode(bytes) {
    var text = '';
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      text += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
    }
    return text;
  }

  function encodeString(text, encoding) {
    switch (encoding) {
      case 'utf8': return utf8Encode(text);
      case 'utf16le': return utf16leEncode(text);
      case 'base64': return base64Decode(text);
      case 'hex': return hexDecode(text);
      case 'latin1': return latin1Decode(text);
      default: throw fail('Buffer 不支持的编码：' + encoding);
    }
  }

  function decodeToString(bytes, encoding) {
    switch (encoding) {
      case 'utf8': return utf8Decode(bytes);
      case 'utf16le': return utf16leDecode(bytes);
      case 'base64': return base64Encode(bytes);
      case 'hex': return hexEncode(bytes);
      case 'latin1': return latin1Encode(bytes);
      default: throw fail('Buffer 不支持的编码：' + encoding);
    }
  }

  function toUint8Array(value, encoding) {
    if (value instanceof Uint8Array) return new Uint8Array(value);
    if (typeof ArrayBuffer === 'function' && value instanceof ArrayBuffer) {
      return new Uint8Array(value.slice(0));
    }
    if (typeof ArrayBuffer === 'function' && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
      // DataView 与各种 TypedArray：按底层字节复制（不做共享内存）。
      return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
    }
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

  // ------------------------------------------------------ Node 的二进制读写面
  // 真实猫源脚本大量用这些方法做协议解析（长度前缀、UTF-16 手工解码、
  // 校验位提取），少了它们脚本会在运行期直接报「不是函数」。
  function checkOffset(bytes, offset, size, name) {
    var index = Math.floor(Number(offset));
    if (!isFinite(index) || index < 0 || index + size > bytes.length) {
      throw new RangeError('Buffer.' + name + ' 越界：offset=' + offset + '，buffer 长度=' + bytes.length);
    }
    return index;
  }

  function readUInt(buffer, offset, size, name, littleEndian) {
    var index = checkOffset(buffer._b, offset, size, name);
    var value = 0;
    for (var i = 0; i < size; i++) {
      var shift = littleEndian ? i : (size - 1 - i);
      value += buffer._b[index + i] * Math.pow(2, 8 * shift);
    }
    return value;
  }

  function writeUInt(buffer, offset, size, name, value, littleEndian) {
    var number = Number(value);
    if (!isFinite(number) || number < 0 || number >= Math.pow(2, 8 * size)) {
      throw new RangeError('Buffer.' + name + ' 的 value 超出范围：' + value);
    }
    var index = checkOffset(buffer._b, offset, size, name);
    for (var i = 0; i < size; i++) {
      var shift = littleEndian ? i : (size - 1 - i);
      buffer._b[index + i] = Math.floor(number / Math.pow(2, 8 * shift)) & 0xff;
    }
    return index + size;
  }

  function signed(value, bits) {
    var limit = Math.pow(2, bits - 1);
    return value >= limit ? value - Math.pow(2, bits) : value;
  }

  function readBigUInt64(buffer, offset, name, littleEndian) {
    if (typeof BigInt !== 'function') throw fail('沙箱引擎不支持 BigInt，无法使用 ' + name);
    var index = checkOffset(buffer._b, offset, 8, name);
    var value = BigInt(0);
    for (var i = 0; i < 8; i++) {
      var shift = BigInt(8 * (littleEndian ? i : (7 - i)));
      value += BigInt(buffer._b[index + i]) << shift;
    }
    return value;
  }

  function writeBigUInt64(buffer, offset, name, value, littleEndian) {
    if (typeof BigInt !== 'function') throw fail('沙箱引擎不支持 BigInt，无法使用 ' + name);
    var index = checkOffset(buffer._b, offset, 8, name);
    var big = BigInt(value);
    for (var i = 0; i < 8; i++) {
      var shift = BigInt(8 * (littleEndian ? i : (7 - i)));
      buffer._b[index + i] = Number((big >> shift) & BigInt(0xff));
    }
    return index + 8;
  }

  function needleBytes(value, encoding) {
    if (typeof value === 'number') return [Number(value) & 0xff];
    if (typeof value === 'string') {
      var name = normalizeEncoding(encoding);
      if (name === null) throw fail('Buffer 不支持的编码：' + encoding);
      return encodeString(value, name);
    }
    if (value instanceof Buffer) return Array.prototype.slice.call(value._b);
    if (value instanceof Uint8Array) return Array.prototype.slice.call(value);
    throw fail('需要数字 / 字符串 / Buffer，收到：' + typeof value);
  }

  Buffer.prototype.readUInt8 = function (offset) { return readUInt(this, offset, 1, 'readUInt8', true); };
  Buffer.prototype.readInt8 = function (offset) { return signed(readUInt(this, offset, 1, 'readInt8', true), 8); };
  Buffer.prototype.readUInt16LE = function (offset) { return readUInt(this, offset, 2, 'readUInt16LE', true); };
  Buffer.prototype.readUInt16BE = function (offset) { return readUInt(this, offset, 2, 'readUInt16BE', false); };
  Buffer.prototype.readInt16LE = function (offset) { return signed(readUInt(this, offset, 2, 'readInt16LE', true), 16); };
  Buffer.prototype.readInt16BE = function (offset) { return signed(readUInt(this, offset, 2, 'readInt16BE', false), 16); };
  Buffer.prototype.readUInt32LE = function (offset) { return readUInt(this, offset, 4, 'readUInt32LE', true); };
  Buffer.prototype.readUInt32BE = function (offset) { return readUInt(this, offset, 4, 'readUInt32BE', false); };
  Buffer.prototype.readInt32LE = function (offset) { return signed(readUInt(this, offset, 4, 'readInt32LE', true), 32); };
  Buffer.prototype.readInt32BE = function (offset) { return signed(readUInt(this, offset, 4, 'readInt32BE', false), 32); };
  Buffer.prototype.readBigUInt64LE = function (offset) { return readBigUInt64(this, offset, 'readBigUInt64LE', true); };
  Buffer.prototype.readBigUInt64BE = function (offset) { return readBigUInt64(this, offset, 'readBigUInt64BE', false); };

  Buffer.prototype.writeUInt8 = function (value, offset) { return writeUInt(this, offset === undefined ? 0 : offset, 1, 'writeUInt8', value, true); };
  Buffer.prototype.writeInt8 = function (value, offset) {
    var number = Number(value);
    return writeUInt(this, offset === undefined ? 0 : offset, 1, 'writeInt8', number < 0 ? number + 256 : number, true);
  };
  Buffer.prototype.writeUInt16LE = function (value, offset) { return writeUInt(this, offset === undefined ? 0 : offset, 2, 'writeUInt16LE', value, true); };
  Buffer.prototype.writeUInt16BE = function (value, offset) { return writeUInt(this, offset === undefined ? 0 : offset, 2, 'writeUInt16BE', value, false); };
  Buffer.prototype.writeInt16LE = function (value, offset) {
    var number = Number(value);
    return writeUInt(this, offset === undefined ? 0 : offset, 2, 'writeInt16LE', number < 0 ? number + 65536 : number, true);
  };
  Buffer.prototype.writeInt16BE = function (value, offset) {
    var number = Number(value);
    return writeUInt(this, offset === undefined ? 0 : offset, 2, 'writeInt16BE', number < 0 ? number + 65536 : number, false);
  };
  Buffer.prototype.writeUInt32LE = function (value, offset) { return writeUInt(this, offset === undefined ? 0 : offset, 4, 'writeUInt32LE', value, true); };
  Buffer.prototype.writeUInt32BE = function (value, offset) { return writeUInt(this, offset === undefined ? 0 : offset, 4, 'writeUInt32BE', value, false); };
  Buffer.prototype.writeInt32LE = function (value, offset) {
    var number = Number(value);
    return writeUInt(this, offset === undefined ? 0 : offset, 4, 'writeInt32LE', number < 0 ? number + 4294967296 : number, true);
  };
  Buffer.prototype.writeInt32BE = function (value, offset) {
    var number = Number(value);
    return writeUInt(this, offset === undefined ? 0 : offset, 4, 'writeInt32BE', number < 0 ? number + 4294967296 : number, false);
  };
  Buffer.prototype.writeBigUInt64LE = function (value, offset) { return writeBigUInt64(this, offset === undefined ? 0 : offset, 'writeBigUInt64LE', value, true); };
  Buffer.prototype.writeBigUInt64BE = function (value, offset) { return writeBigUInt64(this, offset === undefined ? 0 : offset, 'writeBigUInt64BE', value, false); };

  Buffer.prototype.write = function (string, offset, length, encoding) {
    var text = String(string === undefined || string === null ? '' : string);
    var at = offset;
    var size = length;
    var enc = encoding;
    if (typeof at === 'string') {
      enc = at;
      at = 0;
      size = undefined;
    } else if (typeof size === 'string') {
      enc = size;
      size = undefined;
    }
    var name = normalizeEncoding(enc);
    if (name === null) throw fail('Buffer 不支持的编码：' + enc);
    var bytes = encodeString(text, name);
    var start = at === undefined || at === null ? 0 : Math.max(0, Number(at) | 0);
    var limit = size === undefined || size === null ? bytes.length : Math.max(0, Number(size) | 0);
    var count = Math.max(0, Math.min(limit, bytes.length, this._b.length - start));
    for (var i = 0; i < count; i++) this._b[start + i] = bytes[i];
    return count;
  };

  // 沙箱不做共享内存：subarray / slice 都是复制语义（与 Node 的「视图」不同）。
  Buffer.prototype.subarray = function (start, end) {
    var bytes = this._b;
    var from = start === undefined || start === null ? 0 : Math.max(0, Number(start) | 0);
    var to = end === undefined || end === null ? bytes.length : Math.min(bytes.length, Number(end) | 0);
    if (to < from) to = from;
    return makeBuffer(bytes.subarray(from, to));
  };

  Buffer.prototype.indexOf = function (value, byteOffset, encoding) {
    var haystack = this._b;
    var needle = needleBytes(value, encoding);
    var from = byteOffset === undefined || byteOffset === null ? 0 : Math.max(0, Number(byteOffset) | 0);
    if (needle.length === 0 || needle.length > haystack.length - from) return -1;
    for (var i = from; i + needle.length <= haystack.length; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  };

  Buffer.prototype.lastIndexOf = function (value, byteOffset, encoding) {
    var haystack = this._b;
    var needle = needleBytes(value, encoding);
    if (needle.length === 0 || needle.length > haystack.length) return -1;
    var from = byteOffset === undefined || byteOffset === null
      ? haystack.length - needle.length
      : Math.min(Number(byteOffset) | 0, haystack.length - needle.length);
    for (var i = from; i >= 0; i--) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  };

  Buffer.prototype.includes = function (value, byteOffset, encoding) {
    return this.indexOf(value, byteOffset, encoding) !== -1;
  };

  Buffer.prototype.copy = function (target, targetStart, sourceStart, sourceEnd) {
    if (!Buffer.isBuffer(target)) throw fail('Buffer.copy 的目标必须是 Buffer');
    var source = this._b;
    var from = sourceStart === undefined || sourceStart === null ? 0 : Math.max(0, Number(sourceStart) | 0);
    var to = sourceEnd === undefined || sourceEnd === null ? source.length : Math.min(source.length, Number(sourceEnd) | 0);
    var start = targetStart === undefined || targetStart === null ? 0 : Math.max(0, Number(targetStart) | 0);
    var count = Math.max(0, Math.min(to - from, target._b.length - start));
    for (var i = 0; i < count; i++) target._b[start + i] = source[from + i];
    return count;
  };

  Buffer.prototype.fill = function (value, start, end, encoding) {
    var bytes = this._b;
    var from = start === undefined || start === null ? 0 : Math.max(0, Number(start) | 0);
    var to = end === undefined || end === null ? bytes.length : Math.min(bytes.length, Number(end) | 0);
    var pattern = needleBytes(value, encoding);
    if (pattern.length === 0) return this;
    for (var i = from; i < to; i++) bytes[i] = pattern[(i - from) % pattern.length];
    return this;
  };

  Buffer.prototype.reverse = function () {
    this._b.reverse();
    return this;
  };

  Buffer.prototype.compare = function (other) {
    if (!Buffer.isBuffer(other)) throw fail('Buffer.compare 需要另一个 Buffer');
    var left = this._b;
    var right = other._b;
    var limit = Math.min(left.length, right.length);
    for (var i = 0; i < limit; i++) {
      if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
    }
    if (left.length === right.length) return 0;
    return left.length < right.length ? -1 : 1;
  };

  Buffer.prototype.forEach = function (callback, thisArg) {
    for (var i = 0; i < this._b.length; i++) callback.call(thisArg, this._b[i], i, this);
  };

  function indexIterator(buffer, pick) {
    var bytes = Array.prototype.slice.call(buffer._b);
    var index = 0;
    var iterator = {
      next: function () {
        if (index >= bytes.length) return { done: true, value: undefined };
        var i = index++;
        return { done: false, value: pick(bytes, i) };
      }
    };
    if (typeof Symbol === 'function' && Symbol.iterator) {
      iterator[Symbol.iterator] = function () { return this; };
    }
    return iterator;
  }

  Buffer.prototype.entries = function () { return indexIterator(this, function (bytes, i) { return [i, bytes[i]]; }); };
  Buffer.prototype.keys = function () { return indexIterator(this, function (bytes, i) { return i; }); };
  Buffer.prototype.values = function () { return indexIterator(this, function (bytes, i) { return bytes[i]; }); };
  if (typeof Symbol === 'function' && Symbol.iterator) {
    Buffer.prototype[Symbol.iterator] = Buffer.prototype.values;
  }

  Buffer.isEncoding = function (name) { return normalizeEncoding(name) !== null; };
  Buffer.compare = function (a, b) { return a.compare(b); };

  Buffer.__lumeCat = true;

  Buffer.from = function (value, encodingOrOffset, length) {
    if (value instanceof Buffer) return makeBuffer(new Uint8Array(value._b));
    if (typeof ArrayBuffer === 'function' && value instanceof ArrayBuffer && typeof encodingOrOffset === 'number') {
      var view = new Uint8Array(value, Number(encodingOrOffset), length === undefined ? undefined : Number(length));
      return makeBuffer(view);
    }
    return makeBuffer(toUint8Array(value, encodingOrOffset));
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

/// 基础 `require` 模拟：内建模块白名单 + 友好的越界提示。
///
/// 白名单分两层：
/// - 环境内建（本文件）：`buffer` / `process` / `console` / `timers`；
/// - 模块垫片（`cat_node_modules.dart`，经 `globalThis.__lumeModules` 登记）：
///   `crypto` / `events` / `path` / `util` / `assert` / `stream` / `http` /
///   `https` / `fs`（内存盘）/ `os` / `timers/promises`。
///
/// 明确不做的事：不加载任何**外置文件**（没有真实文件系统）、不暴露真实
/// `net` / `tls` / `dns` / `child_process`（网络只能经宿主桥）、不支持
/// `.node` 原生模块与 WASM。越界的模块名一律给出可读错误。
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
        'lume.cat.node.crypto',
        'lume.cat.node.events',
        'lume.cat.node.path',
        'lume.cat.node.util',
        'lume.cat.node.assert',
        'lume.cat.node.stream',
        'lume.cat.node.http',
        'lume.cat.node.fs',
        'lume.cat.node.os',
        'lume.cat.url',
        'lume.cat.node.zlib',
        'lume.cat.node.tty',
        'lume.cat.node.async_hooks',
        'lume.cat.node.diagnostics_channel',
        'lume.cat.node.perf_hooks',
        'lume.cat.node.timers.promises',
      ];

  @override
  String get source => r'''
(function () {
  if (typeof globalThis.require === 'function' && globalThis.require.__lumeCat) return;

  var builtins = {
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
    // 'fs/promises' 这类子路径也按整名匹配（register 时用的就是全名）。
    if (Object.prototype.hasOwnProperty.call(builtins, id)) return builtins[id];
    var modules = globalThis.__lumeModules;
    if (modules && Object.prototype.hasOwnProperty.call(modules, id) && modules[id]) {
      return modules[id];
    }
    throw globalThis.__lumeUnsupportedModule(id);
  };
  requireModule.__lumeCat = true;
  requireModule.resolve = function (name) { return String(name); };
  requireModule.cache = {};
  requireModule.main = undefined;

  globalThis.require = requireModule;
  globalThis.module = { exports: {} };
  globalThis.exports = globalThis.module.exports;
})();
''';
}
