import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/reading/reading.dart';
import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_subscription_sync.dart';
import '../../core/util/lume_log.dart';
import 'log_report.dart';

class DiagnosticBundle {
  const DiagnosticBundle({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

/// Collect metadata only: no source scripts, databases, media, credentials or request bodies.
class DiagnosticExporter {
  static String redact(String input) {
    var text = input.replaceAll(
      RegExp(r'data:[^\s]+', caseSensitive: false),
      '[image data omitted]',
    );
    text = text.replaceAllMapped(
      RegExp(r'https?://[^\s<>"\x27]+', caseSensitive: false),
      (match) {
        final uri = Uri.tryParse(match[0]!);
        return uri?.host.isNotEmpty == true
            ? '${uri!.scheme}://${uri.host}/[path omitted]'
            : '[URL omitted]';
      },
    );
    text = text.replaceAll(
      RegExp(
        r'(authorization|proxy-authorization|cookie|set-cookie|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret|credential|token|session|密钥|密码)\s*["\x27]?\s*[:=]\s*[^\r\n]+',
        caseSensitive: false,
      ),
      '[credential omitted]',
    );
    text = text.replaceAll(
      RegExp(r'\bBearer\s+[^\s,}]+', caseSensitive: false),
      'Bearer [omitted]',
    );
    text = text.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]+'), '[key omitted]');
    text = text.replaceAll(
      RegExp(r'\b[A-Za-z]:[\\/][^\r\n"<>]+'),
      '[local path omitted]',
    );
    text = text.replaceAll(
      RegExp(r'/(Users|home|private|var|data|storage)/[^\s"<>]+'),
      '[local path omitted]',
    );
    text = text.replaceAll(
      RegExp(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}'),
      '[email omitted]',
    );
    return text.length > 20000
        ? '${text.substring(0, 20000)}[truncated]'
        : text;
  }

  static Object? sanitize(Object? value) {
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(
          redact('$key'),
          RegExp(
                r'key|token|password|secret|cookie|authorization|credential|session|positions',
                caseSensitive: false,
              ).hasMatch('$key')
              ? '[omitted]'
              : sanitize(item),
        ),
      );
    }
    if (value is Iterable) return value.map(sanitize).toList();
    if (value is String) return redact(value);
    return value;
  }

  Future<DiagnosticBundle> collect() async {
    final created = DateTime.now();
    final logs = LumeLog.snapshot;
    Map<String, Object?> version;
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      );
      version = {
        'version': info.version,
        'build': info.buildNumber,
        'package': info.packageName,
      };
    } catch (_) {
      version = {'version': 'unavailable'};
    }
    final configuration = <String, Object?>{};
    try {
      final directory = await getApplicationSupportDirectory();
      for (final name in [
        'comic_image_tools.json',
        'speech_cloud.json',
        'tmdb_settings.json',
        'network_settings.json',
        'floating_modules.json',
        'frosted_settings.json',
      ]) {
        final file = File('${directory.path}/$name');
        if (file.existsSync() && file.lengthSync() <= 256 * 1024) {
          try {
            configuration[name] = jsonDecode(file.readAsStringSync());
          } catch (_) {
            configuration[name] = 'unreadable';
          }
        }
      }
    } catch (_) {
      configuration['status'] = 'unavailable';
    }
    final sections = <String, Object?>{};
    for (final section in Section.values) {
      final data = <String, Object?>{};
      try {
        final manager = LumeSources.manager(section);
        data['runtimeAvailable'] = manager.runtimeAvailable;
        if (manager.runtimeAvailable) {
          final sources = await manager.list().timeout(
            const Duration(seconds: 5),
          );
          data['sources'] = [
            for (final source in sources)
              {
                'id': source.id,
                'name': source.name,
                'version': source.version,
                'enabled': source.enabled,
                'broken': source.broken,
                'failureCount': source.failureCount,
                'subscribed': source.subscribed,
              },
          ];
        }
        final library = ReadingLibrary.find(section);
        if (library != null) {
          data['settings'] = {
            for (final entry in library.exportSettings().entries)
              if (entry.key.startsWith('video.player.') ||
                  entry.key.startsWith('comic.reader.') ||
                  entry.key.startsWith('novel.reader.'))
                entry.key: entry.value,
          };
        }
        data['subscriptionChanges'] = SourceSubscriptionSync.notices(section);
      } catch (error) {
        data['collectionError'] = '$error';
      }
      sections[section.id] = data;
    }
    return build(
      created: created,
      metadata: {
        'format': 'lumebox-diagnostics',
        'schema': 1,
        'createdAt': created.toIso8601String(),
        'app': version,
        'environment': {
          'os': Platform.operatingSystem,
          'osVersion': Platform.operatingSystemVersion,
          'dart': Platform.version,
          'locale': Platform.localeName,
          'processors': Platform.numberOfProcessors,
        },
        'sections': sections,
        'configuration': configuration,
      },
      logs: logs,
    );
  }

  static DiagnosticBundle build({
    required DateTime created,
    required Map<String, Object?> metadata,
    required List<LogEntry> logs,
  }) {
    final archive = Archive();
    void add(String name, String text) {
      final data = utf8.encode(text);
      archive.addFile(ArchiveFile(name, data.length, data));
    }

    add(
      'diagnostics.json',
      const JsonEncoder.withIndent('  ').convert(sanitize(metadata)),
    );
    add(
      'recent-logs.txt',
      LogExporter.build([
        for (final entry in logs)
          LogEntry(
            time: entry.time,
            level: entry.level,
            message: redact(entry.message),
            detail: entry.detail == null ? null : redact(entry.detail!),
          ),
      ], generatedAt: created),
    );
    add(
      'README.txt',
      'LumeBox 诊断包\n包含版本、系统环境、源状态、已打开板块的播放/阅读设置和最近运行日志（最多500条）。\n不包含源脚本、数据库、阅读正文、图片音频视频或密钥文件。日志里的凭据、URL路径参数和本地路径已过滤。\n日志仅覆盖当前启动会话；重启前的问题及原生崩溃堆栈可能不在包内。\n排查时请同时说明：问题操作步骤、发生时间、期望结果、实际结果。诊断包帮助定位，不保证涵盖所有原因。\n',
    );
    return DiagnosticBundle(
      name: 'LumeBox-diagnostics-${created.millisecondsSinceEpoch}.zip',
      bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
    );
  }
}
