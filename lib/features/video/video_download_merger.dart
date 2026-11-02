import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Stream-copy remuxing: no re-encoding and no media bytes on the method channel.
class VideoDownloadMerger {
  static const channel = MethodChannel('lumebox/video_remux');
  final _processes = <String, Process>{};
  final _cancelled = <String>{};

  Future<void> merge(Directory directory, File output, String id) async {
    _cancelled.remove(id);
    if (Platform.isIOS) {
      await channel.invokeMethod<void>('merge', {
        'directory': directory.absolute.path,
        'id': id,
      });
      return;
    }
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError('当前平台尚未提供视频合并');
    }
    // Desktop builds can use an installed FFmpeg. iOS uses its bundled libraries.
    final process = await Process.start('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      '-protocol_whitelist',
      'file,crypto,data',
      '-allowed_extensions',
      'ALL',
      '-extension_picky',
      '0',
      '-i',
      p.join(directory.path, 'index.m3u8'),
      '-map',
      '0:v:0',
      '-map',
      '0:a?',
      '-c',
      'copy',
      '-avoid_negative_ts',
      'make_zero',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      output.path,
    ]);
    _processes[id] = process;
    if (_cancelled.contains(id)) process.kill();
    // Drain diagnostics without retaining site paths or unbounded output.
    final errors = process.stderr.drain<void>();
    final stdout = process.stdout.drain<void>();
    try {
      final code = await process.exitCode;
      await Future.wait([errors, stdout]);
      if (code != 0) throw StateError('MP4 合并失败，原始分片已保留（$code）');
    } finally {
      _processes.remove(id);
      _cancelled.remove(id);
    }
  }

  Future<void> cancel(String id) async {
    if (Platform.isIOS) {
      await channel.invokeMethod<void>('cancel', {'id': id});
    } else {
      _cancelled.add(id);
      _processes[id]?.kill();
    }
  }
}
