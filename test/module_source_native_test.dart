import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/js/source_registry.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/session/section_scope.dart';
import 'package:lume_box/core/source/source.dart';
import 'package:lume_box/core/source/source_package.dart';

import 'source_bundles_test.dart' show sourceZip;

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  late Directory root;
  setUp(() async {
    enableEngineOnThisPlatform();
    root = Directory.systemTemp.createTempSync('lume_modules');
    await installTempSectionRoot(root);
  });
  tearDown(() async {
    SourceRegistry.close(Section.video);
    await SectionScope.closeAll();
    restoreEnginePlatformGate();
    root.deleteSync(recursive: true);
  });
  test('模块内建 crypto、buffer、pako 与 CryptoJS 兼容分支无需 ZIP', () async {
    final manager = LumeSources.manager(Section.video);
    final imported = await manager.importScript('''
// LumeSource: {"id":"builtin-module","name":"内建模块","category":"video"}
// LumeRuntime: module
import {createHash} from 'node:crypto';
import {Buffer} from 'buffer';
import pako from 'pako';
var embedded = (function(){ var module, exports;
  if (typeof require === 'function') { try { require('crypto'); } catch (_) {} }
  return 'ok';
})();
export default {categories(){return [{id:'1', title:createHash('sha256').update(Buffer.from('abc')).digest('hex') + ':' + typeof pako.inflate + ':' + embedded}];}};
''');
    expect(imported.isSuccess, isTrue, reason: imported.message);
    final source = (await manager.open(imported.descriptor!.id))!;
    expect(
      (await source.categories()).single.title,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad:function:ok',
    );
  }, skip: available ? null : 'QuickJS 原生桥不可用');
  for (final style in ['default', 'named', 'commonjs']) {
    test('真实 QuickJS $style：导入、分类、搜索、详情、选集、播放与重开', () async {
      final manager = LumeSources.manager(Section.video);
      final declaration = style == 'named' ? 'export ' : '';
      final script =
          '''
// LumeSource: {"id":"module-$style","name":"模块 $style","category":"video"}
// LumeRuntime: module
${declaration}function categories() { return [{id:'movie',title:'电影'}]; }
${declaration}function list(a) { return {items:[{id:'1',title:a.keyword || '首页',cover:'https://example.org/cover.jpg'}],hasMore:false}; }
${declaration}function detail(a) { return {id:a.id,title:'详情'}; }
${declaration}function chapters(a) { return [{id:'ep1',title:'第一集'}]; }
${declaration}function content(a) { return {kind:'video',url:'https://example.org/video.mp4',headers:{Referer:'https://example.org/'}}; }
${style == 'default'
              ? 'export default {categories,list,detail,chapters,content};'
              : style == 'commonjs'
              ? 'module.exports = {categories,list,detail,chapters,content};'
              : ''}
''';
      final imported = await manager.importScript(script);
      expect(imported.isSuccess, isTrue, reason: imported.message);
      expect(imported.descriptor!.runtimeKind, 'module');
      await manager.select(imported.descriptor!.id);
      final source = (await manager.open(imported.descriptor!.id))!;
      expect((await source.categories()).single.title, '电影');
      expect((await source.list(keyword: '搜索')).items.single.title, '搜索');
      expect((await source.detail('1'))!.title, '详情');
      final chapter = (await source.chapters('1')).single;
      final content = (await source.content(
        itemId: '1',
        chapterId: chapter.id,
      )) as VideoContent;
      expect(content.url.path, '/video.mp4');
      expect(content.headers['Referer'], 'https://example.org/');
      SourceRegistry.close(Section.video);
      expect(
        (await source.list(keyword: '重开后')).items.single.title,
        '重开后',
        reason: '旧数据源在板块重开后应使用新注册表，而不是已关闭的数据库',
      );
      final afterReopen = await source.content(
        itemId: '1',
        chapterId: chapter.id,
      );
      expect((afterReopen as VideoContent).url.path, '/video.mp4');
      expect((await manager.open(imported.descriptor!.id))!.name, '模块 $style');
    }, skip: available ? null : 'QuickJS 原生桥不可用');
  }
  test('真实 QuickJS 多文件 ESM、CJS、JSON、重新导出、动态导入与 Spider 协议', () async {
    final manager = LumeSources.manager(Section.video);
    final script = SourcePackage.fromBytes(
      sourceZip({
        'lume.json': jsonEncode({
          'entry': 'main.mjs',
          'protocol': 'spider',
          'metadata': {
            'id': 'bundle-spider',
            'name': '多文件 Spider',
            'category': 'video',
          },
        }),
        'main.mjs': '''
import prefix, {suffix as end} from './helper.mjs';
import * as ns from './classes.cjs';
export {homeContent} from './home.mjs';
export async function searchContent(key,quick,page) { const json=await import('./item.json');return {list:[{vod_id:'1',vod_name:prefix+key+end+json.title}]}; }
export function detailContent(ids) {return {list:[{vod_id:ids[0],vod_name:'详情',vod_play_from:'一',vod_play_url:'播放\$token'}]};}
export function playerContent(flag,id) {return {url:ns.url(id)};}
''',
        'helper.mjs':
            "export {default} from './prefix.cjs'; export const suffix='!';",
        'prefix.cjs': "module.exports = '前';",
        'classes.cjs': "const settings=require('./settings.json');exports.url=id=>settings.base+id+'.mp4';",
        'home.mjs': "export function homeContent() {return {class:[{type_id:'1',type_name:'电影'}]};}",
        'settings.json': '{"base":"https://fixture.invalid/"}',
        'item.json': '{"title":"后"}',
      }),
      name: 'bundle.zip',
    );
    final result = await manager.importScript(script);
    expect(result.isSuccess, isTrue, reason: result.message);
    final source = (await manager.open(result.descriptor!.id))!;
    expect((await source.categories()).single.title, '电影');
    expect((await source.list(keyword: '搜索')).items.single.title, '前搜索!后');
    final id = (await source.chapters('spider:1')).single.id;
    final content = (await source.content(
      itemId: 'spider:1',
      chapterId: id,
    )) as VideoContent;
    expect(content.url.toString(), 'https://fixture.invalid/token.mp4');
    SourceRegistry.close(Section.video);
    expect((await manager.open(result.descriptor!.id))!.name, '多文件 Spider');
  }, skip: available ? null : 'QuickJS 原生桥不可用');
}
