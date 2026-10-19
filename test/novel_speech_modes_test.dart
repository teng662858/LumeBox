import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/speech/speech_settings.dart';
import 'package:lume_box/core/speech/speech_local.dart';
import 'package:lume_box/features/novel/novel_speech_modes.dart';

class _LocalModel extends SpeechLocalModel {
  final installation = Completer<bool>();
  bool? fromFile;
  @override
  Future<bool> check() async => ready;
  @override
  Future<bool> prepare({XFile? archiveFile, bool fromFile = false}) async {
    this.fromFile = fromFile;
    preparing = true;
    notifyListeners();
    ready = await installation.future;
    preparing = false;
    if (!ready) error = '音色包校验失败，请重试';
    notifyListeners();
    return ready;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'four-mode selector guides missing offline model and switches online profile',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => '.cache/speech-unit-config',
          );
      SpeechLocalModel.instance.ready = false;
      var settings = const SpeechSettings(rate: .7);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => NovelSpeechModes(
                settings: settings,
                selectorOnly: true,
                onChanged: (value) => setState(() => settings = value),
              ),
            ),
          ),
        ),
      );
      final selector = tester.widget<DropdownButton<SpeechMode>>(
        find.byType(DropdownButton<SpeechMode>),
      );
      expect(selector.items!.length, 4);
      expect(
        selector.items!
            .singleWhere((item) => item.value == SpeechMode.local)
            .enabled,
        true,
      );
      await tester.tap(find.byType(DropdownButton<SpeechMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(SpeechMode.cloud.label).last);
      await tester.pumpAndSettle();
      expect(settings.mode, SpeechMode.cloud);
      expect(settings.rate, .5);
      expect(settings.copyWith(mode: SpeechMode.system).rate, .7);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('缺失音色包时取消保持系统模式，内置包就绪后再切换本地模式', (tester) async {
    final model = _LocalModel();
    addTearDown(model.dispose);
    var settings = const SpeechSettings(rate: .7);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, refresh) => NovelSpeechModes(
              settings: settings,
              localModel: model,
              selectorOnly: true,
              onChanged: (value) => refresh(() => settings = value),
            ),
          ),
        ),
      ),
    );
    Future<void> chooseLocal() async {
      await tester.tap(find.byType(DropdownButton<SpeechMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地离线朗读（先启用音色包）').last);
      await tester.pumpAndSettle();
      expect(find.text('启用本地离线朗读'), findsOneWidget);
    }

    await chooseLocal();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings.mode, SpeechMode.system);
    expect(
      tester
          .widget<DropdownButton<SpeechMode>>(
            find.byType(DropdownButton<SpeechMode>),
          )
          .value,
      SpeechMode.system,
    );
    expect(model.fromFile, isNull);
    await chooseLocal();
    await tester.tap(find.text('启用内置包'));
    await tester.pumpAndSettle();
    expect(model.preparing, true);
    expect(model.fromFile, false);
    expect(settings.mode, SpeechMode.system);
    model.installation.complete(true);
    await tester.pumpAndSettle();
    expect(settings.mode, SpeechMode.local);
    expect(settings.narratorVoice, '66');
    expect(find.text('离线音色包已就绪，可使用本地朗读'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('从文件安装失败显示原因并保持原朗读模式', (tester) async {
    final model = _LocalModel();
    addTearDown(model.dispose);
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NovelSpeechModes(
              settings: const SpeechSettings(),
              localModel: model,
              onChanged: (_) => changed = true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('启用内置离线音色包（约 147 MB）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从文件安装'));
    await tester.pump();
    expect(model.fromFile, true);
    model.installation.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('音色包校验失败，请重试'), findsWidgets);
    expect(changed, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小说音色列表和已选音色显示中文且保留系统标识', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('lumebox/speech'),
      (call) async => call.method == 'speechVoices'
          ? [
              {'id': 'voice-a', 'name': 'Tingting', 'language': 'zh-CN'},
              {'id': 'voice-b', 'name': 'Grandpa', 'language': 'zh-CN'},
            ]
          : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('lumebox/speech'),
        null,
      ),
    );
    var settings = const SpeechSettings(narratorVoice: 'voice-a');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, refresh) => NovelSpeechModes(
              settings: settings,
              optionsOnly: true,
              singleSpeaker: true,
              onChanged: (value) => refresh(() => settings = value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('婷婷 · 普通话'), findsOneWidget);
    await tester.tap(find.text('旁白音色'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('爷爷 · 普通话').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.narratorVoice, 'voice-b');
    expect(find.text('爷爷 · 普通话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('reader help stays collapsed until explicitly expanded', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: novelSpeechHelp)),
      ),
    );
    expect(find.text('📖听书功能使用帮助'), findsOneWidget);
    expect(find.textContaining('【四种听书模式新手教程】'), findsNothing);
    await tester.tap(find.text('📖听书功能使用帮助'));
    await tester.pumpAndSettle();
    expect(find.textContaining('【四种听书模式新手教程】'), findsOneWidget);
  });
}
