import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:lume_box/core/cat/cat_web_parse.dart';
import 'package:lume_box/core/media/playback_focus.dart';
import 'package:lume_box/features/video/source_web_player_page.dart';

class _Platform extends WebViewPlatform {
  late _Controller controller;
  late _Delegate delegate;
  int created = 0, views = 0, disposedViews = 0;
  Future<void>? loadBarrier;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    created++;
    return controller = _Controller(params, loadBarrier: loadBarrier);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => delegate = _Delegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _View(params, this);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params, {this.loadBarrier}) : super.implementation();
  final Future<void>? loadBarrier;
  final loads = <Uri>[];
  final scripts = <String>[];
  int reloads = 0;
  String result = 'selected';
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
    if (params.uri.scheme != 'about') await loadBarrier;
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    scripts.add(javaScript);
    return result;
  }

  @override
  Future<void> reload() async {
    reloads++;
  }
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();
  late PageEventCallback finished, started;
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {
    started = callback;
  }

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}
  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _View extends PlatformWebViewWidget {
  _View(super.params, this.owner) : super.implementation();
  final _Platform owner;
  @override
  Widget build(BuildContext context) => _TrackingView(owner: owner);
}

class _TrackingView extends StatefulWidget {
  const _TrackingView({required this.owner});
  final _Platform owner;
  @override
  State<_TrackingView> createState() => _TrackingViewState();
}

class _TrackingViewState extends State<_TrackingView> {
  @override
  void initState() {
    super.initState();
    widget.owner.views++;
  }

  @override
  void dispose() {
    widget.owner.disposedViews++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _Platform platform;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumebox/mediaTracks'), (_) async => null);
    platform = _Platform();
    WebViewPlatform.instance = platform;
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumebox/mediaTracks'), null);
  });
  Future<void> open(WidgetTester tester, {String? selector, bool settle = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SourceWebPlayerPage(
          request: CatWebParseRequired(
            Uri.parse('https://play.example/watch/1'),
            {},
            webPlayer: true,
            episodeSelector: selector,
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('网页加载前等待其他播放器停止，关闭后不会接管焦点', (tester) async {
    final stopped = Completer<void>();
    var releases = 0;
    Future<void> stopAudio() async {
      releases++;
      await stopped.future;
    }
    await PlaybackFocus.acquire('web-test-audio', onRelease: stopAudio);
    addTearDown(() {
      if (!stopped.isCompleted) stopped.complete();
      PlaybackFocus.unregister('web-test-audio', stopAudio);
    });
    await open(tester, settle: false);
    expect(releases, 1);
    expect(platform.controller.loads, isEmpty);
    await tester.pumpWidget(const SizedBox());
    stopped.complete();
    await tester.pumpAndSettle();
    expect(platform.controller.loads.map((u) => u.toString()), ['about:blank']);
    expect(PlaybackFocus.owner, isNot('web_video'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('其他播放器接管时停止网页，刷新后才重新取得播放焦点', (tester) async {
    await open(tester);
    expect(PlaybackFocus.owner, 'web_video');
    var releases = 0;
    Future<void> stopAudio() async { releases++; }
    await PlaybackFocus.acquire('web-test-audio', onRelease: stopAudio);
    addTearDown(() => PlaybackFocus.unregister('web-test-audio', stopAudio));
    await tester.pumpAndSettle();
    expect(platform.controller.loads.last.toString(), 'about:blank');
    expect(find.textContaining('已停止网页播放'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(releases, 1);
    expect(PlaybackFocus.owner, 'web_video');
    expect(platform.controller.loads.last.toString(), 'https://play.example/watch/1');
    expect(find.textContaining('已停止网页播放'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final loadCount = platform.controller.loads.length;
    await PlaybackFocus.acquire('web-test-after-close');
    expect(platform.controller.loads.length, loadCount);
  });

  testWidgets('网页加载完成前被接管，迟到的加载与选集回调不能恢复页面', (tester) async {
    final loaded = Completer<void>();
    platform.loadBarrier = loaded.future;
    await open(tester, settle: false, selector: 'button.playbtn[data-id="74596"]');
    expect(PlaybackFocus.owner, 'web_video');
    await PlaybackFocus.acquire('web-test-new-player');
    await tester.pumpAndSettle();
    loaded.complete();
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pumpAndSettle();
    expect(platform.controller.loads.last.toString(), 'about:blank');
    expect(platform.controller.scripts, isEmpty);
    expect(platform.views, 0);
    expect(find.textContaining('已停止网页播放'), findsOneWidget);
    expect(find.text('重试选集'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('指定集数加载后选择一次，刷新后重新选择，跨站页面不执行', (tester) async {
    await open(tester, selector: 'button.playbtn[data-id="74596"]');
    expect(platform.controller.scripts, isEmpty);
    platform.delegate.finished('https://other.example/');
    await tester.pump();
    expect(platform.controller.scripts, isEmpty);
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    expect(platform.controller.scripts.single, contains('74596'));
    await tester.pump(const Duration(seconds: 3));
    expect(platform.controller.scripts.length, 1);
    platform.delegate.started('https://play.example/watch/1');
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    expect(platform.controller.scripts.length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('等待验证时可重试，关闭页面取消选集轮询', (tester) async {
    await open(tester, selector: 'button.playbtn[data-id="74596"]');
    platform.controller.result = 'waiting';
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('重试选集'), findsOneWidget);
    platform.controller.result = 'selected';
    await tester.tap(find.text('重试选集'));
    await tester.pump();
    expect(find.text('重试选集'), findsNothing);
    platform.controller.result = 'waiting';
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final count = platform.controller.scripts.length;
    await tester.pump(const Duration(seconds: 3));
    expect(platform.controller.scripts.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets('网页播放全屏切换保留同一页面，刷新不创建第二控制器', (tester) async {
    await open(tester);
    expect(find.text(SourceWebPlayerPage.limitations), findsOneWidget);
    expect(platform.views, 1);
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    expect(platform.views, 1);
    expect(platform.disposedViews, 0);
    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    expect(platform.controller.reloads, 1);
    expect(platform.created, 1);
    expect(platform.controller.loads.length, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(platform.controller.loads.last.toString(), 'about:blank');
  });
  testWidgets('已选中集数回前台不提示重选，等待验证时回前台显示重试', (tester) async {
    await open(tester, selector: 'button.playbtn[data-id="74596"]');
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('重试选集'), findsNothing);
    platform.controller.result = 'waiting';
    platform.delegate.finished('https://play.example/watch/1');
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('重试选集'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('进入后台暂停媒体，恢复前台不自动播放，退出停止页面', (tester) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.controller.scripts.last, contains('media.pause()'));
    final scripts = platform.controller.scripts.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.controller.scripts.length, scripts);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(platform.controller.loads.last.toString(), 'about:blank');
    expect(tester.takeException(), isNull);
  });
}
