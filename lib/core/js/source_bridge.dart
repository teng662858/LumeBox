import 'dart:convert';

import 'sandbox/sandbox_polyfill.dart';

/// 宿主注入的全局桥接对象 `LumeSource`（**所有板块都注入**，猫源也一样）。
///
/// 解决的问题（用户反馈）：脚本没写 `var LumeSource = { … }` 时，引擎按
/// `LumeSource.list` 调用只会得到「全局对象不存在: LumeSource」——脚本明明写好了
/// `async function getList(page)`，却完全跑不起来。桥接对象把「谁是图源实现」
/// 从脚本的写法里解耦出来：宿主先注入 `LumeSource`，脚本再执行，三种写法都认。
///
/// 注入顺序（严格，见 [LumeSourcePolyfills] 的登记顺序与 `SandboxContext`）：
/// 1. 创建 QuickJS-NG 虚拟机实例（JSRuntime + JSContext）；
/// 2. 注入环境垫片：console / 定时器（沙箱 prelude）+ process / Buffer /
///    简易 require（猫源 Node 垫片）等；
/// 3. 注入桥接全局 `LumeSource`（本文件）：绑定宿主能力（HTTP、沙盒文件 IO），
///    并为五个契约方法装好派发器；
/// 4. 载入并执行用户图源脚本。
///
/// 脚本侧三种写法（派发顺序见 JS 里的 `locate`）：
/// - **函数式**：`async function getList(page) { … }`——按位置参数收
///   `getList(page)` / `getSearch(keyword, page)` / `getDetail(id)` /
///   `getChapters(id)` / `getContent(id, chapterId)` / `getCategories()`；
/// - **对象式**（契约 v2）：`LumeSource.list(argument)` 收对象入参；
///   `var LumeSource = { list: … }` 与 `LumeSource.list = …` 都算——脚本对全局
///   `LumeSource` 的**赋值会合并进桥接对象**（脚本读全局拿到的仍是同一个桥接
///   对象），因此 `LumeSource.http` / `LumeSource.fs` 始终可用；
/// - **词法声明**：`let` / `const LumeSource = { … }`（全局词法绑定优先于全局
///   对象属性，派发器把它作为最后一路来源）。
///
/// 脚本可用的宿主能力：
/// - `LumeSource.http.request({url, method, headers, body})` / `.get(url, opts)` /
///   `.post(url, body, opts)` → 返回 `{status, headers, body, text(), json()}`
///   （与全局 `fetch` 同一形状，最终都走宿主的 `http.fetch` 代理）；
/// - `LumeSource.fs.readText(path)` / `.writeText(path, text)` / `.exists(path)` /
///   `.remove(path)` / `.list()` → 按图源隔离的进程内存储（见 `SandboxStore`），
///   不落盘、有上限，随引擎释放。
///
/// 纪律：本垫片不引入任何新的系统能力——HTTP 与文件 IO 都只是宿主代理
/// （`LumeBridge.invoke`）的语法糖，与 `fetch`、猫源 `http` 模块走同一条路。
class LumeSourceBridgePolyfill implements SandboxPolyfill {
  /// 以别名表构造（一般用默认的 [LumeSourceBridge.aliases]，测试可传自己的）。
  const LumeSourceBridgePolyfill([this.aliasTable, this.bridge = '']);

  /// 桥接服务地址（用户口径 2.2）：非空时脚本读 `LumeSource.bridge` 拿到它，
  /// 把 API 请求转发给那个「已过验证的无头浏览器桥」。宿主只负责传值。
  final String bridge;

  /// 桥接地址占位（注入时替换成 JSON 字符串）。
  static const String _bridgePlaceholder = '__LUME_BRIDGE__';

  /// 方法别名表：契约方法 → 脚本可能使用的名字（顺序即派发优先级，末位是契约名）。
  final Map<String, List<String>>? aliasTable;

  @override
  String get id => LumeSourceBridge.polyfillId;

  /// 依赖网络垫片：`LumeSource.http` 建立在 `fetch` 之上（垫片登记表按依赖排序，
  /// 因此本桥接一定在所有环境垫片之后注入）。
  @override
  List<String> get requires => const <String>['lume.source.fetch'];

  @override
  String get source => _template
      .replaceFirst(
        _aliasPlaceholder,
        jsonEncode(aliasTable ?? LumeSourceBridge.aliases),
      )
      .replaceFirst(_bridgePlaceholder, jsonEncode(bridge));

  /// `var aliases = <JSON>;` —— 表由 Dart 侧唯一声明，JS 不做二次维护。
  static const String _aliasPlaceholder = '__LUME_ALIAS_TABLE__';

  static const String _template = r'''
(function () {
  if (typeof globalThis.LumeBridge !== 'object') return;
  // 幂等：同一上下文里重复注入时复用已装的桥接对象。
  if (globalThis.__lumeSourceBridge) return;

  // 契约方法 → 脚本可能使用的名字（顺序即优先级；末位是契约名本身）。
  var aliases = __LUME_ALIAS_TABLE__;
  // 搜索是 list 的一路分支：函数式脚本用它实现「关键词 + 页码」。
  var searchAliases = ['getSearch', 'search'];

  function invoke(method, payload) {
    return globalThis.LumeBridge.invoke(method, payload);
  }

  // ------------------------------------------------------------ 宿主能力：文件
  var fs = {
    readText: function (path) {
      return invoke('store.read', { key: String(path) }).then(function (reply) {
        reply = reply || {};
        return reply.value == null ? null : String(reply.value);
      });
    },
    writeText: function (path, text) {
      return invoke('store.write', {
        key: String(path),
        value: text == null ? '' : String(text)
      }).then(function () { return true; });
    },
    exists: function (path) {
      return invoke('store.has', { key: String(path) }).then(function (reply) {
        return !!(reply && reply.exists);
      });
    },
    remove: function (path) {
      return invoke('store.remove', { key: String(path) }).then(function (reply) {
        return !!(reply && reply.removed);
      });
    },
    list: function () {
      return invoke('store.keys', {}).then(function (reply) {
        return (reply && reply.keys) || [];
      });
    }
  };

  // ------------------------------------------------------------ 宿主能力：网络
  function withTarget(method, url, options) {
    var settings = {};
    if (options && typeof options === 'object') {
      var names = Object.keys(options);
      for (var i = 0; i < names.length; i++) settings[names[i]] = options[names[i]];
    }
    settings.url = String(url);
    settings.method = settings.method || method;
    return settings;
  }

  var http = {
    request: function (options) {
      options = options || {};
      var url = String(options.url || '');
      if (!url) return Promise.reject(new Error('LumeSource.http.request 缺少 url'));
      return globalThis.fetch(url, {
        method: options.method || 'GET',
        headers: options.headers || {},
        body: options.body == null ? null : String(options.body)
      });
    },
    get: function (url, options) {
      return http.request(withTarget('GET', url, options));
    },
    post: function (url, body, options) {
      var settings = withTarget('POST', url, options);
      if (settings.body == null) settings.body = body == null ? '' : String(body);
      return http.request(settings);
    }
  };

  // ---------------------------------------------------------------- 桥接对象
  // `bridge` 字段就是「桥接服务地址」（空串 = 不用桥接），脚本读
  // `LumeSource.bridge` 即可；其余图源不受影响（读到空串）。
  var bridge = { http: http, fs: fs, bridge: __LUME_BRIDGE__ };

  // 宿主能力不被脚本对象覆盖（脚本自己的实现可以占用其余任何名字）。
  var reserved = { http: true, fs: true };

  function namesOf(name) { return aliases[name] || [name]; }

  // 三步查找脚本实现：桥上的属性 → 顶层函数 → 全局词法绑定（let / const）。
  // 命中契约名本身是对象式（收对象入参），命中别名是函数式（收位置参数）。
  function locate(names, contractName) {
    var i;
    var candidate;
    for (i = 0; i < names.length; i++) {
      candidate = bridge[names[i]];
      if (typeof candidate === 'function' && !candidate.__lumeDispatch) {
        return { fn: candidate, style: names[i] === contractName ? 'object' : 'function' };
      }
    }
    for (i = 0; i < names.length; i++) {
      candidate = globalThis[names[i]];
      if (typeof candidate === 'function' && !candidate.__lumeDispatch) {
        return { fn: candidate, style: names[i] === contractName ? 'object' : 'function' };
      }
    }
    try {
      var lexical = typeof LumeSource === 'undefined' ? undefined : LumeSource;
      if (lexical && lexical !== bridge) {
        for (i = 0; i < names.length; i++) {
          candidate = lexical[names[i]];
          if (typeof candidate === 'function') {
            return { fn: candidate, style: names[i] === contractName ? 'object' : 'function' };
          }
        }
      }
    } catch (error) { /* 读不到就按「没有实现」处理 */ }
    return null;
  }

  // 是否提供某个契约方法（按别名表判定，不产生任何调用副作用）。
  // 导入路径用它回答一个基本问题：这份脚本到底是不是本 App 的图源
  // ——见 LumeJsEngine.contractMethods。
  globalThis.__lumeContractMethods = function () {
    var found = [];
    var names = Object.keys(aliases);
    for (var i = 0; i < names.length; i++) {
      if (locate(namesOf(names[i]), names[i])) found.push(names[i]);
    }
    return found;
  };

  // 函数式契约的位置参数：getList(page) / getDetail(id) / getContent(id, chapterId)…
  function positionalArgs(name, argument) {
    var settings = (argument && typeof argument === 'object') ? argument : {};
    switch (name) {
      case 'list':
        return [settings.page == null ? 1 : settings.page];
      case 'detail':
      case 'chapters':
        return [settings.id == null ? '' : settings.id];
      case 'content':
        return [settings.id == null ? '' : settings.id,
                settings.chapterId == null ? '' : settings.chapterId];
      default:
        return [argument];
    }
  }

  function describe(name, extra) {
    var names = namesOf(name);
    return '源脚本没有实现 ' + name + ' 方法：请定义顶层函数 ' + names[0] + (extra || '')
      + '，或在脚本里给 LumeSource.' + name + ' 赋值';
  }

  function call(name, argument) {
    var found = locate(namesOf(name), name);
    var keyword = (name === 'list' && argument && typeof argument === 'object')
      ? argument.keyword
      : '';
    // 关键词搜索：函数式脚本通常单列 getSearch(keyword, page)。
    if (keyword && (!found || found.style === 'function')) {
      var search = locate(searchAliases, null);
      if (search) {
        return search.fn.apply(bridge, [
          keyword,
          argument.page == null ? 1 : argument.page
        ]);
      }
      if (!found) throw new Error(describe(name, '（或 ' + searchAliases[0] + '）'));
    }
    if (!found) throw new Error(describe(name));
    if (found.style === 'object') return found.fn.call(bridge, argument);
    return found.fn.apply(bridge, positionalArgs(name, argument));
  }

  var contract = Object.keys(aliases);
  for (var index = 0; index < contract.length; index++) {
    (function (name) {
      if (typeof bridge[name] === 'function') return;
      var dispatch = function (argument) { return call(name, argument); };
      dispatch.__lumeDispatch = true;
      bridge[name] = dispatch;
    }(contract[index]));
  }

  // 脚本对全局 LumeSource 的赋值：合并进桥接对象（宿主能力保留）。
  // 只吸收对象：函数自带的 length / name / prototype 不是图源实现的一部分。
  function absorb(value) {
    if (value === null || typeof value !== 'object') return;
    var owned = Object.getOwnPropertyNames(value);
    for (var i = 0; i < owned.length; i++) {
      var key = owned[i];
      if (reserved[key]) continue;
      try {
        var descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (descriptor) {
          Object.defineProperty(bridge, key, descriptor);
        } else {
          bridge[key] = value[key];
        }
      } catch (error) {
        try { bridge[key] = value[key]; } catch (ignored) { /* 只读属性：忽略 */ }
      }
    }
  }

  Object.defineProperty(globalThis, 'LumeSource', {
    configurable: true,
    enumerable: true,
    get: function () { return bridge; },
    set: function (value) { absorb(value); }
  });

  globalThis.__lumeSourceBridge = bridge;
})();
''';
}

/// 桥接对象的契约常量（Dart 侧唯一声明，供垫片与测试引用）。
class LumeSourceBridge {
  LumeSourceBridge._();

  /// 垫片标识。
  static const String polyfillId = 'lume.source.bridge';

  /// 契约方法 → 脚本可用的名字（顺序即派发优先级，末位是对象式契约名）。
  ///
  /// 每个方法的第一个名字是「函数式契约」的推荐写法，也是报错里点名的那个：
  /// 脚本作者照着写就能被认出来。
  static const Map<String, List<String>> aliases = <String, List<String>>{
    'categories': <String>['getCategories', 'getCategory', 'categories'],
    'list': <String>['getList', 'list'],
    'detail': <String>['getDetail', 'getBookInfo', 'detail'],
    'chapters': <String>['getChapters', 'getChapterList', 'chapters'],
    'content': <String>['getContent', 'getChapterContent', 'content'],
    // 首页（可选契约，用户口径任务 3）：多板块模式 / 旧兼容的纯列表模式。
    'home': <String>['getHome', 'getHomeContent', 'home'],
    // 筛选标签（可选契约，用户口径任务 1）：分页跳转筛选的标签组。
    'filters': <String>['getFilters', 'getFilterGroups', 'filters'],
  };

  /// 契约方法名列表（与 `JsSourceContract.methods` 同名同序）。
  static List<String> get methods => aliases.keys.toList(growable: false);
}
