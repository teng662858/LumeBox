import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/playback_failure.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/video/playback_failure_panel.dart';

import 'support/fake_source_manager.dart';

void main() {
  test('failure categories keep access restrictions distinct from network and stale scripts', () {
    for (final (raw, kind) in [
      ('HTTP 401 Unauthorized', PlaybackFailureKind.login),
      ('HTTP 402 payment required', PlaybackFailureKind.membership),
      ('此集需要会员', PlaybackFailureKind.membership),
      ('HTTP 403 Forbidden', PlaybackFailureKind.forbidden),
      ('TimeoutException', PlaybackFailureKind.network),
      ('TLS_HANDSHAKE_FAILED', PlaybackFailureKind.network),
      ('TypeError: old script failed', PlaybackFailureKind.invalidSource),
      ('HTTP 404', PlaybackFailureKind.invalidSource),
      ('网络异常：HTTP 404', PlaybackFailureKind.invalidSource),
      ('HTTP 503', PlaybackFailureKind.network),
      ('unsupported codec', PlaybackFailureKind.decoder),
    ]) {
      expect(PlaybackFailure.from(raw).kind, kind, reason: raw);
    }
  });
  testWidgets(
    'invalid source offers update with versions and retains working retry',
    (tester) async {
      const old = SourceDescriptor(
        id: 'video',
        name: '视频源',
        version: '1',
        enabled: true,
        originUrl: 'https://example.test/source.js',
        siteUrl: 'https://example.test',
      );
      const next = SourceDescriptor(
        id: 'video',
        name: '视频源',
        version: '2',
        enabled: true,
        originUrl: 'https://example.test/source.js',
        siteUrl: 'https://example.test',
      );
      final manager = FakeSourceManager(sources: [old]);
      manager.updateResults['video'] = const SourceUpdateResult.updated(
        next,
        previousVersion: '1',
      );
      var retries = 0, updates = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackFailurePanel(
              error: 'HTTP 404',
              sourceId: 'video',
              manager: manager,
              retry: () async {
                retries++;
              },
              onUpdated: () async {
                updates++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('打开源站'), findsNothing);
      await tester.tap(find.text('更多恢复方式'));
      await tester.pumpAndSettle();
      expect(find.text('打开源站'), findsOneWidget);
      await tester.tap(find.text('更新源'));
      await tester.pumpAndSettle();
      expect(manager.updatedIds, ['video']);
      expect(updates, 1);
      expect(find.textContaining('1 → 2'), findsOneWidget);
      await tester.tap(find.text('重试播放'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'membership failure does not advertise script updates as an unlock',
    (tester) async {
      final manager = FakeSourceManager(
        sources: const [
          SourceDescriptor(
            id: 'a',
            name: 'A',
            version: '1',
            enabled: true,
            siteUrl: 'https://example.test',
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackFailurePanel(
              error: 'VIP 会员限制',
              sourceId: 'a',
              manager: manager,
              retry: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('源站要求会员或购买'), findsOneWidget);
      expect(find.text('打开源站'), findsNothing);
      await tester.tap(find.text('更多恢复方式'));
      await tester.pumpAndSettle();
      expect(find.text('打开源站'), findsOneWidget);
      expect(find.text('更新源'), findsNothing);
    },
  );
}
