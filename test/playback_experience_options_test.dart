import 'package:lume_box/core/media/playback_focus.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/net/network_settings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cache/media_preload.dart';
import 'package:lume_box/core/player/mpv_engine.dart';
import 'package:lume_box/core/player/playback_network.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/player/video_disk_cache.dart';
import 'package:lume_box/core/source/source_models.dart';
import 'package:lume_box/features/video/seek_preview.dart';
import 'package:lume_box/shared/widgets/number_setting_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all expanded buffering limits survive reopening, including arbitrary disk sizes', () async {
    final root = await Directory.systemTemp.createTemp('playback-options-');
    final policy = MediaPreload();
    final disk = VideoDiskCache();
    final reopenedDisk = VideoDiskCache();
    try {
      await policy.boot(directory: root);
      policy.update(
        triggerSeconds: 1800,
        triggerPercent: 99,
        bufferSeconds: 300,
        capacityMb: 2048,
        wifiOnly: false,
        pageCacheSeconds: 900,
      );
      await policy.flush();
      final reopened = MediaPreload();
      await reopened.boot(directory: root);
      expect(
        (
          reopened.triggerSeconds,
          reopened.triggerPercent,
          reopened.bufferSeconds,
          reopened.capacityMb,
          reopened.wifiOnly,
          reopened.pageCacheSeconds,
        ),
        (1800, 99, 300, 2048, false, 900),
      );
      reopened.dispose();
      await disk.boot(directory: root);
      await disk.configure(capacityMb: 7777);
      await reopenedDisk.boot(directory: root);
      expect(reopenedDisk.capacityMb, 7777);
      await disk.configure(capacityMb: 99999);
      expect(disk.capacityMb, 20480);
      await disk.configure(capacityMb: 1);
      expect(disk.capacityMb, 100);
    } finally {
      await disk.close();
      await reopenedDisk.close();
      await policy.flush();
      policy.dispose();
      await root.delete(recursive: true);
    }
  });
  test('forward and backward steps persist independently; legacy decoder bool remains valid', () {
    final gesture = const PlayerGestureOptions().copyWith(
      forwardSeconds: 90,
      backwardSeconds: 5,
    );
    final restored = PlayerGestureOptions.fromJson(gesture.toJson());
    expect(restored, gesture);
    expect((restored.forwardSeconds, restored.backwardSeconds), (90, 5));
    expect(
      PlayerGestureOptions.fromJson({
        'forwardSeconds': -1,
        'backwardSeconds': 999,
      }).backwardSeconds,
      300,
    );
    expect(
      const PlayerSettings(hardwareDecoding: false).hardwareDecoding,
      false,
    );
    expect(
      const PlayerSettings()
          .copyWith(decodingPreset: DecodingPreset.software)
          .hardwareDecoding,
      false,
    );
    expect(
      const PlayerSettings(hardwareDecoding: false)
          .copyWith(decodingPreset: DecodingPreset.hardware)
          .hardwareDecoding,
      true,
    );
  });
  testWidgets(
    'network checks coalesce, cellular stops speculative work and dispose cancels timeouts',
    (tester) async {
      const channel = MethodChannel('lumebox/experience');
      var facts = <String, Object>{'wifi': true, 'cellular': false};
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            calls++;
            return facts;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final network = PlaybackNetwork();
      expect(network.allowsPreload(true), false);
      for (var i = 0; i < 100; i++) {
        network.refresh();
      }
      await tester.pump();
      expect(calls, 1);
      expect(network.allowsPreload(true), true);
      facts = {'wifi': false, 'cellular': true};
      network.refresh(force: true);
      await tester.pump();
      expect(network.cellular, true);
      expect(network.allowsPreload(true), false);
      expect(network.allowsPreload(false), true);
      final hung = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => hung.future);
      network.refresh(force: true);
      network.dispose();
      await tester.pump();
      hung.complete(null);
      await tester.pump();
    },
  );
  test('playing media reserves image slots for visible work', () async {
    Future<void> release() async {}
    PlaybackFocus.register('cache-test', release);
    await PlaybackFocus.acquire('cache-test');
    PlaybackFocus.setPlaying('cache-test', true);
    final gate = Completer<void>();
    final started = <String>[];
    final queue = NetworkQueue(
      settings: const NetworkSettings(),
      sender: (request) async {
        started.add(request.url);
        await gate.future;
        return const NetworkResponse(statusCode: 200, body: [], headers: {});
      },
    );
    final requests = [
      queue.send(
        NetworkRequest(
          url: 'https://a.test/image',
          source: '图片缓存',
          isForeground: () => false,
        ),
      ),
      queue.send(
        NetworkRequest(
          url: 'https://b.test/image',
          source: '图片缓存',
          isForeground: () => false,
        ),
      ),
      queue.send(
        NetworkRequest(
          url: 'https://c.test/image',
          source: '图片缓存',
          isForeground: () => true,
        ),
      ),
    ];
    try {
      await Future<void>.delayed(Duration.zero);
      expect(
        started,
        containsAll(['https://a.test/image', 'https://c.test/image']),
      );
      expect(started, isNot(contains('https://b.test/image')));
      gate.complete();
      await Future.wait(requests);
      expect(started.length, 3);
    } finally {
      if (!gate.isCompleted) gate.complete();
      PlaybackFocus.setPlaying('cache-test', false);
      PlaybackFocus.unregister('cache-test', release);
    }
  });

  testWidgets('numeric edits reject out-of-range input and commit once', (
    tester,
  ) async {
    final changes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NumberSettingTile(
            title: '预算',
            value: 256,
            min: 32,
            max: 1024,
            unit: 'MiB',
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('预算'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '9999');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(changes, isEmpty);
    expect(find.text('请输入 32～1024 的整数'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '768');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(changes, [768]);
  });
  test('source thumbnails are optional, sorted and validated without changing source scripts', () {
    final content = ChapterContent.parse({
      'kind': 'video',
      'url': 'https://video.test/v.mp4',
      'thumbnails': [
        {'time': 30, 'url': 'https://video.test/30.jpg'},
        {'time': 0, 'url': 'https://video.test/0.jpg'},
        {'time': -1, 'url': 'file:///bad'},
        {'time': 'NaN', 'url': 'https://video.test/bad'},
      ],
    }) as VideoContent;
    expect(content.previews.map((p) => p.seconds), [0, 30]);
  });
  testWidgets(
    'decoded previews are sampled sparingly, bounded and invalidated per media',
    (tester) async {
      final frames = SeekPreviewFrames()..reset('one');
      final capture = _Capture();
      await tester.runAsync(() => frames.sample(capture, 10));
      await tester.runAsync(() => frames.sample(capture, 11));
      expect(capture.calls, 1);
      expect(frames.nearest(12)?.$1, 10);
      expect(frames.nearest(100), isNull);
      frames.reset('two');
      expect(frames.nearest(10), isNull);
      frames.dispose();
    },
  );
}

class _Capture implements VideoFrameCapture {
  int calls = 0;
  @override
  Future<MpvVideoFrame?> captureFrame() async {
    calls++;
    return MpvVideoFrame(
      pixels: Uint8List(4 * 4 * 4),
      width: 4,
      height: 4,
      stride: 16,
    );
  }
}
