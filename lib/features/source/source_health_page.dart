import 'dart:convert';

import '../../core/reading/reading.dart';
import '../../core/source/source_preferences.dart';
import 'source_login_page.dart';
import 'source_preferences_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_health.dart';
import '../../core/source/source_capability_history.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';

class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({
    super.key,
    required this.section,
    required this.manager,
    required this.source,
  });
  final Section section;
  final SourceManager manager;
  final SourceDescriptor source;
  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  SourceHealthCheck? _check;
  List<SourceHealthStep> _steps = [];
  bool _running = true, _repairing = false;
  String? _lastChecked;
  String get _historyKey => 'source.health.last.${widget.source.id}';
  @override
  void initState() {
    super.initState();
    _lastChecked = ReadingLibrary.find(widget.section)?.setting(_historyKey);
    unawaited(_run());
  }

  @override
  void dispose() {
    _check?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    _check?.cancel();
    late final SourceHealthCheck check;
    check = SourceHealthCheck(
      manager: widget.manager,
      section: widget.section,
      descriptor: widget.source,
      onChanged: (steps) {
        if (mounted && identical(_check, check)) setState(() => _steps = steps);
      },
    );
    setState(() {
      _check = check;
      _steps = [];
      _running = true;
    });
    await check.run();
    if (mounted && identical(_check, check)) setState(() => _running = false);
    if (!check.cancellation.isCancelled) unawaited(saveHistory(check));
  }

  Future<void> saveHistory(SourceHealthCheck check) async {
    try {
      final library = await ReadingLibrary.open(widget.section);
      SourceCapabilityHistory.save(
        library,
        widget.source.id,
        widget.source.version,
        check.steps,
      );
      final record = library.setting(_historyKey)!;
      if (mounted) setState(() => _lastChecked = record);
    } catch (_) {
      /* Reporting remains usable when history storage is unavailable. */
    }
  }

  Future<void> repair(SourceHealthIssue issue) async {
    if (_repairing || _running) return;
    setState(() => _repairing = true);
    try {
      await repairAction(issue);
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
  }

  Future<void> repairAction(SourceHealthIssue issue) async {
    if (issue == SourceHealthIssue.parsing && widget.source.subscribed) {
      try {
        final result = await widget.manager.updateFromSubscription(
          widget.source.id,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('源更新：${result.versionChange}')));
        await _run();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('更新失败：${SourceHealthCheck.safeMessage(e)}')),
          );
        }
      }
      return;
    }
    final prefs = SourcePreferences.read(widget.section, widget.source.id);
    final url = prefs.customOrigin.isEmpty
        ? widget.source.siteUrl
        : prefs.customOrigin;
    if ((issue == SourceHealthIssue.verification ||
            issue == SourceHealthIssue.authentication) &&
        Uri.tryParse(url)?.hasScheme == true) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SourceLoginPage(
            section: widget.section,
            sourceId: widget.source.id,
            name: widget.source.name,
            url: url,
          ),
        ),
      );
      if (mounted) await _run();
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SourcePreferencesPage(
            section: widget.section,
            sourceId: widget.source.id,
            name: widget.source.name,
            siteUrl: widget.source.siteUrl,
            descriptor: widget.source,
            manager: widget.manager,
          ),
        ),
      );
    }
  }

  String repairLabel(SourceHealthIssue issue) => switch (issue) {
    SourceHealthIssue.verification => '打开网页验证',
    SourceHealthIssue.authentication => '登录站点',
    SourceHealthIssue.parsing when widget.source.subscribed => '更新源并重测',
    SourceHealthIssue.image => '检查图片与网络设置',
    _ => '打开站点设置',
  };
  String get previousCheck {
    try {
      final data = jsonDecode(_lastChecked ?? '') as Map;
      final at = DateTime.parse(data['at'] as String).toLocal();
      return '上次检测：${at.year}-${at.month}-${at.day} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '尚无历史检测记录';
    }
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '源体检',
    effectModule: GlassModule.sources,
    behindBar: true,
    actions: [
      TextButton(
        onPressed: _repairing
            ? null
            : _running
            ? () => _check?.cancel()
            : _run,
        child: Text(_running ? '停止' : '重新体检'),
      ),
    ],
    child: ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.source.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(_running ? '正在逐项检查…' : '检查结束，请查看每项结果。'),
              Text(previousCheck),
              const Text('地址解析通过不等于实际播放通过；本页不启动视频。'),
              if (ReadingLibrary.find(widget.section) case final library?)
                Text(
                  '上次实际起播：${library.setting('source.playback.last.${widget.source.id}') ?? '尚未记录'}',
                ),
              const SizedBox(height: 8),
              const Text('检查实际接口和少量图片数据，不会起播视频或下载整本内容。退出页面会停止本次体检。'),
            ],
          ),
        ),
        for (final step in _steps)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GlassCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (step.running)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    LumeIcon(
                      step.issue == SourceHealthIssue.none
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                      slot: 'source_health.result',
                      color: step.issue == SourceHealthIssue.none
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        if (step.issue != SourceHealthIssue.none)
                          Text(
                            step.issue.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        Text(step.message),
                        if (!_running &&
                            step.issue != SourceHealthIssue.none &&
                            step.issue != SourceHealthIssue.cancelled)
                          TextButton(
                            onPressed: _repairing
                                ? null
                                : () => repair(step.issue),
                            child: Text(repairLabel(step.issue)),
                          ),
                        if (step.issue.suggestion.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(step.issue.suggestion),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
