import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/comic/comic_settings.dart';
import 'package:lume_box/features/novel/novel_typesetting.dart';

/// 阅读底座的验证：板块独占的库与缓存、归属校验、书架与两套进度口径。
///
/// 全部在 Windows 上跑真实 sqlite 与真实文件：path_provider 用方法通道打桩，
/// 因此「漫画的数据不会出现在小说库里」这类隔离断言是对着真实库文件断言的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lume_box_reading');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ComicProgress comicProgress({
    String itemId = 'book',
    int chapterIndex = 2,
    int page = 5,
    double fraction = 0.4,
  }) =>
      ComicProgress(
        section: Section.comic,
        itemId: itemId,
        chapterIndex: chapterIndex,
        chapterId: 'c$chapterIndex',
        chapterTitle: '第 ${chapterIndex + 1} 章',
        updatedAt: DateTime.now(),
        page: page,
        pageFraction: fraction,
      );

  NovelProgress novelProgress({
    String itemId = 'book',
    int chapterIndex = 2,
    int charOffset = 1200,
    int chapterLength = 4800,
  }) =>
      NovelProgress(
        section: Section.novel,
        itemId: itemId,
        chapterIndex: chapterIndex,
        chapterId: 'c$chapterIndex',
        chapterTitle: '第 ${chapterIndex + 1} 章',
        updatedAt: DateTime.now(),
        charOffset: charOffset,
        chapterLength: chapterLength,
      );

  group('板块隔离', () {
    test('阅读库与图源库分文件，且落在本板块目录下', () async {
      final library = await ReadingLibrary.open(Section.comic);
      final comicDir = Directory('${root.path}/sections/comic');

      expect(comicDir.existsSync(), isTrue);
      expect(File('${comicDir.path}/reading.db').existsSync(), isTrue);
      // 图源库是另一个文件，阅读数据不写进图源库。
      expect(File('${comicDir.path}/comic.db').existsSync(), isFalse);
      // 缓存目录独立且已建好。
      expect(Directory(library.imageCacheDir).existsSync(), isTrue);
      expect(Directory(library.exportDir).existsSync(), isTrue);
      expect(library.imageCacheDir, contains('sections'));
      expect(library.imageCacheDir, contains('reading_cache'));
    });

    test('漫画与小说各存各的：同一个 itemId 互不影响', () async {
      final comic = await ReadingLibrary.open(Section.comic);
      final novel = await ReadingLibrary.open(Section.novel);

      comic.shelve(
        sourceId: 'comic-src',
        itemId: 'shared-id',
        title: '漫画书',
        chapterCount: 10,
      );
      novel.shelve(
        sourceId: 'novel-src',
        itemId: 'shared-id',
        title: '小说书',
        chapterCount: 20,
      );
      comic.saveProgress(comicProgress(itemId: 'shared-id', page: 7));
      novel.saveProgress(novelProgress(itemId: 'shared-id', charOffset: 900));

      expect(comic.shelf().single.title, '漫画书');
      expect(novel.shelf().single.title, '小说书');
      expect(comic.comicProgress('shared-id')!.page, 7);
      expect(novel.novelProgress('shared-id')!.charOffset, 900);
      // 形状不对的进度不会被当成本板块的进度。
      expect(novel.comicProgress('shared-id'), isNull);
      expect(comic.novelProgress('shared-id'), isNull);
      // 缓存目录也不交叉。
      expect(comic.imageCacheDir, isNot(novel.imageCacheDir));
    });

    test('库内自证归属：标记不符时拒绝打开', () async {
      final scope = await SectionScope.open(Section.novel);
      final path = '${scope.root.path}/reading.db';
      final raw = sqlite3.open(path);
      raw.execute(
        'CREATE TABLE IF NOT EXISTS reading_setting (key TEXT PRIMARY KEY, '
        'value TEXT NOT NULL)',
      );
      raw.execute(
        "INSERT INTO reading_setting (key, value) VALUES ('owner_section', ?)",
        <Object?>[Section.comic.id],
      );
      raw.close();

      await expectLater(
        ReadingStore.open(Section.novel),
        throwsA(isA<StateError>()),
      );
    });

    test('跨板块写入书架与进度都被拒绝', () async {
      final library = await ReadingLibrary.open(Section.novel);

      // 进度带归属标记，跨板块直接抛错。
      expect(
        () => library.saveProgress(
          ComicProgress(
            section: Section.comic,
            itemId: 'x',
            chapterIndex: 0,
            chapterId: 'c',
            chapterTitle: 'c',
            updatedAt: DateTime.now(),
            page: 0,
          ),
        ),
        throwsArgumentError,
      );
      expect(library.shelf(), isEmpty);
      expect(library.progress('x'), isNull);
    });
  });

  group('书架与进度', () {
    test('入架、补全信息、移出', () async {
      final library = await ReadingLibrary.open(Section.comic);

      final shelved = library.shelve(
        sourceId: 'src',
        itemId: 'a',
        title: '甲',
        cover: 'https://example.invalid/a.jpg',
        chapterCount: 5,
      );
      expect(shelved.chapterCount, 5);
      expect(shelved.readChapterIndex, -1);
      expect(library.onShelf('a'), isTrue);

      // 再次入架只补信息，不重置阅读记录。
      library.saveProgress(comicProgress(itemId: 'a', chapterIndex: 3));
      final again = library.shelve(
        sourceId: 'src',
        itemId: 'a',
        title: '甲（新）',
        chapterCount: 8,
      );
      expect(again.title, '甲（新）');
      expect(again.chapterCount, 8);
      expect(again.readChapterIndex, 3);

      library.unshelve('a');
      expect(library.onShelf('a'), isFalse);
      expect(library.progress('a'), isNull, reason: '移出书架会连进度一起清掉');
    });

    test('未读角标口径：章节总数 - 已读章节 - 1，未知章节数时不显示', () async {
      final library = await ReadingLibrary.open(Section.comic);

      final unknown = library.shelve(
        sourceId: 'src',
        itemId: 'unknown',
        title: '还没同步章节',
      );
      expect(unknown.unreadChapters, 0, reason: '章节总数未知时不猜数字');

      final fresh = library.shelve(
        sourceId: 'src',
        itemId: 'fresh',
        title: '从未读',
        chapterCount: 12,
      );
      expect(fresh.unreadChapters, 12);

      library.shelve(
        sourceId: 'src',
        itemId: 'reading',
        title: '读到一半',
        chapterCount: 12,
      );
      library.saveProgress(comicProgress(itemId: 'reading', chapterIndex: 4));
      expect(library.item('reading')!.unreadChapters, 7);

      library.shelve(
        sourceId: 'src',
        itemId: 'done',
        title: '读完',
        chapterCount: 12,
      );
      library.saveProgress(comicProgress(itemId: 'done', chapterIndex: 11));
      expect(library.item('done')!.unreadChapters, 0);

      // 回翻旧章节不会让未读重新涨起来（只记「最远读到」）。
      library.saveProgress(comicProgress(itemId: 'done', chapterIndex: 2));
      expect(library.item('done')!.readChapterIndex, 11);
      expect(library.item('done')!.unreadChapters, 0);
    });

    test('书架按最近阅读排序', () async {
      final library = await ReadingLibrary.open(Section.novel);
      library.shelve(
        sourceId: 'src',
        itemId: 'first',
        title: '先入架',
        chapterCount: 3,
      );
      // 排序键是毫秒时间戳，两次入架之间留一毫秒，断言才确定。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      library.shelve(
        sourceId: 'src',
        itemId: 'second',
        title: '后入架',
        chapterCount: 3,
      );
      expect(library.shelf().first.itemId, 'second');

      library.saveProgress(
        NovelProgress(
          section: Section.novel,
          itemId: 'first',
          chapterIndex: 1,
          chapterId: 'c1',
          chapterTitle: '第 2 章',
          updatedAt: DateTime.now().add(const Duration(seconds: 1)),
          charOffset: 100,
          chapterLength: 1000,
        ),
      );
      expect(library.shelf().first.itemId, 'first', reason: '刚读过的排最前');
    });

    test('章节同步：非零值才覆盖，避免图源少返章节把角标算错', () async {
      final library = await ReadingLibrary.open(Section.comic);
      library.shelve(
        sourceId: 'src',
        itemId: 'a',
        title: '甲',
        chapterCount: 20,
      );

      library.syncChapters('a', 24);
      expect(library.item('a')!.chapterCount, 24);
      library.syncChapters('a', 0);
      expect(library.item('a')!.chapterCount, 24, reason: '0 视为未知，不覆盖');
    });

    test('小说进度记录字符偏移，比例由章节长度算出', () async {
      final library = await ReadingLibrary.open(Section.novel);
      library.shelve(
        sourceId: 'src',
        itemId: 'n',
        title: '小说',
        chapterCount: 10,
      );
      final saved = novelProgress(itemId: 'n', charOffset: 600, chapterLength: 2400);
      library.saveProgress(saved);

      final loaded = library.novelProgress('n')!;
      expect(loaded.charOffset, 600);
      expect(loaded.chapterLength, 2400);
      expect(loaded.chapterRatio, closeTo(0.25, 0.0001));
      expect(loaded.chapterTitle, '第 3 章');
    });
  });

  group('阅读偏好与缓存', () {
    test('排版参数与主题按板块各存各的', () async {
      final comic = await ReadingLibrary.open(Section.comic);
      final novel = await ReadingLibrary.open(Section.novel);

      final typesetting = const NovelTypesetting().copyWith(
        fontSize: 22,
        lineHeight: 2.2,
        paragraphSpacing: 14,
        margin: 30,
      );
      novel.setSetting(NovelTypesetting.settingKey, typesetting.encode());
      NovelReaderTheme.custom(const Color(0xFF123456)).save(novel);

      final reloaded = NovelTypesetting.decode(
        novel.setting(NovelTypesetting.settingKey),
      );
      expect(reloaded.fontSize, 22);
      expect(reloaded.lineHeight, closeTo(2.2, 0.0001));
      expect(reloaded.margin, 30);
      expect(reloaded.signature, typesetting.signature);

      final theme = NovelReaderTheme.load(novel);
      expect(theme.isCustom, isTrue);
      expect(theme.background.toARGB32(), const Color(0xFF123456).toARGB32());

      // 漫画板块没有写过这些键，读到的是默认主题与默认排版。
      expect(NovelReaderTheme.load(comic).id, NovelReaderTheme.parchment.id);
      expect(
        NovelTypesetting.decode(comic.setting(NovelTypesetting.settingKey))
            .fontSize,
        const NovelTypesetting().fontSize,
      );
    });

    test('漫画阅读器设置往返', () async {
      final library = await ReadingLibrary.open(Section.comic);
      const settings = ComicReaderSettings(
        mode: ComicReadingMode.doublePage,
        marginRatio: 0.2,
        doubleTapZoom: true,
      );
      settings.save(library);

      final loaded = ComicReaderSettings.load(library);
      expect(loaded.mode, ComicReadingMode.doublePage);
      expect(loaded.marginRatio, closeTo(0.2, 0.0001));
      expect(loaded.doubleTapZoom, isTrue);
      // 侧边距上限 50%，越界值会被收敛。
      expect(loaded.copyWith(marginRatio: 0.9).marginRatio, 0.5);
    });

    test('缓存键稳定、无路径字符，且同一 URL 得到同一文件', () async {
      final library = await ReadingLibrary.open(Section.comic);
      const url = 'https://example.invalid/a/b/c.jpg?x=1&y=2';

      final key = ReadingStore.cacheKey(url);
      expect(key, ReadingStore.cacheKey(url));
      expect(key, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(key, isNot(contains('/')));

      final store = await ReadingStore.open(Section.comic);
      expect(store.imageCacheFile(url), contains(library.imageCacheDir));
      expect(store.imageCacheFile(url), store.imageCacheFile(url));
      expect(store.imageCacheFile(url), isNot(store.imageCacheFile('$url#2')));
    });

    test('清理缓存只删图片缓存，不动用户保存的图片', () async {
      final library = await ReadingLibrary.open(Section.comic);
      File('${library.imageCacheDir}/cached.img').writeAsBytesSync(<int>[1, 2, 3]);
      final saved = library.saveImage(
        'page1.jpg',
        Uint8List.fromList(<int>[9, 9, 9]),
      );
      final savedAgain = library.saveImage(
        'page1.jpg',
        Uint8List.fromList(<int>[8, 8]),
      );

      expect(File(saved.path).existsSync(), isTrue);
      expect(savedAgain.path, isNot(saved.path), reason: '同名不覆盖，自动加序号');
      expect(library.cacheBytes(), greaterThan(0));

      library.clearCache();
      expect(library.cacheBytes(), 0);
      expect(File(saved.path).existsSync(), isTrue);
      expect(File(savedAgain.path).existsSync(), isTrue);
    });
  });

  group('板块库生命周期', () {
    test('关闭后可重开：数据在磁盘上，旧引用的读写静默降级', () async {
      final library = await ReadingLibrary.open(Section.comic);
      library.shelve(sourceId: 'src', itemId: 'a', title: '甲', chapterCount: 3);

      // 关闭：释放 sqlite 句柄与内存，门面缓存里不再有它。
      ReadingLibrary.close(Section.comic);
      expect(ReadingLibrary.find(Section.comic), isNull);

      // 页面上仍握着旧引用：读写都不能抛，写也不落库（库已释放）。
      expect(library.shelf(), isEmpty);
      expect(library.progress('a'), isNull);
      library.saveProgress(comicProgress(itemId: 'a', chapterIndex: 1));
      expect(library.cacheBytes(), 0, reason: '缓存统计不依赖库句柄，仍然可用');

      // 重新打开：同一库文件，之前入架的数据还在；关闭期间的写入没有落库。
      final reopened = await ReadingLibrary.open(Section.comic);
      expect(reopened.onShelf('a'), isTrue);
      expect(reopened.item('a')!.title, '甲');
      expect(reopened.progress('a'), isNull, reason: '关闭期间的写入不落库');

      reopened.saveProgress(comicProgress(itemId: 'a', chapterIndex: 1));
      expect(reopened.comicProgress('a')!.chapterIndex, 1);
      expect(reopened.shelf().single.itemId, 'a');
      // 旧引用仍指向已关闭的库，不会把新库带坏。
      expect(library.shelf(), isEmpty);

      // 重复关闭安全。
      ReadingLibrary.close(Section.comic);
      ReadingLibrary.close(Section.comic);
    });
  });
}
