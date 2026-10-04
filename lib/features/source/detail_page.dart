import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/state_view.dart';

/// 详情页：作品信息 + 章节列表，全部经统一数据源接口取得。
///
/// Phase1 到此为止——章节仅展示，不进入阅读器（漫画阅读器、小说阅读器属 Phase2）。
/// 章节内容接口（[DataSource.content]）已在接口层就绪，但本页不消费它。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.dataSource, required this.item});

  final DataSource dataSource;
  final SourceItem item;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  SourceDetail? _detail;
  List<SourceChapter> _chapters = const <SourceChapter>[];
  bool _loading = true;
  SourceException? _failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final detail = await widget.dataSource.detail(widget.item.id);
      final chapters = await widget.dataSource.chapters(widget.item.id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _chapters = chapters;
        _loading = false;
      });
    } catch (error) {
      if (error is! SourceException) rethrow;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return GlassScaffold(
        title: _title,
        child: const SourceStateView(state: SourceStateKind.loading),
      );
    }
    final failure = _failure;
    if (failure != null) {
      return GlassScaffold(
        title: _title,
        child: SourceStateView(
          state: stateForError(failure),
          detail: failure.message,
          onRetry: _load,
        ),
      );
    }
    final detail = _detail;
    return GlassScaffold(
      title: _title,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          GlassCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  detail?.title ?? widget.item.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (detail?.subtitle != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    detail!.subtitle!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: LumeTheme.muted,
                    ),
                  ),
                ],
                if (detail?.description != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    detail!.description!,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '章节（${_chapters.length}）',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          if (_chapters.isEmpty)
            const SizedBox(
              height: 180,
              child: SourceStateView(
                state: SourceStateKind.empty,
                detail: '该图源没有提供章节',
              ),
            )
          else
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  for (final chapter in _chapters)
                    ListTile(
                      dense: true,
                      onTap: _notifyReaderPending,
                      title: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 章节点击仅提示，Phase1 不进入阅读器（阅读器属 Phase2）。
  void _notifyReaderPending() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('阅读器尚未实现'),
      ),
    );
  }

  /// 标题：板块名 · 图源名。
  String get _title =>
      '${widget.dataSource.section.label} · ${widget.dataSource.name}';
}
