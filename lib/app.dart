import 'package:flutter/material.dart';

import 'core/theme/lume_theme.dart';
import 'features/shell/home_page.dart';

/// Lume Box 应用入口。
class LumeBoxApp extends StatelessWidget {
  const LumeBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: LumeTheme.appName,
      debugShowCheckedModeBanner: false,
      theme: LumeTheme.build(),
      home: const HomePage(),
    );
  }
}
