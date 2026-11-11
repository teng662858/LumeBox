import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/util/lume_log.dart';
import 'package:lume_box/core/player/playback_diagnostics.dart';

void main() {
  test('previous-session errors are bounded, redacted, survive reopen, and can be cleared', () async {
    final dir = await Directory.systemTemp.createTemp('lume-previous-errors-');
    try {
      await LumeLog.startPersistence(directory: dir);
      LumeLog.info('ordinary info must not persist');
      for (var i = 0; i < 100; i++) {
        LumeLog.warn(
          'failure $i https://video.example/private/file.m3u8?token=never-store-this password=never-store-password',
        );
      }
      await LumeLog.flushPersistence();
      final file = File('${dir.path}/last-session-errors.json');
      final text = await file.readAsString();
      expect(await file.length(), lessThanOrEqualTo(128 * 1024));
      expect(jsonDecode(text), hasLength(80));
      for (final secret in [
        'private/file',
        'never-store-this',
        'never-store-password',
        'ordinary info',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      await LumeLog.stopPersistence();
      await LumeLog.startPersistence(directory: dir);
      expect(LumeLog.previousSession, hasLength(80));
      expect(LumeLog.previousSession.last.message, contains('failure 99'));
      expect(
        LumeLog.previousSession.every((e) => e.level == LogLevel.warn),
        isTrue,
      );
      final message = LumeLog.previousSession.last.message;
      expect(message, contains('https://video.example/[path omitted]'));
      expect(message, isNot(contains('omitted] omitted]')));
      await LumeLog.playbackCheckpoint('[aether] 原生装载开始 · HLS');
      // The checkpoint must already be on disk before entering the native call.
      final rows = jsonDecode(await file.readAsString()) as List;
      expect(rows.last['level'], 'info');
      expect(rows.last['message'], contains('原生装载开始'));
      LumeLog.clear();
      await LumeLog.flushPersistence();
      expect(await file.exists(), false);
    } finally {
      await LumeLog.stopPersistence();
      LumeLog.clear();
      await dir.delete(recursive: true);
    }
  });
  test('playback metadata records stages and hosts without playback credentials or paths', () {
    for (var i = 0; i < 40; i++) {
      PlaybackDiagnostics.record(
        'media-failed',
        source: 'source',
        kernel: 'mpv',
        uri: Uri.parse('https://cdn.example/private?id=secret'),
        elapsedMs: i,
        error: 'failed https://cdn.example/private?token=never-store-this',
      );
    }
    final rows = PlaybackDiagnostics.snapshot;
    expect(rows, hasLength(30));
    expect(rows.last['elapsedMs'], 39);
    expect(rows.last['host'], 'cdn.example');
    expect(jsonEncode(rows), isNot(contains('/private')));
    expect(jsonEncode(rows), isNot(contains('never-store-this')));
  });
}
