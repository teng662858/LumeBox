import 'dart:collection';

import '../session/section.dart';

/// 一次内存缓存的占用统计（条目数 + 估算字节数）。
class MemoryCacheUsage {
  const MemoryCacheUsage({required this.entries, required this.bytes});

  const MemoryCacheUsage.empty()
      : entries = 0,
        bytes = 0;

  /// 条目数。
  final int entries;

  /// 估算字节数（见 [SectionMemoryCache.estimateBytes]）。
  ///
  /// 是**估算**不是精确值：只用于设置页展示「缓存有多大」，不参与任何阈值判断。
  final int bytes;

  bool get isEmpty => entries == 0;

  /// 设置页的一句话：`空` / `3 项 · 12.4 KB`。
  String describe() {
    if (isEmpty) return '空';
    return '$entries 项 · ${formatBytes(bytes)}';
  }

  /// 字节数的人类可读写法（与缓存管理的磁盘口径同一套）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 数据源读缓存端口。
///
/// 只服务「元数据读取」（分类 / 详情 / 章节）：这三种内容在一次运行里反复
/// 命中同一个小结果，缓存收益明确、体积可控。**列表与章节内容不进来**——
/// 列表变化快、内容体积大，缓存它们属于 Phase2 的离线缓存范围。
abstract interface class SourceReadCache {
  /// 读：未命中返回 null。
  Object? read(Section section, String sourceId, String key);

  /// 写：值应当是**不可变的小对象**（列表 / 映射 / 字符串），写入后不再改动。
  void write(Section section, String sourceId, String key, Object value);
}

/// 应用级、**按板块隔离**的内存缓存（只做内存级；磁盘缓存属 Phase2）。
///
/// 隔离：一个板块一格，清一个板块不碰另一个板块的任何条目；图源 id 只在其
/// 所属板块的格子里出现，跨板块读不到（宪法第 3 条：四板块互相独立）。
///
/// 生命周期：条目跨页面退出保留——这正是它区别于「页面资源」的地方
/// （图片位图、脚本引擎退出板块即释放，不在这里）。进程退出即清空；
/// 本轮不做过期淘汰策略，容量由用户在设置 →「缓存管理」里按板块清空。
class SectionMemoryCache implements SourceReadCache {
  SectionMemoryCache._();

  /// 应用级单例：四个板块共用这张登记表，键按板块分格。
  static final SectionMemoryCache instance = SectionMemoryCache._();

  /// 板块 → （`图源 id|键` → 条目）。插入序即写入序，便于调试时看最新条目。
  final Map<Section, LinkedHashMap<String, _Entry>> _stores =
      <Section, LinkedHashMap<String, _Entry>>{};

  @override
  Object? read(Section section, String sourceId, String key) =>
      _stores[section]?[_cacheKey(sourceId, key)]?.value;

  @override
  void write(Section section, String sourceId, String key, Object value) {
    final store =
        _stores.putIfAbsent(section, LinkedHashMap<String, _Entry>.new);
    store[_cacheKey(sourceId, key)] = _Entry(value, estimateBytes(value));
  }

  /// 某板块的占用（条目数 + 估算字节）。
  MemoryCacheUsage usageOf(Section section) {
    final store = _stores[section];
    if (store == null) return const MemoryCacheUsage.empty();
    var bytes = 0;
    for (final entry in store.values) {
      bytes += entry.bytes;
    }
    return MemoryCacheUsage(entries: store.length, bytes: bytes);
  }

  /// 清空一个板块，返回清掉的条目数；其他板块一条不动。
  int clear(Section section) {
    final store = _stores.remove(section);
    return store?.length ?? 0;
  }

  /// 清空一个图源的全部条目（脚本被覆盖导入、图源删除或运行时被释放时调用：
  /// 缓存的读结果必须跟着运行时一起作废，否则会读到上一个脚本的输出）。
  int removeSource(Section section, String sourceId) {
    final store = _stores[section];
    if (store == null) return 0;
    final prefix = '$sourceId|';
    final stale = store.keys.where((key) => key.startsWith(prefix)).toList();
    for (final key in stale) {
      store.remove(key);
    }
    if (store.isEmpty) _stores.remove(section);
    return stale.length;
  }

  /// 清空四个板块（测试隔离用；界面上的入口是分板块清空）。
  void clearAll() => _stores.clear();

  static String _cacheKey(String sourceId, String key) => '$sourceId|$key';

  /// 估算一份读结果的字节数。
  ///
  /// 口径：字符串按 UTF-16 码元 ×2，数字 / 布尔按固定小值，容器逐项累加，
  /// 其余类型按一个保守小值计。只用于展示，不追求精确。
  static int estimateBytes(Object? value) {
    if (value == null) return 0;
    if (value is String) return value.length * 2;
    if (value is num || value is bool) return 8;
    if (value is List) {
      var bytes = 8;
      for (final item in value) {
        bytes += estimateBytes(item);
      }
      return bytes;
    }
    if (value is Map) {
      var bytes = 8;
      for (final entry in value.entries) {
        bytes += estimateBytes(entry.key) + estimateBytes(entry.value);
      }
      return bytes;
    }
    return 16;
  }
}

class _Entry {
  const _Entry(this.value, this.bytes);

  final Object? value;
  final int bytes;
}
