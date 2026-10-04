import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/js/sandbox/sandbox.dart';

/// 不依赖原生库的沙箱用例：策略、预算、中断判定、结果信封、宿主抽象、
/// 垫片登记与不可用降级。真实引擎相关用例见 sandbox_native_test.dart。
void main() {
  group('SandboxPolicy', () {
    test('超时被强制收敛到 3–5 秒', () {
      expect(
        const SandboxPolicy(timeout: Duration(seconds: 1)).clamped().timeout,
        SandboxPolicy.minTimeout,
      );
      expect(
        const SandboxPolicy(timeout: Duration(seconds: 30)).clamped().timeout,
        SandboxPolicy.maxTimeout,
      );
      expect(
        const SandboxPolicy(timeout: Duration(seconds: 4)).clamped().timeout,
        const Duration(seconds: 4),
      );
    });

    test('预设策略符合文档区间', () {
      expect(SandboxPolicy.standard.timeout, const Duration(seconds: 4));
      expect(SandboxPolicy.standard.allowHostAccess, isFalse);
      expect(SandboxPolicy.strict.timeout, SandboxPolicy.minTimeout);
      expect(SandboxPolicy.strict.poisonOnScriptError, isTrue);
      expect(
        SandboxPolicy.strict.maxHostCalls < SandboxPolicy.standard.maxHostCalls,
        isTrue,
      );
      // 默认策略本身必须已经在合法区间内，clamped 不改变它。
      expect(SandboxPolicy.standard.clamped().timeout, SandboxPolicy.standard.timeout);
    });

    test('copyWith 只覆盖指定字段', () {
      final custom = SandboxPolicy.standard.copyWith(
        timeout: const Duration(seconds: 5),
        allowHostAccess: true,
      );
      expect(custom.timeout, const Duration(seconds: 5));
      expect(custom.allowHostAccess, isTrue);
      expect(custom.maxInstructions, SandboxPolicy.standard.maxInstructions);
      expect(custom.memoryLimitBytes, SandboxPolicy.standard.memoryLimitBytes);
    });
  });

  group('SandboxBudget', () {
    SandboxBudget budgetWith(SandboxPolicy policy, {Duration age = Duration.zero}) =>
        SandboxBudget(policy, DateTime.now().subtract(age));

    test('步数记账到上限即拒绝', () {
      final budget = budgetWith(SandboxPolicy.standard.copyWith(maxSteps: 2));
      expect(budget.spendStep(), isTrue);
      expect(budget.spendStep(), isTrue);
      expect(budget.spendStep(), isFalse);
      expect(budget.steps, 3);
    });

    test('宿主调用与微任务轮数分别记账', () {
      final budget = budgetWith(
        SandboxPolicy.standard.copyWith(maxHostCalls: 1, maxJobRounds: 1),
      );
      expect(budget.spendHostCall(), isTrue);
      expect(budget.spendHostCall(), isFalse);
      expect(budget.spendJobRound(), isTrue);
      expect(budget.spendJobRound(), isFalse);
      // 各预算互不影响
      expect(budget.spendStep(), isTrue);
    });

    test('剩余预算与到期判定', () {
      final fresh = budgetWith(const SandboxPolicy(timeout: Duration(seconds: 4)));
      expect(fresh.isExpired, isFalse);
      expect(fresh.remaining.inSeconds, greaterThanOrEqualTo(3));

      final expired = budgetWith(
        const SandboxPolicy(timeout: Duration(seconds: 4)),
        age: const Duration(seconds: 10),
      );
      expect(expired.isExpired, isTrue);
      expect(expired.remaining, Duration.zero);
    });
  });

  group('SandboxGuard 中断判定', () {
    final now = DateTime.now().millisecondsSinceEpoch;

    test('到点触发超时中断', () {
      final arming = SandboxArming(deadlineMillis: now - 1, ticksLeft: 1000);
      expect(SandboxGuard.shouldInterrupt(arming, now), isTrue);
      expect(arming.fired, SandboxInterrupt.timeout);
    });

    test('指令计数耗尽触发中断', () {
      final arming = SandboxArming(deadlineMillis: now + 60000, ticksLeft: 3);
      expect(SandboxGuard.shouldInterrupt(arming, now), isFalse);
      expect(SandboxGuard.shouldInterrupt(arming, now), isFalse);
      expect(SandboxGuard.shouldInterrupt(arming, now), isTrue);
      expect(arming.fired, SandboxInterrupt.instructions);
    });

    test('已中断后保持中断，不再重复计数', () {
      final arming = SandboxArming(deadlineMillis: now - 1, ticksLeft: 5);
      expect(SandboxGuard.shouldInterrupt(arming, now), isTrue);
      final remaining = arming.ticksLeft;
      expect(SandboxGuard.shouldInterrupt(arming, now), isTrue);
      expect(arming.ticksLeft, remaining);
    });

    test('不计数时只按时间判定', () {
      final arming = SandboxArming(deadlineMillis: now + 60000, ticksLeft: 1);
      for (var i = 0; i < 10; i++) {
        expect(SandboxGuard.shouldInterrupt(arming, now, countTick: false), isFalse);
      }
      expect(arming.ticksLeft, 1);
    });
  });

  group('SandboxResult 信封', () {
    test('成功信封可往返', () {
      const result = SandboxSuccess(<String, Object?>{'title': '示例'});
      final decoded = SandboxResult.fromJson(result.encode());
      expect(decoded.isOk, isTrue);
      expect((decoded.value! as Map)['title'], '示例');
    });

    test('失败信封保留分类与消息', () {
      const failure = SandboxFailure(SandboxErrorKind.timeout, '执行超时: latest');
      final decoded = SandboxResult.fromJson(failure.encode());
      expect(decoded.isOk, isFalse);
      expect(decoded.error!.kind, SandboxErrorKind.timeout);
      expect(decoded.error!.message, '执行超时: latest');
      expect(decoded.toJson(), failure.toJson());
    });

    test('未知分类回退为引擎错误', () {
      final decoded = SandboxResult.fromJson(
        '{"ok":false,"error":{"kind":"unknown-kind","message":"x"}}',
      );
      expect(decoded.error!.kind, SandboxErrorKind.engine);
    });

    test('非法输入归类为协议异常', () {
      expect(
        SandboxResult.fromJson('not json').error!.kind,
        SandboxErrorKind.protocol,
      );
      expect(
        SandboxResult.fromJson('[1,2]').error!.kind,
        SandboxErrorKind.protocol,
      );
    });

    test('污染分类划分正确', () {
      const poisoning = <SandboxErrorKind>[
        SandboxErrorKind.timeout,
        SandboxErrorKind.instructions,
        SandboxErrorKind.memory,
        SandboxErrorKind.protocol,
        SandboxErrorKind.engine,
      ];
      const benign = <SandboxErrorKind>[
        SandboxErrorKind.script,
        SandboxErrorKind.hostDenied,
        SandboxErrorKind.unsupported,
        SandboxErrorKind.disposed,
      ];
      for (final kind in poisoning) {
        expect(kind.poisonsContext, isTrue, reason: '${kind.id} 应当销毁上下文');
      }
      for (final kind in benign) {
        expect(kind.poisonsContext, isFalse, reason: '${kind.id} 不应销毁上下文');
      }
    });
  });

  group('SandboxHost 默认拒绝', () {
    test('未注入宿主时一切外部能力被拒绝', () async {
      const host = DenyAllSandboxHost();
      await expectLater(
        host.invoke(
          const SandboxHostRequest(
            sandboxId: 'demo',
            method: SandboxHostMethods.httpFetch,
            payload: <String, Object?>{'url': 'https://example.com'},
          ),
        ),
        throwsA(isA<SandboxHostException>()),
      );
    });
  });

  group('PolyfillRegistry', () {
    test('默认登记表为空且不注入任何源码', () {
      expect(PolyfillRegistry.empty.isEmpty, isTrue);
      expect(PolyfillRegistry.empty.bootstrap(), isEmpty);
    });

    test('按依赖顺序注入', () {
      final registry = PolyfillRegistry(<SandboxPolyfill>[
        const _FakePolyfill('b', requires: <String>['a'], marker: 'B'),
        const _FakePolyfill('a', marker: 'A'),
      ]);
      expect(registry.ordered().map((item) => item.id).toList(), <String>['a', 'b']);
      final bootstrap = registry.bootstrap();
      expect(bootstrap.indexOf('A'), lessThan(bootstrap.indexOf('B')));
    });

    test('缺少依赖或存在环时明确报错', () {
      expect(
        () => PolyfillRegistry(<SandboxPolyfill>[
          const _FakePolyfill('a', requires: <String>['missing'], marker: 'A'),
        ]).ordered(),
        throwsA(isA<StateError>()),
      );
      expect(
        () => PolyfillRegistry(<SandboxPolyfill>[
          const _FakePolyfill('a', requires: <String>['b'], marker: 'A'),
          const _FakePolyfill('b', requires: <String>['a'], marker: 'B'),
        ]).ordered(),
        throwsA(isA<StateError>()),
      );
    });

    test('空 id 或空源码被拒绝', () {
      expect(
        () => PolyfillRegistry().register(const _FakePolyfill('', marker: 'A')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => PolyfillRegistry().register(const _FakePolyfill('a', marker: '')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('原生库不可用时的降级', () {
    test(
      '创建沙箱明确抛错，调用方不会拿到半可用实例',
      () async {
        expect(LumeSandbox.isSupported, isFalse);
        expect(
          () => LumeSandbox.create(id: 'nope'),
          throwsStateError,
        );
        expect(LumeSandbox.availabilityDetail, isNotEmpty);
      },
      skip: LumeSandbox.isSupported ? '当前平台原生库可用，跳过降级用例' : null,
    );
  });

  group('SandboxScopeOwner 页面生命周期', () {
    testWidgets('页面退出自动销毁沙箱作用域', (tester) async {
      SandboxScope? scope;
      await tester.pumpWidget(
        MaterialApp(home: _ScopeProbe(onReady: (value) => scope = value)),
      );
      expect(scope, isNotNull);
      expect(scope!.isDisposed, isFalse);
      expect(scope!.count, 0);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(scope!.isDisposed, isTrue);
    });
  });
}

/// 用页面混入 [SandboxScopeOwner]，验证 `State.dispose` 会销毁作用域。
class _ScopeProbe extends StatefulWidget {
  const _ScopeProbe({required this.onReady});

  final ValueChanged<SandboxScope> onReady;

  @override
  State<_ScopeProbe> createState() => _ScopeProbeState();
}

class _ScopeProbeState extends State<_ScopeProbe> with SandboxScopeOwner {
  @override
  void initState() {
    super.initState();
    widget.onReady(sandboxes);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _FakePolyfill implements SandboxPolyfill {
  const _FakePolyfill(this.id, {this.requires = const <String>[], required this.marker});

  @override
  final String id;

  @override
  final List<String> requires;

  /// 用于断言注入顺序的标记。
  final String marker;

  @override
  String get source => marker.isEmpty ? '' : 'var $marker = 1; // $marker';
}
