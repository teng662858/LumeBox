import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/core/reading/image_pipeline.dart';
import 'package:lume_box/features/reading/section_image.dart';

Uint8List _png(int size) =>
    Uint8List.fromList(img.encodePng(img.Image(width: size, height: size)));

NetworkResponse _response(int size) =>
    NetworkResponse(statusCode: 200, body: _png(size), headers: const {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('换封面地址时保留上一帧，不闪成占位图', (tester) async {
    final gates = <String, Completer<NetworkResponse>>{};
    final pipeline = SectionImagePipeline(
      cacheDir: '',
      diskCache: false,
      maxConcurrent: 4,
      maxRetries: 0,
      requestSender: (request) =>
          (gates[Uri.parse(request.url).path] = Completer<NetworkResponse>())
              .future,
    );
    addTearDown(pipeline.dispose);

    Widget build(String url) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 100,
          height: 160,
          child: SectionImage(pipeline: pipeline, url: url, targetWidth: 200),
        ),
      ),
    );

    await tester.pumpWidget(build('https://img.test/frame-1'));
    await tester.pump();
    gates['/frame-1']!.complete(_response(4));
    // 解码是真异步：让它跑完再收帧。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    final first = tester.widget<RawImage>(find.byType(RawImage));
    expect(first.image, isNotNull);
    expect(first.image!.width, 4);

    // 换地址：新图还在路上，这一帧必须继续显示旧图（旧实现此时是占位图）。
    await tester.pumpWidget(build('https://img.test/frame-2'));
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image!.width,
      4,
      reason: '新帧未到之前要保留上一帧',
    );

    // 新帧到了就地替换。
    gates['/frame-2']!.complete(_response(6));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 6);
    expect(tester.takeException(), isNull);
  });
}
