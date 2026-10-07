import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

import '../util/lume_log.dart';

/// QuickJS 与插件 C 桥的不透明句柄。
/// ABI 上都是指针，具体布局由原生侧定义，Dart 侧只做传递。
final class JsRuntimeHandle extends Opaque {}

final class JsContextHandle extends Opaque {}

final class JsValueHandle extends Opaque {}

/// JS 值类型标签，与 quickjs-ng 的 JS_TAG_* 对应。
const int jsTagException = 6;

/// JS 求值类型：全局脚本。
const int jsEvalTypeGlobal = 0;

/// 插件 C 桥的 JS→Dart 回调签名：
/// `JSValue *(*)(const JSContext *ctx, const char *channel, const char *message)`
typedef JsChannelCallback = Pointer<JsValueHandle> Function(
  Pointer<JsContextHandle> context,
  Pointer<Utf8> channel,
  Pointer<Utf8> message,
);

/// `int JSInterruptHandler(JSRuntime *rt, void *opaque)`，返回非 0 表示中断。
typedef JsInterruptCallback = Int32 Function(
  Pointer<JsRuntimeHandle>,
  Pointer<Void>,
);

typedef _NewRuntimeNative = Pointer<JsRuntimeHandle> Function();

typedef _NewContextNative = Pointer<JsContextHandle> Function(
  Pointer<JsRuntimeHandle>,
  Pointer<NativeFunction<JsChannelCallback>>,
  Pointer<NativeFunction<JsChannelCallback>>,
  Pointer<NativeFunction<JsChannelCallback>>,
);

typedef _EvalNative = Pointer<JsValueHandle> Function(
  Pointer<JsContextHandle>,
  Pointer<Utf8>,
  IntPtr,
  Pointer<Utf8>,
  Int32,
);

typedef _ToCStringNative = Pointer<Utf8> Function(
  Pointer<JsContextHandle>,
  Pointer<JsValueHandle>,
);

typedef _FreeCStringNative = Void Function(
  Pointer<JsContextHandle>,
  Pointer<Utf8>,
);

typedef _FreeValueNative = Void Function(
  Pointer<JsContextHandle>,
  Pointer<JsValueHandle>,
  Int32,
);

typedef _FreeContextNative = Void Function(Pointer<JsContextHandle>);

typedef _FreeRuntimeNative = Void Function(Pointer<JsRuntimeHandle>);

typedef _GetExceptionNative = Pointer<JsValueHandle> Function(
  Pointer<JsContextHandle>,
);

typedef _ExecutePendingJobNative = Int32 Function(Pointer<JsRuntimeHandle>);

typedef _NewStringNative = Pointer<JsValueHandle> Function(
  Pointer<JsContextHandle>,
  Pointer<Utf8>,
);

typedef _ValueToAtomNative = Int32 Function(
  Pointer<JsContextHandle>,
  Pointer<JsValueHandle>,
);

typedef _GetPropertyNative = Pointer<JsValueHandle> Function(
  Pointer<JsContextHandle>,
  Pointer<JsValueHandle>,
  Int32,
);

typedef _FreeAtomNative = Void Function(Pointer<JsContextHandle>, Int32);

typedef _ValueGetTagNative = Int32 Function(Pointer<JsValueHandle>);

typedef _SetSizeNative = Void Function(Pointer<JsRuntimeHandle>, IntPtr);

typedef _SetInterruptHandlerNative = Void Function(
  Pointer<JsRuntimeHandle>,
  Pointer<NativeFunction<JsInterruptCallback>>,
  Pointer<Void>,
);

/// QuickJS-NG 原生入口。全部按需查找：库或某个符号不存在时，
/// [isAvailable] 返回 false，具体访问器抛 [StateError]，不会让调用方崩溃。
///
/// 库解析刻意不经过 `quickjs_engine` 插件的 Dart 层：该插件在 Windows 上写死了
/// 一个并不存在的 `flutter_js_plugin.dll`。这里按平台逐个候选名探测，
/// 并以真实符号是否存在作为判定依据。
class Qjs {
  Qjs._();

  static const List<String> _windowsCandidates = <String>[
    'quickjs_c_bridge_plugin.dll',
    'flutter_js_plugin.dll',
  ];

  static DynamicLibrary? _override;
  static DynamicLibrary? _library;
  static bool _resolved = false;

  /// 探测用的核心符号，缺失即认定该库不可用。
  static const String _probeSymbol = 'JS_NewRuntimeDartBridge';

  /// 注入原生库（测试或自建桥使用）。传 null 恢复自动探测。
  static void overrideLibrary(DynamicLibrary? library) {
    _override = library;
    _library = null;
    _resolved = false;
    _clearCache();
  }

  /// 当前原生库；不可用时返回 null。解析结果会缓存。
  ///
  /// 无论来自自动探测还是 [overrideLibrary]，都必须通过符号探测才算可用，
  /// 避免拿到一个「能打开但没有桥符号」的库后才发现问题。
  static DynamicLibrary? get library {
    if (_resolved) return _library;
    _resolved = true;
    final candidate = _override ?? _resolve();
    if (candidate != null && _probe(candidate)) {
      _library = candidate;
    }
    return _library;
  }

  static DynamicLibrary? _resolve() {
    for (final candidate in _candidates()) {
      try {
        return candidate.isEmpty
            ? DynamicLibrary.process()
            : DynamicLibrary.open(candidate);
      } catch (error) {
        LumeLog.warn(
          'QuickJS 库探测失败 (${candidate.isEmpty ? 'process' : candidate}): $error',
        );
      }
    }
    return null;
  }

  static bool _probe(DynamicLibrary library) {
    try {
      library.lookup<NativeFunction<Void Function()>>(_probeSymbol);
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<String> _candidates() {
    if (Platform.isAndroid) {
      return const <String>['libfastdev_quickjs_runtime.so'];
    }
    if (Platform.isWindows) return _windowsCandidates;
    // iOS / macOS / Linux：桥与 quickjs 一起编入进程镜像。
    return const <String>[''];
  }

  /// 沙箱能力是否可用（原生库存在且核心符号可解析）。
  static bool get isAvailable => library != null;

  /// 可用性判定依据，写进日志便于定位环境问题。
  static String get availabilityDetail => isAvailable
      ? '原生桥可用（${interruptHookAvailable ? '含中断通路' : '无中断通路'}）'
      : '未找到可用的 QuickJS 原生库';

  /// QuickJS 本体的中断通路是否可用。
  ///
  /// 上游插件的构建把 quickjs 本体符号设为 hidden 可见性，`JS_SetInterruptHandler`
  /// 不在动态符号表里，中断通路不可用、超时保护退化为预算机制。本项目在
  /// `third_party/quickjs_engine` 的本地副本里补了一个导出包装
  /// （`jsSetInterruptHandler`，见该目录 `PATCHES.md`），因此这里优先找包装符号；
  /// 找不到时回退找 quickjs 本体符号——两条路径都通不了才判定为「无中断通路」。
  static bool get interruptHookAvailable {
    if (!isAvailable) return false;
    _resolveInterrupt();
    return _setInterruptHandler != null;
  }

  /// 是否真正释放 JSRuntime。
  ///
  /// **这是一个已实测的崩溃开关。** quickjs 在 `JS_FreeRuntime` 里断言
  /// `list_empty(&rt->gc_obj_list)`，而插件每次 `JS_NewContextDartBridge` 都会
  /// 往 runtime 泄漏一个全局 `stringifyFn` 对象，于是该断言在开启断言的构建
  /// （Debug / 未定义 NDEBUG）里必然失败，进程直接 abort。
  ///
  /// 实测：Debug 产物 `jsFreeRuntime` → 进程 exit=3；Release 产物 → exit=0；
  /// 只调 `jsFreeContext` 则连续 30 次创建/销毁循环稳定退出。
  /// 因此默认只在 Release 下回收 runtime，其余情况只释放 context 并记账。
  static bool reclaimRuntime = kReleaseMode;

  /// 因无法安全回收而被放弃的 runtime 数量，用于诊断内存占用。
  static int abandonedRuntimes = 0;

  /// 常驻的 JS_NULL 值，用于回填 C 桥的返回值。
  /// JSValue 布局为 { union u; int64 tag; }，JS_NULL 的 tag 为 JS_TAG_NULL(2)。
  static Pointer<JsValueHandle> get nullValue {
    final cached = _nullValue;
    if (cached != null) return cached;
    final raw = calloc<Uint8>(16);
    raw.asTypedList(16)[8] = 2;
    final value = Pointer<JsValueHandle>.fromAddress(raw.address);
    _nullValue = value;
    return value;
  }

  static Pointer<JsValueHandle>? _nullValue;

  // ---------------------------------------------------------------- 符号缓存

  static Pointer<JsRuntimeHandle> Function()? _newRuntime;
  static Pointer<JsContextHandle> Function(
    Pointer<JsRuntimeHandle>,
    Pointer<NativeFunction<JsChannelCallback>>,
    Pointer<NativeFunction<JsChannelCallback>>,
    Pointer<NativeFunction<JsChannelCallback>>,
  )? _newContext;
  static Pointer<JsValueHandle> Function(
    Pointer<JsContextHandle>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    int,
  )? _evaluate;
  static Pointer<Utf8> Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>)?
      _toCString;
  static void Function(Pointer<JsContextHandle>, Pointer<Utf8>)? _freeCString;
  static void Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>, int)?
      _freeValue;
  static void Function(Pointer<JsContextHandle>)? _freeContext;
  static void Function(Pointer<JsRuntimeHandle>)? _freeRuntime;
  static Pointer<JsValueHandle> Function(Pointer<JsContextHandle>)?
      _getException;
  static Pointer<JsValueHandle> Function(Pointer<JsContextHandle>, Pointer<Utf8>)?
      _newString;
  static int Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>)?
      _valueToAtom;
  static Pointer<JsValueHandle> Function(
    Pointer<JsContextHandle>,
    Pointer<JsValueHandle>,
    int,
  )? _getProperty;
  static void Function(Pointer<JsContextHandle>, int)? _freeAtom;
  static int Function(Pointer<JsRuntimeHandle>)? _executePendingJob;
  static int Function(Pointer<JsValueHandle>)? _valueTag;
  static void Function(Pointer<JsRuntimeHandle>, int)? _setMemoryLimit;
  static void Function(Pointer<JsRuntimeHandle>, int)? _setMaxStackSize;
  static void Function(
    Pointer<JsRuntimeHandle>,
    Pointer<NativeFunction<JsInterruptCallback>>,
    Pointer<Void>,
  )? _setInterruptHandler;
  static bool _interruptResolved = false;

  static void _clearCache() {
    _newRuntime = null;
    _newContext = null;
    _evaluate = null;
    _toCString = null;
    _freeCString = null;
    _freeValue = null;
    _freeContext = null;
    _freeRuntime = null;
    _getException = null;
    _newString = null;
    _valueToAtom = null;
    _getProperty = null;
    _freeAtom = null;
    _executePendingJob = null;
    _valueTag = null;
    _setMemoryLimit = null;
    _setMaxStackSize = null;
    _setInterruptHandler = null;
    _interruptResolved = false;
  }

  static DynamicLibrary _require() {
    final resolved = library;
    if (resolved == null) {
      throw StateError('QuickJS 原生库不可用（$availabilityDetail）');
    }
    return resolved;
  }

  /// 按需查找符号；任何失败都收敛成 [StateError]。
  static T _lookup<T extends Function>(
    T? cached,
    String name,
    T Function(DynamicLibrary) bind,
  ) {
    if (cached != null) return cached;
    try {
      return bind(_require());
    } catch (error) {
      throw StateError('QuickJS 符号不可用: $name ($error)');
    }
  }

  static void _resolveInterrupt() {
    if (_interruptResolved) return;
    _interruptResolved = true;
    final resolved = library;
    if (resolved == null) return;
    // 先找本仓库补丁导出的包装符号（vendored 副本），再回退 quickjs 本体符号。
    for (final name in const <String>[
      'jsSetInterruptHandler',
      'JS_SetInterruptHandler',
    ]) {
      try {
        _setInterruptHandler = resolved
            .lookup<NativeFunction<_SetInterruptHandlerNative>>(name)
            .asFunction();
        return;
      } catch (_) {
        // 换下一个候选名。
      }
    }
    _setInterruptHandler = null;
  }

  // -------------------------------------------------------------- 符号访问器

  static Pointer<JsRuntimeHandle> Function() get newRuntime =>
      _newRuntime ??= _lookup(
        _newRuntime,
        'JS_NewRuntimeDartBridge',
        (lib) => lib.lookupFunction<_NewRuntimeNative,
            Pointer<JsRuntimeHandle> Function()>('JS_NewRuntimeDartBridge'),
      );

  static Pointer<JsContextHandle> Function(
    Pointer<JsRuntimeHandle>,
    Pointer<NativeFunction<JsChannelCallback>>,
    Pointer<NativeFunction<JsChannelCallback>>,
    Pointer<NativeFunction<JsChannelCallback>>,
  ) get newContext =>
      _newContext ??= _lookup(
        _newContext,
        'JS_NewContextDartBridge',
        (lib) => lib.lookupFunction<_NewContextNative,
            Pointer<JsContextHandle> Function(
              Pointer<JsRuntimeHandle>,
              Pointer<NativeFunction<JsChannelCallback>>,
              Pointer<NativeFunction<JsChannelCallback>>,
              Pointer<NativeFunction<JsChannelCallback>>,
            )>('JS_NewContextDartBridge'),
      );

  static Pointer<JsValueHandle> Function(
    Pointer<JsContextHandle>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    int,
  ) get evaluate => _evaluate ??= _lookup(
        _evaluate,
        'jsEval',
        (lib) => lib.lookupFunction<_EvalNative,
            Pointer<JsValueHandle> Function(Pointer<JsContextHandle>,
                Pointer<Utf8>, int, Pointer<Utf8>, int)>('jsEval'),
      );

  static Pointer<Utf8> Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>)
      get toCString => _toCString ??= _lookup(
            _toCString,
            'jsToCString',
            (lib) => lib.lookupFunction<_ToCStringNative,
                Pointer<Utf8> Function(Pointer<JsContextHandle>,
                    Pointer<JsValueHandle>)>('jsToCString'),
          );

  static void Function(Pointer<JsContextHandle>, Pointer<Utf8>)
      get freeCString => _freeCString ??= _lookup(
            _freeCString,
            'jsFreeCString',
            (lib) => lib.lookupFunction<_FreeCStringNative,
                void Function(Pointer<JsContextHandle>, Pointer<Utf8>)>(
                'jsFreeCString'),
          );

  static void Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>, int)
      get freeValue => _freeValue ??= _lookup(
            _freeValue,
            'jsFreeValue',
            (lib) => lib.lookupFunction<_FreeValueNative,
                void Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>,
                    int)>('jsFreeValue'),
          );

  static void Function(Pointer<JsContextHandle>) get freeContext =>
      _freeContext ??= _lookup(
        _freeContext,
        'jsFreeContext',
        (lib) => lib.lookupFunction<_FreeContextNative,
            void Function(Pointer<JsContextHandle>)>('jsFreeContext'),
      );

  static void Function(Pointer<JsRuntimeHandle>) get freeRuntime =>
      _freeRuntime ??= _lookup(
        _freeRuntime,
        'jsFreeRuntime',
        (lib) => lib.lookupFunction<_FreeRuntimeNative,
            void Function(Pointer<JsRuntimeHandle>)>('jsFreeRuntime'),
      );

  /// 取出并清除上下文里的待处理异常。
  ///
  /// 必须在求值失败后立即调用：quickjs 会把未消费的异常留在上下文里，
  /// 之后的每次求值都会直接把该异常抛回来（实测到的「上下文被污染」现象）。
  static Pointer<JsValueHandle> Function(Pointer<JsContextHandle>)
      get getException => _getException ??= _lookup(
            _getException,
            'jsGetException',
            (lib) => lib.lookupFunction<_GetExceptionNative,
                Pointer<JsValueHandle> Function(
                    Pointer<JsContextHandle>)>('jsGetException'),
          );

  /// 新建一个 JS 字符串值（读属性用的键）。
  static Pointer<JsValueHandle> Function(Pointer<JsContextHandle>, Pointer<Utf8>)
      get newString => _newString ??= _lookup(
            _newString,
            'jsNewString',
            (lib) => lib.lookupFunction<_NewStringNative,
                    Pointer<JsValueHandle> Function(
                        Pointer<JsContextHandle>, Pointer<Utf8>)>(
                'jsNewString'),
          );

  /// JS 值 → 属性原子上（属性名做键用）。
  static int Function(Pointer<JsContextHandle>, Pointer<JsValueHandle>)
      get valueToAtom => _valueToAtom ??= _lookup(
            _valueToAtom,
            'jsValueToAtom',
            (lib) => lib.lookupFunction<_ValueToAtomNative,
                    int Function(Pointer<JsContextHandle>,
                        Pointer<JsValueHandle>)>(
                'jsValueToAtom'),
          );

  /// 读对象属性（返回新引用，用完要 [freeValue]）。
  static Pointer<JsValueHandle> Function(
    Pointer<JsContextHandle>,
    Pointer<JsValueHandle>,
    int,
  ) get getProperty => _getProperty ??= _lookup(
        _getProperty,
        'jsGetProperty',
        (lib) => lib.lookupFunction<_GetPropertyNative,
                Pointer<JsValueHandle> Function(Pointer<JsContextHandle>,
                    Pointer<JsValueHandle>, int)>(
            'jsGetProperty'),
      );

  /// 释放属性原子。
  static void Function(Pointer<JsContextHandle>, int) get freeAtom =>
      _freeAtom ??= _lookup(
        _freeAtom,
        'jsFreeAtom',
        (lib) => lib.lookupFunction<_FreeAtomNative,
            void Function(Pointer<JsContextHandle>, int)>('jsFreeAtom'),
      );

  static int Function(Pointer<JsRuntimeHandle>) get executePendingJob =>
      _executePendingJob ??= _lookup(
        _executePendingJob,
        'jsExecutePendingJob',
        (lib) => lib.lookupFunction<_ExecutePendingJobNative,
            int Function(Pointer<JsRuntimeHandle>)>('jsExecutePendingJob'),
      );

  static int Function(Pointer<JsValueHandle>) get valueTag => _valueTag ??=
      _lookup(
        _valueTag,
        'jsValueGetTag',
        (lib) => lib.lookupFunction<_ValueGetTagNative,
            int Function(Pointer<JsValueHandle>)>('jsValueGetTag'),
      );

  static void Function(Pointer<JsRuntimeHandle>, int) get setMemoryLimit =>
      _setMemoryLimit ??= _lookup(
        _setMemoryLimit,
        'jsSetMemoryLimit',
        (lib) => lib.lookupFunction<_SetSizeNative,
            void Function(Pointer<JsRuntimeHandle>, int)>('jsSetMemoryLimit'),
      );

  static void Function(Pointer<JsRuntimeHandle>, int) get setMaxStackSize =>
      _setMaxStackSize ??= _lookup(
        _setMaxStackSize,
        'jsSetMaxStackSize',
        (lib) => lib.lookupFunction<_SetSizeNative,
            void Function(Pointer<JsRuntimeHandle>, int)>('jsSetMaxStackSize'),
      );

  /// 安装中断处理器。符号不可用时返回 false。
  static bool installInterruptHandler(
    Pointer<JsRuntimeHandle> runtime,
    Pointer<NativeFunction<JsInterruptCallback>> handler,
  ) {
    _resolveInterrupt();
    final setter = _setInterruptHandler;
    if (setter == null) return false;
    try {
      setter(runtime, handler, nullptr);
      return true;
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      return false;
    }
  }

  /// 安全释放 runtime：断言型构建下只记账不释放，避免触发 quickjs 的
  /// 泄漏断言导致进程 abort。
  static void releaseRuntime(Pointer<JsRuntimeHandle> runtime) {
    if (!reclaimRuntime) {
      abandonedRuntimes++;
      return;
    }
    try {
      freeRuntime(runtime);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
    }
  }
}
