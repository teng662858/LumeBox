import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/player/hls_attributes.dart';
import '../../core/player/hls_variants.dart';

typedef _LocalVariant = ({
  String media,
  Map<String, String> attributes,
  List<Map<String, String>> renditions,
});

/// The downloader writes one selected variant per master. Decoders expect
/// each URI in the final master to lead directly to a media playlist.
Future<void> flattenOfflineHlsMaster(File entry) async {
  final root = await entry.parent.resolveSymbolicLinks();
  var nested = false;
  final cache = <(String, int), _LocalVariant>{};

  Future<_LocalVariant> read(File file, int depth) async {
    if (depth > 3 || !p.isWithin(root, await file.resolveSymbolicLinks())) {
      throw const FormatException('离线清单路径或嵌套层级无效');
    }
    final key = (file.path, depth);
    final known = cache[key];
    if (known != null) return known;
    final name = p
        .split(p.relative(file.path, from: entry.parent.path))
        .join('/');
    if (await file.length() > 4 * 1024 * 1024) {
      throw const FormatException('离线清单过大');
    }
    final lines = const LineSplitter().convert(await file.readAsString());
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
      throw const FormatException('离线清单格式无效');
    }
    final variants = hlsVariants(lines).toList();
    if (variants.isEmpty) {
      return cache[key] = (
        media: name,
        attributes: const <String, String>{},
        renditions: const <Map<String, String>>[],
      );
    }
    if (depth > 0) nested = true;

    Future<_LocalVariant> child(String reference) {
      final uri = Uri.parse(reference);
      if (uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) {
        throw const FormatException('离线清单包含非本地地址');
      }
      return read(File.fromUri(file.uri.resolveUri(uri)), depth + 1);
    }

    final candidates = [
      for (final pair in variants)
        (uri: pair.uri, attributes: hlsRawAttributes(lines[pair.tag].trim())),
    ];
    if (candidates.any((v) => hlsVariantHasVideo(v.attributes) != false)) {
      candidates.removeWhere((v) => hlsVariantHasVideo(v.attributes) == false);
    }
    candidates.sort(
      (a, b) => compareHlsQuality(
        hlsVariantQuality(a.attributes),
        hlsVariantQuality(b.attributes),
      ),
    );
    final variant = candidates.first;
    final primary = await child(lines[variant.uri].trim());
    final attributes = {...variant.attributes, ...primary.attributes};
    final renditions = [...primary.renditions];
    final localTypes = <String>{};
    for (final line in lines.map((line) => line.trim())) {
      if (!line.startsWith('#EXT-X-MEDIA:')) continue;
      final track = hlsRawAttributes(line);
      final type = track['TYPE'];
      if (type == null ||
          track['GROUP-ID'] == null ||
          track['GROUP-ID'] != variant.attributes[type]) {
        continue;
      }
      if (localTypes.add(type)) {
        renditions.removeWhere((inner) => inner['TYPE'] == type);
      }
      attributes[type] = track['GROUP-ID']!;
      final uri = track['URI'];
      if (uri != null) {
        final branch = await child(hlsAttributeValue(uri));
        final candidates = branch.renditions.where((r) => r['TYPE'] == type);
        final preferred =
            candidates.where((r) => r['DEFAULT'] == 'YES').firstOrNull ??
            candidates.firstOrNull;
        track['URI'] = preferred?['URI'] ?? '"${branch.media}"';
      }
      renditions.add(track);
    }
    return cache[key] = (
      media: primary.media,
      attributes: attributes,
      renditions: renditions,
    );
  }

  final result = await read(entry, 0);
  if (!nested) return;
  final lines = [
    '#EXTM3U',
    for (final track in result.renditions) hlsTag('#EXT-X-MEDIA', track),
    hlsTag('#EXT-X-STREAM-INF', result.attributes),
    result.media,
  ];
  final temporary = File('${entry.path}.flatten.part');
  try {
    await temporary.writeAsString('${lines.join('\n')}\n', flush: true);
    await temporary.rename(entry.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
