import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../session/section.dart';
import '../session/privacy_settings.dart';

enum ResourceKind {
  audioBook('音频'),
  video('视频');

  const ResourceKind(this.label);
  final String label;
  Section get defaultSection => Section.video;
}

class MediaTrackInfo {
  const MediaTrackInfo({
    this.known = false,
    this.audio = false,
    this.video = false,
    this.width,
    this.height,
  });
  final bool known, audio, video;
  final double? width, height;
  ResourceKind? get kind => !known
      ? null
      : video
      ? ResourceKind.video
      : audio
      ? ResourceKind.audioBook
      : null;
}

class MediaTrackProbe {
  const MediaTrackProbe();
  static final _cache = <String, ({DateTime time, MediaTrackInfo value})>{};
  Future<MediaTrackInfo> inspect(
    Uri uri, {
    Map<String, String> headers = const {},
    bool includeDimensions = false,
  }) {
    final key = sha256
        .convert(
          utf8.encode(jsonEncode([uri.toString(), headers, includeDimensions])),
        )
        .toString();
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 5)) {
      return Future.value(cached.value);
    }
    if (_cache.length >= 64) _cache.remove(_cache.keys.first);
    return _inspect(uri, headers, includeDimensions: includeDimensions).then((
      value,
    ) {
      _cache[key] = (time: DateTime.now(), value: value);
      return value;
    });
  }

  Future<MediaTrackInfo> _inspect(
    Uri uri,
    Map<String, String> headers, {
    required bool includeDimensions,
  }) async {
    try {
      final data = await const MethodChannel('lumebox/mediaTracks')
          .invokeMapMethod<String, dynamic>('inspect', {
            'url': uri.toString(),
            'headers': headers,
            if (includeDimensions) 'includeDimensions': true,
          })
          .timeout(const Duration(seconds: 10));
      return MediaTrackInfo(
        known: data?['known'] == true,
        audio: data?['audio'] == true,
        video: data?['video'] == true,
        width: (data?['width'] as num?)?.toDouble(),
        height: (data?['height'] as num?)?.toDouble(),
      );
    } catch (_) {
      return const MediaTrackInfo();
    }
  }
}

class ResourceEpisode {
  const ResourceEpisode({
    required this.id,
    required this.title,
    this.url,
    this.headers = const {},
  });
  final String id, title;
  final Uri? url;
  final Map<String, String> headers;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'url': url?.toString(),
    'headers': headers,
  };
  static ResourceEpisode fromJson(Map data) => ResourceEpisode(
    id: data['id'] as String,
    title: data['title'] as String,
    url: data['url'] is String ? Uri.tryParse(data['url'] as String) : null,
    headers: data['headers'] is Map
        ? Map<String, String>.from(data['headers'] as Map)
        : const {},
  );
}

class MediaResource {
  const MediaResource({
    required this.id,
    required this.title,
    required this.kind,
    required this.destination,
    required this.episodes,
    this.originSection,
    this.sourceId,
    this.itemId,
    this.cover,
    this.manual = false,
  });
  final String id, title;
  final ResourceKind kind;
  final Section destination;
  final bool manual;
  final Section? originSection;
  final String? sourceId, itemId, cover;
  final List<ResourceEpisode> episodes;
  static String sourceKey(Section section, String source, String item) => sha256
      .convert(utf8.encode(jsonEncode([section.id, source, item])))
      .toString();
  MediaResource placed(ResourceKind kind, Section section) => MediaResource(
    id: id,
    title: title,
    kind: kind,
    destination: section,
    episodes: episodes,
    originSection: originSection,
    sourceId: sourceId,
    itemId: itemId,
    cover: cover,
    manual: true,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'kind': kind.name,
    'destination': destination.id,
    'episodes': episodes.map((e) => e.toJson()).toList(),
    'originSection': originSection?.id,
    'sourceId': sourceId,
    'itemId': itemId,
    'cover': cover,
    'manual': manual,
  };
  static MediaResource fromJson(Map data) => MediaResource(
    id: data['id'] as String,
    title: data['title'] as String,
    kind: ResourceKind.values.byName(data['kind'] as String),
    destination: data['destination'] == 'novel' && data['kind'] == 'audioBook'
        ? Section.video
        : Section.values.singleWhere((s) => s.id == data['destination']),
    episodes: (data['episodes'] as List)
        .map((e) => ResourceEpisode.fromJson(e as Map))
        .toList(),
    originSection: Section.values
        .where((s) => s.id == data['originSection'])
        .firstOrNull,
    sourceId: data['sourceId'] as String?,
    itemId: data['itemId'] as String?,
    cover: data['cover'] as String?,
    manual: data['manual'] == true,
  );
}

/// Cross-library placement is a reference overlay. Source IDs, scripts and
/// existing section databases are never moved or rewritten.
class MediaLibrary extends ChangeNotifier {
  static final instance = MediaLibrary();
  final Map<String, MediaResource> _items = {};
  Future<void>? _loading;
  Future<void> _pending = Future.value();
  File? _file;
  List<MediaResource> entries(Section section) => _items.values
      .where(
        (r) =>
            r.destination == section &&
            PrivacySettings.instance.allowsSource(r.sourceId ?? r.id, r.title),
      )
      .toList();
  MediaResource? byId(String id) => _items[id];
  Future<void> boot({Directory? directory}) =>
      _loading ??= _boot(directory).catchError((_) {
        notifyListeners();
      });
  Future<void> _boot(Directory? directory) async {
    final base = directory ?? await getApplicationSupportDirectory();
    _file = File('${base.path}/media_library.json');
    if (await _file!.exists()) {
      try {
        final data = jsonDecode(await _file!.readAsString());
        if (data is List) {
          for (final row in data) {
            try {
              final item = MediaResource.fromJson(row as Map);
              _items[item.id] = item;
            } catch (_) {
              /* A malformed row cannot hide valid books. */
            }
          }
        }
      } on FormatException {
        /* Empty safe defaults; never touch source data. */
      }
    }
    notifyListeners();
  }

  Future<MediaResource> add(MediaResource item) async {
    await boot();
    final previous = _items[item.id];
    if (previous?.manual == true && !item.manual) {
      item = item.placed(previous!.kind, previous.destination);
    }
    _items[item.id] = item;
    notifyListeners();
    await _save();
    return item;
  }

  Future<MediaResource> move(
    String id,
    ResourceKind kind,
    Section section,
  ) async {
    await boot();
    if (section != Section.video) {
      throw ArgumentError('不支持的目标库');
    }
    final item = _items[id];
    if (item == null) throw StateError('资源不存在');
    return add(item.placed(kind, section));
  }

  bool visibleAtOrigin(Section section, String source, String item) {
    final value = _items[MediaResource.sourceKey(section, source, item)];
    return value == null || value.destination == section;
  }

  Future<void> remove(String id) async {
    await boot();
    _items.remove(id);
    notifyListeners();
    await _save();
  }

  Future<void> _save() {
    final encoded = jsonEncode(_items.values.map((i) => i.toJson()).toList());
    final next = _pending.then((_) async {
      await _file!.parent.create(recursive: true);
      final temp = File('${_file!.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(_file!.path);
    });
    _pending = next.catchError((_) {});
    return next;
  }
}
