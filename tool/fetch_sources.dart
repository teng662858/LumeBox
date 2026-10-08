import 'dart:io';

import 'package:http/http.dart' as http;

/// 拉取 LumeBox 源仓库里的脚本，缓存到 `.sources-cache/`。
///
/// 脚本已经不放在 App 仓库里了（见 `test/support/source_scripts.dart` 的说明）：
/// 需要在真实 QuickJS 上跑真脚本的原生用例，先跑一次这个脚本：
///
/// ```
/// dart run tool/fetch_sources.dart
/// ```
///
/// 三个板块各有一个订阅清单（`<section>/sources.txt`，一行一个脚本地址），
/// 这里按清单逐个拉下来，存成 `.sources-cache/<section>/<文件名>`。
/// 每条带 20s 超时 + 两次重试：GitHub raw 在国内网络下偶尔超时，
/// 一条失败不打断整体（最后打印拉到几份）。
Future<void> main(List<String> args) async {
  const base =
      'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main';
  const sections = <String>['novel', 'comic', 'video'];
  const timeout = Duration(seconds: 20);
  final root = Directory('.sources-cache');
  var ok = 0;
  var failed = 0;

  /// 拉一次文本；带重试与超时，失败返回 null。
  Future<String?> get(String url) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = http.Client();
      try {
        final response =
            await client.get(Uri.parse(url)).timeout(timeout);
        if (response.statusCode == 200) return response.body;
        stderr.writeln('[fail] $url → HTTP ${response.statusCode}');
        return null;
      } catch (error) {
        if (attempt == 2) {
          stderr.writeln('[fail] $url → $error');
          return null;
        }
      } finally {
        client.close();
      }
    }
    return null;
  }

  for (final section in sections) {
    // 清单文件是 `sources.js`：一行一个脚本地址（App 也按这个口径解析）。
    final indexUrl = '$base/$section/sources.js';
    final list = await get(indexUrl);
    if (list == null) {
      failed++;
      continue;
    }

    for (final line in list.split('\n')) {
      final url = line.trim();
      if (url.isEmpty || url.startsWith('#')) continue;
      final name = url.split('/').last;
      final target = File('${root.path}/$section/$name');
      final text = await get(url);
      if (text == null) {
        failed++;
        continue;
      }
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(text, flush: true);
      stdout.writeln('[ok] ${target.path} （${text.length} 字符）');
      ok++;
    }
  }

  // 站点快照（与脚本一起放在源仓库的 snapshots/）：校验脚本解析规则时要用。
  final snapshotList = await get('$base/snapshots/snapshots.txt');
  if (snapshotList == null) {
    failed++;
  } else {
    final target = Directory('${root.path}/snapshots');
    target.createSync(recursive: true);
    for (final line in snapshotList.split('\n')) {
      final name = line.trim();
      if (name.isEmpty || name.startsWith('#')) continue;
      final text = await get('$base/snapshots/$name');
      if (text == null) {
        failed++;
        continue;
      }
      final file = File('${target.path}/$name');
      file.writeAsStringSync(text, flush: true);
      stdout.writeln('[ok] ${file.path} （${text.length} 字符）');
      ok++;
    }
  }

  stdout.writeln('拉到 $ok 份，失败 $failed 份 → ${root.absolute.path}');
  if (ok == 0) exitCode = 1;
}
