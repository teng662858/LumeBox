import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../session/section.dart';
import '../util/lume_log.dart';

/// 浏览页的布局档位（用户可选三档）。
///
/// 为什么是「档位」而不是「列数」：用户点的是「单列 / 双列 / 三列紧凑」这三种
/// **观感**，列表与网格的卡片内部排版本来就不一样（列表是横排大字、网格是竖排
/// 封面 + 标题），把列数当唯一参数会逼展示层到处写 if。
enum BrowseLayoutMode {
  /// 单列列表：现有样式，也是三个板块的默认。
  list('list', '单列列表', '一行一条，标题为主'),

  /// 双列网格：封面更大，适合漫画 / 视频。
  grid2('grid2', '双列网格', '封面较大，两列并排'),

  /// 三列紧凑网格：一屏看到更多。
  grid3('grid3', '三列网格', '封面较小，一屏更多');

  const BrowseLayoutMode(this.id, this.label, this.hint);

  /// 落盘用的稳定标识（改文案不影响用户配置）。
  final String id;

  final String label;

  /// 菜单里的副标题：说清这一档长什么样。
  final String hint;

  static BrowseLayoutMode? fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return null;
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

  File? _file;

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
      final payload = _modes.map((key, mode) => MapEntry(key, mode.id));
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
