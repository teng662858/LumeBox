import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 漫画书签：一条记录 = 一个位置（章节序号 + 页序号）。
///
/// 存**页序号**而不是滚动偏移：页序号不随视口 / 侧边距 / 页间距变化，换阅读设置
/// 之后书签仍落在同一页上（瀑布流模式下页序号就是图序号）。
@immutable
class ComicBookmark {
  const ComicBookmark({
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.page,
    required this.createdAt,
  });

  /// 章节序号（0 起）。
  final int chapterIndex;

  final String chapterId;

  /// 章节标题快照：章节列表可能改名，书签仍要能说清在哪。
  final String chapterTitle;

  /// 章节内页序号（0 起；瀑布流模式下为图序号）。
  final int page;

  final DateTime createdAt;

  /// 稳定键：同一章同一页视为同一条（重复添加即覆盖）。
  String get key => '$chapterIndex@$page';

  Map<String, Object?> toJson() => <String, Object?>{
    'chapterIndex': chapterIndex,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'page': page,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static ComicBookmark? parse(Object? json) {
    if (json is! Map) return null;
    final chapterIndex = json['chapterIndex'];
    final page = json['page'];
    if (chapterIndex is! int || page is! int) return null;
    final createdAt = json['createdAt'];
    return ComicBookmark(
      chapterIndex: chapterIndex,
      chapterId: '${json['chapterId'] ?? ''}',
      chapterTitle: '${json['chapterTitle'] ?? ''}',
      page: page,
      createdAt: createdAt is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAt)
          : DateTime.now(),
    );
  }

  /// 列表展示文案：`第 12 章 · 第 3 页`。
  String describe() {
    final chapter = chapterTitle.isEmpty
        ? '第 ${chapterIndex + 1} 章'
        : chapterTitle;
    return '$chapter · 第 ${page + 1} 页';
  }

  @override
  bool operator ==(Object other) => other is ComicBookmark && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// 书签的编解码（存进板块阅读库的 `reading_setting` 表，一部作品一条 JSON 数组）。
///
/// 按作品存：一部作品的书签与另一部作品互不可见；板块之间本来就分库（隔离沿用
/// 阅读底座），因此不需要额外做跨板块防护。
class ComicBookmarks {
  ComicBookmarks._();

  /// 设置键前缀：`comic.bookmarks.<itemId>`。
  static const String keyPrefix = 'comic.bookmarks.';

  static String keyFor(String itemId) => '$keyPrefix$itemId';

  /// 解析书签列表；坏数据一律当空列表（不因一条坏记录让整部作品的书签打不开）。
  static List<ComicBookmark> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <ComicBookmark>[];
    try {
      final json = jsonDecode(raw);
      if (json is! List) return const <ComicBookmark>[];
      final bookmarks = <ComicBookmark>[];
      for (final item in json) {
        final parsed = ComicBookmark.parse(item);
        if (parsed != null) bookmarks.add(parsed);
      }
      // 按位置排序：列表读起来与阅读顺序一致。
      bookmarks.sort((a, b) {
        final byChapter = a.chapterIndex.compareTo(b.chapterIndex);
        return byChapter != 0 ? byChapter : a.page.compareTo(b.page);
      });
      return List<ComicBookmark>.unmodifiable(bookmarks);
    } catch (_) {
      return const <ComicBookmark>[];
    }
  }

  static String encode(List<ComicBookmark> bookmarks) => jsonEncode(<Object?>[
    for (final bookmark in bookmarks) bookmark.toJson(),
  ]);

  /// 加入一条（同位置覆盖）；返回新列表（按位置排序）。
  static List<ComicBookmark> add(
    List<ComicBookmark> current,
    ComicBookmark bookmark,
  ) {
    final next = <ComicBookmark>[
      for (final item in current)
        if (item.key != bookmark.key) item,
      bookmark,
    ];
    return decode(encode(next));
  }

  /// 移除一条；返回新列表。
  static List<ComicBookmark> remove(
    List<ComicBookmark> current,
    ComicBookmark bookmark,
  ) => decode(
    encode(<ComicBookmark>[
      for (final item in current)
        if (item.key != bookmark.key) item,
    ]),
  );

  /// 当前位置是否已有书签。
  static ComicBookmark? at(
    List<ComicBookmark> bookmarks, {
    required int chapterIndex,
    required int page,
  }) {
    for (final item in bookmarks) {
      if (item.chapterIndex == chapterIndex && item.page == page) {
        return item;
      }
    }
    return null;
  }
}
