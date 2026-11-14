import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'music_models.dart';

/// Music has its own namespace; existing comic/video source IDs are untouched.
class MusicLibrary extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  MusicLibrary({Directory? directory}) : _directory = directory;
  static final instance = MusicLibrary();
  Directory? _directory;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  final plugins = <MusicPlugin>[];
  final favorites = <MusicTrack>[];
  final recent = <MusicTrack>[];
  final queue = <MusicTrack>[];
  String quality = 'standard';

  Future<void> load() => _loading ??= _load().onError((Object e, StackTrace s) {
    _loading = null;
    Error.throwWithStackTrace(e, s);
  });
  Future<void> _load() async {
    _directory ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/music',
    );
    await _directory!.create(recursive: true);
    final file = File('${_directory!.path}/library.json');
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map;
    final restoredPlugins = <MusicPlugin>[];
    for (final row in data['plugins'] as List? ?? []) {
      if (row is Map) restoredPlugins.add(MusicPlugin.fromJson(row));
    }
    final restoredTracks = <String, List<MusicTrack>>{};
    for (final pair in [
      ('favorites', favorites),
      ('recent', recent),
      ('queue', queue),
    ]) {
      for (final row in data[pair.$1] as List? ?? []) {
        if (row is Map) {
          (restoredTracks[pair.$1] ??= []).add(MusicTrack.fromJson(row));
        }
      }
    }
    plugins
      ..clear()
      ..addAll(restoredPlugins);
    favorites
      ..clear()
      ..addAll(restoredTracks['favorites'] ?? []);
    recent
      ..clear()
      ..addAll(restoredTracks['recent'] ?? []);
    queue
      ..clear()
      ..addAll(restoredTracks['queue'] ?? []);
    final saved = data['quality'];
    if (['low', 'standard', 'high', 'super'].contains(saved)) {
      quality = saved as String;
    }
    notifyListeners();
  }

  MusicPlugin? plugin(String id) {
    for (final p in plugins) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<String> script(String id) async {
    await load();
    _checkId(id);
    return File('${_directory!.path}/$id.js').readAsString();
  }

  static void _checkId(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('无效的音乐插件标识');
    }
  }

  Future<void> install(MusicPlugin plugin, String script) async {
    await load();
    _checkId(plugin.id);
    final file = File('${_directory!.path}/${plugin.id}.js');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(script, flush: true);
    await temp.rename(file.path);
    final index = plugins.indexWhere((p) => p.id == plugin.id);
    if (index < 0) {
      plugins.add(plugin);
    } else {
      plugins[index] = plugin;
    }
    await save();
  }

  Future<void> change(MusicPlugin plugin) async {
    await load();
    final index = plugins.indexWhere((p) => p.id == plugin.id);
    if (index >= 0) plugins[index] = plugin;
    await save();
  }

  Future<void> remove(String id) async {
    await load();
    _checkId(id);
    plugins.removeWhere((p) => p.id == id);
    await save();
    final file = File('${_directory!.path}/$id.js');
    if (await file.exists()) await file.delete();
  }

  bool isFavorite(MusicTrack track) => favorites.any((t) => t.key == track.key);
  Future<void> toggleFavorite(MusicTrack track) async {
    await load();
    if (isFavorite(track)) {
      favorites.removeWhere((t) => t.key == track.key);
    } else {
      favorites.insert(0, track);
    }
    await save();
  }

  Future<void> remember(MusicTrack track) async {
    await load();
    recent.removeWhere((t) => t.key == track.key);
    recent.insert(0, track);
    if (recent.length > 200) recent.removeRange(200, recent.length);
    await save();
  }

  Future<void> save() {
    final encoded = jsonEncode({
      'plugins': plugins.map((p) => p.toJson()).toList(),
      'favorites': favorites.map((t) => t.toJson()).toList(),
      'recent': recent.map((t) => t.toJson()).toList(),
      'queue': queue.map((t) => t.toJson()).toList(),
      'quality': quality,
    });
    final next = _writes.then((_) async {
      final file = File('${_directory!.path}/library.json');
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
    });
    _writes = next.catchError((_) {});
    notifyListeners();
    return next;
  }
}
