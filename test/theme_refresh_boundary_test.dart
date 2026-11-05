import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/shared/widgets/theme_refresh_boundary.dart';

Color _color = Colors.white;
int _initializations = 0;

class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  int count = 0;
  @override
  void initState() {
    super.initState();
    _initializations++;
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _color,
    child: TextButton(
      onPressed: () => setState(() => count++),
      child: Text('$count'),
    ),
  );
}

void main() {
  testWidgets(
    'theme reevaluation retains page state and refreshes static colors',
    (tester) async {
      _initializations = 0;
      _color = Colors.white;
      Widget app(String id) => MaterialApp(
        home: ThemeRefreshBoundary(identity: id, child: const _Page()),
      );
      await tester.pumpWidget(app('light'));
      await tester.tap(find.text('0'));
      await tester.pump();
      _color = Colors.black;
      await tester.pumpWidget(app('dark'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(_initializations, 1);
      expect(
        tester.widget<ColoredBox>(find.byType(ColoredBox).last).color,
        Colors.black,
      );
    },
  );
}
