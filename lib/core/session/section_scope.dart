import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'section.dart';

/// 板块级隔离根。缓存、数据库、图源全部落在 `sections/<id>/` 之下，
/// 并通过 [resolve] 拒绝任何越界路径，保证板块间无法互相访问。
class SectionScope {
  SectionScope._(this.section, this.root);

  final Section section;
  final Directory root;

  static final Map<Section, SectionScope> _opened = {};

  static Future<SectionScope> open(Section section) async {
    final existing = _opened[section];
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final scope = SectionScope._(
      section,
      Directory(p.join(base.path, 'sections', section.id)),
    );
    await scope._prepare();
    _opened[section] = scope;
    return scope;
  }

  Future<void> _prepare() async {
    for (final dir in [root.path, cacheDir, sourceDir]) {
      await Directory(dir).create(recursive: true);
    }
  }

  String get dbPath => p.join(root.path, '${section.id}.db');

  String get cacheDir => p.join(root.path, 'cache');

  String get sourceDir => p.join(root.path, 'sources');

  /// 将板块内相对路径解析为绝对路径；越界即抛错，避免跨板块读写。
  String resolve(String relative) {
    final target = p.normalize(p.join(root.path, relative));
    if (target != root.path && !p.isWithin(root.path, target)) {
      throw ArgumentError('拒绝跨板块路径访问: $relative');
    }
    return target;
  }

  /// 仅供进程退出或测试隔离使用。
  static Future<void> closeAll() async {
    _opened.clear();
  }
}
