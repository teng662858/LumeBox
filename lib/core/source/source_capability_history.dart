import 'dart:convert';

import '../reading/reading.dart';
import 'source_health.dart';

class SourceCapabilityHistory {
  static void save(
    ReadingLibrary library,
    String sourceId,
    String version,
    List<SourceHealthStep> steps,
  ) {
    library.setSetting(
      'source.health.last.$sourceId',
      jsonEncode({
        'at': DateTime.now().toIso8601String(),
        'version': version,
        'issues': [for (final step in steps) step.issue.name],
        'steps': [
          for (final step in steps)
            {
              'title': step.title,
              'issue': step.issue.name,
              'deferred': step.message.contains('不预取'),
            },
        ],
      }),
    );
    if (steps.isNotEmpty &&
        steps.every((s) => s.issue == SourceHealthIssue.none && !s.running)) {
      library.setSetting(
        'source.health.success.$sourceId',
        DateTime.now().toIso8601String(),
      );
    }
  }

  static Map<String, dynamic>? read(ReadingLibrary library, String id) {
    try {
      return jsonDecode(library.setting('source.health.last.$id') ?? '')
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static String summary(ReadingLibrary library, String id, String version) {
    final record = read(library, id);
    final played = library.setting('source.playback.last.$id');
    final playback = played == null
        ? '实际起播：未记录'
        : '上次实际起播：${DateTime.tryParse(played)?.toLocal().toString().split('.').first ?? played}';
    if (record == null) return played == null ? '尚未分项验证' : '$playback（未做分项体检）';
    final rawSteps = record['steps'];
    final steps = (rawSteps is List ? rawSteps : []).whereType<Map>();
    final result = <String>[];
    for (final (title, label) in [
      ('运行环境与依赖', '加载'),
      ('搜索接口', '搜索'),
      ('封面图片', '封面'),
      ('目录／选集', '目录'),
      ('详情解析', '详情'),
      ('正文／播放地址解析', '地址解析'),
    ]) {
      final step = steps.where((s) => s['title'] == title).firstOrNull;
      result.add(
        '$label：${step == null
            ? '未测'
            : step['deferred'] == true
            ? '待实际加载验证'
            : step['issue'] == 'none'
            ? '通过'
            : '未通过'}',
      );
    }
    final at =
        DateTime.tryParse('${record['at']}')
            ?.toLocal()
            .toString()
            .split('.')
            .first ??
        '未知时间';
    final issues = (record['issues'] as List? ?? []);
    final auth = issues.contains('authentication')
        ? '需要登录或授权'
        : issues.contains('verification')
        ? '需要网页验证'
        : '本次检测未遇到登录要求';
    final success = library.setting('source.health.success.$id');
    return '${record['version'] != version ? '旧版本检测 · ' : ''}${result.join(' · ')}\n登录状态：$auth\n检测时间：$at\n最近检测成功：${success ?? '未记录'}\n$playback';
  }
}
