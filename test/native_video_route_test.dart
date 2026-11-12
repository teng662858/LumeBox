import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/native_video_bridge.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/features/video/video_player_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('lumebox/native_video');
  late ReadingLibrary library;
  late Directory directory;
  late NativeVideoBridge bridge;
  final calls = <MethodCall>[];
  setUp(() async {
    calls.clear();
    directory = await Directory.systemTemp.createTemp('native-route-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await SectionScope.open(Section.video);
    library = await ReadingLibrary.open(Section.video);
    bridge = NativeVideoBridge();
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    await SectionScope.closeAll();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/mediaTracks'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });
  Widget route() => MaterialApp(
    home: VideoPlayerPage(
      media: PlayerMedia(uri: Uri.parse('https://example/video.mp4')),
      library: library,
      bridge: bridge,
      prepareMedia: (media, _) async => media,
      playerFactory: (_) =>
          throw StateError('Legacy Dart engine must not be created'),
    ),
  );
  testWidgets(
    'route hands off once, does not run a hidden Flutter animation, and tears down on exit',
    (tester) async {
      await tester.pumpWidget(route());
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    },
  );
  testWidgets('native presentation failure keeps back and retry available', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') {
        throw PlatformException(code: 'native', message: 'cannot present');
      }
      return null;
    });
    await tester.pumpWidget(route());
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot present'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
