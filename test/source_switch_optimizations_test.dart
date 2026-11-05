import 'package:lume_box/core/session/section.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_cancellation.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_runtime_pins.dart';
import 'package:lume_box/features/reading/source_home_view.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

class _HomeSource extends MockDataSource implements HomeCapable {
  _HomeSource() : super(section: Section.video);
  int probes = 0, calls = 0;
  Completer<SourceHome>? gate;
  NetworkCancellation? token;
  @override
  Future<bool> supportsHome() async {
    probes++;
    return true;
  }

  @override
  Future<SourceHome> home() async {
    calls++;
    token = NetworkCancellation.current;
    return gate?.future ??
        const SourceHome(
          items: [SourceItem(id: 'one', title: '缓存首页')],
        );
  }
}

Widget _page(
  _HomeSource source, {
  Duration ttl = const Duration(minutes: 2),
  Key? homeKey,
  VoidCallback? onLoaded,
}) => MaterialApp(
  home: Scaffold(
    body: SourceHomeView(
      key: homeKey,
      source: source,
      pipeline: null,
      cacheTtl: ttl,
      onOpenItem: (_) {},
      onHomeLoaded: onLoaded,
    ),
  ),
);

void main() {
  setUp(SectionPreloader.discard);
  tearDown(SectionPreloader.discard);

  test('首页能力探测共享同一次请求，同 id 替换对象不会误用旧能力', () async {
    final source = _HomeSource();
    expect(
      await Future.wait(
        List.generate(8, (_) => SectionPreloader.supportsHome(source)),
      ),
      everyElement(true),
    );
    expect(source.probes, 1);
    final replacement = _HomeSource();
    await SectionPreloader.supportsHome(replacement);
    expect(replacement.probes, 1);
  });

  testWidgets('预热接管超时先取消旧请求，晚到结果不能污染缓存', (tester) async {
    final source = _HomeSource()..gate = Completer<SourceHome>();
    final manager = FakeSourceManager(
      sources: [
        SourceDescriptor(
          id: source.id,
          name: source.name,
          version: '1',
          enabled: true,
        ),
      ],
      opened: {source.id: source},
    );
    final warm = SectionPreloader.warm(Section.video, manager: manager);
    await tester.pump();
    expect(source.calls, 1);
    final handoff = SectionPreloader.waitForWarm(
      Section.video,
      sourceId: source.id,
      home: true,
    );
    await tester.pump(const Duration(seconds: 3));
    await handoff;
    expect(source.token!.isCancelled, isTrue);
    source.gate!.complete(const SourceHome());
    await warm;
    expect(SectionPreloader.hasWarm(Section.video), isFalse);
  });

  testWidgets('切回新鲜首页立即恢复，不重复请求并通知宿主', (tester) async {
    final source = _HomeSource();
    await tester.pumpWidget(_page(source, homeKey: const ValueKey('first')));
    await tester.pumpAndSettle();
    expect(find.text('缓存首页'), findsOneWidget);
    var loaded = 0;
    await tester.pumpWidget(
      _page(
        source,
        homeKey: const ValueKey('return'),
        onLoaded: () => loaded++,
      ),
    );
    expect(find.text('缓存首页'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(source.calls, 1);
    expect(loaded, 1);
  });

  testWidgets('过期首页边展示边刷新，刷新失败保留内容且可重试', (tester) async {
    final source = _HomeSource();
    await tester.pumpWidget(_page(source, homeKey: const ValueKey('first')));
    await tester.pumpAndSettle();
    source.gate = Completer<SourceHome>();
    await tester.pumpWidget(
      _page(source, homeKey: const ValueKey('stale'), ttl: Duration.zero),
    );
    await tester.pump();
    expect(find.text('缓存首页'), findsOneWidget);
    expect(source.calls, 2);
    source.gate!.completeError(
      const SourceException(SourceErrorKind.network, '网络中断'),
    );
    await tester.pumpAndSettle();
    expect(find.text('缓存首页'), findsOneWidget);
    expect(find.textContaining('保留'), findsOneWidget);
    source.gate = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(source.calls, 3);
    expect(find.textContaining('保留'), findsNothing);
  });

  test('运行时引用计数隔离板块，重复释放不影响另一个播放器或下载', () {
    final first = SourceRuntimePins.retain(Section.video, 'same');
    final second = SourceRuntimePins.retain(Section.video, 'same');
    final comic = SourceRuntimePins.retain(Section.comic, 'same');
    first();
    first();
    expect(SourceRuntimePins.contains(Section.video, 'same'), isTrue);
    second();
    expect(SourceRuntimePins.contains(Section.video, 'same'), isFalse);
    expect(SourceRuntimePins.contains(Section.comic, 'same'), isTrue);
    comic();
    expect(SourceRuntimePins.contains(Section.comic, 'same'), isFalse);
  });
}
