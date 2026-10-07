import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../reading/reading.dart';
import '../util/lume_log.dart';

/// 片头 / 片尾标记（用户要求：播放中「记一下」，下次自动跳过）。
///
/// 语义（就是用户描述的那种用法）：
/// - **片头**：在片头刚放完、正片开始的位置点「记片头」——那一点就是标记。
///   下次起播时若位置早于它，直接跳到它（跳过片头）；
/// - **片尾**：在片尾开始的位置点「记片尾」——到了它就直接进下一集
///   （没有下一集时跳到结尾）。
///
/// 标记按**作品**存（同一部剧的每一集共用一套），因为片头片尾时长通常一致；
/// 想逐集不同的话，用户在那一集重新记一次即可（覆盖同一部作品的标记）。
@immutable
class SkipMarks {
  const SkipMarks({this.intro, this.outro});

  /// 片头结束点（跳过它之前的内容）。
  final Duration? intro;

  /// 片尾开始点（到这里就跳下一集 / 结尾）。
  final Duration? outro;

  static const SkipMarks none = SkipMarks();

  bool get isEmpty => intro == null && outro == null;
  bool get hasIntro => intro != null;
  bool get hasOutro => outro != null;

  SkipMarks copyWith({Duration? intro, Duration? outro, bool clearIntro = false, bool clearOutro = false}) =>
      SkipMarks(
        intro: clearIntro ? null : (intro ?? this.intro),
        outro: clearOutro ? null : (outro ?? this.outro),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (intro != null) 'introMs': intro!.inMilliseconds,
        if (outro != null) 'outroMs': outro!.inMilliseconds,
      };

  /// 宽容解析：坏值只影响那一项。
  static SkipMarks fromJson(Object? json) {
    if (json is! Map) return none;
    Duration? at(Object? value) {
      final ms = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
      if (ms == null || ms <= 0) return null;
      return Duration(milliseconds: ms);
    }

    return SkipMarks(intro: at(json['introMs']), outro: at(json['outroMs']));
  }

  @override
  bool operator ==(Object other) =>
      other is SkipMarks && other.intro == intro && other.outro == outro;

  @override
  int get hashCode => Object.hash(intro, outro);

  @override
  String toString() => 'SkipMarks(intro: $intro, outro: $outro)';
}

/// 标记的持久化：按作品存在**本板块阅读库**的设置表里（键带 itemId）。
///
/// 为什么放阅读库而不是新表：它和播放进度是同一类数据（跟着作品走、按板块隔离），
/// 复用既有存储就不用动 schema，也不会在升级时丢。
class SkipMarksStore {
  SkipMarksStore(this.library);

  final ReadingLibrary library;

  static const String keyPrefix = 'skip.marks.';

  static String keyFor(String itemId) => '$keyPrefix$itemId';

  SkipMarks load(String itemId) {
    final raw = library.setting(keyFor(itemId));
    if (raw == null || raw.trim().isEmpty) return SkipMarks.none;
    try {
      return SkipMarks.fromJson(jsonDecode(raw));
    } catch (error) {
      LumeLog.warn('[skip] $itemId 的片头片尾标记解析失败：$error');
      return SkipMarks.none;
    }
  }

  void save(String itemId, SkipMarks marks) {
    library.setSetting(
      keyFor(itemId),
      marks.isEmpty ? '' : jsonEncode(marks.toJson()),
    );
  }

  void clear(String itemId) => library.setSetting(keyFor(itemId), '');
}

/// 跳过的动作。
enum SkipAction {
  /// 不跳。
  none,

  /// 跳到某个位置（片头结束点 / 结尾）。
  seek,

  /// 直接进下一集（片尾到点且还有下一集）。
  advance,
}

/// 一次「跳过判定」的结果。
@immutable
class SkipOutcome {
  const SkipOutcome._(this.action, [this.position]);

  const SkipOutcome.none() : this._(SkipAction.none);
  const SkipOutcome.seekTo(Duration position) : this._(SkipAction.seek, position);
  const SkipOutcome.advance() : this._(SkipAction.advance);

  final SkipAction action;

  /// [SkipAction.seek] 时的目标位置。
  final Duration? position;

  @override
  bool operator ==(Object other) =>
      other is SkipOutcome &&
      other.action == action &&
      other.position == position;

  @override
  int get hashCode => Object.hash(action, position);
}

/// 播放中「该不该跳、跳到哪」的判定（纯函数：好测，也不掺 UI）。
///
/// 三条边界（都是刻意的）：
/// 1. **片头只在起播时判一次**（[introHandled]）：用户可能刻意拖回片头看，
///    每次都把他弹回去就变成了「拉不动进度条」；
/// 2. **片尾到点就跳**：还有下一集就进下一集，没有就跳到结尾；
/// 3. 标记越界（为 0 / 大于时长）不生效——不拿坏数据折腾播放器。
class SkipDecision {
  const SkipDecision._();

  static SkipOutcome resolve({
    required SkipMarks marks,
    required Duration position,
    required Duration duration,
    required bool introEnabled,
    required bool outroEnabled,
    required bool introHandled,
    required bool hasNext,
  }) {
    final intro = marks.intro;
    if (introEnabled &&
        !introHandled &&
        intro != null &&
        intro > Duration.zero &&
        position < intro &&
        (duration <= Duration.zero || intro < duration)) {
      return SkipOutcome.seekTo(intro);
    }
    final outro = marks.outro;
    if (outroEnabled &&
        outro != null &&
        outro > Duration.zero &&
        position >= outro &&
        (duration <= Duration.zero || outro < duration)) {
      if (hasNext) return const SkipOutcome.advance();
      if (duration > Duration.zero) return SkipOutcome.seekTo(duration);
    }
    return const SkipOutcome.none();
  }
}
