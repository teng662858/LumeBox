import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// 主题色档位（11 种，用户点名的那一份）。
///
/// 只做「主色」一个维度：全局色板的结构（底色 / 卡片 / 文字 / 玻璃）两套亮度各
/// 一套固定值，换主题色只换 [accent] 及其衍生色——这样「换主题色」在任何一种
/// 颜色下都仍然是同一套可读性（对比度、层级不随颜色漂移）。
enum ThemeAccent {
  pink('pink', '粉红色', 0xFFE8629B),
  ruby('ruby', '红宝石', 0xFFD3405A),
  terracotta('terracotta', '赤陶', 0xFFC4664A),
  sakura('sakura', '樱花', 0xFFE79BB6),
  indigo('indigo', '靛蓝', 0xFF4C6FE0),
  midnight('midnight', '午夜', 0xFF3B4A8C),
  mint('mint', '薄荷', 0xFF3FBFA0),
  sunset('sunset', '日落', 0xFFE07A3C),
  amethyst('amethyst', '紫水晶', 0xFF7C5CFF),
  gold('gold', '金色', 0xFFC9A227),
  forest('forest', '森林', 0xFF3F8F5B);

  const ThemeAccent(this.id, this.label, this.argb);

  /// 稳定标识：落库用（改名不动它）。
  final String id;

  /// 展示名（设置页那一列用的就是它）。
  final String label;

  /// 主色（浅色主题下的取值；深色主题会自动提亮，见 [colorFor]）。
  final int argb;

  /// 默认主题色：品牌紫（与既有 UI 完全一致，升级后不改变观感）。
  static const ThemeAccent fallback = ThemeAccent.amethyst;

  /// 读取落库值；无法识别时回退默认。
  static ThemeAccent fromId(String? id) {
    for (final accent in values) {
      if (accent.id == id) return accent;
    }
    return fallback;
  }

  /// 当前亮度下的实际主色。
  ///
  /// 深色主题下**提亮**（往白色混 22%）：同一个色值直接用在深底上会偏闷、
  /// 描边与文字对比度不足；提亮后 11 种颜色在深色主题下都能看清。
  Color colorFor(Brightness brightness) {
    final color = Color(argb);
    if (brightness == Brightness.light) return color;
    return Color.lerp(color, const Color(0xFFFFFFFF), 0.22) ?? color;
  }
}

/// 外观设置：亮暗模式 + 主题色。
@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.mode = ThemeMode.system,
    this.accent = ThemeAccent.fallback,
  });

  /// 亮暗模式：跟随系统 / 浅色 / 深色。
  final ThemeMode mode;

  /// 主题色。
  final ThemeAccent accent;

  static const AppearanceSettings defaults = AppearanceSettings();

  AppearanceSettings copyWith({ThemeMode? mode, ThemeAccent? accent}) =>
      AppearanceSettings(
        mode: mode ?? this.mode,
        accent: accent ?? this.accent,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.name,
        'accent': accent.id,
      };

  /// 读取落库值；坏值只影响那一项（回落默认），不让设置整块失效。
  static AppearanceSettings fromJson(Object? json) {
    if (json is! Map) return defaults;
    final mode = switch ('${json['mode'] ?? ''}') {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => defaults.mode,
    };
    return AppearanceSettings(mode: mode, accent: ThemeAccent.fromId('${json['accent']}'));
  }

  @override
  bool operator ==(Object other) =>
      other is AppearanceSettings && other.mode == mode && other.accent == accent;

  @override
  int get hashCode => Object.hash(mode, accent);
}

/// 外观设置的持久化（应用级，与板块无关）。
///
/// 与壳层设置同一套做法：应用支持目录下的一个 JSON 文件、临时文件 + rename 落盘；
/// 读不到 / 读坏了都回退默认（**不阻断启动**）。
class AppearanceSettingsStore {
  AppearanceSettingsStore._(this._file);

  static const String fileName = 'appearance_settings.json';

  final File _file;

  static AppearanceSettingsStore? _current;

  static Future<AppearanceSettingsStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = AppearanceSettingsStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  /// 仅测试用：清掉实例缓存（换目录后重新打开）。
  static void resetForTesting() => _current = null;

  AppearanceSettings load() {
    try {
      if (!_file.existsSync()) return AppearanceSettings.defaults;
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return AppearanceSettings.defaults;
      return AppearanceSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('外观设置读取失败，回退默认（跟随系统 + 品牌紫）: $error');
      LumeLog.error(error, stackTrace);
      return AppearanceSettings.defaults;
    }
  }

  void save(AppearanceSettings settings) {
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
      throw StateError('外观设置写入失败：$error');
    }
  }

  String get path => _file.path;
}

/// 外观设置的应用级入口（与 [ShellSettingsController] 同一套形态）。
///
/// 做成 [ChangeNotifier]：设置页改了亮暗或主题色，**整棵树要立刻重建**——
/// 它改的就是主题本身，不重启也不切页签就能看到效果。
class AppearanceController extends ChangeNotifier {
  AppearanceController._();

  static final AppearanceController instance = AppearanceController._();

  AppearanceSettings _settings = AppearanceSettings.defaults;
  AppearanceSettingsStore? _store;

  AppearanceSettings get settings => _settings;

  ThemeMode get mode => _settings.mode;

  ThemeAccent get accent => _settings.accent;

  /// 启动时读盘。**必须 await**（首帧就该是用户选过的主题，闪一下再变很难看），
  /// 读盘失败已在 store 内部吞掉并回默认。
  Future<void> boot() async {
    final store = await AppearanceSettingsStore.open();
    _store = store;
    _settings = store.load();
    notifyListeners();
  }

  /// 改设置：落库 + 通知重建；写库失败只记日志（已经生效的这次改动不回退）。
  void apply(AppearanceSettings next) {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    try {
      _store?.save(next);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('外观设置写库失败，本次仍按已生效的值显示');
    }
  }

  /// 仅测试用：回到默认并断开存储。
  void resetForTesting() {
    _settings = AppearanceSettings.defaults;
    _store = null;
    notifyListeners();
  }
}
