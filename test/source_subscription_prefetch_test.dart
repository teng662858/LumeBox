import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/net/source_subscription.dart';

void main() {
  test('官方订阅文件最多六路并发且按清单顺序返回', () async {
    const base =
        'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/';
    final gate = Completer<void>();
    final allStarted = Completer<void>();
    var active = 0, peak = 0;
    final resolver = SourceSubscription(
      fetch: (url) async {
        if (url.endsWith('/manifest')) {
          final text = [for (var i = 0; i < 6; i++) '${base}video/$i.js']
              .join('\n');
          return SourceFetchResult(bytes: utf8.encode(text), text: text);
        }
        active++;
        if (active > peak) peak = active;
        if (active == 6) allStarted.complete();
        await gate.future;
        active--;
        const text = '// LumeSource: {}\nLumeSource = {};';
        return SourceFetchResult(bytes: utf8.encode(text), text: text);
      },
    );
    final pending = resolver.resolveRefs(['${base}manifest']);
    await allStarted.future.timeout(const Duration(seconds: 2));
    expect(peak, 6);
    gate.complete();
    expect((await pending).map((r) => r.url), [
      for (var i = 0; i < 6; i++) '${base}video/$i.js',
    ]);
  });

  test('首个源慢时其余下载槽继续处理后续文件，结果顺序保持不变', () async {
    final first = Completer<void>();
    final laterFinished = Completer<void>();
    var active = 0, peak = 0, finished = 0;
    final resolver = SourceSubscription(
      fetch: (url) async {
        if (url.endsWith('/manifest')) {
          final text = [
            for (var i = 0; i < 8; i++) 'https://fixture.test/$i.js',
          ].join('\n');
          return SourceFetchResult(bytes: utf8.encode(text), text: text);
        }
        active++;
        if (active > peak) peak = active;
        if (url.endsWith('/0.js')) {
          await first.future;
        }
        active--;
        if (!url.endsWith('/0.js') && ++finished == 7) laterFinished.complete();
        const text = '// LumeSource: {}\nLumeSource = {};';
        return SourceFetchResult(bytes: utf8.encode(text), text: text);
      },
    );
    final pending = resolver.resolveRefs(['https://fixture.test/manifest']);
    await laterFinished.future.timeout(const Duration(seconds: 2));
    expect(peak, lessThanOrEqualTo(4));
    first.complete();
    final refs = await pending;
    expect(refs.map((r) => r.url), [
      for (var i = 0; i < 8; i++) 'https://fixture.test/$i.js',
    ]);
  });

  test('下载最多四路并发，完成乱序仍按清单导入，单文件失败不吞掉其余源', () async {
    final gates = List.generate(8, (_) => Completer<void>());
    final firstBatch = Completer<void>();
    final secondBatch = Completer<void>();
    var active = 0, peak = 0, started = 0;
    final failures = <String>[];
    final resolver = SourceSubscription(
      onSkip: (url, error) => failures.add(url),
      fetch: (url) async {
        String text;
        if (url.endsWith('/manifest')) {
          text = [for (var i = 0; i < 8; i++) 'https://fixture.test/$i.js']
              .join('\n');
        } else {
          final i = int.parse(
            Uri.parse(url).pathSegments.last.split('.').first,
          );
          active++;
          started++;
          if (active > peak) peak = active;
          if (started == 4) firstBatch.complete();
          if (started == 8) secondBatch.complete();
          try {
            await gates[i].future;
            if (i == 5) throw StateError('fixture failure');
            text = '// LumeSource: {}\nLumeSource = {};';
          } finally {
            active--;
          }
        }
        return SourceFetchResult(bytes: utf8.encode(text), text: text);
      },
    );
    final pending = resolver.resolveRefs(['https://fixture.test/manifest']);
    await firstBatch.future.timeout(const Duration(seconds: 2));
    expect(peak, 4);
    for (final i in [3, 2, 1, 0]) {
      gates[i].complete();
    }
    await secondBatch.future.timeout(const Duration(seconds: 2));
    for (final i in [7, 6, 5, 4]) {
      gates[i].complete();
    }
    final refs = await pending;
    expect(refs.map((r) => r.url), [
      for (var i = 0; i < 8; i++)
        if (i != 5) 'https://fixture.test/$i.js',
    ]);
    expect(peak, 4);
    expect(failures, ['https://fixture.test/5.js']);
    expect(resolver.complete, isFalse);
  });
}
