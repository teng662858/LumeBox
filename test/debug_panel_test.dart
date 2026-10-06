import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/net/lume_net.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/core/util/debug_request_log.dart';
import 'package:lume_box/core/util/developer_mode.dart';
import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/features/settings/debug_panel_page.dart';
import 'package:lume_box/features/settings/settings_page.dart';

/// 调试面板（文档「调试日志规范」）。
///
/// 三条要验的性质：
/// 1. **默认不收集**——抓包开关默认关闭，请求照发但一条都不记；
/// 2. **开关真的生效**——打开后网络层的请求进缓冲，关掉即清空；
/// 3. **脱敏**——凭据类请求头只留「存在」，不留值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  void mockPathProvider(String? path) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? path : null,
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('lume_box_debug_panel');
    mockPathProvider(root.path);
    DeveloperModeStore.resetForTesting();
    DeveloperMode.resetForTesting();
    LumeLog.clear();
    // 设置页里的「播放器内核」逃生入口会打开视频板块的库：板块作用域必须在
    // **真实时钟**里先建好——testWidgets 的测试体跑在 fake-async 时钟里，
    // 首次打开要创建目录（真实异步），在测试体里 await 会等不到。
    for (final section in Section.values) {
      await SectionScope.open(section);
    }
  });

  tearDown(() async {
    DeveloperModeStore.resetForTesting();
    DeveloperMode.resetForTesting();
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    mockPathProvider(null);
    LumeLog.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 造一个不真发网络的队列（sender 直接返回响应），用来驱动抓包。
  NetworkQueue queueWith(NetworkResponse response, {Object? throws}) {
    return NetworkQueue(
      settings: const NetworkSettings(),
      sender: (request) async {
        if (throws != null) throw throws;
        return response;
      },
    );
  }

  group('默认不收集', () {
    test('抓包默认关闭', () {
      expect(DebugRequestLog.enabled, isFalse);
      expect(const DeveloperModeSettings().enabled, isFalse);
      expect(const DeveloperModeSettings().requestCapture, isFalse);
      expect(const DeveloperModeSettings().capturing, isFalse);
    });

    test('开关关闭时请求照发，但一条都不记', () async {
      final queue = queueWith(
        const NetworkResponse(statusCode: 200, body: <int>[], headers: {}),
      );
      final response = await queue.send(
        const NetworkRequest(url: 'https://example.com/a', source: '测试源'),
      );
      expect(response.statusCode, 200, reason: '关闭抓包不影响请求本身');
      expect(
        DebugRequestLog.snapshot,
        isEmpty,
        reason: '默认不收集：关着开关时一条记录都不该有',
      );
    });

    test('总开关关着时，抓包开关开了也不记（capturing 依赖两者）', () async {
      DeveloperMode.apply(
        const DeveloperModeSettings(enabled: false, requestCapture: true),
      );
      expect(DebugRequestLog.enabled, isFalse, reason: '总开关优先');

      final queue = queueWith(
        const NetworkResponse(statusCode: 200, body: <int>[], headers: {}),
      );
      await queue.send(const NetworkRequest(url: 'https://example.com/a'));
      expect(DebugRequestLog.snapshot, isEmpty);
    });
  });

  group('开启后真的记录', () {
    setUp(() {
      DeveloperMode.apply(
        const DeveloperModeSettings(enabled: true, requestCapture: true),
      );
    });

    test('成功的请求被记录：方法 / 状态 / 来源 / 字节数', () async {
      final queue = queueWith(
        const NetworkResponse(
          statusCode: 200,
          body: <int>[1, 2, 3, 4, 5],
          headers: <String, String>{},
        ),
      );
      await queue.send(
        const NetworkRequest(
          url: 'https://example.com/list?page=1',
          method: 'POST',
          source: '示例源',
        ),
      );

      final record = DebugRequestLog.snapshot.single;
      expect(record.method, 'POST');
      expect(record.status, 200);
      expect(record.source, '示例源');
      expect(record.host, 'example.com');
      expect(record.responseBytes, 5);
      expect(record.isFailure, isFalse);
      expect(record.describe(), contains('POST 200'));
    });

    test('失败的请求也被记录：状态 0 + 可读原因', () async {
      final queue = queueWith(
        const NetworkResponse(statusCode: 200, body: <int>[], headers: {}),
        throws: const SocketException('connection refused'),
      );
      await expectLater(
        () => queue.send(const NetworkRequest(url: 'https://down.example/x')),
        throwsA(isA<SocketException>()),
      );

      final record = DebugRequestLog.snapshot.single;
      expect(record.status, 0, reason: '没能完成的请求状态记 0');
      expect(record.isFailure, isTrue);
      expect(record.error, contains('connection refused'));
      expect(record.describe(), contains('失败'));
    });

    test('4xx / 5xx 记为失败', () async {
      final queue = queueWith(
        const NetworkResponse(statusCode: 404, body: <int>[], headers: {}),
      );
      await queue.send(const NetworkRequest(url: 'https://example.com/miss'));
      expect(DebugRequestLog.snapshot.single.isFailure, isTrue);
    });

    test('缓冲有上限：超过就丢最旧的', () async {
      final queue = queueWith(
        const NetworkResponse(statusCode: 200, body: <int>[], headers: {}),
      );
      for (var i = 0; i < DebugRequestLog.limit + 10; i++) {
        await queue.send(NetworkRequest(url: 'https://example.com/$i'));
      }
      expect(DebugRequestLog.snapshot, hasLength(DebugRequestLog.limit));
      // 新 → 旧：最新的在最前，最旧的已被丢掉。
      expect(DebugRequestLog.snapshot.first.url, endsWith('/${DebugRequestLog.limit + 9}'));
    });

    test('关掉开关会清空缓冲（不留「关掉但旧数据还在」）', () {
      DeveloperMode.apply(
        const DeveloperModeSettings(enabled: true, requestCapture: true),
      );
      DebugRequestLog.record(
        DebugRequestRecord(
          time: DateTime(2026, 10, 7, 10),
          method: 'GET',
          url: 'https://example.com/a',
          source: 'x',
          host: 'example.com',
          status: 200,
          elapsed: const Duration(milliseconds: 10),
          requestHeaders: const <String, String>{},
        ),
      );
      expect(DebugRequestLog.snapshot, isNotEmpty);

      DeveloperMode.apply(const DeveloperModeSettings());
      expect(DebugRequestLog.enabled, isFalse);
      expect(DebugRequestLog.snapshot, isEmpty, reason: '关闭即清空');
    });
  });

  group('脱敏：凭据类请求头不留值', () {
    test('Cookie / Authorization 只留存在与长度', () {
      final redacted = DebugRequestLog.redactHeaders(<String, String>{
        'Cookie': 'session=abcdef123456',
        'Authorization': 'Bearer tok_1234567890',
        'User-Agent': 'Mozilla/5.0',
        'Accept': '*/*',
      });

      expect(redacted['Cookie'], isNot(contains('abcdef123456')));
      expect(redacted['Cookie'], contains('已隐藏'));
      expect(redacted['Authorization'], isNot(contains('tok_1234567890')));
      expect(redacted['Authorization'], contains('已隐藏'));
      // 非凭据头原样保留（排障要看的就是这些）。
      expect(redacted['User-Agent'], 'Mozilla/5.0');
      expect(redacted['Accept'], '*/*');
    });

    test('大小写不敏感（cookie / COOKIE 都要脱敏）', () {
      final redacted = DebugRequestLog.redactHeaders(<String, String>{
        'cookie': 'a=1',
        'COOKIE': 'b=2',
        'set-cookie': 'c=3',
      });
      for (final value in redacted.values) {
        expect(value, contains('已隐藏'));
      }
    });

    test('请求头在入缓冲时就已脱敏（不是展示时才处理）', () async {
      DeveloperMode.apply(
        const DeveloperModeSettings(enabled: true, requestCapture: true),
      );
      final queue = queueWith(
        const NetworkResponse(statusCode: 200, body: <int>[], headers: {}),
      );
      await queue.send(
        const NetworkRequest(
          url: 'https://example.com/a',
          headers: <String, String>{
            'Cookie': 'session=supersecret',
            'User-Agent': 'UA',
          },
        ),
      );

      final record = DebugRequestLog.snapshot.single;
      expect(
        record.requestHeaders['Cookie'],
        isNot(contains('supersecret')),
        reason: '缓冲里就不该有明文凭据',
      );
    });
  });

  group('设置落盘', () {
    test('开关落盘往返', () async {
      final store = await DeveloperModeStore.open();
      store.save(
        const DeveloperModeSettings(enabled: true, requestCapture: true),
      );

      DeveloperModeStore.resetForTesting();
      final reopened = await DeveloperModeStore.open();
      final loaded = reopened.load();
      expect(loaded.enabled, isTrue);
      expect(loaded.requestCapture, isTrue);
      expect(loaded.capturing, isTrue);
    });

    test('文件损坏时回退默认（关闭），不让 App 起不来', () async {
      final store = await DeveloperModeStore.open();
      File(store.path).writeAsStringSync('{ 不是 JSON');
      expect(store.load().enabled, isFalse);
      expect(store.load().capturing, isFalse);
    });

    test('默认关闭：文件不存在时是关闭态', () async {
      final store = await DeveloperModeStore.open();
      expect(store.load().enabled, isFalse);
    });
  });

  group('页面', () {
    Future<void> pumpPanel(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const DebugPanelPage(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('设置页有「调试面板」入口', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: const SettingsPage(runtimeAvailable: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('调试面板'), findsOneWidget);
    });

    testWidgets('页面显示两个开关、抓包状态与运行环境', (tester) async {
      await pumpPanel(tester);

      expect(find.text('开发者模式'), findsOneWidget);
      expect(find.text('请求抓包'), findsWidgets);
      expect(find.textContaining('抓包未开启'), findsOneWidget);
      expect(find.text('运行环境'), findsOneWidget);
      expect(find.text('在册 JS 上下文'), findsOneWidget);
    });

    testWidgets('抓包开关在开发者模式关闭时不可用', (tester) async {
      await pumpPanel(tester);

      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switches, hasLength(2));
      // 第二个（请求抓包）在总开关关闭时 onChanged 为 null（禁用）。
      expect(switches[1].onChanged, isNull);
    });

    testWidgets('打开开发者模式后抓包开关可用，打开即开始记录', (tester) async {
      await pumpPanel(tester);

      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();

      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList(growable: false);
      expect(switches[1].onChanged, isNotNull, reason: '总开关开了，抓包可选');

      await tester.tap(find.byType(SwitchListTile).at(1));
      await tester.pumpAndSettle();
      expect(DebugRequestLog.enabled, isTrue);
      expect(DeveloperMode.current.capturing, isTrue);
    });

    testWidgets('有记录时显示明细，可清空', (tester) async {
      DeveloperMode.apply(
        const DeveloperModeSettings(enabled: true, requestCapture: true),
      );
      DebugRequestLog.record(
        DebugRequestRecord(
          time: DateTime(2026, 10, 7, 10, 30),
          method: 'GET',
          url: 'https://example.com/list',
          source: '示例源',
          host: 'example.com',
          status: 200,
          elapsed: const Duration(milliseconds: 128),
          requestHeaders: const <String, String>{'User-Agent': 'UA'},
        ),
      );
      await pumpPanel(tester);

      expect(find.textContaining('GET 200 128ms'), findsOneWidget);
      expect(find.textContaining('example.com/list'), findsWidgets);

      await tester.tap(find.byTooltip('清空抓包'));
      await tester.pumpAndSettle();
      expect(DebugRequestLog.snapshot, isEmpty);
      expect(find.textContaining('抓包未开启'), findsNothing);
    });
  });

  group('全局网络设置摘要（面板里的运行环境）', () {
    tearDown(LumeNet.resetForTesting);

    test('面板读取的是当前全局设置', () {
      LumeNet.apply(
        const NetworkSettings(
          globalConcurrency: 10,
          perHostConcurrency: 3,
          userAgent: 'UA-test',
        ),
      );
      expect(LumeNet.settings.globalConcurrency, 10);
      expect(LumeNet.settings.userAgent, 'UA-test');
    });
  });
}
