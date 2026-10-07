import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// 全局壳层设置：底部导航栏（5 个主 Tab）是否显示。
///
/// ## 为什么需要一个「恢复入口」
///
/// 5 个 Tab 是 App 的**顶层导航**。把它整块藏掉而不给回来的路，用户会被困在
/// 当前板块里——在小说页就再也点不到设置、换不了板块。因此本设置只决定
/// **默认是否显示**；隐藏时壳层会留一个很小的悬浮按钮（见 `AppShell`），
/// 点它就能把导航栏召唤回来。这条是硬约束，不是可选项。
///
/// ## 作用范围
///
/// 只作用于**移动端的底部 Dock**。桌面端（Windows / macOS / Linux）用的是左侧
/// NavigationRail，那是桌面端的标准布局，不受本设置影响。
class ShellSettings {
  const ShellSettings({this.dockEnabled = true});

  /// 是否显示底部导航栏。默认显示（与历史行为一致）。
  final bool dockEnabled;

  ShellSettings copyWith({bool? dockEnabled}) =>
      ShellSettings(dockEnabled: dockEnabled ?? this.dockEnabled);

  Map<String, Object?> toJson() => <String, Object?>{'dockEnabled': dockEnabled};

  static ShellSettings fromJson(Object? json) {
    if (json is! Map) return const ShellSettings();
    // 缺项按默认（显示）：旧配置或坏配置都不会让导航栏消失。
    return ShellSettings(dockEnabled: json['dockEnabled'] != false);
  }

  @override
  bool operator ==(Object other) =>
      other is ShellSettings && other.dockEnabled == dockEnabled;

  @override
  int get hashCode => dockEnabled.hashCode;
}

/// 全局壳层设置的持久化：`<应用支持目录>/shell_settings.json`。
class ShellSettingsStore {
  ShellSettingsStore._(this._file);

  static const String fileName = 'shell_settings.json';

  final File _file;

  static ShellSettingsStore? _current;

  static Future<ShellSettingsStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = ShellSettingsStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  /// 仅测试用：清掉实例缓存（换目录后重新打开）。
  static void resetForTesting() => _current = null;

  ShellSettings load() {
    try {
      if (!_file.existsSync()) return const ShellSettings();
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return const ShellSettings();
      return ShellSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('壳层设置读取失败，回退默认（显示导航栏）: $error');
      LumeLog.error(error, stackTrace);
      return const ShellSettings();
    }
  }

  void save(ShellSettings settings) {
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
      throw StateError('壳层设置写入失败：$error');
    }
  }

  String get path => _file.path;
}

/// 壳层设置的应用级入口。
///
/// 做成 [ChangeNotifier] 而不是纯静态值：设置页改了开关，**导航壳要立刻重建**
/// （它就是被改的那个东西）。设置页与壳在同一个 Navigator 里、是父子关系，
/// 用监听比「退出设置页时再读一次」可靠——后者在设置页被 push 到别的路由时
/// 会漏掉刷新。
class ShellSettingsController extends ChangeNotifier {
  ShellSettingsController._();

  static final ShellSettingsController instance = ShellSettingsController._();

  ShellSettings _settings = const ShellSettings();

  ShellSettings get settings => _settings;

  /// 底部导航栏是否应当显示。
  bool get dockEnabled => _settings.dockEnabled;

  /// 启动时读一次落盘值。失败不阻断启动（回退显示）。
  Future<void> boot() async {
    try {
      final store = await ShellSettingsStore.open();
      _settings = store.load();
      notifyListeners();
    } catch (error, stackTrace) {
      LumeLog.warn('壳层设置加载失败，按显示处理: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 切换并落盘。写盘失败时**仍然生效**（本次运行按新值），只记日志——
  /// 一个偏好项写不进去，不该让开关看起来「点了没反应」。
  Future<void> setDockEnabled(bool enabled) async {
    if (_settings.dockEnabled == enabled) return;
    _settings = _settings.copyWith(dockEnabled: enabled);
    notifyListeners();
    try {
      final store = await ShellSettingsStore.open();
      store.save(_settings);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('底部导航栏设置写盘失败，本次运行仍按新值生效');
    }
  }

  /// 仅测试用：复位到默认并清缓存。
  @visibleForTesting
  void resetForTesting() {
    _settings = const ShellSettings();
    ShellSettingsStore.resetForTesting();
    notifyListeners();
  }

  /// 仅测试用：直接设值（不落盘）。
  @visibleForTesting
  void applyForTesting(ShellSettings settings) {
    _settings = settings;
    notifyListeners();
  }
}
