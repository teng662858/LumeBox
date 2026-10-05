import 'dart:async';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/util/lume_log.dart';
import 'section_cache.dart';

/// 缓存策略的后台执行器：应用启动后按策略修剪一次，之后定期复查。
///
/// 为什么需要它：策略此前只在「保存策略」与「进缓存页」时执行——用户设了 200 MB
/// 上限却从不打开缓存页，缓存就会一直涨。这个执行器把策略变成**后台自动生效**。
///
/// 三条纪律：
/// - **只在有策略时干活**：四个板块都没配策略（默认「不限制」）就整个跳过，
///   不做任何磁盘遍历（空转也要成本）；
/// - **启动延迟执行**：启动瞬间 CPU / IO 忙，推迟一会儿再修剪，不抢启动资源；
/// - **失败不冒泡**：修剪是维护性动作，任何异常只记日志，绝不影响使用。
///
/// 生命周期由 [start] / [dispose] 控制；应用退出时停表。
class CachePruner {
  CachePruner({
    this.service = const SectionCacheService(),
    this.initialDelay = const Duration(seconds: 20),
    this.interval = const Duration(hours: 6),
    this.policyLoader,
  });

  /// 修剪执行者。
  final SectionCacheService service;

  /// 启动后多久跑第一次（避开启动高峰）。
  final Duration initialDelay;

  /// 之后每隔多久复查一次。
  final Duration interval;

  /// 策略读取端口（测试可注入）；为空时从各板块阅读库读。
  final Future<SectionCachePolicy> Function(Section section)? policyLoader;

  Timer? _initialTimer;
  Timer? _periodicTimer;
  bool _running = false;
  bool _disposed = false;

  /// 是否已启动。
  bool get isRunning => _initialTimer != null || _periodicTimer != null;

  /// 是否正在执行一次修剪。
  bool get isPruning => _running;

  /// 启动：延迟首跑 + 周期复查。
  void start() {
    if (_disposed || isRunning) return;
    _initialTimer = Timer(initialDelay, () {
      _initialTimer = null;
      if (_disposed) return;
      unawaited(pruneNow());
      _periodicTimer = Timer.periodic(interval, (_) {
        if (_disposed) return;
        unawaited(pruneNow());
      });
    });
  }

  /// 立即按策略修剪四个板块。返回是否有实际清理。
  ///
  /// 重入保护：上一次还没跑完就跳过这一次（定时器可能在上一次耗时较久时再次触发）。
  Future<bool> pruneNow() async {
    if (_disposed || _running) return false;
    _running = true;
    var removed = 0;
    var freed = 0;
    try {
      for (final section in Section.values) {
        final policy = await _policyFor(section);
        if (!policy.hasLimit) continue;
        try {
          final result = await service.prune(section, policy);
          removed += result.removedFiles;
          freed += result.freedBytes;
        } catch (error, stackTrace) {
          LumeLog.error(error, stackTrace);
          LumeLog.warn('[cache] ${section.label} 策略修剪失败：$error');
        }
      }
      if (removed > 0) {
        final mb = freed / (1024 * 1024);
        LumeLog.info(
          '[cache] 后台策略修剪：清理 $removed 个文件 · 释放 ${mb.toStringAsFixed(1)} MB',
        );
      }
      return removed > 0;
    } finally {
      _running = false;
    }
  }

  /// 取某板块的策略：优先用注入端口，否则从该板块阅读库读。
  Future<SectionCachePolicy> _policyFor(Section section) async {
    final loader = policyLoader;
    if (loader != null) return loader(section);
    try {
      final library = await ReadingLibrary.open(section);
      return CachePolicyStore(library).load(section);
    } catch (error, stackTrace) {
      // 库打不开就当作「不限制」：宁可不修剪，也不误删。
      LumeLog.error(error, stackTrace);
      return SectionCachePolicy.unlimited;
    }
  }

  void dispose() {
    _disposed = true;
    _initialTimer?.cancel();
    _initialTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }
}
