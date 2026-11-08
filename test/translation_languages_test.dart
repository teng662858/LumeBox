import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/translation/translation_languages.dart';
import 'package:lume_box/features/settings/translation_languages_page.dart';
import 'package:lume_box/features/settings/global_translation_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final allButton = find.byKey(
    const ValueKey('download-all-translation-languages'),
  );
  tearDown(
    () =>
        messenger.setMockMethodCallHandler(TranslationLanguages.channel, null),
  );

  List<Map<String, String>> packs({bool ready = false}) => [
    {'code': 'en', 'name': '英语', 'status': 'installed'},
    {'code': 'ja', 'name': '日语', 'status': ready ? 'installed' : 'supported'},
    {'code': 'ko', 'name': '韩语', 'status': ready ? 'installed' : 'supported'},
  ];

  testWidgets('合并翻译设置与语言包，页内切换不新增标题栏或触发下载', (tester) async {
    var downloads = 0;
    messenger.setMockMethodCallHandler(TranslationLanguages.channel, (
      call,
    ) async {
      if (call.method == 'translationLanguages') return packs();
      downloads++;
      return [];
    });
    await tester.pumpWidget(
      const MaterialApp(home: GlobalTranslationSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('实时翻译'), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.text('语言包'));
    await tester.pumpAndSettle();
    expect(allButton, findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(downloads, 0);
    expect(find.text('全局翻译设置'), findsNothing);
    await tester.tap(find.text('翻译设置'));
    await tester.pumpAndSettle();
    expect(find.text('实时翻译'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('language status must come from a valid system response', () async {
    messenger.setMockMethodCallHandler(
      TranslationLanguages.channel,
      (_) async => [
        {'code': 'ja', 'name': '日语', 'status': 'downloaded-maybe'},
      ],
    );
    await expectLater(
      const TranslationLanguages().load(),
      throwsFormatException,
    );
  });

  testWidgets(
    'opening settings never downloads; bulk action skips installed packs and refreshes',
    (tester) async {
      var ready = false, downloads = 0, reads = 0;
      messenger.setMockMethodCallHandler(TranslationLanguages.channel, (
        call,
      ) async {
        if (call.method == 'translationLanguages') {
          reads++;
          return packs(ready: ready);
        }
        expect(call.method, 'prepareTranslationLanguages');
        final args = call.arguments as Map;
        expect(args['languages'], ['ja', 'ko']);
        expect(args['target'], 'zh-Hans');
        downloads++;
        ready = true;
        return ['ja', 'ko'];
      });
      await tester.pumpWidget(
        const MaterialApp(home: TranslationLanguagesPage()),
      );
      await tester.pumpAndSettle();
      expect(find.text('已就绪 1 / 3'), findsOneWidget);
      expect(downloads, 0);
      await tester.tap(allButton);
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(reads, 2);
      expect(find.text('已就绪 3 / 3'), findsOneWidget);
      expect(tester.widget<FilledButton>(allButton).onPressed, isNull);
    },
  );

  testWidgets(
    'partial downloads keep installed languages and expose the actual error',
    (tester) async {
      var partial = false;
      messenger.setMockMethodCallHandler(TranslationLanguages.channel, (
        call,
      ) async {
        if (call.method == 'translationLanguages') {
          final result = packs();
          if (partial) result[1]['status'] = 'installed';
          return result;
        }
        partial = true;
        throw PlatformException(
          code: 'translation_partial',
          message: '韩语下载未完成，日语已保留',
          details: ['ja'],
        );
      });
      await tester.pumpWidget(
        const MaterialApp(home: TranslationLanguagesPage()),
      );
      await tester.pumpAndSettle();
      await tester.tap(allButton);
      await tester.pumpAndSettle();
      expect(find.text('已就绪 2 / 3'), findsOneWidget);
      expect(find.text('韩语下载未完成，日语已保留'), findsOneWidget);
      expect(find.text('下载全部未安装语言包（1）'), findsOneWidget);
    },
  );

  testWidgets('leaving a running download cancels the native job', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    String? started, cancelled;
    messenger.setMockMethodCallHandler(TranslationLanguages.channel, (
      call,
    ) async {
      if (call.method == 'translationLanguages') return packs();
      final args = call.arguments as Map;
      if (call.method == 'prepareTranslationLanguages') {
        started = args['id'] as String;
        return pending.future;
      }
      if (call.method == 'cancel') cancelled = args['id'] as String;
      return null;
    });
    await tester.pumpWidget(
      const MaterialApp(home: TranslationLanguagesPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(allButton);
    await tester.pump();
    expect(started, isNotNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(cancelled, started);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsupported systems show a clear message without a download button',
    (tester) async {
      messenger.setMockMethodCallHandler(TranslationLanguages.channel, (
        _,
      ) async {
        throw PlatformException(
          code: 'unsupported',
          message: '系统翻译语言包需要 iOS 18 或以上',
        );
      });
      await tester.pumpWidget(
        const MaterialApp(home: TranslationLanguagesPage()),
      );
      await tester.pumpAndSettle();
      expect(find.text('系统翻译语言包需要 iOS 18 或以上'), findsOneWidget);
      expect(allButton, findsNothing);
    },
  );
}
