import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/core/music/music_models.dart';
import 'package:lume_box/core/music/music_runtime.dart';
import 'package:lume_box/core/music/music_library.dart';
import 'package:lume_box/core/music/music_service.dart';

import 'js_sandbox/support/js_sandbox_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final available = installBridge();
  final runtimes = <MusicRuntime>[];
  late Directory directory;
  setUp(() async {
    enableEngineOnThisPlatform();
    directory = await Directory.systemTemp.createTemp('lume-music-runtime-');
    await installTempSectionRoot(directory);
  });
  tearDown(() {
    for (final runtime in runtimes) {
      runtime.dispose();
    }
    runtimes.clear();
    restoreEnginePlatformGate();
    directory.deleteSync(recursive: true);
  });
  Future<MusicRuntime> open(String script, MusicProtocol protocol) async {
    final runtime = await QuickJsMusicRuntime.create(
      'test${runtimes.length}',
      script,
      protocol,
    );
    runtimes.add(runtime);
    return runtime;
  }

  test('MusicFree axios and LX request use the host HTTP transport', () async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    final subscription = server.listen((request) async {
      seen.add(request.uri.toString());
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'url': 'https://example.com/song.mp3',
          'headers': {
            'Default': request.headers.value('X-Default'),
            'Override': request.headers.value('X-Override'),
            'Body': body,
          },
        }),
      );
      await request.response.close();
    });
    try {
      final base = 'http://127.0.0.1:${server.port}';
      final mf = await open('''
const api=require('axios').create({baseURL:'$base',headers:{'X-Default':'yes'}});
module.exports={platform:'HTTP fixture',getMediaSource:async()=>
 (await api.get('/mf',{params:{q:'song title'},headers:{'X-Override':'also'}})).data};
''', MusicProtocol.musicFree);
      final media = await mf.call('media') as Map;
      expect(media['headers']['Default'], 'yes');
      expect(media['headers']['Override'], 'also');
      final lx = await open('''
lx.on(lx.EVENT_NAMES.request,()=>new Promise((resolve,reject)=>lx.request('$base/lx',
 {method:'POST',form:{q:'song title'}},(error,response)=>error?reject(error):resolve(response.body))));
lx.send(lx.EVENT_NAMES.inited,{sources:{kw:{actions:['musicUrl'],qualitys:['128k']}}});
''', MusicProtocol.lx);
      final resolved = await lx.call('media', {
        'platform': 'kw',
        'quality': '128k',
        'track': {'songmid': '1'},
      }) as Map;
      expect(resolved['headers']['Body'], 'q=song%20title');
      expect(seen, ['/mf?q=song%20title', '/lx']);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      HttpOverrides.global = saved;
    }
  }, skip: !available);
  test(
    'import detects LX even when the script hides its global access',
    () async {
      final library = MusicLibrary(directory: directory);
      final service = MusicService(library: library);
      try {
        final plugin = await service.importScript('''
/** @name Hidden fixture */
const api=globalThis[['l','x'].join('')];
api.on(api.EVENT_NAMES.request,async()=> 'https://example.com/song.mp3');
api.send(api.EVENT_NAMES.inited,{sources:{kw:{actions:['musicUrl'],qualitys:['128k']}}});
''');
        expect(plugin.protocol, MusicProtocol.lx);
        expect(await library.script(plugin.id), contains("[['l','x']"));
      } finally {
        service.dispose();
        library.dispose();
      }
    },
    skip: !available,
  );

  test('MusicFree CommonJS dependencies, user variables, search, headers and lyrics run in QuickJS', () async {
    final runtime = await open(r'''
const CryptoJS=require('crypto-js');
const cheerio=require('cheerio');
const bigInt=require('big-integer');
const axios=require('axios');
module.exports={platform:'Fixture',version:'1.2.3',userVariables:[{key:'token',name:'Token'}],
 search:async(q,page,type)=>({data:[{id:bigInt('99').add(1).toString(),title:cheerio.load('<b>'+q+'</b>')('b').text(),artist:type}],isEnd:page>1}),
 getMediaSource:async(track,quality)=>({url:'https://example.com/'+track.id+'.mp3',headers:{Token:env.getUserVariables().token,Hash:CryptoJS.MD5('abc').toString(),Quality:quality}}),
 getLyric:async()=>({rawLrc:'[00:01.00]Hello'})};
''', MusicProtocol.musicFree);
    expect((await runtime.describe())['name'], 'Fixture');
    final search =
        await runtime.call('search', {'query': 'Song', 'page': 2}) as Map;
    expect(search['isEnd'], true);
    expect(search['data'], [
      {'id': '100', 'title': 'Song', 'artist': 'music'},
    ]);
    final media = await runtime.call('media', {
      'track': {'id': '100'},
      'quality': 'high',
      'variables': {'token': 'secret'},
    }) as Map;
    expect(media['headers'], {
      'Token': 'secret',
      'Hash': '900150983cd24fb0d6963f7d28e17f72',
      'Quality': 'high',
    });
    expect((await runtime.call('lyric')) as Map, {'rawLrc': '[00:01.00]Hello'});
  }, skip: !available);
  test('LX asynchronous initialization, request contract, crypto and compressed buffer helpers', () async {
    final runtime = await open(r'''
/** @name LX fixture
 * @version 2.3.4
 */
const {on,send,EVENT_NAMES,utils}=lx;
on(EVENT_NAMES.request, async({source,action,info})=>{
 if(action==='lyric')return {lyric:'[00:01]LX'};
 const b=utils.buffer.from('abc');
 const zip=await utils.zlib.deflate(b);
 const restored=await utils.zlib.inflate(zip);
 if(utils.buffer.bufToString(restored)!=='abc')throw Error('roundtrip');
 const encrypted=utils.crypto.aesEncrypt(b,'aes-128-cbc',utils.buffer.from('1234567890123456'),utils.buffer.from('1234567890123456'));
 return 'https://example.com/'+source+'/'+info.musicInfo.songmid+'/'+info.type+'/'+encrypted.toString('hex')+'.mp3';
});
Promise.resolve().then(()=>send(EVENT_NAMES.inited,{sources:{kw:{type:'music',actions:['musicUrl'],qualitys:['128k','320k']}}}));
''', MusicProtocol.lx);
    final info = await runtime.describe();
    expect(info['name'], 'LX fixture');
    expect(info['platforms'], {
      'kw': ['128k', '320k'],
    });
    expect(
      await runtime.call('media', {
        'platform': 'kw',
        'quality': '320k',
        'track': {'songmid': '42'},
      }),
      startsWith('https://example.com/kw/42/320k/'),
    );
    await expectLater(
      runtime.call('search', {'query': 'x'}),
      throwsA(anything),
    );
  }, skip: !available);
  test(
    'invalid MusicFree exports and unknown modules are rejected on import',
    () async {
      await expectLater(
        open('module.exports={platform:"bad"}', MusicProtocol.musicFree),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        open('require("child_process");', MusicProtocol.musicFree),
        throwsA(isA<FormatException>()),
      );
    },
    skip: !available,
  );
}
