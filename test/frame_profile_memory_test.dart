import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/util/frame_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('性能报告记录采集前后内存和帧样本', () {
    final profile = FrameProfile();
    profile.start('多源聚合搜索');
    profile.add(4, 5);
    final report = profile.stop();
    expect(report['frames'], 1);
    expect(report.containsKey('processRssStartBytes'), isTrue);
    expect(report.containsKey('processRssEndBytes'), isTrue);
    expect(report['scene'], '多源聚合搜索');
  });
}
