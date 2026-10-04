import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/features/comic/repo/comic_repo_models.dart';
import 'package:lume_box/features/comic/repo/comic_repo_parser.dart';

/// 两类仓库索引的独立解析验证：字段映射、载体判定、地址解析与容错。
///
/// 关键一条：两种格式不共用解读逻辑——同一份载荷交给「另一个」解析器
/// 解析不出任何扩展（任务书第 1 条「区分两者格式差异做独立解析」）。
void main() {
  final baseUri = Uri.parse('https://repo.example/repo/index.min.json');

  const mihonText = '''
[
  {
    "name": "MangaDex",
    "pkg": "eu.kanade.tachiyomi.extension.all.mangadex",
    "apk": "mangadex-v1.5.0.apk",
    "lang": "all",
    "code": 15,
    "version": "1.5.0",
    "nsfw": 0,
    "sources": [
      {"name": "MangaDex", "lang": "en", "id": "2499283573021220255", "baseUrl": "https://mangadex.org"},
      {"name": "MangaDex (ZH)", "lang": "zh", "id": "2", "baseUrl": "https://mangadex.org"}
    ]
  },
  {"name": "缺 pkg 的条目"},
  {"pkg": "pkg.only", "name": "缺 apk 的条目"}
]
''';

  const veneraText = '''
[
  {"name": "拷贝漫画", "fileName": "copy_manga.js", "key": "copy_manga", "version": "1.4.2"},
  {"name": "拷贝漫画(多账号)", "fileName": "copy_manga_multi_accounts.js", "key": "copy_manga", "version": "1.4.1"},
  {"name": "缺 fileName 的条目", "key": "broken", "version": "1.0.0"}
]
''';

  group('Mihon / Tachiyomi 解析', () {
    test('字段映射：pkg 作标识、apk 拼地址、sources 取名字、nsfw 认数字', () {
      final index = ComicRepoParser.parseText(
        RepoKind.mihon,
        mihonText,
        baseUri: baseUri,
      );

      expect(index.kind, RepoKind.mihon);
      // 两条不合法条目被跳过。
      expect(index.extensions, hasLength(1));

      final extension = index.extensions.single;
      expect(extension.id, 'eu.kanade.tachiyomi.extension.all.mangadex');
      expect(extension.name, 'MangaDex');
      expect(extension.version, '1.5.0');
      expect(extension.language, 'all');
      expect(extension.artifact, ExtensionArtifact.apk);
      expect(extension.isRunnable, isFalse, reason: 'APK 需要 Android 运行时');
      expect(extension.url.toString(), 'https://repo.example/repo/mangadex-v1.5.0.apk');
      expect(extension.nsfw, isFalse);
      expect(extension.sourceNames, <String>['MangaDex', 'MangaDex (ZH)']);
    });

    test('nsfw 的三种写法都认；绝对 apk 地址原样保留', () {
      const text = '''
[
  {"name": "A", "pkg": "a", "apk": "a.apk", "nsfw": 1},
  {"name": "B", "pkg": "b", "apk": "https://cdn.example/b.apk", "nsfw": true},
  {"name": "C", "pkg": "c", "apk": "c.apk", "nsfw": "1"}
]
''';
      final index = ComicRepoParser.parseText(
        RepoKind.mihon,
        text,
        baseUri: baseUri,
      );

      expect(index.extensions.map((e) => e.nsfw), <bool>[true, true, true]);
      expect(
        index.extensions[1].url.toString(),
        'https://cdn.example/b.apk',
      );
    });

    test('整体不是数组：报出可读错误', () {
      expect(
        () => ComicRepoParser.parseText(RepoKind.mihon, '{}', baseUri: baseUri),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Venera 解析', () {
    test('字段映射：fileName 作标识、载体是 JS、无语言与分级字段', () {
      final index = ComicRepoParser.parseText(
        RepoKind.venera,
        veneraText,
        baseUri: Uri.parse('https://venera.example/configs/index.json'),
      );

      expect(index.kind, RepoKind.venera);
      expect(index.extensions, hasLength(2), reason: '缺 fileName 的条目被跳过');

      final first = index.extensions.first;
      // key 相同、fileName 不同：标识用 fileName，两个条目不会互相覆盖。
      expect(first.id, 'copy_manga.js');
      expect(index.extensions[1].id, 'copy_manga_multi_accounts.js');
      expect(first.name, '拷贝漫画');
      expect(first.version, '1.4.2');
      expect(first.artifact, ExtensionArtifact.js);
      expect(first.isRunnable, isTrue);
      expect(first.language, isEmpty);
      expect(first.nsfw, isFalse);
      expect(
        first.url.toString(),
        'https://venera.example/configs/copy_manga.js',
      );
    });
  });

  group('两类格式独立解析', () {
    test('Mihon 载荷交给 Venera 解析器：解析不出扩展', () {
      final index = ComicRepoParser.parse(
        RepoKind.venera,
        jsonDecode(mihonText),
        baseUri: baseUri,
      );
      expect(index.extensions, isEmpty);
    });

    test('Venera 载荷交给 Mihon 解析器：解析不出扩展', () {
      final index = ComicRepoParser.parse(
        RepoKind.mihon,
        jsonDecode(veneraText),
        baseUri: baseUri,
      );
      expect(index.extensions, isEmpty);
    });

    test('非法 JSON：错误信息带仓库类型', () {
      expect(
        () => ComicRepoParser.parseText(
          RepoKind.venera,
          'not json at all',
          baseUri: baseUri,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Venera'),
          ),
        ),
      );
    });
  });
}
