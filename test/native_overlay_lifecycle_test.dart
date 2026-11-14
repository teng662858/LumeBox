import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/features/shell/dock_native_glass.dart';

void main() {
  testWidgets(
    'native material is removed during route exit instead of left offstage',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final disposed = <Object?>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'dispose') disposed.add(call.arguments);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox(
              width: 240,
              height: 80,
              child: DockNativeGlass(
                borderRadius: BorderRadius.all(Radius.circular(20)),
                cornerRadius: 20,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.byType(UiKitView), findsNothing);
      expect(disposed, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.byType(DockNativeGlass), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
