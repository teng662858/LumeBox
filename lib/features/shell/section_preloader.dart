import 'dart:async';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';

/// 板块预热：**在切页签的那一刻就开始准备**，不等页面切过去才发请求。
///
/// ## 为什么需要
///
/// 导航壳的纪律是「只挂当前页签、切走即销毁、切回重建」（见 AppShell 的说明），
/// 因此每次切板块，页面都要从零做这些事：打开本板块阅读库、装载源引擎
/// （QuickJS 上下文 + 脚本执行）、取分类、取第一页。这些都在 `initState` 之后
/// 才开始，用户看到的就是「切过去先白一下」。
///
/// 预热把前两件事提到**手指刚点下去**的时刻：页面构建之后 `ExploreView` 打开
/// 同一个源时会命中已装载的运行时，首页列表也能直接吃到这里取好的第一页。
///
/// ## 三条边界
///
/// 1. **预热结果有保质期**：默认 60 秒。过期即丢，绝不会因此显示陈旧列表
///    （用户下拉刷新时也会丢弃）。
/// 2. **失败静默**：预热只是「提前做」，失败了页面照旧自己取——不弹提示、不设错误态。
/// 3. **同一板块同一目标只预热一次**：连点页签不会反复拉第一页。
class SectionPreloader {
  SectionPreloader._();

  /// 预热结果的有效期。
  static const Duration ttl = Duration(seconds: 60);

  static final Map<Section, _WarmEntry> _warm = <Section, _WarmEntry>{};

  /// 已经预热过的目标键（板块 + 源 + 分类 + 关键词），防重复。
  static final Set<String> _inFlight = <String>{};

  /// 预热一个板块：打开阅读库与当前源，并取一份第一页放进短时缓存。
  ///
  /// [manager] 与 [library] 由调用方给（导航壳没有这些依赖，页面自己也知道），
  /// 二者都可为空——为空时只做能做的部分。
  static Future<void> warm(
    Section section, {
    SourceManager? manager,
    Future<void> Function()? openLibrary,
  }) async {
    try {
      // 阅读库先开：它是 sqlite 句柄，页面 `_boot` 里也是第一步。
      await openLibrary?.call();
    } catch (error) {
      LumeLog.info('[warm] ${section.id} 阅读库预热失败（页面会自己重试）：$error');
    }
    final manager_ = manager;
    if (manager_ == null) return;
    try {
      if (!manager_.runtimeAvailable) return;
      final current = await manager_.current();
      if (current == null) return;
      final key = '${section.id}|${current.id}|';
      if (!_inFlight.add(key)) return;
      final source = await manager_.open(current.id);
      if (source == null) return;
      final list = await source.list(page: 1);
      _warm[section] = _WarmEntry(
        sourceId: current.id,
        categoryId: null,
        keyword: '',
        list: list,
        at: DateTime.now(),
      );
      LumeLog.info('[warm] ${section.id} 首页已预热（${list.items.length} 条）');
    } catch (error) {
      // 预热失败不影响任何事：页面照旧自己取数据。
      LumeLog.info('[warm] ${section.id} 首页预热未完成：$error');
    }
  }

  /// 取走预热好的第一页（取走即失效，避免同一份数据被两个页面各自当成「最新」）。
  ///
  /// 匹配条件：板块、源、分类、关键词都一致，且未超过 [ttl]。
  static SourceList? takeWarmPage(
    Section section, {
    required String sourceId,
    String? categoryId,
    String keyword = '',
  }) {
    final entry = _warm[section];
    if (entry == null) return null;
    if (entry.sourceId != sourceId ||
        entry.categoryId != categoryId ||
        entry.keyword != keyword) {
      return null;
    }
    if (DateTime.now().difference(entry.at) > ttl) {
      _warm.remove(section);
      return null;
    }
    _warm.remove(section);
    _inFlight.clear();
    return entry.list;
  }

  /// 丢弃预热结果（下拉刷新、换源、导入后刷新时调用）。
  static void discard([Section? section]) {
    if (section == null) {
      _warm.clear();
      _inFlight.clear();
      return;
    }
    _warm.remove(section);
    _inFlight.removeWhere((key) => key.startsWith('${section.id}|'));
  }

  /// 仅测试用：观察当前是否有预热结果。
  static bool hasWarm(Section section) => _warm.containsKey(section);
}

class _WarmEntry {
  _WarmEntry({
    required this.sourceId,
    required this.categoryId,
    required this.keyword,
    required this.list,
    required this.at,
  });

  final String sourceId;
  final String? categoryId;
  final String keyword;
  final SourceList list;
  final DateTime at;
}
