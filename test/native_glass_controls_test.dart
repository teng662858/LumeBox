import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/shared/widgets/native_glass_controls.dart';

void main() {
  testWidgets('UIKit 开关与滑块回传值，更新配置不重建控件', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final creations = <Map>[];
    final updates = <Map>[];
    final channels = <MethodChannel>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map;
        final config = const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params'] as Uint8List),
        ) as Map;
        creations.add({...config, 'id': args['id']});
        final channel = MethodChannel('lumebox/glass_control_${args['id']}');
        channels.add(channel);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'update') updates.add(call.arguments as Map);
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    final changes = <Object>[];
    var ends = 0;
    Widget scene(double value) => MaterialApp(
      theme: LumeTheme.build(customAccent: const Color(0xFFFF2D55)),
      home: Scaffold(
        body: Column(
          children: [
            NativeSwitchListTile.adaptive(
              useNative: true,
              value: true,
              title: const Text('开关'),
              onChanged: changes.add,
            ),
            NativeGlassSlider(
              useNative: true,
              value: value,
              min: 0,
              max: 100,
              divisions: 10,
              onChanged: changes.add,
              onChangeEnd: (_) => ends++,
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(scene(20));
    await tester.pumpAndSettle();
    expect(creations.map((m) => m['control']), ['switch', 'slider']);
    expect(creations.map((m) => m['tintColor']), everyElement(0xFFFF2D55));
    Future<void> emit(Map control, String name, Object value) async {
      await messenger.handlePlatformMessage(
        'lumebox/glass_control_${control['id']}',
        const StandardMethodCodec().encodeMethodCall(MethodCall(name, value)),
        (_) {},
      );
      await tester.pump();
    }

    await emit(creations.first, 'changed', false);
    await emit(creations.last, 'changed', 76.0);
    await emit(creations.last, 'ended', 76.0);
    expect(changes, [false, 80.0]);
    expect(ends, 1);
    await tester.pumpWidget(scene(80));
    await tester.pumpAndSettle();
    expect(creations.length, 2);
    expect(updates.where((m) => m['control'] == 'slider').last['value'], 80.0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
