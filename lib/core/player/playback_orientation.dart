/// 播放方向偏好（用户要求：播放器里的「方向锁定」+ 全局设置里的「横屏播放」）。
///
/// 三档语义：
/// - [auto]：**按视频宽高比自动判断**——竖屏短剧（宽 < 高）进全屏时竖屏全屏，
///   普通横片照旧横屏全屏；
/// - [landscape]：强制横屏（覆盖自动判断）；
/// - [portrait]：强制竖屏（竖屏短剧想锁竖屏、或者横片也想竖着看时用）。
///
/// 存储是应用级的一个小 JSON 文件（与外观设置同一套做法），四板块共用一份——
/// 「横屏播放」是用户的观看习惯，不该按板块各存一份。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/lume_log.dart';

/// 播放方向档位。
enum PlaybackOrientation {
  auto('auto', '自动'),
  landscape('landscape', '强制横屏'),
  portrait('portrait', '强制竖屏');

  const PlaybackOrientation(this.id, this.label);

  /// 稳定标识：落库与日志用（改名不动它）。
  final String id;

  /// 展示名（设置面板里的三档芯片用的就是它）。
  final String label;

  /// 默认档：自动（升级后观感与历史一致——横片横屏、竖屏片子才竖屏）。
  static const PlaybackOrientation fallback = PlaybackOrientation.auto;

  /// 读取落库值；无法识别时回退 [fallback]。
  static PlaybackOrientation fromId(String? id) {
    for (final mode in values) {
      if (mode.id == id) return mode;
    }
    return fallback;
  }

  /// 全局设置「横屏播放」开关的取值：只有 [landscape] 视为开。
  bool get isLandscape => this == PlaybackOrientation.landscape;
}

/// 方向偏好的持久化（应用支持目录下的一个 JSON 文件）。
///
/// 读不到 / 读坏了都回退默认（**不阻断启动**）；写入走临时文件 + rename，
/// 与外观设置、壳层设置同一套做法。
class PlaybackOrientationStore {
  PlaybackOrientationStore._(this._file);

  static const String fileName = 'playback_orientation.json';

  final File _file;

  static PlaybackOrientationStore? _current;

  static Future<PlaybackOrientationStore> open() async {
    final existing = _current;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final store = PlaybackOrientationStore._(File(p.join(base.path, fileName)));
    _current = store;
    return store;
  }

  /// 仅测试用：清掉实例缓存（换目录后重新打开）。
  static void resetForTesting() => _current = null;

  PlaybackOrientation load() {
    try {
      if (!_file.existsSync()) return PlaybackOrientation.fallback;
      final text = _file.readAsStringSync();
      if (text.trim().isEmpty) return PlaybackOrientation.fallback;
      final json = jsonDecode(text);
      if (json is! Map) return PlaybackOrientation.fallback;
      return PlaybackOrientation.fromId('${json['orientation']}');
    } catch (error, stackTrace) {
      LumeLog.warn('播放方向设置读取失败，回退「自动」: $error');
      LumeLog.error(error, stackTrace);
      return PlaybackOrientation.fallback;
    }
  }

  void save(PlaybackOrientation orientation) {
    try {
      _file.parent.createSync(recursive: true);
      final temp = File('${_file.path}.tmp');
      temp.writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(<String, Object?>{'orientation': orientation.id}),
        flush: true,
      );
      temp.renameSync(_file.path);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      throw StateError('播放方向设置写入失败：$error');
    }
  }

  String get path => _file.path;
}

/// 方向偏好的应用级入口（与 [AppearanceController] 同一套形态）。
///
/// 做成 [ChangeNotifier]：设置页改了「横屏播放」、播放器里改了「方向锁定」，
/// 两处共用这一份值——正在播放的页面要能当场跟着换方向，不必退出重进。
class PlaybackOrientationController extends ChangeNotifier {
  PlaybackOrientationController._();

  static final PlaybackOrientationController instance =
      PlaybackOrientationController._();

  PlaybackOrientation _orientation = PlaybackOrientation.fallback;
  PlaybackOrientationStore? _store;

  PlaybackOrientation get orientation => _orientation;

  /// 启动时读盘（只影响播放行为、不影响首帧长相，因此调用方不 await）。
  Future<void> boot() async {
    final store = await PlaybackOrientationStore.open();
    _store = store;
    _orientation = store.load();
    notifyListeners();
  }

  /// 改档位：落库 + 通知；写库失败只记日志（已生效的这次改动不回退）。
  void apply(PlaybackOrientation next) {
    if (next == _orientation) return;
    _orientation = next;
    notifyListeners();
    try {
      _store?.save(next);
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      LumeLog.warn('播放方向设置写库失败，本次仍按已生效的档位播放');
    }
  }

  /// 仅测试用：回到默认并断开存储。
  void resetForTesting() {
    _orientation = PlaybackOrientation.fallback;
    _store = null;
    notifyListeners();
  }

  /// 仅测试用：接上一个已打开的存储（免去真实目录）。
  @visibleForTesting
  void useStoreForTesting(PlaybackOrientationStore store) {
    _store = store;
    _orientation = store.load();
    notifyListeners();
  }
}
