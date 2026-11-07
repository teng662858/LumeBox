import '../session/privacy_settings.dart';
import '../media/media_library.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../session/app_preferences.dart';
import '../reading/reading.dart';
import '../session/section.dart';

/// Stable cross-media references; no URLs, cookies or source execution is stored.
class ContentRef {
  const ContentRef(this.section, this.source, this.item, this.title);
  final Section section;
  final String source, item, title;
  bool get visible {
    if (source == '@audio-library') {
      final resource = MediaLibrary.instance.byId(item);
      return resource != null &&
          PrivacySettings.instance.allowsSource(
            resource.sourceId ?? resource.id,
            resource.title,
          );
    }
    return PrivacySettings.instance.allowsSource(source, title);
  }

  String get key => jsonEncode([section.id, source, item]);
  factory ContentRef.of(LibraryItem item) =>
      ContentRef(item.section, item.sourceId, item.itemId, item.title);
  Map<String, String> toJson() => {
    'section': section.id,
    'source': source,
    'item': item,
    'title': title,
  };
  static ContentRef? parse(Object? value) {
    if (value is! Map) return null;
    final section = Section.values
        .where((s) => s.id == value['section'])
        .firstOrNull;
    if (section == null ||
        value['source'] is! String ||
        value['item'] is! String ||
        value['title'] is! String) {
      return null;
    }
    return ContentRef(section, value['source'], value['item'], value['title']);
  }
}

class ContentCenter extends ChangeNotifier {
  static final instance = ContentCenter();
  Map<String, dynamic> get data => AppPreferences.instance.experience;
  List<Map<String, dynamic>> rows(String name) =>
      (data[name] is List ? data[name] as List : const [])
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
  bool enabled(String key, {bool fallback = false}) =>
      data[key] is bool ? data[key] as bool : fallback;
  int number(String key, int fallback) =>
      data[key] is num ? (data[key] as num).toInt() : fallback;
  void put(String key, Object? value) {
    data[key] = value;
    AppPreferences.instance.save();
    notifyListeners();
  }

  String trackingState(ContentRef ref) {
    final value = data['tracking.${ref.key}'];
    return ['active', 'paused', 'completed'].contains(value)
        ? value as String
        : 'active';
  }

  void setTrackingState(ContentRef ref, String state) {
    if (!['active', 'paused', 'completed'].contains(state)) {
      throw ArgumentError('无效更新规则');
    }
    put('tracking.${ref.key}', state);
  }

  void hide(ContentRef ref, bool value) {
    final hidden = Set<String>.from(data['hidden'] as List? ?? []);
    value ? hidden.add(ref.key) : hidden.remove(ref.key);
    put('hidden', hidden.toList());
  }

  bool hidden(ContentRef ref) =>
      (data['hidden'] as List? ?? []).contains(ref.key);
  String workKey(ContentRef ref) =>
      rows('groups')
          .where(
            (g) => (g['members'] as List? ?? []).any(
              (v) => ContentRef.parse(v)?.key == ref.key,
            ),
          )
          .firstOrNull?['id']
          ?.toString() ??
      ref.key;
  List<ContentRef> related(ContentRef ref) {
    final group = rows('groups')
        .where(
          (g) => (g['members'] as List? ?? []).any(
            (v) => ContentRef.parse(v)?.key == ref.key,
          ),
        )
        .firstOrNull;
    return (group?['members'] as List? ?? [])
        .map(ContentRef.parse)
        .whereType<ContentRef>()
        .toList();
  }

  void link(String title, List<ContentRef> entries) {
    final members = List<ContentRef>.of(entries);
    if (title.trim().isEmpty || members.map((m) => m.key).toSet().length < 2) {
      throw ArgumentError('至少选择两个不同条目');
    }
    final ids = members.map((v) => v.key).toSet();
    final all = rows('groups');
    // A reference has one explicit owner. Never merge matching titles automatically.
    for (final group in all) {
      final old = (group['members'] as List? ?? [])
          .map(ContentRef.parse)
          .whereType<ContentRef>();
      if (old.any((v) => ids.contains(v.key))) {
        for (final ref in old) {
          if (ids.add(ref.key)) members.add(ref);
        }
      }
    }
    all.removeWhere(
      (g) => (g['members'] as List? ?? []).any(
        (v) => ids.contains(ContentRef.parse(v)?.key),
      ),
    );
    all.add({
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'title': title.trim(),
      'members': members.map((v) => v.toJson()).toList(),
    });
    put('groups', all);
  }

  void clip(
    ContentRef ref, {
    required String text,
    String folder = '默认',
    int? seconds,
    int? chapter,
    int? page,
  }) {
    if (text.trim().isEmpty) return;
    put('clips', [
      ...rows('clips'),
      {
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'ref': ref.toJson(),
        'text': text.trim(),
        'folder': folder.trim().isEmpty ? '默认' : folder.trim(),
        'seconds': seconds,
        'chapter': chapter,
        'page': page,
        'time': DateTime.now().toIso8601String(),
      },
    ]);
  }

  void remove(String name, String id) =>
      put(name, rows(name)..removeWhere((v) => v['id'] == id));
  void markRead(String id) => put(
    'updates',
    rows('updates')
        .map((v) => v['id'] == id ? {...v, 'read': true} : v)
        .toList(),
  );

  /// First successful check establishes a baseline, never fabricates releases.
  List<SourceChapterFact> compare(
    ContentRef ref,
    List<SourceChapterFact> chapters,
  ) {
    if (chapters.isEmpty) return [];
    final baselines = Map<String, dynamic>.from(
      data['baselines'] as Map? ?? {},
    );
    final previous = baselines[ref.key] as List?;
    final old = previous?.cast<String>().toSet();
    final fresh = old == null
        ? <SourceChapterFact>[]
        : chapters.where((c) => !old.contains(c.key)).toList();
    baselines[ref.key] = chapters.map((c) => c.key).toSet().toList();
    data['baselines'] = baselines;
    if (fresh.isNotEmpty) {
      final log = rows('updates');
      log.insert(0, {
        'id': '${ref.key}:${DateTime.now().microsecondsSinceEpoch}',
        'ref': ref.toJson(),
        'count': fresh.length,
        'latest': fresh.last.title,
        'time': DateTime.now().toIso8601String(),
        'read': false,
      });
      data['updates'] = log.take(500).toList();
    }
    put('checked.${ref.key}', DateTime.now().toIso8601String());
    return fresh;
  }
}

class SourceChapterFact {
  const SourceChapterFact(this.key, this.title);
  final String key, title;
}
