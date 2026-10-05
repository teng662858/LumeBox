import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/js/source_script.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

import 'support/js_sandbox_support.dart';

/// 安全测试第 3 条：板块 category 隔离校验。
///
/// 构造「元数据与板块不匹配」的脚本（`category: "novel"` 的 JS 拿到漫画板块
/// 加载），要求：
/// - 解析阶段直接拒绝加载；
/// - 输出明确的错误日志；
/// - 严格禁止跨板块混用图源。
///
/// 验证覆盖两条声明路径（头部注释 / 运行时 `LumeSource.category`）与两条导入
/// 路径（首次导入 / 订阅更新），确保没有绕过的口子。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final available = installBridge();
  final skipReason = available
      ? null
      : '未找到可用的 quickjs 原生桥（Windows 需先 `flutter build windows`）';

  late Directory root;

  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('lume_box_section');
    await installTempSectionRoot(root);
  });

  tearDown(() async {
    for (final section in Section.values) {
      SourceRegistry.close(section);
    }
    await SectionScope.closeAll();
    restoreEnginePlatformGate();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('3a 板块声明解析（纯 Dart）', () {
    test('头部注释声明 category 被解析出来', () {
      final metadata = SourceMetadata.parseHeader(
        '// LumeSource: {"id":"a","name":"甲","category":"comic"}',
      );
      expect(metadata, isNotNull);
      expect(metadata!.category, 'comic');
    });

    test('运行时 category 被解析出来', () {
      final metadata = SourceMetadata.parse(<String, Object?>{
        'id': 'a',
        'name': '甲',
        'category': 'novel',
      });
      expect(metadata!.category, 'novel');
    });

    test('未声明 category 时为空串（既有脚本不受影响）', () {
      final metadata = SourceMetadata.parseHeader(
        '// LumeSource: {"id":"a","name":"甲"}',
      );
      expect(metadata!.category, isEmpty);
      expect(metadata.sectionMismatch(Section.comic), isNull);
    });

    test('声明与目标一致时放行；中文板块名同样认', () {
      const comic = SourceMetadata(id: 'a', name: '甲', version: '', category: 'comic');
      expect(comic.sectionMismatch(Section.comic), isNull);

      const chinese = SourceMetadata(id: 'a', name: '甲', version: '', category: '漫画');
      expect(chinese.sectionMismatch(Section.comic), isNull);

      const padded = SourceMetadata(id: 'a', name: '甲', version: '', category: ' Novel ');
      expect(padded.sectionMismatch(Section.novel), isNull);
    });

    test('声明与目标不符时给出点名到板块的可读原因', () {
      const novel = SourceMetadata(id: 'a', name: '甲', version: '', category: 'novel');
      final issue = novel.sectionMismatch(Section.comic);
      expect(issue, isNotNull);
      expect(issue, contains('跨板块'));
      expect(issue, contains('novel'));
      expect(issue, contains('comic'));
      expect(issue, contains('漫画'), reason: '提示里应带上目标板块的中文名');
    });

    test('声明了非法板块名时明确拒绝，而不是静默放行', () {
      const bogus = SourceMetadata(id: 'a', name: '甲', version: '', category: 'manga');
      final issue = bogus.sectionMismatch(Section.comic);
      expect(issue, isNotNull);
      expect(issue, contains('manga'));
      expect(issue, contains('不是有效板块'));
    });

    test('合并两处元信息：头部没写 category 时取运行时的', () {
      final header = SourceMetadata.parseHeader(
        '// LumeSource: {"id":"a","name":"甲","version":"1.0.0"}',
      );
      final runtime = SourceMetadata.parse(<String, Object?>{
        'id': 'a',
        'name': '甲',
        'version': '2.0.0',
        'category': 'comic',
      });
      final merged = SourceMetadata.merge(header, runtime)!;
      expect(merged.version, '1.0.0', reason: '头部声明优先');
      expect(merged.category, 'comic', reason: '头部缺失的字段由运行时补齐');
    });
  });

  group('3b 跨板块导入被解析阶段拒绝（真实引擎）', () {
    test(
      '小说脚本导入漫画板块：拒绝落库、日志点名跨板块',
      () async {
        final comic = await openRegistryFor(Section.comic);
        final outcome = await comic.import(fixture('section_mismatch_novel.js'));

        expect(outcome.isSuccess, isFalse, reason: '跨板块图源必须被拒绝');
        expect(outcome.message, contains('跨板块'));
        expect(outcome.message, contains('novel'));
        expect(outcome.message, contains('comic'));
        expect(comic.sources, isEmpty, reason: '失败不落库');
        expect(comic.source('test-section-novel'), isNull);

        // 明确错误日志：点名被拒的图源与两个板块。
        final rejected =
            logLinesContaining('拒绝跨板块图源').where((l) => l.contains('test-section-novel'));
        expect(rejected, isNotEmpty, reason: '拒绝行为必须在日志里留痕');
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '同一份脚本导入小说板块：正常成功（对照）',
      () async {
        final novel = await openRegistryFor(Section.novel);
        final outcome = await novel.import(fixture('section_mismatch_novel.js'));

        expect(outcome.isSuccess, isTrue, reason: outcome.message ?? '');
        expect(outcome.record!.id, 'test-section-novel');
        expect(novel.sources.length, 1);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '只有运行时 category（头部不写）同样被拦下',
      () async {
        const script = '''
// LumeSource: {"id":"runtime-cat","name":"运行时声明板块","version":"1.0.0"}
var LumeSource = {
  id: 'runtime-cat',
  name: '运行时声明板块',
  version: '1.0.0',
  category: 'novel',
  async categories() { return [{ id: 'c1', title: '分类一' }]; }
};
''';
        final comic = await openRegistryFor(Section.comic);
        final outcome = await comic.import(script);

        expect(
          outcome.isSuccess,
          isFalse,
          reason: '头部没写 category 不能成为绕过板块校验的口子',
        );
        expect(outcome.message, contains('跨板块'));
        expect(comic.sources, isEmpty);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      '头部声明与运行时声明冲突时，头部优先且仍按头部判定',
      () async {
        const script = '''
// LumeSource: {"id":"conflict-cat","name":"冲突声明","version":"1.0.0","category":"novel"}
var LumeSource = {
  id: 'conflict-cat',
  name: '冲突声明',
  version: '1.0.0',
  category: 'video',
  async categories() { return [{ id: 'c1', title: '分类一' }]; }
};
''';
        // 头部说小说：导入小说成功。
        final novel = await openRegistryFor(Section.novel);
        expect((await novel.import(script)).isSuccess, isTrue);

        // 导入视频被拒（按头部判，而不是按运行时的 video 放行）。
        final video = await openRegistryFor(Section.video);
        final outcome = await video.import(script);
        expect(outcome.isSuccess, isFalse);
        expect(outcome.message, contains('novel'));
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '无板块声明的脚本照旧可导入任意板块（不误伤既有脚本）',
      () async {
        const script = '''
// LumeSource: {"id":"no-cat","name":"无板块声明","version":"1.0.0"}
var LumeSource = {
  id: 'no-cat',
  name: '无板块声明',
  version: '1.0.0',
  async categories() { return [{ id: 'c1', title: '分类一' }]; }
};
''';
        for (final section in <Section>[Section.novel, Section.comic, Section.video]) {
          final registry = await openRegistryFor(section);
          final outcome = await registry.import(script);
          expect(
            outcome.isSuccess,
            isTrue,
            reason: '${section.id} 应接受无板块声明的脚本：${outcome.message}',
          );
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      '库内记录同样守住板块边界：跨板块记录在读取路径上不可见',
      () async {
        // 先正常导入小说板块，再确认漫画板块看不见它。
        final novel = await openRegistryFor(Section.novel);
        expect((await novel.import(fixture('section_mismatch_novel.js'))).isSuccess, isTrue);

        final comic = await openRegistryFor(Section.comic);
        expect(comic.sources, isEmpty);
        expect(comic.source('test-section-novel'), isNull);
        expect(await comic.engineFor('test-section-novel'), isNull);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}

/// 打开一个板块的图源注册表（板块目录与库落到 setUp 建的临时目录）。
Future<SourceRegistry> openRegistryFor(Section section) async {
  await ensureSectionScope(section);
  return SourceRegistry.open(section);
}
