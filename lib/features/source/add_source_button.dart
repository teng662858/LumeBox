import 'package:flutter/material.dart';

import '../../core/net/source_subscription.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import 'source_import_dialog.dart';

/// 再导出：既有调用方（含测试）仍可从本文件取到该类型。
export '../../core/net/source_subscription.dart' show SourceFetchResult;

/// 板块页右上角的「+」添加源按钮（小说 / 漫画 / 视频 / 猫源统一入口）。
///
/// 弹窗本身在 [SourceImportDialog]（与「源总管理」页共用一份实现），三条通道：
/// 本地文件（可多选）/ 订阅链接 / 剪贴板；导入一律归属当前板块。
///
/// 本类只做两件事：把按钮画出来、把弹窗与导入编排接起来。覆盖确认与结果反馈
/// 都在 `source_import_flow.dart` 里，两个页面口径一致。
///
/// 隔离：按钮绑定一个板块，只写本板块的库，不提供任何跨板块入口。
class AddSourceButton extends StatelessWidget {
  const AddSourceButton({
    super.key,
    required this.section,
    this.manager,
    this.onImported,
    this.readLocalScripts,
    this.fetchSubscription,
  });

  /// 目标板块。源只写入本板块。
  final Section section;

  /// 源管理端口；为空时用本板块的正式实现。
  final SourceManager? manager;

  /// 导入全部结束且至少成功一条时回调（板块页据此刷新自己的列表 / 状态）。
  final VoidCallback? onImported;

  /// 本地文件读取端口（测试注入）；为空时弹系统文件选择器（可多选）。
  final Future<List<({String name, String text})>> Function()? readLocalScripts;

  /// 订阅拉取端口（测试注入）；为空时经宿主网络层拉取。
  final Future<SourceFetchResult> Function(String url)? fetchSubscription;

  /// 单次订阅最多解析的脚本条数（弹窗默认值，与既有口径一致）。
  static const int maxSubscriptionScripts = 20;

  @override
  Widget build(BuildContext context) {
    final target = manager ?? LumeSources.manager(section);
    // 平台边界：没有源运行时的平台（Android / Windows）没有可导入的目标，
    // 与板块页的骨架占位同一口径——按钮不出现。
    if (!target.runtimeAvailable) return const SizedBox.shrink();
    return IconButton(
      tooltip: '添加源',
      icon: const Icon(Icons.add),
      onPressed: () => _open(context, target),
    );
  }

  Future<void> _open(BuildContext context, SourceManager target) async {
    final imported = await runSourceImport(
      context,
      section: section,
      manager: target,
      readLocalScripts: readLocalScripts,
      fetchSubscription: fetchSubscription,
    );
    if (imported) onImported?.call();
  }
}
