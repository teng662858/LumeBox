/// Polyfill 垫片契约：一段注入到每个新建 JSContext 的 JS 源码。
///
/// 本轮只提供注入入口与排序规则，**不提供任何垫片实现体**；后续 iOS 猫源
/// 环境所需的垫片（宿主对象模拟、编码转换等）以独立实现类接入，
/// 通过 [PolyfillRegistry.register] 注册即可，无需改动沙箱本身。
abstract interface class SandboxPolyfill {
  /// 稳定标识，用于去重与依赖声明。
  String get id;

  /// 依赖的其他垫片 id；注入顺序会保证依赖先于自身。
  List<String> get requires;

  /// 注入到上下文的 JS 源码。要求幂等、可重复执行（上下文重建后会再次注入）。
  String get source;
}

/// 垫片登记与注入顺序。
///
/// 注入时机：每个 JSContext 创建完成、沙箱自身 prelude 之后立即注入，
/// 因此垫片可以直接使用 prelude 提供的 `LumeBridge` / `console` 等能力。
/// 上下文因污染被销毁重建时，垫片会随新上下文重新注入。
class PolyfillRegistry {
  PolyfillRegistry([Iterable<SandboxPolyfill> initial = const <SandboxPolyfill>[]]) {
    for (final polyfill in initial) {
      register(polyfill);
    }
  }

  /// 空登记表：默认状态，不注入任何垫片。
  static final PolyfillRegistry empty = PolyfillRegistry();

  final Map<String, SandboxPolyfill> _polyfills = <String, SandboxPolyfill>{};

  void register(SandboxPolyfill polyfill) {
    if (polyfill.id.trim().isEmpty) {
      throw ArgumentError('垫片 id 不能为空');
    }
    if (polyfill.source.trim().isEmpty) {
      throw ArgumentError('垫片 ${polyfill.id} 的源码为空');
    }
    _polyfills[polyfill.id] = polyfill;
  }

  bool remove(String id) => _polyfills.remove(id) != null;

  bool contains(String id) => _polyfills.containsKey(id);

  bool get isEmpty => _polyfills.isEmpty;

  int get length => _polyfills.length;

  /// 按依赖顺序返回全部垫片。
  List<SandboxPolyfill> ordered() {
    final result = <SandboxPolyfill>[];
    final visiting = <String>{};
    final done = <String>{};

    void visit(SandboxPolyfill polyfill) {
      if (done.contains(polyfill.id)) return;
      if (!visiting.add(polyfill.id)) {
        throw StateError('垫片循环依赖: ${polyfill.id}');
      }
      for (final dependency in polyfill.requires) {
        final resolved = _polyfills[dependency];
        if (resolved == null) {
          throw StateError('垫片 ${polyfill.id} 缺少依赖: $dependency');
        }
        visit(resolved);
      }
      visiting.remove(polyfill.id);
      done.add(polyfill.id);
      result.add(polyfill);
    }

    for (final polyfill in _polyfills.values) {
      visit(polyfill);
    }
    return List<SandboxPolyfill>.unmodifiable(result);
  }

  /// 拼接后的注入源码。空白登记表返回空字符串。
  String bootstrap() => ordered().map((item) => item.source).join('\n');
}
