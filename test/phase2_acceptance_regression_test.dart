import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:lume_box/core/db/section_database.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/player_stats.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/features/video/video_player_page.dart';


/// Phase2 真机验收轮发现的三处小 bug 的回归用例。
///
/// 三条都不是「功能没做」，而是**做得对但边界没收干净**，且都属于「用户看得到
/// 假信息 / 页面状态被作废对象改写」这一类：
///
/// 1. 导入失败文案的「自建服务端」附注被**子串误伤**：普通的语法错误只要含
///    `internet` / `network` / `magnet` 这类词（里面嵌着 `net`），就会多出一段
///    「这是自建服务端程序」的说明——用户照着提示去改网络写法，而真正的问题是
///    少了个括号。
/// 2. 全新板块库在首次打开时**记四条假告警**：建表用的 schema 已经带了后续版本
///    追加的列，迁移段却仍按「旧库」去 `ALTER TABLE ADD COLUMN`，撞
///    `duplicate column name` 后每条都写一条 warn。用户导出的错误报告里因此
///    常驻一堆并不存在的「迁移失败」。
/// 3. 视频页换内核时**摘错了监听回调**：挂上去的是 `_onSnapshotChanged`，
///    摘的却是 `_syncDockForPlayback`，等于没摘。旧播放器在释放过程中吐出的
///    快照仍会被页面当成当前状态处理（落进度、判连播、改 Dock 显隐）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_phase2_reg');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? root.path
          : null,
    );
    LumeLog.clear();
    // 视频板块的阅读库在**真实时钟**里先打开：`testWidgets` 的测试体跑在
    // fake-async 时钟里，首次打开要建目录、开 sqlite（真实异步），在测试体里
    // await 会等不到，页面就会一直停在「正在准备播放器」的转圈上。
    await ReadingLibrary.open(Section.video);
  });

  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    SectionDatabase.disposeAll();
    await SectionScope.closeAll();
    LumeLog.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // ==========================================================================
  // Bug 1：导入失败文案的「自建服务端」附注不得被子串误伤
  // ==========================================================================

  group('Bug 1 · 服务端能力识别按整词判定', () {
    /// 取一条失败文案；[reason] 是引擎给出的原因原文。
    String messageFor(String? reason) =>
        SourceRegistry.describeLoadFailure(reason);

    test('普通的语法错误不会被当成自建服务端程序', () {
      // 这些是真实的 JS 报错形状：`net` 藏在 internet / network / magnet 里。
      const falsePositives = <String>[
        'SyntaxError: Unexpected token in internet explorer',
        'TypeError: network error',
        'ReferenceError: planet is not defined',
        'Error: magnet link malformed',
        'Error: genetics dataset missing',
      ];
      for (final reason in falsePositives) {
        final message = messageFor(reason);
        expect(
          message,
          isNot(contains('自建服务端程序')),
          reason: '「$reason」不含服务端能力，不该附上服务端说明',
        );
        expect(message, contains(reason), reason: '引擎原文要原样保留');
      }
    });

    test('真正的服务端能力仍然点名（模块名 / 调用形态都认）', () {
      const positives = <String>[
        '猫源沙箱不支持「http2」：这类模块用于「自建服务端 / 子进程程序」',
        '猫源沙箱不支持「dns」：沙箱不提供进程、线程与底层网络',
        'Cannot find module "net"',
        "require('child_process')",
        'net::ERR_CONNECTION_REFUSED',
        'listen EADDRINUSE',
        'net.createServer is not a function',
        'ReferenceError: tls is not defined',
      ];
      for (final reason in positives) {
        expect(
          messageFor(reason),
          contains('自建服务端程序'),
          reason: '「$reason」确实是服务端能力，必须给出定向说明',
        );
      }
    });

    test('空原因回落到笼统提示（不附服务端说明）', () {
      expect(messageFor(null), contains('脚本载入失败'));
      expect(messageFor('   '), contains('脚本载入失败'));
      expect(messageFor(null), isNot(contains('自建服务端程序')));
    });
  });

  // ==========================================================================
  // Bug 2：全新板块库不得记迁移告警
  // ==========================================================================

  group('Bug 2 · 全新库打开不留假告警', () {
    test('首次打开四个板块：一条迁移告警都不该有', () async {
      for (final section in Section.values) {
        await SectionDatabase.open(await SectionScope.open(section));
      }
      final migrationWarnings = LumeLog.snapshot
          .where((entry) => entry.message.contains('迁移'))
          .map((entry) => entry.message)
          .toList(growable: false);
      expect(
        migrationWarnings,
        isEmpty,
        reason: '全新库的表已经带全部列，不该尝试 ADD COLUMN；'
            '实际告警：$migrationWarnings',
      );
    });

    test('全新库建出来的表结构与迁移后的旧库一致（列齐全）', () async {
      final scope = await SectionScope.open(Section.novel);
      final database = await SectionDatabase.open(scope);
      database.upsertSource(
        id: 'fresh',
        name: '新库源',
        version: '1.0.0',
        section: Section.novel.id,
        script: 'var LumeSource = {};',
      );

      // 后续版本追加的列（section / user_agent / cookie / proxy / origin_url）
      // 在新库里必须都在，且能正常读写——迁移段跳过它们的前提就是这一点。
      database.setSourceOrigin('fresh', 'https://example.com/sub.js');
      database.setSourceNetwork(
        'fresh',
        userAgent: 'UA',
        cookie: 'c',
        proxy: 'http://127.0.0.1:8888',
      );
      final record = database.source('fresh')!;
      expect(record.section, Section.novel.id);
      expect(record.originUrl, 'https://example.com/sub.js');
      expect(record.network.userAgent, 'UA');
      expect(record.network.cookie, 'c');
      expect(record.network.proxy, 'http://127.0.0.1:8888');
    });

    test('旧库（schema v1）迁移路径不受影响：仍会补列并回填板块', () async {
      // 手工造一个真正的 v1 库：没有 section / user_agent / cookie / proxy /
      // origin_url 任何一列——「新库跳过迁移」不能把旧库这条路也跳过。
      final scope = await SectionScope.open(Section.comic);
      final legacy = _createLegacyDatabase(scope.dbPath);

      final database = await SectionDatabase.open(scope);
      final record = database.source('old')!;
      expect(record.section, Section.comic.id, reason: '旧库要回填归属板块');

      // 补出来的列要真的能用。
      database.setSourceNetwork(
        'old',
        userAgent: 'UA2',
        cookie: 'c2',
        proxy: '',
      );
      database.setSourceOrigin('old', 'https://example.com/old.js');
      final updated = database.source('old')!;
      expect(updated.network.userAgent, 'UA2');
      expect(updated.originUrl, 'https://example.com/old.js');

      legacy.close();
    });
  });

  // ==========================================================================
  // Bug 3：换内核时旧播放器的快照不得再被页面消费
  // ==========================================================================

  group('Bug 3 · 换内核后旧播放器不再驱动页面', () {
    testWidgets('换内核：被换下的实例必须已摘掉页面的监听', (tester) async {
      final created = <_ProbePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
            catalog: const _Catalog(),
            playerFactory: (kernel) {
              final player = _ProbePlayer(kernel);
              created.add(player);
              return player;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(created, isNotEmpty);
      final first = created.first;
      expect(first.kernel, PlayerKernel.avplayer);
      expect(
        first.listenerCount,
        greaterThan(0),
        reason: '采用中的播放器要挂上页面监听（否则进度 / Dock / 连播都不工作）',
      );

      // 换到 MPV。
      await tester.tap(find.byTooltip('播放器设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MPV'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(first.disposals, greaterThan(0), reason: '旧实例应已释放');
      // 核心断言：挂 A 摘 B 的实现下这里仍是 1——旧实例在释放过程中吐出的
      // 快照会被页面当成当前状态消费（落进度、判连播、改 Dock 显隐）。
      expect(
        first.listenerCount,
        0,
        reason: '被换下的实例不得再持有页面监听',
      );

      // 新实例接管监听。
      final second = created.last;
      expect(second.kernel, PlayerKernel.mpv);
      expect(second.listenerCount, greaterThan(0));
    });

    testWidgets('反复来回切换：每个被换下的实例都不再监听页面', (tester) async {
      final created = <_ProbePlayer>[];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            media: PlayerMedia(uri: Uri.parse('https://example.com/a.mp4')),
            catalog: const _Catalog(),
            playerFactory: (kernel) {
              final player = _ProbePlayer(kernel);
              created.add(player);
              return player;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 来回切四轮：AVPlayer → MPV → AVPlayer → MPV → AVPlayer。
      for (final kernel in <String>['MPV', 'AVPlayer', 'MPV', 'AVPlayer']) {
        await tester.tap(find.byTooltip('播放器设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kernel));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      // 除最后一个之外，每个实例都应已被释放。
      final live = created.where((player) => player.disposals == 0).toList();
      expect(live, hasLength(1), reason: '只应留下最后采用的那一个实例');
      expect(live.single, same(created.last));

      // 被换下的每一个都不得再持有监听：挂 A 摘 B 的实现下它们会全是 1，
      // 越切越多「幽灵订阅者」，各自把过期快照灌进页面。
      final stillListening = created
          .where((player) => !identical(player, created.last))
          .where((player) => player.listenerCount > 0)
          .toList();
      expect(
        stillListening,
        isEmpty,
        reason: '被换下的实例仍持有监听：${stillListening.length} 个（应 0 个）',
      );
      expect(
        created.last.listenerCount,
        greaterThan(0),
        reason: '当前实例必须持有监听',
      );
    });
  });
}

/// 造一个 schema v1 的旧库文件（无 section / UA / Cookie / 代理 / 来源地址列）。
Database _createLegacyDatabase(String path) {
  final legacy = sqlite3.open(path);
  legacy.execute('''
CREATE TABLE source (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  version    TEXT NOT NULL DEFAULT '',
  script     TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL
);
CREATE TABLE section_setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
  legacy.execute(
    'INSERT INTO source (id, name, version, script, enabled, updated_at) '
    'VALUES (?, ?, ?, ?, 1, ?)',
    ['old', '老图源', '0.9.0', 'var LumeSource = {};', 1],
  );
  legacy.execute('PRAGMA user_version = 1');
  return legacy;
}

class _Catalog implements PlayerKernelCatalog {
  const _Catalog();

  @override
  bool isAvailable(PlayerKernel kernel) =>
      kernel == PlayerKernel.avplayer || kernel == PlayerKernel.mpv;

  @override
  String? unavailableReason(PlayerKernel kernel) =>
      isAvailable(kernel) ? null : '${kernel.label} 内核尚未接入';
}

/// 可以被外部窥探监听者数量的假播放器。
///
/// 「页面是否还挂在这个实例上」是 Bug 3 的直接可观测量：监听计数在挂 / 摘后
/// 立刻变化，不依赖内核是否真的吐快照、也不受 dispose 时机影响。
class _ProbePlayer implements AbstractPlayer {
  _ProbePlayer(this.kernel);

  final PlayerKernel kernel;

  int disposals = 0;

  final _CountingNotifier _snapshot = _CountingNotifier();
  late final ValueNotifier<PlayerStats> _stats = ValueNotifier<PlayerStats>(
    PlayerStats(engineLabel: kernel.label),
  );

  /// 当前快照通知者上的监听者数量（页面挂了几路）。
  int get listenerCount => _snapshot.listeners;

  @override
  ValueListenable<PlayerSnapshot> get snapshot => _snapshot;

  @override
  ValueListenable<PlayerStats> get stats => _stats;

  @override
  Future<void> load(PlayerMedia media) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> applySettings(PlayerSettings settings) async {}

  @override
  Widget buildView() => Text('probe:${kernel.id}');

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// 记账版快照通知者：按**监听者身份**记账，挂一个 +1、摘一个 −1。
///
/// `ChangeNotifier` 不公开监听者数量，而「摘监听有没有摘到点子上」正是 Bug 3
/// 的核心——自己数最直接，也免得依赖框架的诊断属性。
///
/// 必须记身份而不是只记次数：真实的 `removeListener` 对**没注册过的**回调是
/// 静默 no-op（不报错、不减数）。若这里只做计数递减，「摘错了人」反而会被
/// 记成摘干净了——测试就永远抓不到那个 bug。
class _CountingNotifier extends ValueNotifier<PlayerSnapshot> {
  _CountingNotifier() : super(const PlayerSnapshot());

  final List<VoidCallback> _registered = <VoidCallback>[];

  int get listeners => _registered.length;

  @override
  void addListener(VoidCallback listener) {
    _registered.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _registered.remove(listener);
    super.removeListener(listener);
  }
}
