import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 小说书签：一条记录 = 一个位置（章节 + 字符偏移）+ 可选摘录。
///
/// 存**字符偏移**而不是页码：页码随字号 / 行距 / 视口变化，偏移不会。因此换排版
/// 之后书签仍能落到同一句话上。
@immutable
class NovelBookmark {
  const NovelBookmark({
    required this.chapterIndex,
    required this.chapterId,
    required this.chapterTitle,
    required this.charOffset,
    required this.createdAt,
    this.excerpt = '',
  });

  /// 章节序号（0 起）。
  final int chapterIndex;

  final String chapterId;

  /// 章节标题快照：章节列表可能改名，书签仍要能说清在哪。
  final String chapterTitle;

  /// 章节内字符偏移量。
  final int charOffset;

  final DateTime createdAt;

  /// 摘录（该位置附近的一小段正文），列表里展示便于辨认。
  final String excerpt;

  /// 稳定键：同一章节同一偏移视为同一条（重复添加即覆盖）。
  String get key => '$chapterIndex@$charOffset';

  Map<String, Object?> toJson() => <String, Object?>{
        'chapterIndex': chapterIndex,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'charOffset': charOffset,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'excerpt': excerpt,
      };

  static NovelBookmark? parse(Object? json) {
    if (json is! Map) return null;
    final chapterIndex = json['chapterIndex'];
    final charOffset = json['charOffset'];
    if (chapterIndex is! int || charOffset is! int) return null;
    final createdAt = json['createdAt'];
    return NovelBookmark(
      chapterIndex: chapterIndex,
      chapterId: '${json['chapterId'] ?? ''}',
      chapterTitle: '${json['chapterTitle'] ?? ''}',
      charOffset: charOffset,
      createdAt: createdAt is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAt)
          : DateTime.now(),
      excerpt: '${json['excerpt'] ?? ''}',
    );
  }

  /// 列表展示文案：`第 12 章 · 摘录…`。
  String describe() {
    final chapter = chapterTitle.isEmpty
        ? '第 ${chapterIndex + 1} 章'
        : chapterTitle;
    if (excerpt.isEmpty) return chapter;
    return '$chapter · $excerpt';
  }

  @override
  bool operator ==(Object other) =>
      other is NovelBookmark && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// 书签的编解码（存进板块阅读库的 `reading_setting` 表，一本书一条 JSON 数组）。
///
/// 按作品存：一本书的书签与另一本书互不可见；板块之间本来就分库（隔离沿用
/// 阅读底座），因此不需要额外做跨板块防护。
class NovelBookmarks {
  NovelBookmarks._();

  /// 设置键前缀：`novel.bookmarks.<itemId>`。
  static const String keyPrefix = 'novel.bookmarks.';

  static String keyFor(String itemId) => '$keyPrefix$itemId';

  /// 解析书签列表；坏数据一律当空列表（不因一条坏记录让整本书签打不开）。
  static List<NovelBookmark> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <NovelBookmark>[];
    try {
      final json = jsonDecode(raw);
      if (json is! List) return const <NovelBookmark>[];
      final bookmarks = <NovelBookmark>[];
      for (final item in json) {
        final parsed = NovelBookmark.parse(item);
        if (parsed != null) bookmarks.add(parsed);
      }
      // 按位置排序：列表读起来与阅读顺序一致。
      bookmarks.sort((a, b) {
        final byChapter = a.chapterIndex.compareTo(b.chapterIndex);
        return byChapter != 0 ? byChapter : a.charOffset.compareTo(b.charOffset);
      });
      return List<NovelBookmark>.unmodifiable(bookmarks);
    } catch (_) {
      return const <NovelBookmark>[];
    }
  }

  static String encode(List<NovelBookmark> bookmarks) => jsonEncode(
        <Object?>[for (final bookmark in bookmarks) bookmark.toJson()],
      );

  /// 加入一条（同位置覆盖）；返回新列表（按位置排序）。
  static List<NovelBookmark> add(
    List<NovelBookmark> current,
    NovelBookmark bookmark,
  ) {
    final next = <NovelBookmark>[
      for (final item in current)
        if (item.key != bookmark.key) item,
      bookmark,
    ];
    return decode(encode(next));
  }

  /// 移除一条；返回新列表。
  static List<NovelBookmark> remove(
    List<NovelBookmark> current,
    NovelBookmark bookmark,
  ) =>
      decode(encode(<NovelBookmark>[
        for (final item in current)
          if (item.key != bookmark.key) item,
      ]));

  /// 当前位置是否已有书签。
  static NovelBookmark? at(
    List<NovelBookmark> bookmarks, {
    required int chapterIndex,
    required int charOffset,
  }) {
    for (final item in bookmarks) {
      if (item.chapterIndex == chapterIndex && item.charOffset == charOffset) {
        return item;
      }
    }
    return null;
  }
}
