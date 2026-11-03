import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/util/source_load_profile.dart';
import 'package:lume_box/features/video/video_resume_match.dart';
import 'package:lume_box/core/source/source.dart';

void main() {
  test('加载诊断记录成功和失败并限制会话记录数量', () async {
    SourceLoadProfile.entries.value = const [];
    expect(await SourceLoadProfile.measure('读取清单', () async => 3), 3);
    await expectLater(
      SourceLoadProfile.measure('启动源', () async => throw StateError('secret')),
      throwsStateError,
    );
    expect(SourceLoadProfile.entries.value.first, contains('失败／超时'));
    expect(SourceLoadProfile.entries.value.join(), isNot(contains('secret')));
    for (var i = 0; i < 35; i++) {
      await SourceLoadProfile.measure('请求', () async {});
    }
    expect(SourceLoadProfile.entries.value, hasLength(30));
  });

  test('换源续看不能把相同季的不同集判断为准确匹配', () {
    const request = VideoResumeRequest(
      title: '剧名',
      chapterTitle: '第03集',
      chapterIndex: 2,
      position: Duration(minutes: 5),
      duration: Duration(minutes: 40),
    );
    expect(
      request.confident(const SourceChapter(id: '2', title: '第02集')),
      isFalse,
    );
    expect(
      request.confident(const SourceChapter(id: '3', title: '第03集')),
      isTrue,
    );
    expect(
      request.confident(const SourceChapter(id: 'x', title: '预告')),
      isFalse,
    );
  });
}
