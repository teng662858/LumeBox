import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/intro/intro_controller.dart';
import '../../core/intro/intro_models.dart';
import 'intro_settings_page.dart';

class IntroEpisodeSheet extends StatefulWidget {
  const IntroEpisodeSheet({
    super.key,
    required this.controller,
    required this.position,
    this.onRebind,
  });
  final IntroController controller;
  final Duration Function() position;
  final VoidCallback? onRebind;
  @override
  State<IntroEpisodeSheet> createState() => _IntroEpisodeSheetState();
}

class _IntroEpisodeSheetState extends State<IntroEpisodeSheet> {
  final _tmdb = TextEditingController(),
      _imdb = TextEditingController(),
      _season = TextEditingController();
  final _marks = List.generate(4, (_) => TextEditingController());
  bool _movie = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final request = widget.controller.request;
    if (request == null) return;
    final identity = request.episode;
    _tmdb.text = identity.tmdb?.toString() ?? '';
    _imdb.text = identity.imdb ?? '';
    _season.text = '${identity.season}';
    _movie = identity.movie;
    final segments = widget.controller.segments;
    for (final segment in segments) {
      final i = segment.kind == SegmentKind.opening
          ? 0
          : segment.kind == SegmentKind.ending
          ? 2
          : -1;
      if (i < 0) continue;
      _marks[i].text = _time(segment.startMs);
      _marks[i + 1].text = _time(segment.endMs);
    }
  }

  @override
  void dispose() {
    _tmdb.dispose();
    _imdb.dispose();
    _season.dispose();
    for (final field in _marks) {
      field.dispose();
    }
    super.dispose();
  }

  static String _time(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
  }

  static int? _parse(String value) {
    if (value.trim().isEmpty) return null;
    final parts = value.trim().split(':');
    if (parts.length > 3) throw const FormatException('时间格式为 分:秒 或 时:分:秒');
    var seconds = 0.0;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      final n = double.tryParse(part);
      if (n == null ||
          !n.isFinite ||
          n < 0 ||
          (index > 0 && n >= 60) ||
          (index < parts.length - 1 && n != n.floorToDouble())) {
        throw const FormatException('时间格式无效');
      }
      seconds = seconds * 60 + n;
    }
    return (seconds * 1000).round();
  }

  void _saveIdentity() {
    final request = widget.controller.request;
    if (request == null) return;
    final tmdb = _tmdb.text.trim(),
        imdb = _imdb.text.trim(),
        season = int.tryParse(_season.text);
    if ((tmdb.isNotEmpty && (int.tryParse(tmdb) ?? 0) <= 0) ||
        (imdb.isNotEmpty && !RegExp(r'^tt\d{7,9}$').hasMatch(imdb)) ||
        season == null ||
        season < 0) {
      setState(() => _error = '请检查 TMDB、IMDb 与季号');
      return;
    }
    widget.controller.store.saveIdentity(request.episode.series, {
      'tmdb': int.tryParse(tmdb),
      'imdb': imdb.isEmpty ? null : imdb,
      'season': season,
      'movie': _movie,
    });
    widget.onRebind?.call();
    setState(() => _error = null);
  }

  void _saveMarks() {
    try {
      final result = <SkipSegment>[];
      for (var i = 0; i < 4; i += 2) {
        final start = _parse(_marks[i].text), end = _parse(_marks[i + 1].text);
        if (start == null && end == null) continue;
        if (start == null || end == null) {
          throw const FormatException('每段都需要起点与终点');
        }
        final segment = SkipSegment(
          kind: i == 0 ? SegmentKind.opening : SegmentKind.ending,
          startMs: start,
          endMs: end,
          confidence: 1,
          source: 'manual',
          evidence: 'user four-point marks',
        );
        if (!segment.validFor(widget.controller.request!.durationMs)) {
          throw const FormatException('起点必须早于终点，且不能超过视频总时长');
        }
        result.add(segment);
      }
      if (result.length == 2 && result.first.endMs > result.last.startMs) {
        throw const FormatException('片头与片尾不能重叠');
      }
      widget.controller.saveManual(result);
      setState(() => _error = null);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _rememberCurrent({required bool intro}) {
    final request = widget.controller.request;
    final at = widget.position().inMilliseconds;
    if (request == null || at <= 0 || at >= request.durationMs) {
      setState(() => _error = '先播到片头结束或片尾开始的位置再记');
      return;
    }
    final i = intro ? 0 : 2;
    _marks[i].text = _time(intro ? 0 : at);
    _marks[i + 1].text = _time(intro ? at : request.durationMs);
    _saveMarks();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('片头片尾'),
      actions: [
        IconButton(
          tooltip: '全部识别设置',
          icon: const LumeIcon(Icons.tune, slot: 'intro_episode_sheet.1'),
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const IntroSettingsPage()),
          ),
        ),
      ],
    ),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.controller.status),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('不用填写作品 ID。第一次播到片头结束或片尾开始，点下面的按钮记住；同一部剧后续各集自动沿用。'),
          ),
          FilledButton.icon(
            key: const ValueKey('intro-remember-opening'),
            onPressed: () => _rememberCurrent(intro: true),
            icon: const LumeIcon(
              Icons.skip_next,
              slot: 'intro_episode_sheet.2',
            ),
            label: const Text('记住当前位置：片头结束'),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('intro-remember-ending'),
            onPressed: () => _rememberCurrent(intro: false),
            icon: const LumeIcon(
              Icons.last_page,
              slot: 'intro_episode_sheet.3',
            ),
            label: const Text('记住当前位置：片尾开始'),
          ),
          ExpansionTile(
            title: const Text('高级：社区库作品信息（选填）'),
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('社区库身份'),
                subtitle: Text(
                  '绑定本作品的真实 ID；季号保留，第几集使用当前选集序号。缺少 ID 时会继续其他识别方案。',
                ),
              ),
              TextField(
                controller: _tmdb,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'TMDB 作品 ID'),
              ),
              TextField(
                controller: _imdb,
                decoration: const InputDecoration(
                  labelText: 'IMDb 作品 ID，例如 tt0903747',
                ),
              ),
              TextField(
                controller: _season,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '季号（特别篇可用 0）'),
              ),
              SwitchListTile(
                title: const Text('这是一部电影'),
                value: _movie,
                onChanged: (v) => setState(() => _movie = v),
              ),
              FilledButton.tonal(
                onPressed: _saveIdentity,
                child: const Text('保存身份并重新查询'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('高级：精确调整起止时间'),
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('手动四点标记'),
                subtitle: Text('保存 OP 起止、ED 起止，精确到毫秒；本次打点后不会立刻跳走。'),
              ),
              for (var i = 0; i < 4; i++)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _marks[i],
                        keyboardType: TextInputType.datetime,
                        decoration: InputDecoration(
                          labelText: const [
                            'OP 起点',
                            'OP 终点',
                            'ED 起点',
                            'ED 终点',
                          ][i],
                          hintText: '0:00.000',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _marks[i].text = _time(
                        widget.position().inMilliseconds,
                      ),
                      child: const Text('当前位置'),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _saveMarks, child: const Text('保存四点标记')),
            ],
          ),
          OutlinedButton(
            onPressed: () {
              for (final field in _marks) {
                field.clear();
              }
              _saveMarks();
            },
            child: const Text('清除这部剧的跳过记忆'),
          ),
          OutlinedButton(
            onPressed: widget.controller.scanning
                ? null
                : () {
                    widget.controller.retryIdle();
                  },
            child: const Text('重试空闲预扫描（请先暂停播放）'),
          ),
          for (final segment in widget.controller.segments)
            ListTile(
              title: Text(
                '${segment.kind.name}  ${_time(segment.startMs)} → ${_time(segment.endMs)}',
              ),
              subtitle: Text(
                '${segment.source} · ${(segment.confidence * 100).toStringAsFixed(1)}%\n${segment.evidence}',
              ),
            ),
        ],
      ),
    ),
  );
}
