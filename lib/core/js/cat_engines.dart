/// 猫源引擎的平台门、选择与持久化（只有猫源板块有这套概念）。
///
/// 平台矩阵（任务书第 1、2、4 条）：
/// - Android：QuickJS-NG / Node-Mobile 二选一（运行时分支），**只有这里显示切换项**；
/// - iOS：仅 QuickJS-NG，切换项隐藏；
/// - 其他平台：没有引擎 → 猫源板块维持骨架。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../db/section_database.dart';
import '../session/section.dart';
import '../session/section_scope.dart';
import 'node_mobile_engine.dart';
import 'source_engine.dart';

/// 猫源引擎的平台门。
class CatEngines {
  const CatEngines._();

  /// 测试用的平台覆盖（与 `Qjs.overrideLibrary` 同一套做法）：
  /// 'android' / 'ios'；为空时看真实平台。
  @visibleForTesting
  static String? debugPlatformOverride;

  static bool get isAndroid => debugPlatformOverride != null
      ? debugPlatformOverride == 'android'
      : Platform.isAndroid;

  static bool get isIOS => debugPlatformOverride != null
      ? debugPlatformOverride == 'ios'
      : Platform.isIOS;

  /// 本平台可选的引擎（Android 两个、iOS 一个、其余空）。
  static List<CatEngineKind> get choices {
    if (isAndroid) {
      return const <CatEngineKind>[
        CatEngineKind.quickjs,
        CatEngineKind.nodeMobile,
      ];
    }
    if (isIOS) return const <CatEngineKind>[CatEngineKind.quickjs];
    return const <CatEngineKind>[];
  }

  /// 猫源板块在本平台是否有可用引擎（没有 → 板块维持骨架）。
  ///
  /// Android 只要有登记引擎就算可用（Node-Mobile 的原生就绪由探测确认）；
  /// iOS 要求 QuickJS 原生库确实可加载，否则与既有的骨架口径一致。
  static bool get available {
    if (isAndroid) return choices.isNotEmpty;
    if (isIOS) return SourceEngineRegistry.isAvailable(CatEngineKind.quickjs);
    return false;
  }

  /// 引擎切换项是否显示：**只有 Android 显示**，且只属于猫源板块
  /// （任务书第 4 条：其他系统隐藏该设置项）。
  static bool showsEngineSwitch(Section section) =>
      section == Section.cat && isAndroid && available;

  /// 异步探测各引擎的真实就绪情况（设置页据此标注「不可用」）。
  static Future<Map<CatEngineKind, bool>> probeAvailability() async {
    final result = <CatEngineKind, bool>{};
    for (final kind in choices) {
      switch (kind) {
        case CatEngineKind.quickjs:
          result[kind] = SourceEngineRegistry.isAvailable(kind);
        case CatEngineKind.nodeMobile:
          result[kind] = isAndroid &&
              await NodeMobileEngine(sourceId: '__probe__').isSupported();
      }
    }
    return result;
  }
}

/// 猫源引擎选择的持久化：落在**猫源板块自己的图源库**里（与图源同库同板块，
/// 隔离沿用既有机制：板块目录 + 库内自证 + 写入拦截）。
class CatEngineSettings {
  CatEngineSettings._(this._database);

  /// 设置键（与 `current_source` 同一张 KV 表）。
  static const String key = 'cat.engine';

  /// 由图源注册表持有的库句柄：本类只读写，不负责释放。
  final SectionDatabase _database;

  /// 打开猫源板块的图源库（与图源注册表共用同一实例）。
  static Future<CatEngineSettings> open() async => CatEngineSettings._(
        await SectionDatabase.open(await SectionScope.open(Section.cat)),
      );

  /// 读取选择；未设置 / 值非法 / 平台不支持时回退 QuickJS。
  CatEngineKind load() => resolve(_database.setting(key));

  /// 写回选择。
  void save(CatEngineKind kind) => _database.setSetting(key, kind.id);

  /// 落库值 → 引擎种类（带平台与合法性回退）。
  static CatEngineKind resolve(String? raw) {
    final kind = CatEngineKind.fromId(raw);
    return CatEngines.choices.contains(kind) ? kind : CatEngineKind.quickjs;
  }

  /// 某板块该用哪个引擎：只有猫源读自己的选择，其余板块恒为 QuickJS。
  ///
  /// 图源注册表（Phase1）在造引擎前调用这一句完成运行时分支。
  static CatEngineKind engineKindFor(
    Section section,
    SectionDatabase database,
  ) =>
      section == Section.cat
          ? resolve(database.setting(key))
          : CatEngineKind.quickjs;
}
