import '../cat/cat_web_parse.dart';
import 'data_source.dart';
import 'source_models.dart';

enum SourceContentType {
  comic('漫画'),
  video('视频'),
  novel('小说');

  const SourceContentType(this.label);
  final String label;

  static SourceContentType? parse(String? value) =>
      switch (value?.toLowerCase().trim()) {
        'comic' || 'manga' || 'images' || 'image' || 'photo' => comic,
        'text' || 'novel' || 'book' || 'html' => novel,
        'video' || 'movie' || 'tv' || 'audio' || 'webplayer' => video,
        _ => null,
      };
}

/// A short-lived, single-use handoff from detection to the reader/player. Do not
/// retain signed media URLs across page visits or source runtime replacements.
class SourceContentRead {
  static final _probes =
      Expando<Map<String, ({DateTime time, ChapterContent content})>>();
  static String _key(String itemId, String chapterId) =>
      '$itemId\u0000$chapterId';
  static Future<ChapterContent?> read(
    DataSource source, {
    required String itemId,
    required String chapterId,
  }) async {
    final cached = _probes[source]?.remove(_key(itemId, chapterId));
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(seconds: 30)) {
      return cached.content;
    }
    return source.content(itemId: itemId, chapterId: chapterId);
  }

  static void _remember(
    DataSource source,
    String itemId,
    String chapterId,
    ChapterContent content,
  ) {
    // One item per runtime is enough for the current detail page.
    _probes[source] = {
      _key(itemId, chapterId): (time: DateTime.now(), content: content),
    };
  }
}

/// Resolve each work separately. A category name or the source's storage section
/// is not evidence of the actual chapter format.
Future<SourceContentType?> detectSourceContent({
  required DataSource source,
  required String itemId,
  required SourceDetail? detail,
  required List<SourceChapter> chapters,
  String? hint,
}) async {
  final declared =
      SourceContentType.parse(detail?.mediaType) ??
      SourceContentType.parse(hint);
  if (declared != null) return declared;
  if (chapters.isEmpty) return null;
  try {
    final content = await SourceContentRead.read(
      source,
      itemId: itemId,
      chapterId: chapters.first.id,
    );
    if (content != null) {
      SourceContentRead._remember(source, itemId, chapters.first.id, content);
    }
    return switch (content) {
      ImageContent() => SourceContentType.comic,
      VideoContent() => SourceContentType.video,
      TextContent() => SourceContentType.novel,
      null => null,
    };
  } on CatWebParseRequired {
    return SourceContentType.video;
  }
}
