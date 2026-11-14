import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../core/player/hls_attributes.dart';
import 'mp4_language.dart';

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
    final entry = File(p.join(directory.path, 'index.m3u8'));
    final audioMetadata = <String, String>{};
    for (final line in await entry.readAsLines()) {
      if (!line.startsWith('#EXT-X-MEDIA:')) continue;
      final attributes = hlsRawAttributes(line);
      if (attributes['TYPE'] != 'AUDIO') continue;
      final language = hlsAttributeValue(attributes['LANGUAGE'] ?? '');
      final code = mp4Language(language);
      if (code != null) {
        audioMetadata['language:${_selectorValue(language)}'] = 'language=$code';
      }
      final name = hlsAttributeValue(attributes['NAME'] ?? '');
      if (name.isNotEmpty) {
        audioMetadata['comment:${_selectorValue(name)}'] = 'handler_name=$name';
      }
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
      entry.path,
      '-map',
      '0:v:0',
      '-map',
      '0:a?',
      for (final tag in audioMetadata.entries) ...[
        '-metadata:s:a:m:${tag.key}', tag.value,
      ],
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

  // FFmpeg parses stream specifiers even when no shell is involved.
  static String _selectorValue(String value) =>
      value.replaceAllMapped(RegExp(r"[:\\']"), (m) => '\\${m[0]}');

  Future<void> cancel(String id) async {
    if (Platform.isIOS) {
      await channel.invokeMethod<void>('cancel', {'id': id});
    } else {
      _cancelled.add(id);
      _processes[id]?.kill();
    }
  }
}
