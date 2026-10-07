import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../session/section.dart';
import '../util/lume_log.dart';

/// 浏览页的布局档位（用户可选五档）。
///
/// 为什么是「档位」而不是「列数」：用户点的是「单列 / 双列 / …」这几种
/// **观感**，列表与网格的卡片内部排版本来就不一样（列表是横排大字、网格是竖排
/// 封面 + 标题），把列数当唯一参数会逼展示层到处写 if。
enum BrowseLayoutMode {
  /// 单列列表：现有样式，也是三个板块的默认。
  list('list', '单列列表', '一行一条，标题为主'),

  /// 双列网格：封面更大，适合漫画 / 视频。
  grid2('grid2', '双列网格', '封面较大，两列并排'),

  /// 三列紧凑网格：一屏看到更多。
  grid3('grid3', '三列网格', '封面较小，一屏更多'),

  /// 四列网格（用户要求）。
  grid4('grid4', '四列网格', '封面更小，一屏更密'),

  /// 五列网格（用户要求）。
  grid5('grid5', '五列网格', '最小封面，一屏最多');

  const BrowseLayoutMode(this.id, this.label, this.hint);

  /// 落盘用的稳定标识（改文案不影响用户配置）。
  final String id;

  final String label;

  /// 菜单里的副标题：说清这一档长什么样。
  final String hint;

  /// 网格列数；列表档返回 0（调用方按列表渲染）。
  int get columns => switch (this) {
        BrowseLayoutMode.list => 0,
        BrowseLayoutMode.grid2 => 2,
        BrowseLayoutMode.grid3 => 3,
        BrowseLayoutMode.grid4 => 4,
        BrowseLayoutMode.grid5 => 5,
      };

  /// 网格单元的宽高比（宽 / 高）。
  ///
  /// 列越多、单元越窄，而标题那两行文字的高度不缩——因此比例要跟着收窄，
  /// 否则窄单元里的封面会被文字挤没。数值是「封面 1.5 倍宽 + 文字预留」反推的。
  double get tileAspectRatio => switch (this) {
        BrowseLayoutMode.list => 1,
        BrowseLayoutMode.grid2 => 0.72,
        BrowseLayoutMode.grid3 => 0.62,
        BrowseLayoutMode.grid4 => 0.52,
        BrowseLayoutMode.grid5 => 0.46,
      };

  static BrowseLayoutMode? fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return null;
  }
}

/// 网格的标题呈现风格（用户要求新增「标题外置模式」）。
///
/// - [overlay]：**遮罩内置**——标题压在封面底部的深色渐变上（原样式）；
/// - [below]：**外置独立**——封面不画任何遮罩，标题放在封面**外面**的正下方，
///   与图片留一小段空白（黑色文字，浅色底上读起来最清楚）。
///
/// 三个板块共用同一个值（用户口径是「设置里切换，三块都支持」）。
enum GridTitleStyle {
  overlay('overlay', '遮罩内置标题', '标题压在封面底部的深色渐变上'),
  below('below', '外置独立标题', '封面不画遮罩，标题在图片下方（黑字）');

  const GridTitleStyle(this.id, this.label, this.hint);

  final String id;
  final String label;
  final String hint;

  static GridTitleStyle fromId(String? id) {
    for (final style in values) {
      if (style.id == id) return style;
    }
    return GridTitleStyle.overlay;
  }
}

/// 浏览页布局偏好：**按板块分别记住**（小说习惯列表、漫画习惯网格，不该互相覆盖）。
///
/// 存成 `<应用支持目录>/browse_layout.json`，形如 `{"novel":"list","comic":"grid3"}`。
/// 与壳层设置同一套做法：读失败回退默认、写失败不影响本次运行——一个布局偏好
/// 写不进去，不该让用户觉得「点了没反应」。
class BrowseLayoutSettings extends ChangeNotifier {
  BrowseLayoutSettings._();

  static final BrowseLayoutSettings instance = BrowseLayoutSettings._();

  static const String fileName = 'browse_layout.json';

  final Map<String, BrowseLayoutMode> _modes = <String, BrowseLayoutMode>{};

  /// 网格标题风格（全局一个值；与布局档位存在同一个文件里）。
  GridTitleStyle _titleStyle = GridTitleStyle.overlay;

  /// 落盘时用的保留键（不是板块 id，读的时候会被跳过）。
  static const String titleStyleKey = 'gridTitleStyle';

  File? _file;

  /// 当前网格标题风格。
  GridTitleStyle get gridTitleStyle => _titleStyle;

  /// 切换网格标题风格并落盘（三板块同时生效）。
  Future<void> setGridTitleStyle(GridTitleStyle style) async {
    if (_titleStyle == style) return;
    _titleStyle = style;
    notifyListeners();
    await _persist();
  }

  /// 用户为某板块选过的布局；没选过返回 null（由调用方决定默认档）。
  BrowseLayoutMode? modeFor(Section section) => _modes[section.id];

  /// 选用某档并落盘（立刻通知监听者，界面当场重排）。
  Future<void> setMode(Section section, BrowseLayoutMode mode) async {
    if (_modes[section.id] == mode) return;
    _modes[section.id] = mode;
    notifyListeners();
    await _persist();
  }

  /// 启动时读一次落盘值。失败/损坏一律按「没选过」处理（用各板块的默认档）。
  Future<void> boot() async {
    try {
      final base = await getApplicationSupportDirectory();
      _file = File(p.join(base.path, fileName));
      if (!_file!.existsSync()) return;
      final text = _file!.readAsStringSync().trim();
      if (text.isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      _modes.clear();
      decoded.forEach((key, value) {
        if ('$key' == titleStyleKey) {
          _titleStyle = GridTitleStyle.fromId('$value');
          return;
        }
        final mode = BrowseLayoutMode.fromId('$value');
        if (mode != null) _modes['$key'] = mode;
      });
      notifyListeners();
    } catch (error, stackTrace) {
      LumeLog.warn('浏览页布局偏好读取失败，按默认处理: $error');
      LumeLog.error(error, stackTrace);
    }
  }

  Future<void> _persist() async {
    try {
      final file = _file;
      if (file == null) return;
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.tmp');
      // 落盘写的是**稳定 id** 而不是枚举值：jsonEncode 不认枚举对象，
      // 直接编码 _modes 会抛「Converting object to an encodable object failed」，
      // 而这句异常会被下面的 catch 吞掉——表现成「设置看着生效了，重启就丢」。
      final payload = <String, String>{
        ..._modes.map((key, mode) => MapEntry(key, mode.id)),
        titleStyleKey: _titleStyle.id,
      };
      temp.writeAsStringSync(jsonEncode(payload), flush: true);
      temp.renameSync(file.path);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('浏览页布局偏好写盘失败，本次运行仍按新值生效');
    }
  }

  /// 仅测试用：复位到「没选过」并清缓存。
  @visibleForTesting
  void resetForTesting() {
    _modes.clear();
    _file = null;
    notifyListeners();
  }
}
