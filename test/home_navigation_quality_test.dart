import 'package:lume_box/features/reading/browse_header_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/home_browse_mode.dart';
import 'package:lume_box/core/net/ios_image_network.dart';
import 'package:lume_box/core/net/network_queue.dart';
import 'package:lume_box/features/video/source_playback.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';
import 'package:lume_box/shared/widgets/home_browse_navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('首页伸缩只响应主列表的竖向手势，横滑和程序滚动保持状态', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox).first);
    ScrollUpdateNotification update({
      double pixels = 100,
      double delta = 10,
      AxisDirection axis = AxisDirection.down,
      bool drag = true,
    }) => ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: pixels,
        viewportDimension: 600,
        axisDirection: axis,
        devicePixelRatio: 1,
      ),
      context: context,
      scrollDelta: delta,
      dragDetails: drag ? DragUpdateDetails(globalPosition: Offset.zero) : null,
    );
    expect(BrowseHeaderScroll.hiddenAfter(update(), false), isTrue);
    expect(BrowseHeaderScroll.hiddenAfter(update(delta: -10), true), isFalse);
    expect(BrowseHeaderScroll.hiddenAfter(update(pixels: 0), true), isFalse);
    expect(
      BrowseHeaderScroll.hiddenAfter(update(axis: AxisDirection.right), false),
      isFalse,
    );
    expect(BrowseHeaderScroll.hiddenAfter(update(drag: false), false), isFalse);
    expect(
      BrowseHeaderScroll.hiddenAfter(update(drag: false, delta: -10), true),
      isTrue,
    );
  });
  test('最高分辨率和专属请求头一起选择，未知清晰度保持主地址', () {
    final content = VideoContent(
      url: Uri.parse('https://demo/default'),
      headers: const {'Referer': 'https://demo/'},
      qualities: [
        VideoQuality(label: '720P', url: Uri.parse('https://demo/720')),
        VideoQuality(
          label: '4K',
          url: Uri.parse('https://demo/4k'),
          headers: const {'Authorization': 'quality-token'},
        ),
        VideoQuality(label: '1080P', url: Uri.parse('https://demo/1080')),
      ],
    );
    expect(
      SourcePlayback.contentAddress(content),
      Uri.parse('https://demo/4k'),
    );
    expect(SourcePlayback.contentHeaders(content), {
      'Authorization': 'quality-token',
    });
    final unknown = VideoContent(
      url: content.url,
      qualities: [
        VideoQuality(label: '线路 2', url: Uri.parse('https://demo/other')),
      ],
    );
    expect(SourcePlayback.contentAddress(unknown), content.url);
    final dimensions = ChapterContent.parse({
      'kind': 'video',
      'url': 'https://demo/default',
      'qualities': [
        {'url': 'https://demo/a', 'label': 'A', 'height': 2160},
      ],
    }) as VideoContent;
    expect(
      SourcePlayback.contentAddress(dimensions),
      Uri.parse('https://demo/a'),
    );
  });
  test('清晰度高度为字符串或异常值时仍能选择可播放线路', () {
    final video = ChapterContent.parse({
      'kind': 'video', 'url': 'https://demo/default',
      'qualities': [
        {'url': 'https://demo/hd', 'label': 'HD', 'height': '1080',
         'headers': {'Referer': 'https://demo/watch'}},
        {'url': 'https://demo/sd', 'label': '480P', 'height': 'unknown'},
        {'url': 'https://demo/other', 'height': double.infinity},
      ],
    }) as VideoContent;
    expect(video.qualities.map((q) => q.resolutionRank), [1080, 480, 0]);
    expect(SourcePlayback.contentAddress(video), Uri.parse('https://demo/hd'));
    expect(SourcePlayback.contentHeaders(video), {'Referer': 'https://demo/watch'});
  });

  test('热门最新使用源的排序值并保留分类，不误选热门题材', () {
    const groups = [
      SourceFilterGroup(
        id: 'by',
        title: '排序',
        options: [
          SourceFilterOption(id: 'hits', title: '人气'),
          SourceFilterOption(id: 'time', title: '时间'),
        ],
      ),
      SourceFilterGroup(
        id: 'genre',
        title: '题材',
        options: [SourceFilterOption(id: 'hot', title: '热门题材')],
      ),
    ];
    expect(homeBrowseTarget('热门', [], groups), (
      category: null,
      group: 'by',
      option: 'hits',
    ));
    expect(homeBrowseTarget('最新', [], groups), (
      category: null,
      group: 'by',
      option: 'time',
    ));
    expect(
      homeBrowseTarget('最新', [
        const SourceCategory(id: 'updates', title: '热门更新'),
      ], []),
      (category: 'updates', group: null, option: null),
    );
    expect(homeBrowseTarget('热门', [], [groups.last]), isNull);
  });
  test('iOS图片字节和失败状态原样返回供统一管线处理', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosImageNetwork.channel, (call) async {
          expect(call.arguments['requestId'], startsWith('http-'));
          expect(Map.of(call.arguments as Map)..remove('requestId'), {
            'url': 'https://demo/cover',
            'headers': {'Referer': 'https://demo/'},
            'method': 'GET',
            'timeoutSeconds': 15.0,
            'followRedirects': true,
          });
          return {
            'status': 403,
            'body': Uint8List.fromList([1, 2]),
            'headers': {'Content-Type': 'text/html'},
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(IosImageNetwork.channel, null),
    );
    final response = await IosImageNetwork.send(
      const NetworkRequest(
        url: 'https://demo/cover',
        headers: {'Referer': 'https://demo/'},
      ),
    );
    expect(response.statusCode, 403);
    expect(response.body, [1, 2]);
  });
  testWidgets('375像素顶部内容导航与右侧操作并列且没有溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: GlassScaffold(
          title: '漫画',
          mergeHomeHeader: true,
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.history)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.bookmark)),
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.rss_feed),
              label: const Text('订阅'),
            ),
          ],
          child: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.all(24),
              child: HomeHeaderScope.headerOf(
                context,
                navigation: HomeBrowseNavigation(
                  selected: '热门',
                  onSelect: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('热门'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
