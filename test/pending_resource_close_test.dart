import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/reading/reading_library.dart';
import 'package:lume_box/core/reading/reading_store.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Completer<String> directory;
  setUp(() {
    root = Directory.systemTemp.createTempSync('lume-pending-close');
    directory = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) => directory.future,
        );
  });
  tearDown(() async {
    ReadingLibrary.disposeAll();
    ReadingStore.disposeAll();
    SourceRegistry.close(Section.video);
    await SectionScope.closeAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    root.deleteSync(recursive: true);
  });
  test('离开页面早于阅读库初始化完成时，晚到库不会留在全局缓存', () async {
    final pending = ReadingLibrary.open(Section.video);
    ReadingLibrary.close(Section.video);
    directory.complete(root.path);
    final closed = await pending;
    expect(ReadingLibrary.find(Section.video), isNull);
    final reopened = await ReadingLibrary.open(Section.video);
    expect(identical(reopened, closed), isFalse);
  });
  test('源注册表在初始化途中关闭后，晚到数据库与闲置定时器会释放', () async {
    final pending = SourceRegistry.open(Section.video);
    SourceRegistry.close(Section.video);
    directory.complete(root.path);
    final closed = await pending;
    expect(closed.isDisposed, isTrue);
    final reopened = await SourceRegistry.open(Section.video);
    expect(reopened.isDisposed, isFalse);
    expect(identical(reopened, closed), isFalse);
  });
  test('关闭后重新进入页面，新的阅读库使用者撤销待关闭标记', () async {
    final pending = ReadingLibrary.open(Section.video);
    ReadingLibrary.close(Section.video);
    final next = ReadingLibrary.open(Section.video);
    directory.complete(root.path);
    expect(identical(await pending, await next), isTrue);
    expect(ReadingLibrary.find(Section.video), isNotNull);
  });
  test('关闭后新源请求复用在途初始化，不误关新使用者', () async {
    final pending = SourceRegistry.open(Section.video);
    SourceRegistry.close(Section.video);
    final next = SourceRegistry.open(Section.video);
    directory.complete(root.path);
    final current = await next;
    expect(identical(await pending, current), isTrue);
    expect(current.isDisposed, isFalse);
  });
}
