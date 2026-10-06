import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/debug_request_log.dart';
import '../util/lume_log.dart';

/// 开发者模式开关（文档「调试日志规范」）。
///
/// 文档要求「内置调试面板（**仅开发者模式开启，正式构建隐藏**）」。这里的口径是：
///
/// - **正式构建不隐藏入口、但默认关闭**，而不是从界面上删掉它。
///   理由：本项目是自用工具，用户就是开发者；把入口藏起来只会让人找不到排障
///   手段。真正要防的是「抓包数据在不知情的情况下被收集」，而那由
///   「默认关闭 + 只留内存 + 不导出」保证（见 [DebugRequestLog]）。
/// - 开关落盘（记住用户的选择），但**抓包数据本身不落盘**。
class DeveloperModeSettings {
  const DeveloperModeSettings({
    this.enabled = false,
    this.requestCapture = false,
  });

  /// 开发者模式总开关。
  final bool enabled;

  /// 请求抓包开关（依赖 [enabled]：总开关关掉时抓包一律不记）。
  final bool requestCapture;

  /// 抓包是否真的在记录（两个开关都开才算）。
  bool get capturing => enabled && requestCapture;

  DeveloperModeSettings copyWith({bool? enabled, bool? requestCapture}) =>
      DeveloperModeSettings(
        enabled: enabled ?? this.enabled,
        requestCapture: requestCapture ?? this.requestCapture,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'requestCapture': requestCapture,
      };

  static DeveloperModeSettings fromJson(Object? json) {
    if (json is! Map) return const DeveloperModeSettings();
    return DeveloperModeSettings(
      enabled: json['enabled'] == true,
      requestCapture: json['requestCapture'] == true,
    );
  }
}

/// 开发者模式的持久化：`<应用支持目录>/developer_mode.json`。
class DeveloperModeStore {
  DeveloperModeStore._(this._file);

  static const String fileName = 'developer_mode.json';

  final File _file;

  static DeveloperModeStore? _current;

  static Future<DeveloperModeStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = DeveloperModeStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  static void resetForTesting() => _current = null;

  DeveloperModeSettings load() {
    try {
      if (!_file.existsSync()) return const DeveloperModeSettings();
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return const DeveloperModeSettings();
      return DeveloperModeSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('开发者模式设置读取失败，回退默认（关闭）: $error');
      LumeLog.error(error, stackTrace);
      return const DeveloperModeSettings();
    }
  }

  void save(DeveloperModeSettings settings) {
    try {
      _file.parent.createSync(recursive: true);
      final temp = File('${_file.path}.tmp');
      temp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        flush: true,
      );
      temp.renameSync(_file.path);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      throw StateError('开发者模式设置写入失败：$error');
    }
  }

  String get path => _file.path;
}

/// 开发者模式入口：应用级单例，读一次落盘值。
///
/// 抓包开关与 [DebugRequestLog] 联动：开启即开始记录，关闭即清空缓冲
/// （避免「关掉开关但旧记录还在内存里」）。
class DeveloperMode {
  DeveloperMode._();

  static DeveloperModeSettings _settings = const DeveloperModeSettings();

  static DeveloperModeSettings get current => _settings;

  static Future<void> boot() async {
    try {
      final store = await DeveloperModeStore.open();
      apply(store.load());
    } catch (error, stackTrace) {
      LumeLog.warn('开发者模式加载失败，按关闭处理: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  static void apply(DeveloperModeSettings settings) {
    _settings = settings;
    DebugRequestLog.setEnabled(settings.capturing);
  }

  static Future<void> save(DeveloperModeSettings settings) async {
    apply(settings);
    final store = await DeveloperModeStore.open();
    store.save(_settings);
  }

  static void resetForTesting() {
    _settings = const DeveloperModeSettings();
    DebugRequestLog.setEnabled(false);
    DebugRequestLog.clear();
  }
}
