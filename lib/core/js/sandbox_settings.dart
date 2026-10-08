import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';
import 'sandbox/sandbox_policy.dart';

/// 全局沙箱设置：四个板块的图源脚本共用这一份执行预算。
///
/// 对应文档第 4 条：「配置所有图源共用的全局参数（全局并发、全局 UA、全局代理、
/// **JS沙箱超时**等，全局互通生效）」。
///
/// 与网络设置同构（见 `NetworkSettings`）：一份落盘 JSON、应用级单例、越界值
/// 收敛到文档允许的区间。区别只在「管什么」——这里管的是**脚本能跑多久**。
///
/// ## 可配与不可配（为什么这样切）
///
/// 可配的只有**墙钟超时**：它是文档点名的项（3–5 秒），而且用户的机器与站点
/// 差异会让同一个值体验不同（慢站点的正常脚本可能刚好卡在 4 秒）。
///
/// 其余上限（内存、栈、宿主调用数、微任务轮数…）**刻意不做成可配**：
/// 它们是安全兜底，调大等于把「防死循环 / 防内存失控」的保护关掉。
/// 唯一的例外是指令计数：它**跟随超时同向放大**（见 [SandboxSettings.policy]），
/// 因为纯 CPU 空转由墙钟超时一级闸门兜住，指令计数只是「更早发现」的辅助。栈上限尤其
/// 危险——`SandboxPolicy.defaultStackLimitBytes` 的注释里记着实测数据：
/// 调到 1MB 会让进程当场死亡（无异常、无日志）。这类值不该交给设置页。
class SandboxSettings {
  const SandboxSettings({this.timeout = SandboxPolicy.defaultTimeout});

  /// 单次操作（求值 / 调用）的墙钟预算。
  final Duration timeout;

  /// 文档规定的区间下沿（`SandboxPolicy.minTimeout`）。
  static Duration get minTimeout => SandboxPolicy.minTimeout;

  /// 文档规定的区间上沿（`SandboxPolicy.maxTimeout`）。
  static Duration get maxTimeout => SandboxPolicy.maxTimeout;

  static const Duration defaultTimeout = SandboxPolicy.defaultTimeout;

  /// 用户可选的档位（秒）。区间由文档钉死为 3–5 秒，因此只有三档。
  static const List<int> timeoutOptionsSeconds = <int>[3, 4, 5, 6, 8, 10];

  /// 收敛到文档允许的区间（越界值不会生效，与网络设置同一口径）。
  SandboxSettings clamped() => SandboxSettings(
        timeout: timeout < minTimeout
            ? minTimeout
            : (timeout > maxTimeout ? maxTimeout : timeout),
      );

  SandboxSettings copyWith({Duration? timeout}) =>
      SandboxSettings(timeout: timeout ?? this.timeout);

  /// 本设置对应的沙箱策略：在标准预设上只改超时。
  ///
  /// 其余上限全部沿用 [SandboxPolicy.standard] —— 这是「可配项只影响它该影响
  /// 的那一项」的落地：用户调超时，不会顺带把内存 / 栈 / 指令预算改掉。
  /// 指令预算**跟随超时同向放大**（[SandboxPolicy.instructionsFor]）：用户把超时
  /// 调到 8–10s，等于明说「这个源解析重、我愿意等」——这时还按默认的 2 亿条卡死
  /// 说不通（真机反馈：鸟鸟韩漫首页解析撞「超出指令计数上限」）。纯死循环仍由
  /// 墙钟超时一级闸门回收，安全性不靠这个数。
  SandboxPolicy policy() => SandboxPolicy.standard.copyWith(
        timeout: clamped().timeout,
        maxInstructions: SandboxPolicy.instructionsFor(clamped().timeout),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'timeoutMs': clamped().timeout.inMilliseconds,
      };

  /// 从落盘 JSON 还原。缺项与非法值一律回退默认（旧配置不会让沙箱起不来）。
  static SandboxSettings fromJson(Object? json) {
    if (json is! Map) return const SandboxSettings();
    final value = _int(json['timeoutMs']);
    if (value == null) return const SandboxSettings();
    return SandboxSettings(timeout: Duration(milliseconds: value)).clamped();
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SandboxSettings && other.timeout == timeout;

  @override
  int get hashCode => timeout.hashCode;

  @override
  String toString() => 'SandboxSettings(timeout: ${timeout.inSeconds}s)';
}

/// 全局沙箱设置的持久化：`<应用支持目录>/sandbox_settings.json`。
///
/// 与网络设置同样的落点理由：这份配置对四个板块同时生效，放进任何板块目录都会
/// 与「板块互相独立」的口径矛盾。写入用「先写临时文件再改名」，中途崩溃不会
/// 留下半个 JSON。
class SandboxSettingsStore {
  SandboxSettingsStore._(this._file);

  static const String fileName = 'sandbox_settings.json';

  final File _file;

  static SandboxSettingsStore? _current;

  /// 打开（必要时创建目录）。重复调用返回同一实例。
  static Future<SandboxSettingsStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = SandboxSettingsStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  /// 仅测试用：清掉实例缓存（换目录后重新打开）。
  static void resetForTesting() => _current = null;

  /// 读取设置。文件缺失或损坏时回退默认值。
  SandboxSettings load() {
    try {
      if (!_file.existsSync()) return const SandboxSettings();
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return const SandboxSettings();
      return SandboxSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('沙箱设置读取失败，回退默认值: $error');
      LumeLog.error(error, stackTrace);
      return const SandboxSettings();
    }
  }

  /// 写回设置（自动收敛到合法区间）。
  void save(SandboxSettings settings) {
    final clamped = settings.clamped();
    try {
      _file.parent.createSync(recursive: true);
      final temp = File('${_file.path}.tmp');
      temp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(clamped.toJson()),
        flush: true,
      );
      temp.renameSync(_file.path);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      throw StateError('沙箱设置写入失败：$error');
    }
  }

  String get path => _file.path;
}

/// 全局沙箱层入口：**一份设置**，四个板块的图源引擎共用。
///
/// 与 [LumeNet] 同构：启动时读一次落盘值，用户在设置页改动后立即生效
/// （新建的引擎按新超时装配；已经在跑的引擎在下次操作时用新预算——
/// 见 `LumeJsEngine.create` 每次都从 [current] 取策略）。
class LumeSandboxSettings {
  LumeSandboxSettings._();

  static SandboxSettings _settings = const SandboxSettings();

  /// 当前生效的全局沙箱设置。
  static SandboxSettings get current => _settings;

  /// 当前生效的沙箱策略（图源引擎装配用）。
  static SandboxPolicy get policy => _settings.policy();

  /// 启动时读一次落盘设置。失败不阻断启动（回退默认值）。
  static Future<void> boot() async {
    try {
      final store = await SandboxSettingsStore.open();
      apply(store.load());
    } catch (error, stackTrace) {
      LumeLog.warn('全局沙箱设置加载失败，使用默认值: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 应用新设置（收敛后生效）。
  static void apply(SandboxSettings settings) {
    _settings = settings.clamped();
  }

  /// 保存并应用（设置页用）。
  static Future<void> save(SandboxSettings settings) async {
    apply(settings);
    final store = await SandboxSettingsStore.open();
    store.save(_settings);
  }

  /// 仅测试用：复位到默认。
  static void resetForTesting() => _settings = const SandboxSettings();
}
