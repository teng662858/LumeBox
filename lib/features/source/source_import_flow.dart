import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../core/js/source_script.dart';
import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../core/util/lume_log.dart';

/// 待导入的一条：脚本文本 + 来源标签。
///
/// 标签只用于**结果展示**（成功了看图源名，失败了就看标签，否则用户不知道
/// 是哪一条出的问题）；订阅/清单导入时 [originUrl] 非空，落库供「更新订阅源」。
class SourceImportItem {
  const SourceImportItem({
    required this.script,
    this.label = '',
    this.originUrl = '',
  });

  final String script;

  /// 来源标签：文件名 / 「订阅」/「剪贴板」/「粘贴」。
  final String label;

  /// 订阅来源地址（本地导入留空）。
  final String originUrl;

  bool get isSubscription => originUrl.trim().isNotEmpty;
}

/// 没进导入链路的一条（识别不出、是备份、是裸校验值）。
class SourceImportSkip {
  const SourceImportSkip({required this.label, required this.message});

  final String label;

  /// 可读原因（含下一步动作）。
  final String message;
}

/// 单条导入的结论。
enum SourceImportStatus {
  added('added', '已导入'),
  overwritten('overwritten', '已覆盖'),
  failed('failed', '导入失败');

  const SourceImportStatus(this.id, this.label);

  final String id;
  final String label;
}

/// 单条导入结果（成功带图源名，失败带原因）。
class SourceImportOutcome {
  const SourceImportOutcome({
    required this.label,
    required this.status,
    this.name = '',
    this.message = '',
    this.subscription = false,
  });

  /// 来源标签（失败行靠它定位是哪一条）。
  final String label;

  final SourceImportStatus status;

  /// 图源显示名（成功时有值）。
  final String name;

  /// 失败原因（失败时有值，引擎原话）。
  final String message;

  /// 来自订阅 / 清单（结果里标一下，与既有口径一致）。
  final bool subscription;

  bool get isFailure => status == SourceImportStatus.failed;

  /// 一句话结论（单条成功时的 Toast 与结果弹窗的行文本共用）。
  String describe() {
    if (isFailure) {
      return label.isEmpty ? '导入失败：$message' : '导入失败：$label — $message';
    }
    return '${status.label}：$name${subscription ? '（订阅）' : ''}';
  }
}

/// 读板块内的现有源（id → 描述符），供覆盖确认比对。
///
/// 读不到时返回空表而不是抛错：列表读不到不影响导入本身，最坏情况是覆盖前
/// 少一次确认（与既有口径一致，宁可少一次提示也不要因此导入不了）。
Future<Map<String, SourceDescriptor>> existingSources(
  SourceManager manager,
) async {
  final existing = <String, SourceDescriptor>{};
  try {
    for (final source in await manager.list()) {
      existing[source.id] = source;
    }
  } catch (error, stackTrace) {
    LumeLog.error(error, stackTrace);
  }
  return existing;
}

/// 导入前的覆盖确认：**同 id 已存在时先问一句**，避免静默把旧源换掉。
///
/// 返回 true 表示可以继续导入（没命中已有 id，或用户确认覆盖）；
/// false 表示用户取消——调用方必须**零写入**，不做半途导入。
///
/// 只对**头部注释里声明了 id**的脚本生效：只在运行时 `LumeSource` 上声明元信息的
/// 脚本，导入前无法知道 id（要起引擎跑一遍才能拿到，代价与风险都不划算），这类
/// 仍按原样直接导入，结果里会如实标成「已覆盖」而不是「已导入」。这条限制是
/// 有意的，不假装覆盖了全部情况。
Future<bool> confirmOverwrite(
  BuildContext context, {
  required List<SourceImportItem> items,
  required Map<String, SourceDescriptor> existing,
}) async {
  if (existing.isEmpty) return true;

  final hits = <({SourceDescriptor old, SourceMetadata next})>[];
  for (final item in items) {
    final metadata = SourceMetadata.parseHeader(item.script);
    if (metadata == null) continue;
    final old = existing[metadata.id];
    if (old == null) continue;
    hits.add((old: old, next: metadata));
  }
  if (hits.isEmpty) return true;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('覆盖已有源？'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final hit in hits)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '已存在源「${hit.old.name}」'
                    '${_versionArrow(hit.old.version, hit.next.version)}',
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              const SizedBox(height: 4),
              const Text(
                '脚本、名称与版本会换成新的；启停状态与网络配置（UA / Cookie / 代理）保留。',
                style: TextStyle(fontSize: 12, color: LumeTheme.muted),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(hits.length > 1 ? '全部覆盖' : '覆盖'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 「（v1.0.0 → v1.2.0）」；两边版本都空时不显示括号，避免出现「（ → ）」。
String _versionArrow(String oldVersion, String newVersion) {
  final before = oldVersion.trim();
  final after = newVersion.trim();
  if (before.isEmpty && after.isEmpty) return '';
  return '（${before.isEmpty ? '—' : before} → ${after.isEmpty ? '—' : after}）';
}

/// 导入编排：覆盖确认 → 逐条导入 → 结果弹窗（或单条成功时的 Toast）。
///
/// 返回是否有条目导入成功（调用方据此决定是否刷新列表）。
///
/// - [skipped] 是没进导入链路的一条（识别不出 / 备份 / 裸校验值），一并进结果；
/// - [notes] 是过程说明（如清单被截断、文件数超上限），显示在结果顶部；
/// - [sectionLabel] 非空时结果标题与 Toast 带上板块名（总管理页跨板块导入用）。
Future<bool> importSources(
  BuildContext context, {
  required SourceManager manager,
  required List<SourceImportItem> items,
  List<SourceImportSkip> skipped = const <SourceImportSkip>[],
  List<String> notes = const <String>[],
  String? sectionLabel,
}) async {
  if (items.isEmpty && skipped.isEmpty) return false;

  final existing = await existingSources(manager);
  if (!context.mounted) return false;
  if (!await confirmOverwrite(context, items: items, existing: existing)) {
    // 取消也要有回音：否则弹窗关了、什么都没发生，用户不知道是没导入还是失败了。
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消导入：没有写入任何源')),
      );
    }
    return false;
  }
  if (!context.mounted) return false;

  final outcomes = <SourceImportOutcome>[
    for (final skip in skipped)
      SourceImportOutcome(
        label: skip.label,
        status: SourceImportStatus.failed,
        message: skip.message,
      ),
  ];
  var succeeded = false;
  for (final item in items) {
    // 逐条兜住异常：批量导入里一条出意外，不该把后面几条一起丢掉
    // （端口约定是「失败也返回结果」，但落库 / 引擎侧的意外不该由用户买单）。
    final SourceImportResult result;
    try {
      result = await manager.importScript(
        stripScriptBom(item.script),
        originUrl: item.originUrl,
      );
    } catch (error, stackTrace) {
      LumeLog.error(error, stackTrace);
      outcomes.add(
        SourceImportOutcome(
          label: item.label,
          status: SourceImportStatus.failed,
          message: '导入异常：$error',
          subscription: item.isSubscription,
        ),
      );
      continue;
    }
    final descriptor = result.descriptor;
    if (descriptor == null) {
      outcomes.add(
        SourceImportOutcome(
          label: item.label,
          status: SourceImportStatus.failed,
          message: result.message ?? '未知原因',
          subscription: item.isSubscription,
        ),
      );
      continue;
    }
    succeeded = true;
    outcomes.add(
      SourceImportOutcome(
        label: item.label,
        status: existing.containsKey(descriptor.id)
            ? SourceImportStatus.overwritten
            : SourceImportStatus.added,
        name: descriptor.name,
        subscription: item.isSubscription,
      ),
    );
  }

  if (!context.mounted) return succeeded;
  await _report(context, outcomes: outcomes, notes: notes, sectionLabel: sectionLabel);
  return succeeded;
}

/// 结果落地：多条或含失败时给模态弹窗（能看清、能复制），单条成功只给 Toast。
///
/// 与「连通性测试结果弹窗」同一取舍：失败原因与逐条结论是排障要看的信息，
/// SnackBar 几秒就没了、长文案还没读完；单条成功则没必要拦一下。
Future<void> _report(
  BuildContext context, {
  required List<SourceImportOutcome> outcomes,
  required List<String> notes,
  String? sectionLabel,
}) async {
  final failures = outcomes.where((outcome) => outcome.isFailure).length;
  if (outcomes.length < 2 && failures == 0) {
    final line = outcomes.isEmpty ? '没有可导入的内容' : outcomes.first.describe();
    // 板块名放在前面（「猫源 · 已导入：X（订阅）」）：单条结论里已经有「（订阅）」
    // 这类括号，再往后接一个「（猫源）」会读成两层括号。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          notes.isEmpty
              ? (sectionLabel == null ? line : '$sectionLabel · $line')
              : '${notes.first}\n${sectionLabel == null ? line : '$sectionLabel · $line'}',
        ),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _ImportResultDialog(
      outcomes: outcomes,
      notes: notes,
      sectionLabel: sectionLabel,
    ),
  );
}

/// 导入结果弹窗：逐条结论 + 明细复制。
class _ImportResultDialog extends StatelessWidget {
  const _ImportResultDialog({
    required this.outcomes,
    required this.notes,
    this.sectionLabel,
  });

  final List<SourceImportOutcome> outcomes;
  final List<String> notes;
  final String? sectionLabel;

  @override
  Widget build(BuildContext context) {
    final added = outcomes
        .where((outcome) => outcome.status == SourceImportStatus.added)
        .length;
    final overwritten = outcomes
        .where((outcome) => outcome.status == SourceImportStatus.overwritten)
        .length;
    final failed = outcomes.where((outcome) => outcome.isFailure).length;

    return AlertDialog(
      title: Text(
        sectionLabel == null ? '导入结果' : '导入结果 · $sectionLabel',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '共 ${outcomes.length} 条：新增 $added · 覆盖 $overwritten · 失败 $failed',
                style: const TextStyle(fontSize: 13, color: LumeTheme.textPrimary),
              ),
              for (final note in notes) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  note,
                  style: const TextStyle(fontSize: 12, color: LumeTheme.muted),
                ),
              ],
              const SizedBox(height: 10),
              for (final outcome in outcomes)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        outcome.isFailure
                            ? Icons.error_outline
                            : outcome.status == SourceImportStatus.added
                                ? Icons.add_circle_outline
                                : Icons.sync_problem,
                        size: 16,
                        color: outcome.isFailure
                            ? LumeTheme.danger
                            : LumeTheme.success,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          outcome.describe(),
                          style: const TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            final text = <String>[
              for (final note in notes) '# $note',
              for (final outcome in outcomes) outcome.describe(),
            ].join('\n');
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('复制明细'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
