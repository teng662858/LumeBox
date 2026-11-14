import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/player/hls_attributes.dart';

/// Exports an actual local file without loading a movie into a platform-channel byte buffer.
abstract final class LocalDownloadExport {
  static bool _busy = false;
  static Future<bool> file(File file) async {
    if (_busy) throw StateError('另一个导出窗口尚未关闭');
    if (!await file.exists()) throw StateError('本地文件不存在');
    _busy = true;
    try {
      if (Platform.isIOS) {
        return await const MethodChannel(
              'lumebox/configuration',
            ).invokeMethod<bool>('exportPath', {'path': file.absolute.path}) ??
            false;
      }
      final destination = await getSaveLocation(
        suggestedName: p.basename(file.path),
      );
      if (destination == null) return false;
      if (p.equals(
        p.normalize(file.absolute.path),
        p.normalize(File(destination.path).absolute.path),
      )) {
        return true;
      }
      await file.copy(destination.path);
      return true;
    } finally {
      _busy = false;
    }
  }

  static Future<bool> directory(
    Directory dir, {
    String? entryPoint,
    Future<bool> Function(File)? exporter,
  }) async {
    final temporary = await getTemporaryDirectory();
    final target = p.join(
      temporary.path,
      'LumeBox-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    try {
      final source = dir.absolute.path;
      await Isolate.run(() async {
        final encoder = ZipFileEncoder();
        if (entryPoint == null) {
          await encoder.zipDirectory(
            Directory(source),
            filename: target,
            level: ZipFileEncoder.store,
            followLinks: false,
          );
        } else {
          encoder.create(target, level: ZipFileEncoder.store);
          try {
            final pending = <String>[entryPoint];
            final seen = <String>{};
            while (pending.isNotEmpty) {
              final relative = p.normalize(pending.removeLast());
              if (!seen.add(relative)) continue;
              final path = p.normalize(p.join(source, relative));
              if (!p.isWithin(source, path)) throw StateError('离线清单包含无效路径');
              final file = File(path);
              if (!await file.exists()) throw StateError('离线文件不完整');
              await encoder.addFile(file, p.posix.joinAll(p.split(relative)));
              if (!relative.endsWith('.m3u8')) continue;
              for (final line in await file.readAsLines()) {
                final refs = <String>[
                  if (line.isNotEmpty && !line.startsWith('#')) line,
                  for (final attribute in hlsUriAttributes(line)) attribute.value,
                ];
                for (final ref in refs) {
                  if (Uri.parse(ref).hasScheme || p.isAbsolute(ref)) {
                    throw StateError('离线清单仍包含网络地址');
                  }
                  pending.add(p.join(p.dirname(relative), ref));
                }
              }
            }
          } finally {
            await encoder.close();
          }
        }
      });
      return await (exporter ?? file)(File(target));
    } finally {
      final temporaryFile = File(target);
      if (await temporaryFile.exists()) await temporaryFile.delete();
    }
  }
}
