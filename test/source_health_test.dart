import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_health.dart';

import 'support/fake_source_manager.dart';

const descriptor = SourceDescriptor(
  id: 'demo',
  name: '测试源',
  version: '1',
  enabled: true,
  siteUrl: 'https://site.example',
);

class ProbeSource extends MockDataSource {
  ProbeSource({this.error, this.stall = false, this.failFirstCategory = false})
    : super(section: Section.comic);
  final Object? error;
  final bool stall, failFirstCategory;
  final ids = <String?>[];
  @override
  Future<SourceList> list({
    String? categoryId,
    String? keyword,
    int page = 1,
    Map<String, String>? filters,
  }) async {
    ids.add(categoryId);
    if (stall) return Completer<SourceList>().future;
    if (error != null) throw error!;
    if (failFirstCategory && ids.length == 1) {
      throw const FormatException('旧分类字段失效');
    }
    return const SourceList(
      items: [
        SourceItem(id: 'one', title: '作品', cover: 'https://cdn.example/a.png'),
      ],
      hasMore: false,
    );
  }
}

SourceHealthCheck check(
  ProbeSource source, {
  int status = 200,
  String type = 'image/png',
  bool available = true,
  Duration budget = const Duration(seconds: 1),
}) => SourceHealthCheck(
  manager: FakeSourceManager(
    runtimeAvailable: available,
    opened: {'demo': source},
  ),
  section: Section.comic,
  descriptor: descriptor,
  budget: budget,
  sender: (r) async {
    expect(r.headers['Referer'], 'https://site.example');
    expect(r.maxBytes, 32768);
    expect(r.cancellation, isNotNull);
    return NetworkResponse(
      statusCode: status,
      body: [137, 80, 78, 71],
      headers: {'content-type': type},
    );
  },
);
void main() {
  test('完整体检只解析正文，不改变当前源', () async {
    final source = ProbeSource();
    final result = await check(source).run();
    expect(result.length, 8);
    expect(
      result.every((s) => s.issue == SourceHealthIssue.none && !s.running),
      true,
    );
    expect(result.last.message, contains('未下载整章'));
  });
  test('首分类失效继续检查第二分类，图片故障不阻塞详情', () async {
    final source = ProbeSource(failFirstCategory: true);
    final result = await check(source, status: 403).run();
    expect(source.ids.length, 3);
    expect(result.any((s) => s.title == '搜索接口'), isTrue);
    expect(
      result.singleWhere((s) => s.title == '封面图片').issue,
      SourceHealthIssue.image,
    );
    expect(result.last.issue, SourceHealthIssue.none);
  });
  test('图片接口 200 JSON 不误报封面正常', () async {
    final result = await check(ProbeSource(), type: 'application/json').run();
    expect(
      result.singleWhere((s) => s.title == '封面图片').issue,
      SourceHealthIssue.image,
    );
  });
  test('缺少原生环境与延迟依赖分别给出明确原因', () async {
    final unsupported = await check(ProbeSource(), available: false).run();
    expect(unsupported.single.issue, SourceHealthIssue.unsupported);
    final dependency = await check(
      ProbeSource(error: StateError('ModuleNotFoundError: Crypto.PublicKey')),
    ).run();
    expect(dependency.last.issue, SourceHealthIssue.dependency);
  });
  test('总预算停止检查，运行中状态不会永久残留', () async {
    final result = await check(
      ProbeSource(stall: true),
      budget: const Duration(milliseconds: 20),
    ).run();
    expect(result.last.issue, SourceHealthIssue.timeout);
    expect(result.any((s) => s.running), false);
  });
  test('离开体检页取消与错误信息脱敏', () async {
    final job = check(ProbeSource(stall: true));
    final pending = job.run();
    await Future<void>.delayed(Duration.zero);
    job.cancel();
    expect((await pending).last.issue, SourceHealthIssue.cancelled);
    final message = SourceHealthCheck.safeMessage(
      'https://user:pass@a.example/path?token=secret Cookie=secret',
    );
    expect(message, isNot(contains('secret')));
    expect(message, isNot(contains('user:pass')));
  });
}
