import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/lume_js_engine.dart';
import 'package:lume_box/core/js/sandbox/sandbox.dart';
import 'package:lume_box/core/source/source.dart';

/// 状态分类与失败归一的纯 Dart 验证：这是「脚本报错」与「网络异常」能被分开
/// 呈现的唯一依据，因此断言必须精确到类型，而不是文案。
void main() {
  group('异常 → 页面状态', () {
    test('图源禁用：notFound 与平台不支持', () {
      expect(
        stateForError(const SourceException(SourceErrorKind.notFound, '已禁用')),
        SourceStateKind.disabled,
      );
      expect(
        stateForError(const SourceException(SourceErrorKind.unsupported, '无运行时')),
        SourceStateKind.disabled,
      );
    });

    test('网络异常与脚本报错分开', () {
      expect(
        stateForError(const SourceException(SourceErrorKind.network, '连接超时')),
        SourceStateKind.networkError,
      );
      expect(
        stateForError(const SourceException(SourceErrorKind.callFailed, 'TypeError')),
        SourceStateKind.scriptError,
      );
    });

    test('非 SourceException 一律按脚本报错兜底', () {
      expect(stateForError(StateError('boom')), SourceStateKind.scriptError);
      expect(stateForError('莫名其妙'), SourceStateKind.scriptError);
    });

    test('状态标识稳定，文案集中在这里', () {
      expect(SourceStateKind.loading.id, 'loading');
      expect(SourceStateKind.empty.id, 'empty');
      expect(SourceStateKind.disabled.id, 'disabled');
      expect(SourceStateKind.scriptError.id, 'scriptError');
      expect(SourceStateKind.networkError.id, 'networkError');
      expect(SourceStateKind.ready.id, 'ready');
      expect(SourceStateKind.loading.label, '正在加载…');
    });
  });

  group('沙箱失败 → 数据源异常', () {
    test('带网络标记的失败归一到 network', () {
      final failure = SandboxError(
        SandboxErrorKind.script,
        '${LumeSourceHost.networkFailureMarker}：ClientException: 连接被拒绝',
      );
      final mapped = mapSandboxFailure(failure);
      expect(mapped.kind, SourceErrorKind.network);
      expect(mapped.message, contains('连接被拒绝'));
      expect(stateForError(mapped), SourceStateKind.networkError);
    });

    test('普通脚本错误归一到 callFailed', () {
      final mapped = mapSandboxFailure(
        const SandboxError(
          SandboxErrorKind.script,
          'TypeError: LumeSource.list is not a function',
        ),
      );
      expect(mapped.kind, SourceErrorKind.callFailed);
      expect(stateForError(mapped), SourceStateKind.scriptError);
    });

    test('释放与不支持归一到 notFound', () {
      expect(
        mapSandboxFailure(const SandboxError(SandboxErrorKind.disposed, '沙箱已释放'))
            .kind,
        SourceErrorKind.notFound,
      );
      expect(
        mapSandboxFailure(
          const SandboxError(SandboxErrorKind.unsupported, '原生库不可用'),
        ).kind,
        SourceErrorKind.notFound,
      );
    });
  });
}
