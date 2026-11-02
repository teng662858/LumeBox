import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/source/source_content_type.dart';
import '../../core/reading/reading.dart';
import '../comic/comic_detail_page.dart';
import '../novel/novel_detail_page.dart';
import '../video/video_detail_page.dart';
import '../video/video_player_page.dart';

/// Keep the original library/source identity when a comprehensive site mixes
/// formats. Opening a comic from a video source must not migrate its database.
Widget contentDetailPage({
  required SourceContentType type,
  required DataSource source,
  required ReadingLibrary library,
  required ReadingTarget target,
  SourceManager? manager,
}) {
  final bound = _BoundSourceManager(source, manager);
  return switch (type) {
    SourceContentType.novel => NovelDetailPage(
      source: source,
      library: library,
      target: target,
    ),
    SourceContentType.comic => ComicDetailPage(
      library: library,
      manager: bound,
      target: target,
      runtimeAvailable: true,
      detectContent: false,
    ),
    SourceContentType.video => Builder(
      builder: (context) => VideoDetailPage(
        source: source,
        sourceId: source.id,
        manager: manager ?? bound,
        item: SourceItem(
          id: target.itemId,
          title: target.title,
          cover: target.cover,
          subtitle: target.subtitle,
        ),
        library: library,
        detectContent: false,
        onPlay: (media, playTarget, qualities, prelaunch) async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VideoPlayerPage(
                media: media,
                title: playTarget.title,
                target: playTarget,
                sourceId: source.id,
                source: source,
                sourceManager: manager ?? bound,
                library: library,
                qualities: qualities,
                prelaunch: prelaunch,
              ),
            ),
          );
        },
      ),
    ),
  };
}

class _BoundSourceManager implements SourceManager {
  _BoundSourceManager(this.source, this.parent);
  final DataSource source;
  final SourceManager? parent;
  @override
  bool get runtimeAvailable => true;
  @override
  Future<DataSource?> open(String sourceId) => sourceId == source.id
      ? Future.value(source)
      : parent?.open(sourceId) ?? Future.value(null);
  @override
  Future<List<SourceDescriptor>> list() async => parent == null
      ? [
          SourceDescriptor(
            id: source.id,
            name: source.name,
            version: '',
            enabled: true,
          ),
        ]
      : parent!.list();
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('请在源管理中操作');
}
