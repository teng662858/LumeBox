/// 猫源沙箱的**补充 Node 模块垫片**（只对猫源注入）。
///
/// 这一组是真实脚本实测出来的缺口：
///
/// - `zlib`：纯 JS 的 DEFLATE 解压（inflate / gunzip / unzip / inflateRaw）。
///   Node 打包产物常带「响应解压」逻辑，缺了它整模块初始化就会抛错。
///   **只做解压、不做压缩**：压缩侧给可读错误（沙箱里压缩没有实际用途）。
/// - `tty` / `async_hooks` / `diagnostics_channel` / `perf_hooks` / `module`：
///   第三方库的**能力探测**模块。它们只需要「存在且语义安全」——例如
///   `isatty()` 返回 false（不输出颜色）、`diagnostics_channel` 报告
///   `hasSubscribers: false`（观测通道没人订阅）。给最小实现即可让这些库
///   走进「不启用该特性」的分支，而不是在加载期崩溃。
///
/// 依旧不做：`net` / `tls` / `dns` / `http2` / `child_process` /
/// `worker_threads`（真实 socket、进程与线程能力），一律给出可读错误。
library;

import 'sandbox/sandbox_polyfill.dart';

/// `zlib`：纯 JS 的 DEFLATE 解压。
///
/// 实现范围：stored / fixed / dynamic 三种块的 inflate、gzip 与 zlib 容器解析。
/// 不做 CRC/Adler 校验（沙箱里解压失败已经是可读错误，多一层校验只会把
/// 「数据损坏」和「实现缺陷」混在一起），也不做压缩。
class CatZlibPolyfill implements SandboxPolyfill {
  const CatZlibPolyfill();

  @override
  String get id => 'lume.cat.node.zlib';

  @override
  List<String> get requires => const <String>[
        'lume.cat.buffer',
        'lume.cat.node.events',
        'lume.cat.node.stream',
      ];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.zlib) return;

  var Transform = registry.stream.Transform;

  function fail(message) {
    var error = new Error(message);
    error.code = 'Z_DATA_ERROR';
    return error;
  }

  var LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
  var LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
  var DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
  var DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
  var CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
  var LENGTH_SYMBOLS = 288;
  var DIST_SYMBOLS = 30;

  function BitReader(bytes, offset) {
    this.bytes = bytes;
    this.position = offset || 0;
    this.bitBuffer = 0;
    this.bitCount = 0;
  }

  BitReader.prototype.bit = function () {
    if (this.bitCount === 0) {
      if (this.position >= this.bytes.length) throw fail('zlib 数据提前结束');
      this.bitBuffer = this.bytes[this.position++];
      this.bitCount = 8;
    }
    var value = this.bitBuffer & 1;
    this.bitBuffer >>>= 1;
    this.bitCount--;
    return value;
  };

  BitReader.prototype.bits = function (count) {
    var value = 0;
    for (var i = 0; i < count; i++) value |= this.bit() << i;
    return value;
  };

  BitReader.prototype.align = function () {
    this.bitCount = 0;
    this.bitBuffer = 0;
  };

  function buildHuffman(lengths) {
    var maxBits = 0;
    var counts = [];
    for (var i = 0; i < lengths.length; i++) {
      var length = lengths[i];
      if (length > 0) {
        counts[length] = (counts[length] || 0) + 1;
        if (length > maxBits) maxBits = length;
      }
    }
    var offsets = [];
    var total = 0;
    for (var bits = 1; bits <= maxBits; bits++) {
      offsets[bits] = total;
      total += counts[bits] || 0;
    }
    var symbols = [];
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      var size = lengths[symbol];
      if (size > 0) symbols[offsets[size]++] = symbol;
    }
    return { counts: counts, symbols: symbols, maxBits: maxBits };
  }

  function decodeSymbol(reader, huffman) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var bits = 1; bits <= huffman.maxBits; bits++) {
      code |= reader.bit();
      var count = huffman.counts[bits] || 0;
      if (code - first < count) return huffman.symbols[index + (code - first)];
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw fail('zlib 数据损坏：非法的 Huffman 编码');
  }

  function fixedLiteralHuffman() {
    var lengths = [];
    for (var i = 0; i < 144; i++) lengths.push(8);
    for (var j = 144; j < 256; j++) lengths.push(9);
    for (var k = 256; k < 280; k++) lengths.push(7);
    for (var m = 280; m < 288; m++) lengths.push(8);
    return buildHuffman(lengths);
  }

  function fixedDistanceHuffman() {
    var lengths = [];
    for (var i = 0; i < DIST_SYMBOLS; i++) lengths.push(5);
    return buildHuffman(lengths);
  }

  var cachedFixedLiteral = null;
  var cachedFixedDistance = null;

  function dynamicHuffman(reader) {
    var literalCount = reader.bits(5) + 257;
    var distanceCount = reader.bits(5) + 1;
    var codeLengthCount = reader.bits(4) + 4;

    var codeLengths = [];
    for (var i = 0; i < 19; i++) codeLengths.push(0);
    for (var j = 0; j < codeLengthCount; j++) {
      codeLengths[CLEN_ORDER[j]] = reader.bits(3);
    }
    var codeLengthHuffman = buildHuffman(codeLengths);

    var lengths = [];
    var total = literalCount + distanceCount;
    while (lengths.length < total) {
      var symbol = decodeSymbol(reader, codeLengthHuffman);
      if (symbol < 16) {
        lengths.push(symbol);
        continue;
      }
      var repeat = 0;
      var value = 0;
      if (symbol === 16) {
        if (lengths.length === 0) throw fail('zlib 数据损坏：重复码出现在首位');
        value = lengths[lengths.length - 1];
        repeat = 3 + reader.bits(2);
      } else if (symbol === 17) {
        repeat = 3 + reader.bits(3);
      } else {
        repeat = 11 + reader.bits(7);
      }
      for (var r = 0; r < repeat; r++) lengths.push(value);
    }

    return {
      literal: buildHuffman(lengths.slice(0, literalCount)),
      distance: buildHuffman(lengths.slice(literalCount, literalCount + distanceCount))
    };
  }

  function inflateRaw(bytes, offset) {
    var reader = new BitReader(bytes, offset || 0);
    var output = [];
    while (true) {
      var last = reader.bit();
      var type = reader.bits(2);

      if (type === 0) {
        reader.align();
        var length = reader.bytes[reader.position] | (reader.bytes[reader.position + 1] << 8);
        reader.position += 4;
        for (var i = 0; i < length; i++) output.push(reader.bytes[reader.position++]);
      } else if (type === 1 || type === 2) {
        var literalHuffman;
        var distanceHuffman;
        if (type === 1) {
          if (!cachedFixedLiteral) cachedFixedLiteral = fixedLiteralHuffman();
          if (!cachedFixedDistance) cachedFixedDistance = fixedDistanceHuffman();
          literalHuffman = cachedFixedLiteral;
          distanceHuffman = cachedFixedDistance;
        } else {
          var tables = dynamicHuffman(reader);
          literalHuffman = tables.literal;
          distanceHuffman = tables.distance;
        }

        while (true) {
          var symbol = decodeSymbol(reader, literalHuffman);
          if (symbol < 256) {
            output.push(symbol);
            continue;
          }
          if (symbol === 256) break;
          var lengthIndex = symbol - 257;
          if (lengthIndex >= LENGTH_BASE.length) throw fail('zlib 数据损坏：长度码越界');
          var matchLength = LENGTH_BASE[lengthIndex] + reader.bits(LENGTH_EXTRA[lengthIndex]);
          var distanceSymbol = decodeSymbol(reader, distanceHuffman);
          if (distanceSymbol >= DIST_BASE.length) throw fail('zlib 数据损坏：距离码越界');
          var distance = DIST_BASE[distanceSymbol] + reader.bits(DIST_EXTRA[distanceSymbol]);
          var from = output.length - distance;
          if (from < 0) throw fail('zlib 数据损坏：回溯距离超出已解出的数据');
          for (var k = 0; k < matchLength; k++) output.push(output[from + k]);
        }
      } else {
        throw fail('zlib 数据损坏：未知的块类型');
      }

      if (last) break;
    }
    return output;
  }

  function hasGzipMagic(bytes) {
    return bytes.length > 2 && bytes[0] === 0x1f && bytes[1] === 0x8b;
  }

  function gunzip(bytes) {
    if (!hasGzipMagic(bytes)) throw fail('gunzip 需要 gzip 数据（缺少 1f 8b 魔数）');
    var flags = bytes[3];
    var position = 10;
    if (flags & 0x04) {                                   // FEXTRA
      var extraLength = bytes[position] | (bytes[position + 1] << 8);
      position += 2 + extraLength;
    }
    if (flags & 0x08) {                                   // FNAME
      while (position < bytes.length && bytes[position] !== 0) position++;
      position++;
    }
    if (flags & 0x10) {                                   // FCOMMENT
      while (position < bytes.length && bytes[position] !== 0) position++;
      position++;
    }
    if (flags & 0x02) position += 2;                      // FHCRC
    return inflateRaw(bytes, position);
  }

  function inflate(bytes) {
    if (hasGzipMagic(bytes)) return gunzip(bytes);
    // zlib 容器：2 字节头（CMF/FLG），最低两位 = 1 表示使用了预设字典。
    if (bytes.length < 2) throw fail('inflate 数据太短');
    var offset = 2;
    if (bytes[1] & 0x20) offset += 4;
    var output = inflateRaw(bytes, offset);
    // 尾部 4 字节是 Adler-32（不做校验，理由见类型注释）。
    return output;
  }

  function toByteArray(value) {
    if (typeof value === 'string') {
      return Array.prototype.slice.call(globalThis.Buffer.from(value, 'base64')._b);
    }
    // Buffer 实例是 Proxy 包装，`instanceof Uint8Array` 认不出来。
    if (globalThis.Buffer && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(value)) {
      return Array.prototype.slice.call(value._b);
    }
    if (value instanceof Uint8Array) return Array.prototype.slice.call(value);
    if (typeof ArrayBuffer === 'function' && value instanceof ArrayBuffer) {
      return Array.prototype.slice.call(new Uint8Array(value));
    }
    if (typeof ArrayBuffer === 'function' && ArrayBuffer.isView && ArrayBuffer.isView(value)) {
      return Array.prototype.slice.call(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
    }
    throw new TypeError('zlib 只接受 Buffer / TypedArray / ArrayBuffer');
  }

  function asBuffer(bytes) {
    return globalThis.Buffer.from(bytes);
  }

  function gunzipSync(value) { return asBuffer(gunzip(toByteArray(value))); }
  function inflateSync(value) { return asBuffer(inflate(toByteArray(value))); }
  function inflateRawSync(value) { return asBuffer(inflateRaw(toByteArray(value), 0)); }
  function unzipSync(value) {
    var bytes = toByteArray(value);
    return asBuffer(hasGzipMagic(bytes) ? gunzip(bytes) : inflate(bytes));
  }

  function unsupportedCompress(name) {
    var error = new Error('沙箱的 zlib 只提供解压（inflate / gunzip / unzip），不提供压缩：' + name);
    error.code = 'LUME_UNSUPPORTED';
    throw error;
  }

  /// 解压流：进来先攒着，end 时一次性解压后投递（沙箱不做背压）。
  function createDecompressStream(decompress) {
    var chunks = [];
    var stream = new Transform();
    stream._transform = function (chunk, encoding, callback) {
      // Buffer 实例是 Proxy 包装，必须先按 Buffer 认出来再取字节。
      if (globalThis.Buffer.isBuffer(chunk)) {
        chunks.push(chunk);
      } else {
        chunks.push(globalThis.Buffer.from(String(chunk), 'utf8'));
      }
      callback();
    };
    var originalEnd = stream.end;
    stream.end = function () {
      var bytes = [];
      chunks.forEach(function (item) {
        var chunkBytes = item._b;
        for (var i = 0; i < chunkBytes.length; i++) bytes.push(chunkBytes[i]);
      });
      try {
        stream.push(asBuffer(decompress(bytes)));
      } catch (error) {
        stream.emit('error', error);
      }
      return originalEnd.apply(stream, arguments);
    };
    return stream;
  }

  var zlibModule = {
    inflateSync: inflateSync,
    inflateRawSync: inflateRawSync,
    gunzipSync: gunzipSync,
    unzipSync: unzipSync,
    createInflate: function () { return createDecompressStream(inflate); },
    createGunzip: function () { return createDecompressStream(gunzip); },
    createUnzip: function () { return createDecompressStream(function (bytes) { return hasGzipMagic(bytes) ? gunzip(bytes) : inflate(bytes); }); },
    deflateSync: function () { return unsupportedCompress('deflateSync'); },
    gzipSync: function () { return unsupportedCompress('gzipSync'); },
    deflateRawSync: function () { return unsupportedCompress('deflateRawSync'); },
    deflate: function () { return unsupportedCompress('deflate'); },
    gzip: function () { return unsupportedCompress('gzip'); },
    createDeflate: function () { return unsupportedCompress('createDeflate'); },
    createGzip: function () { return unsupportedCompress('createGzip'); },
    constants: {
      Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4,
      Z_OK: 0, Z_STREAM_END: 1, Z_NEED_DICT: 2, Z_ERRNO: -1, Z_STREAM_ERROR: -2,
      Z_DATA_ERROR: -3, Z_MEM_ERROR: -4, Z_BUF_ERROR: -5,
      Z_DEFAULT_COMPRESSION: -1, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9
    }
  };

  registry.zlib = zlibModule;
})();
''';
}

/// `tty`：库用它做「是否彩色输出」的判断，沙箱里一律不是终端。
class CatTtyPolyfill implements SandboxPolyfill {
  const CatTtyPolyfill();

  @override
  String get id => 'lume.cat.node.tty';

  @override
  List<String> get requires => const <String>['lume.cat.node.events'];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.tty) return;

  var EventEmitter = registry.events.EventEmitter;

  function WriteStream() {
    EventEmitter.call(this);
    this.isTTY = false;
    this.columns = 80;
    this.rows = 24;
  }
  WriteStream.prototype = Object.create(EventEmitter.prototype);
  WriteStream.prototype.constructor = WriteStream;
  WriteStream.prototype.write = function () { return true; };
  WriteStream.prototype.end = function () {};
  WriteStream.prototype.clearLine = function () { return false; };
  WriteStream.prototype.cursorTo = function () { return false; };
  WriteStream.prototype.moveCursor = function () { return false; };

  function ReadStream() {
    EventEmitter.call(this);
    this.isTTY = false;
  }
  ReadStream.prototype = Object.create(EventEmitter.prototype);
  ReadStream.prototype.constructor = ReadStream;
  ReadStream.prototype.setRawMode = function () { return this; };

  registry.tty = {
    isatty: function () { return false; },
    WriteStream: WriteStream,
    ReadStream: ReadStream
  };
  // process.stdout / stderr 补齐 Node 形状（库会读 .isTTY / .columns）。
  if (globalThis.process) {
    if (!globalThis.process.stdout) globalThis.process.stdout = new WriteStream();
    if (!globalThis.process.stderr) globalThis.process.stderr = new WriteStream();
  }
})();
''';
}

/// `async_hooks`：给出 AsyncLocalStorage / AsyncResource 的最小可用实现。
class CatAsyncHooksPolyfill implements SandboxPolyfill {
  const CatAsyncHooksPolyfill();

  @override
  String get id => 'lume.cat.node.async_hooks';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.async_hooks) return;

  /// 单执行栈的存储：沙箱里是同步投递模型，够 AsyncLocalStorage 的常见用法。
  function AsyncLocalStorage() {
    this._store = undefined;
  }

  AsyncLocalStorage.prototype.run = function (store, callback) {
    var previous = this._store;
    this._store = store;
    try {
      return callback.apply(null, Array.prototype.slice.call(arguments, 2));
    } finally {
      this._store = previous;
    }
  };

  AsyncLocalStorage.prototype.getStore = function () {
    return this._store;
  };

  AsyncLocalStorage.prototype.enterWith = function (store) {
    this._store = store;
  };

  AsyncLocalStorage.prototype.disable = function () {};

  function AsyncResource(type, options) {
    this.type = type || 'LumeAsyncResource';
    this._options = options || {};
  }
  AsyncResource.prototype.runInAsyncScope = function (callback, thisArg) {
    return callback.apply(thisArg, Array.prototype.slice.call(arguments, 2));
  };
  AsyncResource.prototype.emitDestroy = function () { return this; };
  AsyncResource.prototype.asyncId = function () { return 1; };
  AsyncResource.prototype.triggerAsyncId = function () { return 0; };
  AsyncResource.bind = function (fn) { return fn; };

  var hooks = {
    AsyncLocalStorage: AsyncLocalStorage,
    AsyncResource: AsyncResource,
    createHook: function () {
      return {
        enable: function () { return this; },
        disable: function () { return this; }
      };
    },
    executionAsyncId: function () { return 1; },
    executionAsyncResource: function () { return {}; },
    triggerAsyncId: function () { return 0; },
    asyncWrapProviders: {}
  };

  registry.async_hooks = hooks;
  registry['async_hooks/promises'] = hooks;
})();
''';
}

/// `diagnostics_channel`：观测通道在沙箱里没有订阅者（走「不启用」分支）。
class CatDiagnosticsChannelPolyfill implements SandboxPolyfill {
  const CatDiagnosticsChannelPolyfill();

  @override
  String get id => 'lume.cat.node.diagnostics_channel';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.diagnostics_channel) return;

  var channels = {};

  function Channel(name) {
    this.name = name;
    this.hasSubscribers = false;
  }
  Channel.prototype.subscribe = function () {};
  Channel.prototype.unsubscribe = function () {};
  Channel.prototype.publish = function () {};
  Channel.prototype.bindStore = function () {};
  Channel.prototype.unbindStore = function () {};
  Channel.prototype.runStores = function (store, callback) {
    return callback.apply(null, Array.prototype.slice.call(arguments, 2));
  };

  function channel(name) {
    var key = String(name);
    if (!channels[key]) channels[key] = new Channel(key);
    return channels[key];
  }

  function tracingChannel(name) {
    var start = channel(name + ':start');
    var end = channel(name + ':end');
    return {
      start: start,
      end: end,
      asyncStart: channel(name + ':asyncStart'),
      asyncEnd: channel(name + ':asyncEnd'),
      error: channel(name + ':error'),
      hasSubscribers: false,
      traceSync: function (fn, context) { return fn.apply(context, Array.prototype.slice.call(arguments, 2)); },
      tracePromise: function (fn, context) {
        return Promise.resolve().then(function () {
          return fn.apply(context, Array.prototype.slice.call(arguments, 2));
        });
      },
      traceCallback: function (fn, position, context) {
        return fn.apply(context, Array.prototype.slice.call(arguments, 3));
      }
    };
  }

  var module = {
    channel: channel,
    hasSubscribers: function (name) { return channel(name).hasSubscribers; },
    subscribe: function () {},
    unsubscribe: function () {},
    tracingChannel: tracingChannel
  };

  registry.diagnostics_channel = module;
})();
''';
}

/// `perf_hooks`：复用引擎自带的 `performance`。
class CatPerfHooksPolyfill implements SandboxPolyfill {
  const CatPerfHooksPolyfill();

  @override
  String get id => 'lume.cat.node.perf_hooks';

  @override
  List<String> get requires => const <String>[];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.perf_hooks) return;

  var performanceImpl = globalThis.performance;
  if (!performanceImpl) {
    var start = Date.now();
    performanceImpl = { now: function () { return Date.now() - start; } };
    globalThis.performance = performanceImpl;
  }

  function PerformanceObserver(callback) {
    this._callback = callback;
  }
  PerformanceObserver.prototype.observe = function () {};
  PerformanceObserver.prototype.disconnect = function () {};
  PerformanceObserver.prototype.takeRecords = function () { return []; };
  PerformanceObserver.supportedEntryTypes = [];

  registry.perf_hooks = {
    performance: performanceImpl,
    PerformanceObserver: PerformanceObserver,
    PerformanceEntry: function PerformanceEntry(name, entryType) {
      this.name = name;
      this.entryType = entryType;
    },
    constants: { NODE_PERFORMANCE_GC_MAJOR: 4, NODE_PERFORMANCE_GC_MINOR: 1 }
  };
  if (typeof globalThis.performance === 'undefined') globalThis.performance = performanceImpl;
})();
''';
}

/// `module`：只需要 `createRequire` 与 `builtinModules` 这类元信息。
class CatModulePolyfill implements SandboxPolyfill {
  const CatModulePolyfill();

  @override
  String get id => 'lume.cat.node.module';

  @override
  List<String> get requires => const <String>['lume.cat.require'];

  @override
  String get source => r'''
(function () {
  var registry = globalThis.__lumeModules = globalThis.__lumeModules || {};
  if (registry.module) return;

  function createRequire() {
    return globalThis.require;
  }

  registry.module = {
    createRequire: createRequire,
    builtinModules: [
      'buffer', 'console', 'crypto', 'events', 'fs', 'http', 'https', 'os',
      'path', 'process', 'stream', 'timers', 'url', 'util', 'assert', 'zlib'
    ],
    isBuiltin: function (name) {
      var id = String(name).replace(/^node:/, '');
      return registry.module.builtinModules.indexOf(id.split('/')[0]) >= 0;
    },
    Module: function Module() {}
  };
  if (globalThis.module) registry.module.Module = globalThis.module.constructor || registry.module.Module;
})();
''';
}
