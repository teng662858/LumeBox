// Development-only snapshots of the production drawer with real Chinese fonts.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/video_source_picker_test.dart' as picker_tests;

void main() {
  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\Deng.ttf');
    if (font.existsSync()) {
      for (final family in ['Roboto', 'Ahem']) {
        final loader = FontLoader(family);
        loader.addFont(
          font.readAsBytes().then((bytes) => bytes.buffer.asByteData()),
        );
        await loader.load();
      }
    }
    final icons = File(
      r'C:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(
        icons.readAsBytes().then((bytes) => bytes.buffer.asByteData()),
      );
      await loader.load();
    }
  });
  picker_tests.main();
}
