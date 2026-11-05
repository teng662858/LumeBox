import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/explore_view.dart';
import 'package:lume_box/features/shell/section_preloader.dart';

import 'support/fake_source_manager.dart';

class _SerialSource extends MockDataSource implements HomeCapable {
  _SerialSource({this.failHome = false}) : super(section: Section.video);
  final bool failHome;
  final metadata = Completer<void>();
  final calls = <String>[];
  Future<void> _queue = Future.value();
  Future<T> _run<T>(String name, Future<T> Function() body) {
    final result = _queue.then((_) {
      calls.add(name);
      return body();
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<bool> supportsHome() async => true;
  @override
  Future<SourceHome> home() => _run('home', () async {
    if (failHome) {
      throw const SourceException(SourceErrorKind.network, '测试首页失败');
    }
    return const SourceHome(
      items: [SourceItem(id: 'one', title: '先出首页')],
    );
  });
  @override
  Future<List<SourceCategory>> categories() => _run('categories', () async {
    await metadata.future;
    return [const SourceCategory(id: 'cat', title: '随后补齐分类')];
  });
}

void main() {
  tearDown(SectionPreloader.discard);
  for (final fails in [false, true]) {
    testWidgets('PY 首页优先于串行元数据，失败也补齐分类：$fails', (tester) async {
      final source = _SerialSource(failHome: fails);
      await tester.pumpWidget(
        MaterialApp(
          home: ExploreView(
            section: Section.video,
            manager: FakeSourceManager(
              sources: [
                SourceDescriptor(
                  id: source.id,
                  name: source.name,
                  version: '1',
                  enabled: true,
                  runtimeKind: 'python',
                ),
              ],
              opened: {source.id: source},
            ),
            onOpenItem: (_) {},
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(source.calls.first, 'home');
      expect(source.calls, ['home', 'categories']);
      if (!fails) expect(find.text('先出首页'), findsOneWidget);
      source.metadata.complete();
      await tester.pumpAndSettle();
      expect(find.text('随后补齐分类'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
