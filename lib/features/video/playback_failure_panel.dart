import 'package:flutter/material.dart';

import '../../core/js/source_web_runtime.dart';

import '../../core/player/playback_failure.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_preferences.dart';
import '../source/source_import_dialog.dart';
import '../source/waf_webview_page.dart';

/// Shared recovery for address parsing and decoder failures.
class PlaybackFailurePanel extends StatefulWidget {
  const PlaybackFailurePanel({
    super.key,
    required this.error,
    required this.retry,
    this.sourceId,
    this.manager,
    this.onUpdated,
    this.dark = false,
    this.extraActions = const [],
  });
  final Object error;
  final Future<void> Function() retry;
  final Future<void> Function()? onUpdated;
  final String? sourceId;
  final SourceManager? manager;
  final bool dark;
  final List<Widget> extraActions;
  @override
  State<PlaybackFailurePanel> createState() => _PlaybackFailurePanelState();
}

class _PlaybackFailurePanelState extends State<PlaybackFailurePanel> {
  late final SourceManager manager =
      widget.manager ?? LumeSources.manager(Section.video);
  SourceDescriptor? source;
  bool busy = false;
  String? feedback;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant PlaybackFailurePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId) {
      source = null;
      feedback = null;
      load();
    }
  }

  Future<void> load() async {
    if (widget.sourceId == null) return;
    final id = widget.sourceId;
    try {
      final rows = await manager.list();
      if (mounted && id == widget.sourceId) {
        setState(
          () => source = rows.where((s) => s.id == widget.sourceId).firstOrNull,
        );
      }
    } catch (_) {
      /* Retry still works if local metadata is unavailable. */
    }
  }

  Uri? get site {
    final row = source;
    if (row == null) return null;
    final value = row.siteConfig.resolvedDomain.isEmpty
        ? row.siteUrl
        : row.siteConfig.resolvedDomain;
    final uri = Uri.tryParse(
      SourcePreferences.read(Section.video, row.id).rewrite(value),
    );
    return uri != null &&
            const ['https', 'http'].contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => feedback = '操作未完成，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openSite() async {
    final uri = site;
    final row = source;
    if (uri == null || row == null) return;
    final kind = PlaybackFailure.from(widget.error).kind;
    if (kind == PlaybackFailureKind.login ||
        kind == PlaybackFailureKind.forbidden) {
      final outcome = await runWafWebViewFlow(
        context: context,
        section: Section.video,
        sourceId: row.id,
        sourceName: row.name,
        originUrl: uri.toString(),
        failureMessage: 'NEED_WEBVIEW_VERIFY：请在源站完成登录或验证',
      );
      if (mounted) {
        setState(
          () => feedback = outcome == WafWebViewOutcome.collected
              ? '登录或验证信息已保存，请重试播放'
              : '验证尚未完成，原有配置已保留；可再次打开源站。',
        );
      }
    } else if (await SourceWebRuntime.channel.invokeMethod<bool>(
          'openExternal',
          {'url': uri.toString()},
        ) !=
        true) {
      if (mounted) setState(() => feedback = '无法打开源站，请在浏览器中访问 ${uri.host}');
    }
  }

  Future<void> update() async {
    final row = source;
    if (row == null) return;
    if (!row.subscribed) {
      final before = await manager.exportScript(row.id);
      if (!mounted) return;
      final imported = await runSourceImport(
        context,
        section: Section.video,
        manager: manager,
        helpText: '请选择同一源的新版本文件。原有分类、置顶、排序和网络设置会保留。',
      );
      if (!imported || !mounted) return;
      final after = await manager.exportScript(row.id);
      if (before == after) {
        setState(() => feedback = '当前源没有变化；若导入了其他源，请切换后播放。');
        return;
      }
      if (widget.onUpdated != null) await widget.onUpdated!();
    } else {
      final result = await manager.updateFromSubscription(row.id);
      if (!mounted) return;
      setState(
        () => feedback = result.status == SourceUpdateStatus.updated
            ? '已更新 ${result.versionChange}，个人设置已保留，请重试播放'
            : result.status == SourceUpdateStatus.unchanged
            ? '已是最新版本，可打开源站检查内容'
            : result.message,
      );
      if (result.status == SourceUpdateStatus.updated &&
          widget.onUpdated != null) {
        await widget.onUpdated!();
      }
    }
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final failure = PlaybackFailure.from(widget.error);
    Widget body = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            failure.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(failure.hint, textAlign: TextAlign.center),
          if (feedback != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(feedback!),
            ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => run(widget.retry),
                child: const Text('重试播放'),
              ),
              SizedBox(
                width: double.infinity,
                child: ExpansionTile(
                  title: const Text('更多恢复方式'),
                  children: [
                    if (site != null)
                      TextButton(
                        onPressed: busy ? null : () => run(openSite),
                        child: const Text('打开源站'),
                      ),
                    if (failure.offerUpdate && source != null)
                      TextButton(
                        onPressed: busy ? null : () => run(update),
                        child: const Text('更新源'),
                      ),
                    ...widget.extraActions,
                  ],
                ),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          ExpansionTile(
            title: const Text('查看错误详情'),
            children: [SelectableText('${widget.error}')],
          ),
        ],
      ),
    );
    if (widget.dark) {
      body = Theme(
        data: ThemeData.dark(),
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: body,
        ),
      );
    }
    return body;
  }
}
