import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 隔离守卫（宪法第 3 条 / 任务书第 4 条）：扩展仓库的解析与存储代码只允许
/// 出现在漫画模块内。
///
/// 这是一条源码级检查：把「其他板块不能调用相关解析代码」从约定变成会失败的
/// 用例——只要小说 / 视频 / 猫源或共享层引用了仓库模块，这里立刻报错。
void main() {
  test('仓库模块只被漫画模块引用，且自身只住在漫画模块目录', () {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '用例要在项目根目录下运行');

    final offenders = <String>[];
    final misplaced = <String>[];

    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final inComic = path.contains('/features/comic/');

      if (!inComic && _fileNameMentionsRepo(path)) {
        misplaced.add(path);
      }
      for (final target in _imports(entity)) {
        if (target.contains('comic_repo') && !inComic) {
          offenders.add('$path → $target');
        }
      }
    }

    expect(misplaced, isEmpty, reason: '仓库模块文件只能住在 features/comic 下');
    expect(
      offenders,
      isEmpty,
      reason: '扩展仓库能力只属于漫画模块，其他板块与共享层不得引用',
    );
  });
}

/// 文件名是否属于仓库模块（模块内文件统一以 comic_repo 开头）。
bool _fileNameMentionsRepo(String path) {
  final name = path.split('/').last;
  return name.startsWith('comic_repo_');
}

/// 源文件里的 import 目标（相对路径与包路径都算）。
Iterable<String> _imports(File file) {
  final pattern = RegExp(r"""^\s*import\s+['"]([^'"]+)['"]""", multiLine: true);
  return pattern
      .allMatches(file.readAsStringSync())
      .map((match) => match.group(1)!);
}
