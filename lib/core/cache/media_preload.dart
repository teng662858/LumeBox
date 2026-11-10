import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Shared speculative-work policy. Visible images/current playback are never
/// blocked by these switches. Video/audio buffers remain owned by their kernels.
class MediaPreload extends ChangeNotifier {
  static final instance = MediaPreload();
  bool video = true, images = true, audio = true;
  int triggerSeconds = 30, bufferSeconds = 15, capacityMb = 128;
  bool pages = true;
  int pageCacheSeconds = 120;
  int triggerPercent = 85;
  bool wifiOnly = true;
  int generation = 0;
  bool clearing = false;
  Directory? _root;
  File? _settings;
  int? _knownBytes;
  Future<void>? _diskQueue;
  Future<void> flush() => _diskQueue ?? Future.value();

  Future<T> _diskWork<T>(Future<T> Function() action) {
    final task = _diskQueue?.then((_) => action()) ?? Future.sync(action);
    late final Future<void> tail;
    tail = task
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_diskQueue, tail)) _diskQueue = null;
        });
    _diskQueue = tail;
    return task;
  }

  final _clearers = <FutureOr<void> Function()>{};
  int get imageBudgetBytes => capacityMb * 1024 * 1024 ~/ 2;
  int get mediaBudgetBytes => capacityMb * 1024 * 1024 ~/ 4;

  Future<void> boot({Directory? directory}) async {
    generation++;
    await flush();
    final base = directory ?? await getApplicationSupportDirectory();
    _root = Directory('${base.path}/media-preload-v1');
    _knownBytes = null;
    _settings = File('${base.path}/media_preload.json');
    try {
      if (await _settings!.exists()) {
        final data = jsonDecode(await _settings!.readAsString()) as Map;
        pages = data['pages'] != false;
        pageCacheSeconds = _integer(data['pageCacheSeconds'], 120, 15, 900);
        video = data['video'] != false;
        images = data['images'] != false;
        audio = data['audio'] != false;
        triggerSeconds = _integer(data['triggerSeconds'], 30, 5, 1800);
        triggerPercent = _integer(data['triggerPercent'], 85, 50, 99);
        wifiOnly = data['wifiOnly'] != false;
        bufferSeconds = _integer(data['bufferSeconds'], 15, 3, 300);
        capacityMb = _integer(data['capacityMb'], 128, 16, 2048);
      }
    } catch (_) {
      /* Invalid settings retain bounded defaults. */
    }
    await _diskWork(_prune);
  }

  static int _integer(Object? value, int fallback, int min, int max) =>
      value is num && value.isFinite ? value.toInt().clamp(min, max) : fallback;

  void update({
    bool? pages,
    int? pageCacheSeconds,
    bool? video,
    bool? images,
    bool? audio,
    int? triggerSeconds,
    int? triggerPercent,
    bool? wifiOnly,
    int? bufferSeconds,
    int? capacityMb,
  }) {
    this.pages = pages ?? this.pages;
    this.pageCacheSeconds = (pageCacheSeconds ?? this.pageCacheSeconds).clamp(
      15,
      900,
    );
    this.video = video ?? this.video;
    this.images = images ?? this.images;
    this.audio = audio ?? this.audio;
    this.triggerSeconds = (triggerSeconds ?? this.triggerSeconds).clamp(
      5,
      1800,
    );
    this.bufferSeconds = (bufferSeconds ?? this.bufferSeconds).clamp(3, 300);
    this.capacityMb = (capacityMb ?? this.capacityMb).clamp(16, 2048);
    this.triggerPercent = (triggerPercent ?? this.triggerPercent).clamp(50, 99);
    this.wifiOnly = wifiOnly ?? this.wifiOnly;
    generation++;
    final file = _settings;
    if (file != null) {
      final encoded = jsonEncode({
        'pages': this.pages,
        'pageCacheSeconds': this.pageCacheSeconds,
        'video': this.video,
        'images': this.images,
        'audio': this.audio,
        'triggerSeconds': this.triggerSeconds,
        'triggerPercent': this.triggerPercent,
        'wifiOnly': this.wifiOnly,
        'bufferSeconds': this.bufferSeconds,
        'capacityMb': this.capacityMb,
      });
      unawaited(
        _diskWork(() async {
          await file.parent.create(recursive: true);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(encoded);
          await temp.rename(file.path);
        }).catchError((Object _) {}),
      );
    }
    if (_root != null) unawaited(_diskWork(_prune).catchError((Object _) {}));
    notifyListeners();
  }

  VoidCallback onClear(FutureOr<void> Function() callback) {
    _clearers.add(callback);
    return () => _clearers.remove(callback);
  }

  File? _file(String key) => _root == null
      ? null
      : File('${_root!.path}/${sha256.convert(utf8.encode(key))}.image');
  Future<Uint8List?> image(String key) async {
    final file = _file(key);
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      await file.setLastModified(DateTime.now());
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> cacheImage(
    String key,
    Uint8List bytes,
    int expectedGeneration,
  ) => _diskWork(() async {
    if (!images ||
        clearing ||
        generation != expectedGeneration ||
        bytes.length > imageBudgetBytes) {
      return;
    }
    final file = _file(key);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final previous = await file.exists() ? await file.length() : 0;
      final before = _knownBytes ?? await _measure();
      if (clearing || generation != expectedGeneration) return;
      await file.writeAsBytes(bytes);
      _knownBytes = before + bytes.length - previous;
      await _prune();
    } catch (_) {
      _knownBytes = null;
      // Speculative caching must not interrupt display.
    }
  });

  Future<List<({File file, int bytes, DateTime modified})>> _files() async {
    final root = _root;
    if (root == null || !await root.exists()) return [];
    final files = <({File file, int bytes, DateTime modified})>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(r'[/\\][0-9a-f]{64}\.image$').hasMatch(entity.path)) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.file) {
        files.add((file: entity, bytes: stat.size, modified: stat.modified));
      }
    }
    return files;
  }

  // Settings read the last asynchronously measured size; scrolling never scans disk.
  int get diskBytes => _knownBytes ?? 0;
  Future<int> _measure() async =>
      (await _files()).fold<int>(0, (sum, entry) => sum + entry.bytes);

  Future<void> _prune() async {
    _knownBytes ??= await _measure();
    if (_knownBytes! <= imageBudgetBytes) return;
    final files = await _files()
      ..sort((a, b) => a.modified.compareTo(b.modified));
    var bytes = files.fold<int>(0, (sum, entry) => sum + entry.bytes);
    for (final entry in files) {
      if (bytes <= imageBudgetBytes) break;
      await entry.file.delete();
      bytes -= entry.bytes;
    }
    _knownBytes = bytes;
  }

  Future<int> clear() async {
    if (clearing) throw StateError('正在清理预载');
    clearing = true;
    try {
      generation++;
      final callbacks = _clearers.toList();
      // Clear every registered owner even when one kernel cannot release a buffer.
      final errors = <Object>[];
      for (final callback in callbacks) {
        try {
          await callback();
        } catch (error) {
          errors.add(error);
        }
      }
      final freed = await _diskWork(() async {
        var freed = 0;
        for (final entry in await _files()) {
          await entry.file.delete();
          freed += entry.bytes;
        }
        _knownBytes = 0;
        return freed;
      });
      if (errors.isNotEmpty) throw StateError('部分播放内核未能释放预载，请退出播放后重试');
      notifyListeners();
      return freed;
    } finally {
      clearing = false;
    }
  }
}
