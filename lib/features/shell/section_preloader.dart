import 'dart:async';

import '../../core/net/network_cancellation.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/util/lume_log.dart';
import '../../core/reading/cover_warmup.dart';

/// One bounded, shared request per section. Explicit refresh invalidates in-flight results.
class SectionPreloader {
  SectionPreloader._();
  static const ttl = Duration(seconds: 60);
  static final _warm = <Section, _WarmEntry>{};
  static final _tasks = <Section, Future<void>>{};
  static final _generation = <Section, int>{};
  static final _requests = NetworkRequestOwner();
  static final _targets = <Section, Completer<({String id, bool home})?>>{};

  static final _capabilities =
      <(Section, String, Object), ({DateTime at, Future<bool> value})>{};
  static Future<bool> supportsHome(DataSource source) {
    if (source is! HomeCapable) return Future.value(false);
    final key = (
      source.section,
      source.id,
      source is JsDataSource ? JsDataSource : source,
    );
    final cached = _capabilities[key];
    if (cached != null && DateTime.now().difference(cached.at) < ttl) {
      return cached.value;
    }
    late Future<bool> value;
    value =
        NetworkCancellation.runWith(
          null,
          () => Future.sync(() => (source as HomeCapable).supportsHome()),
        ).timeout(const Duration(seconds: 2)).catchError((Object error) {
          if (identical(_capabilities[key]?.value, value)) {
            _capabilities.remove(key);
          }
          LumeLog.info('[warm] 首页能力探测未完成：$error');
          return false;
        });
    _capabilities[key] = (at: DateTime.now(), value: value);
    return value;
  }

  static Future<void> warm(
    Section section, {
    SourceManager? manager,
    Future<void> Function()? openLibrary,
    Future<void> Function(DataSource, SourceDescriptor, Iterable<SourceItem>)?
    preloadCovers,
  }) {
    final existing = _tasks[section];
    if (existing != null) return existing;
    final generation = _generation[section] ?? 0;
    final target = Completer<({String id, bool home})?>();
    _targets[section] = target;
    late Future<void> task;
    task = _requests
        .run(
          section.id,
          () => _perform(
            section,
            manager,
            openLibrary,
            generation,
            target,
            preloadCovers,
          ),
          timeout: const Duration(seconds: 12),
        )
        .catchError((Object error) {
          if (error is! NetworkCancelled) {
            LumeLog.info('[warm] ${section.id} 预热停止：$error');
          }
        })
        .whenComplete(() {
          if (!target.isCompleted) target.complete(null);
          if (identical(_targets[section], target)) _targets.remove(section);
          if (identical(_tasks[section], task)) _tasks.remove(section);
        });
    _tasks[section] = task;
    return task;
  }

  static Future<void> _perform(
    Section section,
    SourceManager? manager,
    Future<void> Function()? openLibrary,
    int generation,
    Completer<({String id, bool home})?> target,
    Future<void> Function(DataSource, SourceDescriptor, Iterable<SourceItem>)?
    preloadCovers,
  ) async {
    final token = NetworkCancellation.current;
    try {
      await openLibrary?.call();
      token?.check();
      if (manager == null || !manager.runtimeAvailable) return;
      final current = await manager.current();
      token?.check();
      if (current == null) return;
      final cached = _valid(section, current.id);
      if (cached != null) return;
      final source = await manager.open(current.id);
      token?.check();
      if (source == null) return;
      SourceHome? home;
      SourceList? list;
      final homeSupported = await supportsHome(source);
      token?.check();
      if (!target.isCompleted) {
        target.complete((id: source.id, home: homeSupported));
      }
      if (homeSupported) {
        token?.check();
        home = await (source as HomeCapable).home();
      } else {
        token?.check();
        list = await source.list(page: 1);
      }
      token?.check();
      if ((_generation[section] ?? 0) != generation) return;
      _warm[section] = _WarmEntry(source.id, list, home);
      if (preloadCovers != null) {
        final items = home == null
            ? list!.items
            : home.isBoards
            ? home.boards.expand((board) => board.items)
            : home.items;
        // Preparing the image pipeline must not delay the first covers until UI build.
        await preloadCovers(source, current, items);
      }
    } on NetworkCancelled {
      // Discarded warm-ups must not start any later source requests.
    } catch (error) {
      LumeLog.info('[warm] ${section.id} 预热失败，页面可正常重试：$error');
    }
  }

  static Future<void> waitForWarm(
    Section section, {
    String? sourceId,
    bool? home,
  }) async {
    final task = _tasks[section];
    if (task != null) {
      final target = _targets[section];
      await (() async {
        final destination = await target?.future;
        if (destination != null &&
            ((sourceId != null && destination.id != sourceId) ||
                (home != null && destination.home != home))) {
          // A foreground category page must not wait for an unrelated home request.
          if (identical(_tasks[section], task)) discard(section);
          return;
        }
        await task;
      })().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // The foreground must not race a still-running warm request.
          if (identical(_tasks[section], task)) discard(section);
        },
      );
    }
  }

  static _WarmEntry? _valid(Section section, String sourceId) {
    final entry = _warm[section];
    if (entry == null || entry.sourceId != sourceId) return null;
    if (DateTime.now().difference(entry.at) > ttl) {
      _warm.remove(section);
      return null;
    }
    return entry;
  }

  static SourceList? takeWarmPage(
    Section section, {
    required String sourceId,
    String? categoryId,
    String keyword = '',
  }) {
    if (categoryId != null || keyword.isNotEmpty) return null;
    final entry = _valid(section, sourceId);
    if (entry?.list == null) return null;
    _warm.remove(section);
    return entry!.list;
  }

  static SourceHome? takeWarmHome(Section section, {required String sourceId}) {
    final entry = _valid(section, sourceId);
    if (entry?.home == null) return null;
    _warm.remove(section);
    return entry!.home;
  }

  static void cancelPendingExcept(Section? active) {
    for (final section in _tasks.keys.toList()) {
      if (section != active) discard(section);
    }
    for (final section in Section.values) {
      if (section != active) CoverWarmup.discard(section);
    }
  }

  static void discard([Section? section]) {
    CoverWarmup.discard(section);
    for (final target in section == null ? Section.values : [section]) {
      _capabilities.removeWhere((key, _) => key.$1 == target);
      _requests.cancel(target.id);
      _warm.remove(target);
      _tasks.remove(target);
      _generation[target] = (_generation[target] ?? 0) + 1;
    }
  }

  static bool hasWarm(Section section) => _warm.containsKey(section);
}

class _WarmEntry {
  _WarmEntry(this.sourceId, this.list, this.home);
  final String sourceId;
  final SourceList? list;
  final SourceHome? home;
  final at = DateTime.now();
}
