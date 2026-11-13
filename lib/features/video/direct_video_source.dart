import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/source/source.dart';
import '../../core/session/section.dart';

/// One media capture from a web home. It exposes only data the page supplied.
class DirectVideoSource implements DataSource {
  DirectVideoSource({
    required this.id,
    required this.name,
    required this.title,
    required this.uri,
    this.headers = const {},
    this.episodes = const [],
    this.selected = 0,
    this.cover,
    this.description = '',
    this.resolveEpisode,
  });
  @override
  final String id, name;
  final String title;
  final Uri uri;
  final Map<String, String> headers;
  final List<SourceChapter> episodes;
  final int selected;
  final String? cover;
  final String description;
  final Future<VideoContent> Function(int)? resolveEpisode;
  bool _initialUsed = false;

  static String captureItemId(String itemId, Uri originalUri) {
    if (itemId.isNotEmpty && Uri.tryParse(itemId)?.hasAuthority != true) {
      return itemId;
    }
    final identity = itemId.isEmpty ? originalUri.toString() : itemId;
    return 'capture-${sha256.convert(utf8.encode(identity))}';
  }
  @override
  Section get section => Section.video;
  @override
  Future<List<SourceCategory>> categories() async => [];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async => const SourceList(items: [], hasMore: false);
  @override
  Future<SourceDetail?> detail(String itemId) async => SourceDetail(
    mediaType: 'video',
    id: itemId,
    title: title,
    subtitle: name,
    cover: cover,
    description: description,
  );
  @override
  Future<List<SourceChapter>> chapters(String itemId) async =>
      episodes.isNotEmpty
      ? episodes
      : const [SourceChapter(id: 'web-episode-0', title: '正片')];

  Future<VideoContent> downloadContent(String itemId, String chapterId) async {
    if (episodes.isEmpty ||
        (!_initialUsed && episodes.indexWhere((e) => e.id == chapterId) == selected)) {
      return VideoContent(url: uri, headers: headers);
    }
    return content(itemId: itemId, chapterId: chapterId);
  }
  @override
  Future<VideoContent> content({
    required String itemId,
    required String chapterId,
  }) async {
    if (episodes.isEmpty) return VideoContent(url: uri, headers: headers);
    final index = episodes.indexWhere((e) => e.id == chapterId);
    if (index < 0) throw const FormatException('网页剧集已失效');
    if (index == selected && (!_initialUsed || resolveEpisode == null)) {
      _initialUsed = true;
      return VideoContent(url: uri, headers: headers);
    }
    if (resolveEpisode == null) throw const FormatException('网页未提供切集解析器');
    return resolveEpisode!(index);
  }
}
