import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/source/source.dart';

import 'support/fake_reading_source.dart';

/// 弹幕上报（可选能力端口）的验证：契约透传、返回值归一、能力缺失降级。
///
/// 「能读不能写」是多数图源的常态，因此这里重点验两件事：
/// 1. 不支持写入时**返回 false 而不是抛错**（调用方据此提示「仅本机可见」）；
/// 2. 真正的失败（网络 / 脚本报错）仍然抛 [SourceException]，不被误判成不支持。
void main() {
  group('DanmakuPostCapable 契约', () {
    test('脚本返回 true：上报成功', () async {
      final runtime = _RecordingRuntime(result: true);
      final source = _source(runtime);

      final accepted = await source.postDanmaku(
        itemId: 'i1',
        chapterId: 'c1',
        text: '前方高能',
        positionMs: 12345,
        mode: 'scroll',
        color: 0xFFFFFF,
      );

      expect(accepted, isTrue);
      expect(runtime.calls, hasLength(1));
      expect(runtime.calls.single.$1, 'postDanmaku');
      final args = runtime.calls.single.$2! as Map<String, Object?>;
      expect(args['id'], 'i1');
      expect(args['chapterId'], 'c1');
      expect(args['text'], '前方高能');
      expect(args['position'], 12345);
      expect(args['mode'], 'scroll');
      expect(args['color'], 0xFFFFFF);
    });

    test('脚本返回 {ok: false}：明确拒绝，返回 false', () async {
      final runtime = _RecordingRuntime(result: <String, Object?>{'ok': false});
      final source = _source(runtime);
      expect(
        await source.postDanmaku(
          itemId: 'i',
          chapterId: 'c',
          text: 'x',
          positionMs: 0,
          mode: 'scroll',
        ),
        isFalse,
      );
    });

    test('脚本没有返回值：按成功处理（发出去了就行）', () async {
      final runtime = _RecordingRuntime(result: null);
      final source = _source(runtime);
      expect(
        await source.postDanmaku(
          itemId: 'i',
          chapterId: 'c',
          text: 'x',
          positionMs: 0,
          mode: 'top',
        ),
        isTrue,
      );
    });

    test('颜色缺省时不传该字段（脚本可以不给颜色）', () async {
      final runtime = _RecordingRuntime(result: true);
      final source = _source(runtime);
      await source.postDanmaku(
        itemId: 'i',
        chapterId: 'c',
        text: 'x',
        positionMs: 0,
        mode: 'scroll',
      );
      final args = runtime.calls.single.$2! as Map<String, Object?>;
      expect(args.containsKey('color'), isFalse);
    });

    test('「方法不存在」= 图源不支持写入，返回 false 而不是抛错', () async {
      final runtime = _RecordingRuntime(
        error: const SourceException(
          SourceErrorKind.callFailed,
          'LumeSource.postDanmaku 不是函数',
        ),
      );
      final source = _source(runtime);
      expect(
        await source.postDanmaku(
          itemId: 'i',
          chapterId: 'c',
          text: 'x',
          positionMs: 0,
          mode: 'scroll',
        ),
        isFalse,
        reason: '只读源是正常情况，不该报错',
      );
    });

    test('英文措辞的「不是函数」同样识别为不支持', () async {
      final runtime = _RecordingRuntime(
        error: const SourceException(
          SourceErrorKind.callFailed,
          'TypeError: LumeSource.postDanmaku is not a function',
        ),
      );
      final source = _source(runtime);
      expect(
        await source.postDanmaku(
          itemId: 'i',
          chapterId: 'c',
          text: 'x',
          positionMs: 0,
          mode: 'scroll',
        ),
        isFalse,
      );
    });

    test('真实失败（网络 / 脚本报错）仍然抛错，不被误判成不支持', () async {
      final runtime = _RecordingRuntime(
        error: const SourceException(SourceErrorKind.callFailed, '请求超时'),
      );
      final source = _source(runtime);
      await expectLater(
        source.postDanmaku(
          itemId: 'i',
          chapterId: 'c',
          text: 'x',
          positionMs: 0,
          mode: 'scroll',
        ),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('能力探测', () {
    test('JsDataSource 同时具备读与写两个能力', () {
      final source = _source(_RecordingRuntime(result: true));
      expect(source, isA<DanmakuCapable>());
      expect(source, isA<DanmakuPostCapable>());
    });

    test('不支持弹幕的数据源两个能力都没有（调用方静默降级）', () {
      final source = FakeReadingDataSource(section: Section.video);
      expect(source, isNot(isA<DanmakuCapable>()));
      expect(source, isNot(isA<DanmakuPostCapable>()));
    });
  });
}

JsDataSource _source(JsSourceRuntime runtime) => JsDataSource(
      id: 'test',
      name: '测试源',
      section: Section.video,
      runtime: runtime,
    );

/// 记录调用的运行时替身：可配置返回结果或抛错。
class _RecordingRuntime implements JsSourceRuntime {

  @override
  Future<Set<String>> contractMethods() async =>
      const <String>{'categories', 'list', 'detail', 'chapters', 'content'};
  _RecordingRuntime({this.result, this.error});

  final Object? result;
  final SourceException? error;

  final List<(String, Object?)> calls = <(String, Object?)>[];

  @override
  Future<Object?> call(String method, [Object? argument]) async {
    calls.add((method, argument));
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }
}
