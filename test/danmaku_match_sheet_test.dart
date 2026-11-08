import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/danmaku/dandanplay_client.dart';
import 'package:lume_box/features/video/danmaku/danmaku_match_sheet.dart';
import 'package:lume_box/features/video/danmaku/danmaku_panel.dart';

void main() {
  testWidgets('横屏弹层贴右占四成，内容保持物理右边缘', (tester) async {
    tester.view.physicalSize = const Size(932, 430);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(
      left: 62,
      right: 62,
      bottom: 21,
    );
    tester.view.padding = const FakeViewPadding(
      left: 62,
      right: 62,
      bottom: 21,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuPanel<void>(
                context: context,
                builder: (_) => const Text('面板内容'),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.byKey(const ValueKey('danmaku-panel-frame')),
    );
    expect(rect.right, 932);
    expect(rect.width, closeTo(932 * .4, .01));
    expect(tester.getRect(find.text('面板内容')).right, lessThanOrEqualTo(932));
    expect(rect.left, greaterThanOrEqualTo(62));
    expect(tester.takeException(), isNull);
  });

  for (final landscape in [false, true]) {
    testWidgets('匹配先核对作品和集数，空弹幕不提交，横屏=$landscape', (tester) async {
      await tester.binding.setSurfaceSize(
        landscape ? const Size(900, 450) : const Size(450, 850),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var empty = true;
      final requests = <Uri>[];
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          '',
          '',
          baseUrl: 'https://danmu.example/custom',
        ),
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode(
              request.url.path.contains('/comment/')
                  ? {
                      'comments': empty
                          ? []
                          : [
                              {'p': '0,1,16777215,test', 'm': '第一集弹幕'},
                            ],
                    }
                  : {
                      'animes': [
                        {
                          'animeId': 1,
                          'animeTitle': '熔城(2026)【电视剧】from tencent',
                          'episodes': [
                            {'episodeId': 11, 'episodeTitle': '【qq】 熔城_01'},
                            {'episodeId': 12, 'episodeTitle': '第2集'},
                          ],
                        },
                        {
                          'animeId': 2,
                          'animeTitle': '活火熔城(1997)【电影】from 360',
                          'episodes': [
                            {'episodeId': 21, 'episodeTitle': '正片'},
                          ],
                        },
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      DanmakuMatchSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    selected = await showDanmakuPanel<DanmakuMatchSelection>(
                      context: context,
                      builder: (_) => DanmakuMatchSheet(
                        client: client,
                        title: '熔城',
                        episode: 1,
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(requests.first.queryParameters['episode'], '1');
      // Both fields stay usable above the software keyboard in either layout.
      final titleField = find.byKey(const ValueKey('danmaku-match-title'));
      await tester.tap(titleField);
      await tester.pump();
      final editor = tester.state<EditableTextState>(
        find.descendant(of: titleField, matching: find.byType(EditableText)),
      );
      expect(editor.widget.focusNode.hasFocus, isTrue);
      tester.view.viewInsets = FakeViewPadding(
        bottom: (landscape ? 300 : 300) * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      expect(editor.mounted, isTrue, reason: '切换紧凑布局时必须保留输入框，避免键盘弹出后立刻失焦');
      expect(editor.widget.focusNode.hasFocus, isTrue);
      final field = tester.getRect(
        find.byKey(const ValueKey('danmaku-match-title')),
      );
      expect(field.height, greaterThan(36));
      expect(
        field.bottom,
        lessThan((landscape ? 450 : 850) - (landscape ? 300 : 300)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('danmaku-match-title')),
        '熔城测试',
      );
      expect(find.text('熔城测试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(editor.mounted, isTrue, reason: '键盘收起恢复完整布局时也要保留输入连接');
      expect(editor.widget.focusNode.hasFocus, isTrue);
      expect(find.text('熔城'), findsWidgets);
      expect(find.text('活火熔城'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('danmaku-work-1|2026|tencent')),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前集数'), findsOneWidget);
      await tester.tap(find.text('加载所选集弹幕'));
      await tester.pumpAndSettle();
      expect(requests.last.path, '/custom/api/v2/comment/11');
      expect(selected, isNull);
      expect(find.byKey(const ValueKey('danmaku-match-error')), findsOneWidget);
      empty = false;
      await tester.tap(find.text('加载所选集弹幕'));
      await tester.pumpAndSettle();
      expect(selected?.episode.id, '11');
      expect(selected?.track.length, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final firstStatus in [200, 502]) {
    testWidgets('手动匹配选到空或失败条目时换同集来源 HTTP=$firstStatus', (tester) async {
      final requests = <Uri>[];
      final client = DandanplayClient(
        credentials: const DandanplayCredentials(
          '',
          '',
          baseUrl: 'https://danmu.example/custom',
        ),
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/search/episodes')) {
            expect(request.url.queryParameters['anime'], '大刑伺候');
            return http.Response(
              jsonEncode({
                'animes': [
                  {
                    'animeId': 1,
                    'animeTitle': '大刑伺候(2026)【国产剧】from tencent',
                    'source': 'TMDB',
                    'episodes': [
                      {
                        'episodeId': 11,
                        'episodeTitle': '第1集',
                        'episodeNumber': '1',
                      },
                    ],
                  },
                  {
                    'animeId': 2,
                    'animeTitle': '大刑伺候(2026)【国产剧】from tencent',
                    'source': 'tencent',
                    'episodes': [
                      {
                        'episodeId': 12,
                        'episodeTitle': '第1集',
                        'episodeNumber': '1',
                      },
                    ],
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.path.endsWith('/comment/11')) {
            return http.Response(
              '{"comments":[]}',
              firstStatus,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (request.url.path.endsWith('/comment/12')) {
            return http.Response(
              jsonEncode({
                'comments': [
                  {'p': '0,1,16777215,test', 'm': '原生来源的弹幕'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          fail('unexpected ${request.url}');
        }),
      );
      addTearDown(client.close);
      DanmakuMatchSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    selected = await showDanmakuPanel<DanmakuMatchSelection>(
                      context: context,
                      builder: (_) => DanmakuMatchSheet(
                        client: client,
                        title: '大刑伺候 2026·国产剧·tencent',
                        episode: 1,
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(requests.first.queryParameters['anime'], '大刑伺候');
      await tester.tap(find.byKey(const ValueKey('danmaku-work-1|2026|TMDB')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('danmaku-episode-11')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载所选集弹幕'));
      await tester.pumpAndSettle();
      expect(selected?.episode.id, '12');
      expect(selected?.track.length, 1);
      expect(
        requests.map((uri) => uri.path),
        contains('/custom/api/v2/comment/11'),
      );
      expect(
        requests.map((uri) => uri.path),
        contains('/custom/api/v2/comment/12'),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
