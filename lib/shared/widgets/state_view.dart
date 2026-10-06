import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import 'notice_card.dart';

/// 统一状态视图：加载中 / 空数据 / 图源已停用 / 脚本报错 / 网络异常。
///
/// 业务页、浏览面、详情页与管理页共用它；状态的分类与默认文案集中在
/// [SourceStateKind]。说明文字直接呈现数据层给出的原因（便于定位），
/// 错误与空态可以带「重试」，也可以带一个额外动作（例如「图源管理」）。
class SourceStateView extends StatelessWidget {
  const SourceStateView({
    super.key,
    required this.state,
    this.title,
    this.detail,
    this.onRetry,
    this.action,
  });

  final SourceStateKind state;

  /// 标题覆盖。为空时用状态自带的短标签。
  ///
  /// 同一个状态在不同页面需要的说法不同（例如「板块内一个图源都没有」与
  /// 「搜不到结果」都是空数据），此时由页面给出更准确的一句话。
  final String? title;

  /// 补充说明，通常是数据层的原始原因。加载态忽略。
  final String? detail;

  /// 重试入口。为空时不显示重试按钮。
  final VoidCallback? onRetry;

  /// 额外动作。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    if (state == SourceStateKind.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              state.label,
              style: const TextStyle(fontSize: 13, color: LumeTheme.muted),
            ),
          ],
        ),
      );
    }
    if (state == SourceStateKind.ready) return const SizedBox.shrink();
    return NoticeCard(
      title: title ?? state.label,
      subtitle: detail ?? _defaultDetail(state),
      action: _buildAction(),
    );
  }

  Widget? _buildAction() {
    final buttons = <Widget>[
      if (onRetry != null)
        FilledButton.tonal(
          onPressed: onRetry,
          child: const Text('重试'),
        ),
      ?action,
    ];
    if (buttons.isEmpty) return null;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: buttons,
    );
  }

  /// 没有具体原因时的默认说明。
  static String _defaultDetail(SourceStateKind state) => switch (state) {
        SourceStateKind.empty => '换个条件试试',
        SourceStateKind.disabled => '去源管理里启用它',
        SourceStateKind.scriptError => '源脚本执行失败，可重试或检查源',
        SourceStateKind.networkError => '网络请求没能完成，检查网络后重试',
        _ => LumeTheme.appName,
      };
}
