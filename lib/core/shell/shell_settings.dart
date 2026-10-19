import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../session/section.dart';
import '../util/lume_log.dart';
import 'dock_liquid_settings.dart';
export 'dock_liquid_settings.dart';

/// 底部导航栏里的一个页签（稳定标识 + 展示名）。
///
/// 标识与展示名分开：标识用于落盘与匹配（改文案不影响用户配置），
/// 展示名只用于界面。四个板块的展示名取自 [Section.label]（视频板块显示
/// 「视频」，底层标识仍是 `video`）。
class ShellTab {
  const ShellTab(this.id, this.label);

  final String id;
  final String label;

  /// 全部页签的**规范顺序**（也是首次安装的默认顺序）。
  ///
  /// 用户拖拽只改「显示顺序」，不改这个规范顺序——它决定了新页签将来插入的
  /// 位置，也让「恢复默认」有据可依。
  static const List<ShellTab> all = <ShellTab>[
    ShellTab('novel', '小说'),
    ShellTab('comic', '漫画'),
    ShellTab('video', '视频'),
    ShellTab('cat', '猫源'),
    ShellTab('settings', '设置'),
  ];

  /// 设置页的标识。它在「隐藏后就进不去管理页」这件事上有特殊地位，
  /// 见 [ShellSettings.settingsTabId] 的说明。
  static const String settingsId = 'settings';

  static ShellTab? byId(String id) {
    for (final tab in all) {
      if (tab.id == id) return tab;
    }
    return null;
  }
}

/// 一个页签的用户配置：是否显示。
class ShellTabConfig {
  const ShellTabConfig({required this.id, this.visible = true});

  final String id;
  final bool visible;

  ShellTabConfig copyWith({bool? visible}) =>
      ShellTabConfig(id: id, visible: visible ?? this.visible);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'visible': visible,
  };

  static ShellTabConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    return ShellTabConfig(id: id, visible: json['visible'] != false);
  }
}

/// 底部 Dock 收起后，左下角悬浮球的样式。
enum DockHandleStyle {
  /// 灵动箭头：圆角箭头 + 主题渐变毛玻璃。
  arrow('arrow'),

  /// 精致网格：9 个圆点 + 白色玻璃。
  grid('grid'),

  /// 极简线条：三条加粗圆润横线 + 半透明玻璃。
  lines('lines');

  const DockHandleStyle(this.id);

  final String id;

  static DockHandleStyle fromId(Object? id) {
    for (final style in values) {
      if (style.id == id) return style;
    }
    return DockHandleStyle.lines;
  }

  String get label => switch (this) {
    DockHandleStyle.arrow => '灵动箭头',
    DockHandleStyle.grid => '精致网格',
    DockHandleStyle.lines => '极简线条',
  };

  String get description => switch (this) {
    DockHandleStyle.arrow => '圆角箭头 + 主题渐变毛玻璃',
    DockHandleStyle.grid => '九点网格 + 白色玻璃与轻阴影',
    DockHandleStyle.lines => '三横线 + 半透明玻璃（主题紫线条）',
  };
}

/// 底部 Dock 的外观参数：尺寸、玻璃边缘、投影与选中动效。
///
/// 与 [FloatingModules] 的分工：
/// - 这里的参数属于「导航栏本身」（多大、多高、离底边多远、边框/阴影多亮）；
/// - 玻璃的**白度与磨砂强度**仍在 [FloatingModules]（「悬浮模块」里也能调），
///   两处读写同一个值，不存在第二份真相。
///
/// 所有取值都在 [fromJson] 里收敛到安全区间：旧配置缺字段、手改越界值都不会
/// 把导航栏画到屏幕外或压没内容。
class DockAppearance {
  const DockAppearance({
    this.horizontalMargin = 24,
    this.height = 54,
    this.safeGap = 4,
    this.borderOpacity = .4,
    this.shadowOpacity = .05,
    this.animateSelection = true,
    this.animationMs = 250,
    this.liquid = const DockLiquidSettings(),
  });

  /// 与上一轮精修后的实际取值一致：默认即「当前这版外观」。
  static const DockAppearance defaults = DockAppearance();

  /// 左右外边距（逻辑像素）。范围 0–100。
  ///
  /// 0 = 贴屏幕边缘；大值会把 Dock 收窄。壳层按剩余宽度均分页签，宽度不够时
  /// 文案走省略号、图标自动缩放，不会溢出。
  final double horizontalMargin;

  /// 内容条高度（不含手势条避让）。范围 40–150。
  ///
  /// 40 是紧凑下限：图标槽与文案会自动缩放，不会出现 RenderFlex overflow。
  final double height;

  /// 胶囊底边与系统安全区之间再留的距离。范围 -50–100。
  ///
  /// 负值会把胶囊**压进安全区并继续下沉**（-50 在 34pt 的 Home Indicator 机型上
  /// 会向屏幕外压 16pt）；正值把胶囊抬高。
  final double safeGap;

  /// 玻璃边框（1px 白色高光）的不透明度。范围 0–1。0 = 无边框。
  final double borderOpacity;

  /// 胶囊投影的不透明度（黑色，blurRadius 20）。范围 0–1。
  final double shadowOpacity;

  /// 切换页签时是否播放「水滴 / 果冻」过渡。
  final bool animateSelection;

  /// 水滴吸附的弹簧时长（毫秒）。范围 100–2000。
  ///
  /// 不是固定补间时长：壳层用它换算 [SpringSimulation] 的刚度与阻尼——数值越大
  /// 弹簧越软，吸附与回弹越慢。
  final int animationMs;
  final DockLiquidSettings liquid;

  DockAppearance copyWith({
    double? horizontalMargin,
    double? height,
    double? safeGap,
    double? borderOpacity,
    double? shadowOpacity,
    bool? animateSelection,
    int? animationMs,
    DockLiquidSettings? liquid,
  }) => DockAppearance(
    horizontalMargin: horizontalMargin ?? this.horizontalMargin,
    height: height ?? this.height,
    safeGap: safeGap ?? this.safeGap,
    borderOpacity: borderOpacity ?? this.borderOpacity,
    shadowOpacity: shadowOpacity ?? this.shadowOpacity,
    animateSelection: animateSelection ?? this.animateSelection,
    animationMs: animationMs ?? this.animationMs,
    liquid: liquid ?? this.liquid,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'horizontalMargin': horizontalMargin,
    'height': height,
    'safeGap': safeGap,
    'borderOpacity': borderOpacity,
    'shadowOpacity': shadowOpacity,
    'animateSelection': animateSelection,
    'animationMs': animationMs,
    'liquid': liquid.toJson(),
  };

  static DockAppearance fromJson(Object? json) {
    if (json is! Map) return defaults;
    double read(String key, double fallback, double min, double max) {
      final raw = json[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    final rawMs = json['animationMs'];
    return DockAppearance(
      liquid: DockLiquidSettings.fromJson(json['liquid']),
      horizontalMargin: read('horizontalMargin', 24, 0, 100),
      height: read('height', 54, 40, 150),
      safeGap: read('safeGap', 4, -50, 100),
      borderOpacity: read('borderOpacity', .4, 0, 1),
      shadowOpacity: read('shadowOpacity', .05, 0, 1),
      animateSelection: json['animateSelection'] != false,
      animationMs: rawMs is num && rawMs.isFinite
          ? rawMs.toInt().clamp(100, 2000)
          : 250,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! DockAppearance) return false;
    return other.horizontalMargin == horizontalMargin &&
        other.height == height &&
        other.safeGap == safeGap &&
        other.borderOpacity == borderOpacity &&
        other.shadowOpacity == shadowOpacity &&
        other.animateSelection == animateSelection &&
        other.animationMs == animationMs &&
        other.liquid == liquid;
  }

  @override
  int get hashCode => Object.hash(
    horizontalMargin,
    height,
    safeGap,
    borderOpacity,
    shadowOpacity,
    animateSelection,
    animationMs,
    liquid,
  );
}

/// 全局壳层设置：底部导航栏的**每个页签是否显示**与**显示顺序**。
class ShellSettings {
  const ShellSettings({
    this.tabs = _defaultTabs,
    this.handleStyle = DockHandleStyle.lines,
    this.appearance = DockAppearance.defaults,
  });

  static const List<ShellTabConfig> _defaultTabs = <ShellTabConfig>[
    ShellTabConfig(id: 'novel'),
    ShellTabConfig(id: 'comic'),
    ShellTabConfig(id: 'video'),
    ShellTabConfig(id: 'cat'),
    ShellTabConfig(id: 'settings'),
  ];

  /// 按**显示顺序**排列的页签配置。
  final List<ShellTabConfig> tabs;

  /// 导航栏滚动收起时，左下角悬浮球的样式。
  final DockHandleStyle handleStyle;

  /// 尺寸、玻璃边缘、投影与选中动效（管理页可调，壳层实时读取）。
  final DockAppearance appearance;

  /// 可见的页签（按显示顺序）。
  List<ShellTabConfig> get visibleTabs =>
      tabs.where((tab) => tab.visible).toList(growable: false);

  /// 可见页签数。
  int get visibleCount => visibleTabs.length;

  bool isVisible(String id) {
    for (final tab in tabs) {
      if (tab.id == id) return tab.visible;
    }
    return false;
  }

  /// 设置页是否可见。隐藏时壳层要留恢复入口（见类文档的硬约束 2）。
  bool get settingsVisible => isVisible(ShellTab.settingsId);

  /// 某个页签当前是否**允许**被关掉。
  ///
  /// 只有「它是最后一个可见页签」时才不允许——那正是「至少保留 1 个」。
  bool canHide(String id) {
    if (!isVisible(id)) return true; // 已经隐藏的，再关一次是幂等的
    return visibleCount > 1;
  }

  /// 关掉最后一个可见页签时的可读原因（管理页直接展示）。
  static const String lastTabMessage = '至少要保留 1 个页签，否则底部导航就空了';

  /// 切换某个页签的显示。违反「至少保留 1 个」时返回 false 且**不改动**。
  ///
  /// 返回新设置（成功）或 null（被拒），调用方据此提示。
  ShellSettings? withVisible(String id, bool visible) {
    if (!visible && !canHide(id)) return null;
    final next = <ShellTabConfig>[];
    var found = false;
    for (final tab in tabs) {
      if (tab.id == id) {
        found = true;
        next.add(tab.copyWith(visible: visible));
      } else {
        next.add(tab);
      }
    }
    if (!found) return null;
    return ShellSettings(
      tabs: next,
      handleStyle: handleStyle,
      appearance: appearance,
    );
  }

  /// 拖拽排序：把第 [from] 项移到**最终位置** [to]。
  ///
  /// **语义是「移动后的下标」**，与 `ReorderableListView.onReorderItem` 一致
  /// （那个回调已经替调用方把 newIndex 按「先移除再插入」调整过）。
  ///
  /// 用旧版 `onReorder` 的**原始下标**语义会差一行：它给的 newIndex 是按
  /// 移动前的列表算的，向下拖时要在调用方减一。这里刻意只提供一种语义，
  /// 免得同一个函数在不同调用点被理解成两回事。
  ShellSettings withMove(int from, int to) {
    if (from < 0 || from >= tabs.length) return this;
    var target = to;
    if (target < 0) target = 0;
    if (target >= tabs.length) target = tabs.length - 1;
    if (target == from) return this;
    final next = List<ShellTabConfig>.of(tabs);
    final moved = next.removeAt(from);
    next.insert(target, moved);
    return ShellSettings(
      tabs: next,
      handleStyle: handleStyle,
      appearance: appearance,
    );
  }

  /// 切换收起悬浮球样式。
  ShellSettings withHandleStyle(DockHandleStyle style) {
    if (style == handleStyle) return this;
    return ShellSettings(
      tabs: tabs,
      handleStyle: style,
      appearance: appearance,
    );
  }

  /// 切换外观参数（尺寸 / 玻璃边缘 / 投影 / 动效）。
  ShellSettings withAppearance(DockAppearance appearance) {
    if (appearance == this.appearance) return this;
    return ShellSettings(
      tabs: tabs,
      handleStyle: handleStyle,
      appearance: appearance,
    );
  }

  /// 恢复默认顺序与可见性（全部显示、规范顺序），外观参数保持不变。
  ShellSettings withDefaultTabs() => ShellSettings(appearance: appearance);

  /// 恢复默认顺序与可见性（全部显示、规范顺序）。
  static const ShellSettings defaults = ShellSettings();

  Map<String, Object?> toJson() => <String, Object?>{
    'tabs': <Object?>[for (final tab in tabs) tab.toJson()],
    'handleStyle': handleStyle.id,
    'appearance': appearance.toJson(),
  };

  /// 从落盘 JSON 还原。
  ///
  /// 三种情况都要兜住，且**任何异常都不能让导航栏消失**：
  /// - 旧格式（上一版的 `{dockEnabled: bool}`）：那份设置只有一个总开关，
  ///   与现在的「逐项 + 顺序」模型不同构，无法迁移。此时回退默认（全部显示）
  ///   ——「把导航栏藏起来」这个语义在新模型里不再合法（至少保留 1 个），
  ///   强行映射只会得到一个更让人困惑的状态。
  /// - 缺页签 / 多页签 / 未知 id：以 [ShellTab.all] 为准做**补全与过滤**
  ///   （新版本加了页签要能自动出现，旧配置里的陌生 id 要能忽略）。
  /// - 可见性全 false：回退默认，避免出现空的导航栏。
  static ShellSettings fromJson(Object? json) {
    if (json is! Map) return defaults;
    final raw = json['tabs'];
    if (raw is! List) return defaults;

    final parsed = <ShellTabConfig>[];
    for (final item in raw) {
      final config = ShellTabConfig.fromJson(item);
      // 过滤未知 id：配置里可能出现旧版本遗留或手改的陌生页签。
      if (config == null || ShellTab.byId(config.id) == null) continue;
      // 去重：同一 id 只认第一次出现。
      if (parsed.any((existing) => existing.id == config.id)) continue;
      parsed.add(config);
    }
    if (parsed.isEmpty) return defaults;

    // 补全：规范表里有、配置里没有的页签，按规范顺序追加到末尾（默认显示）。
    for (final tab in ShellTab.all) {
      if (parsed.any((existing) => existing.id == tab.id)) continue;
      parsed.add(ShellTabConfig(id: tab.id));
    }

    if (parsed.every((tab) => !tab.visible)) return defaults;
    return ShellSettings(
      tabs: parsed,
      handleStyle: DockHandleStyle.fromId(json['handleStyle']),
      appearance: DockAppearance.fromJson(json['appearance']),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! ShellSettings) return false;
    if (other.handleStyle != handleStyle) return false;
    if (other.appearance != appearance) return false;
    if (other.tabs.length != tabs.length) return false;
    for (var i = 0; i < tabs.length; i++) {
      if (other.tabs[i].id != tabs[i].id) return false;
      if (other.tabs[i].visible != tabs[i].visible) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    handleStyle,
    appearance,
    Object.hashAll(tabs.map((tab) => Object.hash(tab.id, tab.visible))),
  );
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
      if (!_file.existsSync()) return ShellSettings.defaults;
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return ShellSettings.defaults;
      return ShellSettings.fromJson(jsonDecode(text));
    } catch (error, stackTrace) {
      LumeLog.warn('壳层设置读取失败，回退默认（全部显示）: $error');
      LumeLog.error(error, stackTrace);
      return ShellSettings.defaults;
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
/// 做成 [ChangeNotifier] 而不是纯静态值：管理页改了开关 / 顺序，**导航壳要立刻
/// 重建**（它就是被改的那个东西），不需要重启或切页签。
class ShellSettingsController extends ChangeNotifier {
  ShellSettingsController._();

  static final ShellSettingsController instance = ShellSettingsController._();

  ShellSettings _settings = ShellSettings.defaults;

  ShellSettings get settings => _settings;

  /// 按显示顺序排列的页签配置。
  List<ShellTabConfig> get tabs => _settings.tabs;

  /// 可见页签的 id（按显示顺序）。
  List<String> get visibleTabIds =>
      _settings.visibleTabs.map((tab) => tab.id).toList(growable: false);

  /// 设置页是否可见（隐藏时壳层要留恢复入口）。
  bool get settingsVisible => _settings.settingsVisible;

  /// 导航栏收起时左下角悬浮球的样式。
  DockHandleStyle get handleStyle => _settings.handleStyle;

  /// 尺寸 / 玻璃边缘 / 投影 / 动效（管理页实时改，壳层实时读）。
  DockAppearance get appearance => _settings.appearance;

  /// 某个页签当前是否允许被关掉（「至少保留 1 个」）。
  bool canHide(String id) => _settings.canHide(id);

  /// 启动时读一次落盘值。失败不阻断启动（回退默认）。
  ///
  /// **有超时**：本方法在 `main()` 里被 await（首帧的导航栏要按用户配置渲染，
  /// 不能先画一份默认的再跳），因此这里绝不允许无限期挂住——平台通道一旦
  /// 不响应，超时即按默认继续启动。宁可导航栏这次回到默认，也不能白屏。
  Future<void> boot() async {
    try {
      final store = await ShellSettingsStore.open().timeout(bootTimeout);
      apply(store.load());
    } catch (error, stackTrace) {
      LumeLog.warn('壳层设置加载失败，按默认处理: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  /// 启动读盘的等待上限。正常是本地文件读，毫秒级；给足余量只为了兜住
  /// 「平台通道不响应」这种异常路径。
  static const Duration bootTimeout = Duration(seconds: 3);

  /// 直接应用（启动路径与测试用；会通知监听者）。
  void apply(ShellSettings settings) {
    if (_settings == settings) return;
    _settings = settings;
    notifyListeners();
  }

  /// 切换某个页签的显示并落盘。
  ///
  /// 返回 false 表示被「至少保留 1 个」拒绝（设置未改动）——管理页据此提示。
  Future<bool> setVisible(String id, bool visible) async {
    final next = _settings.withVisible(id, visible);
    if (next == null) return false;
    _settings = next;
    notifyListeners();
    await _persist();
    return true;
  }

  /// 拖拽排序并落盘（[to] 是移动后的最终下标）。
  Future<void> move(int from, int to) async {
    final next = _settings.withMove(from, to);
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _persist();
  }

  /// 切换收起悬浮球样式并落盘（壳层会立刻按新样式重绘）。
  Future<void> setHandleStyle(DockHandleStyle style) async {
    final next = _settings.withHandleStyle(style);
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _persist();
  }

  /// 恢复默认顺序与可见性（全部显示 + 规范顺序）；**外观参数保持不变**。
  ///
  /// 外观有自己的复位入口（管理页的「恢复材质默认」），两边分开才不会出现
  /// 「只想把页签全部打开，结果连调好的玻璃参数也被清掉」。
  Future<void> restoreDefaults() async {
    final next = _settings.withDefaultTabs();
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _persist();
  }

  /// 修改外观参数。滑块拖动时传 `persist: false` 只更新内存与界面，
  /// 松手（`onChangeEnd`）再走 [saveAppearance] 落盘——避免每一帧都写文件。
  Future<void> setAppearance(
    DockAppearance appearance, {
    bool persist = true,
  }) async {
    final next = _settings.withAppearance(appearance);
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    if (persist) await _persist();
  }

  /// 把当前外观参数落盘（滑块松手 / 开关切换后调用）。
  Future<void> saveAppearance() => _persist();

  /// 写盘。**失败不影响本次运行**（内存里已生效），只记日志——
  /// 一个偏好项写不进去，不该让用户觉得「点了没反应」。
  Future<void> _persist() async {
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
    _settings = ShellSettings.defaults;
    ShellSettingsStore.resetForTesting();
    notifyListeners();
  }
}
