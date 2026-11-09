import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/reading/browse_layout.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/features/reading/poster_card.dart';

void main() {
  tearDown(BrowseLayoutSettings.instance.resetForTesting);

  group('SourceItem.coverLabel 解析', () {
    test('顶层字段与 mediaInfo 两种写法都认', () {
      final top = SourceItem.parse(<String, Object?>{
        'id': '1',
        'title': 'Luna',
        'coverLabel': '🇹🇼 台湾',
      });
      final nested = SourceItem.parse(<String, Object?>{
        'id': '2',
        'title': 'Mia',
        'mediaInfo': <String, Object?>{'liveCover': true, 'coverLabel': '🇨🇳 中国'},
      });
      expect(top!.coverLabel, '🇹🇼 台湾');
      expect(nested!.coverLabel, '🇨🇳 中国');
      // 角标不影响「是否直播」这类既有 mediaInfo 字段。
      expect(nested.mediaInfo['liveCover'], true);
    });

    test('空白、换行、超长与非字符串都当没写', () {
      expect(SourceItem.parseCoverLabel('   '), isNull);
      expect(SourceItem.parseCoverLabel('\n  '), isNull);
      expect(SourceItem.parseCoverLabel(123), isNull);
      expect(SourceItem.parseCoverLabel('这是一个明显太长的地区角标文本'), isNull);
      expect(SourceItem.parseCoverLabel(' 🇯🇵  日本 '), '🇯🇵 日本');
      // 恰好在长度上限内的短标签保留。
      expect(SourceItem.parseCoverLabel('🇺🇸 美国'), '🇺🇸 美国');
    });
  });

  testWidgets('封面角标画在封面上，空值不占位', (tester) async {
    await BrowseLayoutSettings.instance.setGridTitleStyle(GridTitleStyle.overlay);
    Future<void> pump(String? label) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 110,
              height: 190,
              child: PosterTile(
                item: SourceItem(
                  id: 'one',
                  title: '主播名',
                  coverLabel: label,
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await pump('🇹🇼 台湾');
    await tester.pumpAndSettle();
    expect(find.byType(CoverLabelTag), findsOneWidget);
    expect(find.text('🇹🇼 台湾'), findsOneWidget);
    // 遮罩标题样式下角标在上排，不压住底部标题。
    final card = tester.getRect(find.byType(PosterCard));
    final tag = tester.getRect(find.text('🇹🇼 台湾'));
    expect(tag.top - card.top, lessThan(12));

    await pump(null);
    await tester.pumpAndSettle();
    expect(find.byType(CoverLabelTag), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题外置样式时角标落在封面底部，且不越出卡片', (tester) async {
    await BrowseLayoutSettings.instance.setGridTitleStyle(GridTitleStyle.below);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 110,
              height: 190,
              child: PosterTile(
                item: const SourceItem(
                  id: 'one',
                  title: '主播名',
                  coverLabel: '🇨🇳 中国',
                ),
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(PosterCard));
    final cover = tester.getRect(find.byType(CoverThumb));
    final tag = tester.getRect(find.text('🇨🇳 中国'));
    expect(tag.left, greaterThanOrEqualTo(card.left));
    expect(tag.bottom, lessThanOrEqualTo(cover.bottom + 1));
    expect(tester.takeException(), isNull);
  });
}
