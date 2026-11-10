import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/cat/cat_data_source.dart';
import 'package:lume_box/core/cat/cat_service.dart';
import 'package:lume_box/features/reading/section_toolbar.dart';

class FakeCatService extends CatService {
  FakeCatService() : super.testing();
  final calls = <String>[];
  String title = '测试作品';

  @override
  Future<Map<String, dynamic>> call(
    CatSite site,
    String operation, [
    Map<String, dynamic> body = const {},
  ]) async {
    calls.add(site.id);
    if (site.key == 'bad') throw StateError('failed');
    return {
      'list': [
        {'vod_id': '1', 'vod_name': title},
      ],
    };
  }
}

void main() {
  test('Cat adapter does not retain a second stale copy of centrally cached metadata', () async {
    final service = FakeCatService();
    final source = CatDataSource(
      service,
      CatSite(subscriptionId: 's', key: 'site', name: 'site', api: '/site'),
    );
    expect((await source.homeData())['list'][0]['vod_name'], '测试作品');
    expect((await source.rawDetail('1'))['vod_name'], '测试作品');
    service.title = '刷新结果';
    expect((await source.homeData())['list'][0]['vod_name'], '刷新结果');
    expect((await source.rawDetail('1'))['vod_name'], '刷新结果');
    service.dispose();
  });

  test('猫源聚合跨启用订阅，过滤不可搜索站点并隔离失败', () async {
    final service = FakeCatService();
    CatSite site(String subscription, String key, {bool searchable = true}) =>
        CatSite(
          subscriptionId: subscription,
          key: key,
          name: key,
          api: '/$key',
          searchable: searchable,
        );
    final first = site('a', 'first');
    final second = site('b', 'second');
    final bad = site('b', 'bad');
    service.subscriptions.addAll([
      CatSubscription(
        id: 'a',
        name: 'a',
        url: '',
        sites: [first, site('a', 'off', searchable: false)],
      ),
      CatSubscription(id: 'b', name: 'b', url: '', sites: [second, bad]),
      CatSubscription(
        id: 'c',
        name: 'c',
        url: '',
        enabled: false,
        sites: [site('c', 'disabled')],
      ),
    ]);
    final manager = CatAggregateSourceManager(service);
    final result = await AggregateSearch.run(
      sources: await manager.list(),
      open: manager.open,
      keyword: '测试',
    );
    expect(result.hits.map((hit) => hit.sourceId), [first.id, second.id]);
    expect(result.failed, 1);
    expect(service.calls.toSet(), {first.id, second.id, bad.id});
    expect(await manager.open('c|video|disabled'), isNull);
    service.dispose();
  });
}
