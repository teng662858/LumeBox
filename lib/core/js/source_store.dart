import 'sandbox/sandbox_host.dart';

/// 沙盒文件 IO 的后端：**按图源隔离的进程内键值存储**。
///
/// 图源脚本里的 `LumeSource.fs.*` 落在这一层：JS 侧只看到「路径 → 文本」的读写，
/// 真正的字节留在 Dart 侧的这张表里。三条纪律：
///
/// - **不落盘**：数据只在进程内，随引擎释放一起消失——沙盒脚本拿不到真实文件
///   系统，缓存类写入也不会污染用户设备；
/// - **按图源隔离**：一个图源一个实例（引擎创建时新建），实例之间没有任何共享
///   状态，路径还能互相看见的只有自己的表；
/// - **有界**：条数与总字符数都有上限，写超即抛 [SandboxHostException]，
///   错误文本可读（脚本侧表现为 Promise 拒绝），不让脚本把内存吃光。
///
/// 生命周期：由 [LumeSourceHost] 持有，引擎释放时 [clear]。
class SandboxStore {
  SandboxStore({
    this.maxEntries = defaultMaxEntries,
    this.maxValueChars = defaultMaxValueChars,
    this.maxTotalChars = defaultMaxTotalChars,
  });

  /// 单实例条目上限。
  static const int defaultMaxEntries = 64;

  /// 单条值字符数上限（64 KiB）。
  static const int defaultMaxValueChars = 64 * 1024;

  /// 单实例总字符数上限（512 KiB）。
  static const int defaultMaxTotalChars = 512 * 1024;

  final int maxEntries;
  final int maxValueChars;
  final int maxTotalChars;

  final Map<String, String> _entries = <String, String>{};

  int _totalChars = 0;

  int get entryCount => _entries.length;

  int get totalChars => _totalChars;

  /// 读取。不存在返回 null。
  String? read(String key) => _entries[normalizeKey(key)];

  bool containsKey(String key) => _entries.containsKey(normalizeKey(key));

  /// 写入（覆盖同路径的旧值）。超限抛 [SandboxHostException]。
  void write(String key, String value) {
    final path = normalizeKey(key);
    if (value.length > maxValueChars) {
      throw SandboxHostException(
        '写入超出单条上限（$maxValueChars 字符）：$path',
      );
    }
    final previous = _entries[path];
    final projected = _totalChars - (previous?.length ?? 0) + value.length;
    if (projected > maxTotalChars) {
      throw SandboxHostException('沙盒存储已满（上限 $maxTotalChars 字符）');
    }
    if (previous == null && _entries.length >= maxEntries) {
      throw SandboxHostException('沙盒存储条目已达上限（$maxEntries 条）');
    }
    _entries[path] = value;
    _totalChars = projected;
  }

  /// 删除。返回是否确实删掉了一条。
  bool remove(String key) {
    final removed = _entries.remove(normalizeKey(key));
    if (removed == null) return false;
    _totalChars -= removed.length;
    return true;
  }

  /// 全部路径（字典序，读取口径稳定）。
  List<String> keys() {
    final result = _entries.keys.toList(growable: false);
    result.sort();
    return result;
  }

  /// 清空（引擎释放时调用）。
  void clear() {
    _entries.clear();
    _totalChars = 0;
  }

  /// 路径归一：去掉前导斜杠、压掉重复斜杠，空路径即非法。
  ///
  /// 归一在 Dart 侧做，脚本写 `'/cache/a.json'` 与 `'cache/a.json'` 落到同一条目，
  /// 不会因为写法不同而互相看不见。
  static String normalizeKey(String key) {
    final segments = key
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      throw const SandboxHostException('沙盒路径为空');
    }
    return segments.join('/');
  }
}
