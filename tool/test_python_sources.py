"""Offline tests for the production embedded Spider host.

Optional positional .py paths validate user files without copying them into Git.
All HTTP replies are local fixtures; this test never calls source websites.
"""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".cache/python-source-runtime/packages"))
sys.path.insert(0, str(ROOT / "assets/python"))
USER_SCRIPTS = []
CALLS = []
STORAGE = {}


def invoke(raw):
    request = json.loads(raw)
    payload = request["payload"]
    CALLS.append(request)
    if request["method"] == "tools":
        import zlib
        assert payload["operation"] == "inflate"
        value = base64.b64encode(zlib.decompress(base64.b64decode(payload["data"]))).decode()
        return json.dumps({"ok":True,"value":value})
    if request["method"] == "web.render":
        return json.dumps({"ok": True, "value": {"html": "<article>动态结果</article>", "media": [{"url": "https://fixture.invalid/video.mp4", "headers": {"Referer": payload["url"]}}]}})
    if request["method"] == "html.extract":
        assert payload["fields"]["title"]["selector"] == "a"
        return json.dumps({"ok": True, "value": [{"title": "动态结果", "id": "web1"}]})
    if request["method"] == "storage":
        key = (request["sourceId"], payload["key"])
        if payload["operation"] == "get": value = STORAGE.get(key, payload.get("defaultValue"))
        elif payload["operation"] == "set": STORAGE[key] = payload["value"]; value = True
        else: STORAGE.pop(key, None); value = True
        return json.dumps({"ok": True, "value": value})
    if request["method"] == "crypto":
        # Forwarding is tested here; real algorithms use independent Dart KATs.
        return json.dumps({"ok": False, "error": "crypto fixture intentionally unavailable"})
    if request["method"] == "proxy":
        return json.dumps({"ok": True, "value": "http://127.0.0.1:12345/token/proxy?do=py"})
    url = payload["url"]
    headers, status = {"Content-Type": "application/json; charset=utf-8"}, 200
    video = {"vod_id": "v1", "vod_name": "测试影片", "vod_pic": "https://fixture.invalid/cover.jpg", "vod_remarks": "更新中"}
    if "searchByWord" in url:
        body = {"data": {"result": {"list": [{"vodId": "v1", "vodName": "测试影片", "vodPic": "", "typeId1": 1, "vodVersion": "高清"}]}}}
    elif "/anonymous/video/detail" in url:
        body = {"data": {"typeName": "电影", "vodName": "测试影片", "vodRemarks": "高清", "vodYear": "2026", "vodArea": "", "vodActor": "", "vodDirector": "", "vodContent": "说明", "episodeList": [{"name": "第一集", "nid": "ep1"}]}}
    elif "/episode/url" in url:
        body = {"data": {"list": [{"url": "https://fixture.invalid/video.mp4"}]}}
    elif "/app/nav" in url:
        body = {"list": [{"type_id": "1", "type_name": "电影", "type_extend": {"year": "2026,2025"}}]}
    elif "/app/search" in url or "/app/video?" in url:
        body = {"list": [video], "page": 1, "pagecount": 2}
    elif "/app/video_detail" in url:
        body = {"data": {**video, "vod_url_with_player": [{"name": "线路一", "url": "第一集$https://fixture.invalid/video.mp4"}]}}
    elif url.endswith("/api/me"):
        body = {"auth_token": "fixture-public-token"}
    elif "/cookie" in url:
        body = {"ok": True}
        headers["Set-Cookie"] = "fixture=session; Path=/"
    else:
        body = "<html><head><title>测试</title></head><body></body></html>"
        headers["Content-Type"] = "text/html; charset=utf-8"
    if "/redirect" in url:
        status, headers = 302, {"Location": "https://fixture.invalid/cookie"}
        body = ""
    encoded = (json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body).encode()
    return json.dumps({"ok": True, "value": {"status": status, "headers": headers, "body": base64.b64encode(encoded).decode()}})


native = types.ModuleType("_lume_host")
native.invoke = invoke
sys.modules["_lume_host"] = native
if "lume_python" in sys.modules:
    host = sys.modules["lume_python"]
    host._lume_host = native
else:
    spec = importlib.util.spec_from_file_location("lume_python", ROOT / "assets/python/lume_python.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)

FIXTURE = '''
from base.spider import Spider
class Spider(Spider):
    def init(self, extend): self.initialized = extend
    def homeContent(self, filter): return {'class':[{'type_id':'1','type_name':'电影'}], 'filters':{}}
    def homeVideoContent(self): return {'list':[{'vod_id':'one','vod_name':'首页'}]}
    def categoryContent(self, tid, pg, filter, extend): return {'list':[{'vod_id':'one','vod_name':tid}], 'page':int(pg), 'pagecount':2}
    def searchContent(self, key, quick, pg='1'): return {'list':[{'vod_id':'one','vod_name':key + pg}]}
    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_name':'详情','vod_play_from':'线路一$$$线路二','vod_play_url':'第一集$token1#第二集$token2$$$备用$token3'}]}
    def playerContent(self, flag, id, vipFlags): return {'parse':0,'url':'https://fixture.invalid/' + id + '.mp4','header':'{"Referer":"https://fixture.invalid/"}'}
'''


def call(source, action="call", **kwargs):
    result = json.loads(host.run(json.dumps({"sourceId": source, "action": action, "timeout": 2, **kwargs})))
    return result


class HostTests(unittest.TestCase):
    def test_spider_can_call_parent_init(self):
        source = FIXTURE.replace('def init(self, extend): self.initialized = extend', 'def init(self, extend):\n        super().init(extend)\n        self.initialized = extend')
        self.assertTrue(call('parent-init', 'load', script=source)['ok'])
        result = call('parent-init', method='categories')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['value'][0]['title'], '电影')

    def test_declared_audio_in_comic_section_uses_player_and_returns_audio(self):
        source = '# LumeSource: {"id":"audio-test","name":"听书","version":"1","category":"comic","mediaType":"audio"}\n' + FIXTURE + "\n    def imageContent(self, id): raise ValueError('不应请求图片接口')\n    def playerContent(self, flag, id, vipFlags=None): return {'url':'https://media.test/book.mp3','header':{'Referer':'https://media.test/'}}"
        for encoded in (False, True):
            script = '# LumePythonBytes: ' + base64.b64encode(source.encode()).decode() if encoded else source
            source_id = 'audio-declared-' + str(encoded)
            self.assertTrue(call(source_id, 'load', script=script, section='comic')['ok'])
            result = call(source_id, method='content', argument={'id':'book','chapterId':json.dumps({'id':'chapter'})})
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['value']['kind'], 'audio')
            self.assertEqual(result['value']['url'], 'https://media.test/book.mp3')
            self.assertEqual(result['value']['headers']['Referer'], 'https://media.test/')

    def test_declared_audio_preserves_explicit_video_content(self):
        source = '# LumeSource: {"id":"audio-mixed","name":"混合","version":"1","category":"comic","mediaType":"audio"}\n' + FIXTURE + "\n    def playerContent(self, flag, id, vipFlags=None): return {'kind':'video','url':'https://media.test/video.mp4'}"
        self.assertTrue(call('audio-mixed', 'load', script=source, section='comic')['ok'])
        result = call('audio-mixed', method='content', argument={'id':'book','chapterId':json.dumps({'id':'chapter'})})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['value']['kind'], 'video')

    def test_comic_spider_uses_declared_text_method_instead_of_image_method(self):
        source = FIXTURE + "\n    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_name':'书','mediaType':'novel'}]}\n    def imageContent(self, id): raise ValueError('不应请求图片接口')\n    def playerContent(self, flag, id, vipFlags=None): return {'kind':'text','text':'实际正文'}"
        self.assertTrue(call('comic-with-novel', 'load', script=source, section='comic')['ok'])
        self.assertTrue(call('comic-with-novel', method='detail', argument={'id':'book'})['ok'])
        result = call('comic-with-novel', method='content', argument={'id':'book','chapterId':json.dumps({'id':'chapter'})})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['value']['kind'], 'text')

    def test_explicit_video_inside_comic_source_is_not_coerced_to_images(self):
        source = FIXTURE + "\n    def playerContent(self, flag, id, vipFlags=None): return {'kind':'video','url':'https://media.test/episode.mp4'}"
        self.assertTrue(call('comic-with-video', 'load', script=source, section='comic')['ok'])
        result = call('comic-with-video', method='content', argument={'id':'item','chapterId':json.dumps({'id':'episode'})})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['value']['kind'], 'video')

    def test_comprehensive_spider_preserves_text_images_and_video(self):
        source = FIXTURE + "\n    def playerContent(self, flag, id, vipFlags=None):\n        if id == 'novel': return {'kind':'text','text':'第一段\\n\\n第二段'}\n        if id == 'comic': return {'kind':'images','images':['https://img.test/page.jpg']}\n        return {'url':'https://media.test/episode.mp4'}"
        self.assertTrue(call('mixed', 'load', script=source)['ok'])
        for item, kind in [('novel','text'), ('comic','images'), ('video','video')]:
            result = call('mixed', method='content', argument={'id':item, 'chapterId':json.dumps({'id':item})})
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['value']['kind'], kind)
        self.assertEqual(call('mixed', method='content', argument={'id':'novel', 'chapterId':json.dumps({'id':'novel'})})['value']['text'], '第一段\n\n第二段')

    def test_tvbox_extend_survives_config_and_encoded_python_bytes(self):
        program = '''# coding: gbk
from base.spider import Spider
class Spider(Spider):
    def init(self, extend): self.ext = extend
    def homeContent(self, filter): return {'class':[{'type_id':'1','type_name':self.ext['label'] + '中文'}]}
    def detailContent(self, ids): return {'list':[]}
    def playerContent(self, flag, id, vipFlags): return {'parse':0,'url':'https://fixture.invalid/a.mp4'}
'''
        encoded = base64.b64encode(program.encode('gbk')).decode()
        script = '# LumeTVBoxExtend: {"label":"扩展"}\n# LumePythonBytes: ' + encoded
        self.assertTrue(call('tvbox-extend', 'load', script=script)['ok'])
        self.assertTrue(call('tvbox-extend', 'config', config={'domain':'https://fixture.invalid'})['ok'])
        categories = call('tvbox-extend', method='categories')
        self.assertTrue(categories['ok'], categories)
        self.assertEqual(categories['value'][0]['title'], '扩展中文')
    def test_ecc_deterministic_fallback_matches_rfc6979_vectors(self):
        from unittest.mock import patch
        from Crypto.PublicKey import ECC
        from Crypto.Signature import DSS
        from Crypto.Hash import SHA256, SHA512
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from cryptography.exceptions import UnsupportedAlgorithm
        from lume_ecc import _Dss
        real = _Dss._algorithm

        def legacy(self, digest, deterministic=False):
            if deterministic:
                raise UnsupportedAlgorithm('Fixture: bundled legacy OpenSSL')
            return real(self, digest, deterministic=False)

        vectors = json.loads(Path(__file__).with_name('ecc_rfc6979_vectors.json').read_text())['vectors']
        with patch.object(_Dss, '_algorithm', legacy):
            for vector in vectors:
                with self.subTest(curve=vector['curve'], hash=vector['hash']):
                    key = ECC.construct(curve=vector['curve'], d=int(vector['key'], 16))
                    digest = {'sha256':SHA256, 'sha512':SHA512}[vector['hash']].new(vector['message'].encode())
                    signature = DSS.new(key, 'deterministic-rfc6979', encoding='der').sign(digest)
                    r, s = utils.decode_dss_signature(signature)
                    self.assertEqual((r,s), (int(vector['r'],16),int(vector['s'],16)))
                    DSS.new(key.public_key(), 'deterministic-rfc6979', encoding='der').verify(digest,signature)

    def test_comic_python_returns_ordered_images_and_per_image_headers(self):
        source = '''
class Spider:
    def homeVideoContent(self): return {'list':[{'vod_id':'book','vod_name':'测试漫画'}]}
    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_name':'测试漫画','vod_play_url':'第1话$https://comic.test/read/1'}]}
    def imageContent(self, chapter_id):
        return {'images':['/pages/1.jpg', {'url':'https://img.test/2.jpg','headers':{'X-Page':'2'}}],
                'headers':{'Referer':chapter_id}, 'imageHeaders':{'/pages/1.jpg':{'X-Page':'1'}}}
'''
        loaded = call('comic-images', 'load', script=source, section='comic')
        self.assertTrue(loaded['ok'], loaded)
        item = call('comic-images', method='list')['value']['items'][0]
        chapter = call('comic-images', method='chapters', argument={'id':item['id']})['value'][0]
        result = call('comic-images', method='content', argument={'id':item['id'], 'chapterId':chapter['id']})
        self.assertTrue(result['ok'], result)
        content = result['value']
        self.assertEqual(content['kind'], 'images')
        self.assertEqual(content['images'], ['https://comic.test/pages/1.jpg','https://img.test/2.jpg'])
        self.assertEqual(content['imageHeaders'][content['images'][0]], {'Referer':'https://comic.test/read/1','X-Page':'1'})

    def test_comic_player_compatibility_rejects_video_and_invalid_images(self):
        for value in ("{'url':'https://media.test/movie.mp4'}", "{'images':['javascript:bad']}", "{'images':[]}"):
            source = FIXTURE + '\n    def playerContent(self, flag, id, vipFlags=None): return ' + value
            self.assertTrue(call('comic-invalid', 'load', script=source, section='comic')['ok'])
            result = call('comic-invalid', method='content', argument={'id':'one','chapterId':json.dumps({'id':'https://comic.test/read/1'})})
            self.assertFalse(result['ok'], result)
        source = FIXTURE + "\n    def playerContent(self, flag, id, vipFlags=None): return ['https://img.test/1.jpg']"
        self.assertTrue(call('comic-player', 'load', script=source, section='comic')['ok'])
        result = call('comic-player', method='content', argument={'id':'one','chapterId':json.dumps({'id':'chapter'})})
        self.assertEqual(result['value']['images'], ['https://img.test/1.jpg'])

    def test_source_signature_hook_and_web_player_mode(self):
        source = FIXTURE + '''
    def prepareRequest(self, request):
        assert callable(request['bridge'].request)
        return {'headers': {'x-source-sign':'local-signature'}, 'body':'signed-body'}
    def searchContent(self, key, quick, pg='1'):
        import requests
        requests.post('https://fixture.invalid/search', data='original')
        return {'list':[]}
    def playerContent(self, flag, id, vipFlags):
        return {'webPlayer':True,'pageUrl':'https://fixture.invalid/play','url':'blob:https://fixture.invalid/internal'}
'''
        self.assertTrue(call('signed-web', 'load', script=source)['ok'])
        self.assertTrue(call('signed-web',method='list',argument={'keyword':'test','page':1})['ok'])
        outgoing = next(c for c in reversed(CALLS) if c['method'] == 'http')
        self.assertEqual(outgoing['payload']['headers']['x-source-sign'],'local-signature')
        self.assertEqual(base64.b64decode(outgoing['payload']['body']),b'signed-body')
        content = call('signed-web',method='content',argument={'id':'one','chapterId':json.dumps({'id':'one','flag':'line'})})
        self.assertTrue(content['value']['webPlayer'],content)
        self.assertEqual(content['value']['pageUrl'],'https://fixture.invalid/play')

    def test_empty_home_uses_real_categories_and_default_filters(self):
        source = FIXTURE + '''
    def homeVideoContent(self): return {'list':None}
    def homeContent(self, filter):
        return {'class':[{'type_id':'empty','type_name':'空分类'}, {'type_id':'movie','type_name':'电影'}],
                'filters':{'movie':[{'key':'order','value':[{'v':'new','n':'最新'}]}]}}
    def categoryContent(self, tid, pg, filter, extend):
        assert int(pg) == 1
        if tid == 'empty': return {'list':[]}
        assert extend == {'order':'new'}
        return {'list':[{'vod_id':'real','vod_name':'真实分类内容'}]}
'''
        self.assertTrue(call('fallback', 'load', script=source)['ok'])
        result = call('fallback', method='home')['value']
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['title'], '电影')
        self.assertEqual(result[0]['moreUrl'], 'movie')
        self.assertEqual(result[0]['items'][0]['id'], 'py:real')

    def test_home_capability_without_recommendation_method(self):
        source = FIXTURE.replace("    def homeVideoContent(self): return {'list':[{'vod_id':'one','vod_name':'首页'}]}\n", '')
        loaded = call('category-only', 'load', script=source)
        self.assertIn('home', loaded['value']['methods'])
        home = call('category-only', method='home')['value']
        self.assertEqual(home[0]['moreUrl'], '1')
        self.assertEqual(home[0]['items'][0]['title'], '1')

    def test_failed_category_does_not_hide_other_categories_or_real_errors(self):
        source = FIXTURE + '''
    def homeVideoContent(self): return {}
    def homeContent(self, filter):
        return {'class':[{'type_id':str(i),'type_name':str(i)} for i in range(6)]}
    def categoryContent(self, tid, pg, filter, extend):
        if tid == '0': raise ValueError('分类不可用')
        if int(tid) > 2: raise AssertionError('首页最多请求三个分类')
        return {'list':[{'vod_id':tid,'vod_name':tid}]}
'''
        self.assertTrue(call('partial', 'load', script=source)['ok'])
        result = call('partial', method='home')['value']
        self.assertEqual([row['moreUrl'] for row in result], ['1'])
        source += "\n    def categoryContent(self, tid, pg, filter, extend): raise ValueError('站点连接失败')\n"
        self.assertTrue(call('broken', 'load', script=source)['ok'])
        result = call('broken', method='home')
        self.assertFalse(result['ok'])
        self.assertIn('站点连接失败', result['error']['message'])

    def test_startup_reuses_metadata_and_first_usable_category_returns_immediately(self):
        source = FIXTURE + """
    reads = 0
    pages = []
    def homeVideoContent(self): return {}
    def homeContent(self, filter):
        if filter: self.reads += 1
        return {'class':[{'type_id':'1','type_name':'电影'},{'type_id':'2','type_name':'慢分类'}], 'filters':{}}
    def categoryContent(self, tid, pg, filter, extend):
        self.pages.append(tid)
        if tid == '2': raise AssertionError('可用首页不应等待其他分类')
        return {'list':[{'vod_id':'one','vod_name':'电影'}]}
"""
        self.assertTrue(call('fast', 'load', script=source)['ok'])
        self.assertTrue(call('fast', method='categories')['ok'])
        self.assertTrue(call('fast', method='filters', argument={'categoryId':'1'})['ok'])
        self.assertTrue(call('fast', method='home')['value'])
        spider = host._contexts['fast']['spider']
        self.assertEqual(spider.reads, 1)
        self.assertEqual(spider.pages, ['1'])
        call('fast', 'config', config={'account':'new'})
        call('fast', method='categories')
        self.assertEqual(spider.reads, 2)
        host._contexts['fast']['home_metadata'] = (-1000, '{}')
        call('fast', method='categories')
        self.assertEqual(spider.reads, 3)
        call('other', 'load', script=source)
        call('other', method='categories')
        self.assertEqual(host._contexts['other']['spider'].reads, 1)
        self.assertEqual(spider.reads, 3)

    def test_metadata_failure_is_not_cached_and_false_mode_recommendations_still_work(self):
        source = FIXTURE + """
    reads = 0
    def homeVideoContent(self): return {}
    def homeContent(self, filter):
        if not filter: return {'list':[{'vod_id':'false','vod_name':'推荐'}]}
        self.reads += 1
        raise ValueError('分类暂时不可用')
"""
        call('modes', 'load', script=source)
        self.assertEqual(call('modes', method='home')['value'][0]['id'], 'py:false')
        self.assertFalse(call('modes', method='categories')['ok'])
        self.assertEqual(host._contexts['modes']['spider'].reads, 2)

    def setUp(self):
        CALLS.clear()
        for state in host._contexts.values():
            host._close_source(state)
        host._contexts.clear()
        self.assertTrue(call("fixture", "load", script=FIXTURE)["ok"])

    def test_custom_local_server_dependency_warns_without_running_a_server(self):
        source = 'from http.server import ThreadingHTTPServer\n' + FIXTURE
        result = call('local-server-note', 'load', script=source)
        self.assertTrue(result['ok'], result)
        self.assertTrue(any('自建本地 HTTP 服务' in w for w in result['value']['warnings']))

    def test_script_network_timeouts_are_forwarded_and_never_extend_call_budget(self):
        source = FIXTURE + """
    def homeVideoContent(self):
        import requests, urllib.request, http.client
        requests.get('https://fixture.invalid/short', timeout=2)
        requests.get('https://fixture.invalid/pair', timeout=(1, 3))
        urllib.request.urlopen('https://fixture.invalid/urllib', timeout=3).read()
        conn = http.client.HTTPSConnection('fixture.invalid', timeout=4)
        conn.request('GET', '/client')
        conn.getresponse().read()
        requests.get('https://fixture.invalid/long', timeout=500)
        return {'list':[{'vod_id':'one','vod_name':'bounded'}]}
"""
        self.assertTrue(call('network-timeout', 'load', script=source)['ok'])
        result = call('network-timeout', method='home', timeout=30)
        self.assertTrue(result['ok'], result)
        requests = [r for r in CALLS if r['method'] == 'http']
        self.assertEqual([round(r['timeout']) for r in requests[:4]], [2, 4, 3, 4])
        self.assertLessEqual(requests[-1]['timeout'], 30)
        self.assertGreater(requests[-1]['timeout'], 0)

    def test_shared_tools_import_and_host_decompression(self):
        source = FIXTURE + """
    def homeVideoContent(self):
        import lume_tools, zlib
        assert lume_tools.base64_decode(lume_tools.base64_encode('中文')) == '中文'
        assert lume_tools.url_decode(lume_tools.url_encode('中文 +/?')) == '中文 +/?'
        decoded = lume_tools.inflate(zlib.compress(b'host inflate')).decode()
        return {'list':[{'vod_id':lume_tools.digest('sha256','abc'),'vod_name':decoded}]}
"""
        self.assertTrue(call('tools','load',script=source)['ok'])
        result=call('tools',method='home')['value'][0]
        self.assertEqual(result['title'],'host inflate')
        self.assertEqual(result['id'],'py:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')

    def test_mobile_browser_html_and_storage_helpers(self):
        source = FIXTURE + """
    def homeVideoContent(self):
        page = self.renderPage('https://fixture.invalid/', waitForSelector='.card', steps=[{'type':'click','selector':'#go'}])
        rows = self.extractHtml(page['html'], {'title':{'selector':'a'}}, '.card', 'https://fixture.invalid/')
        self.setItem('saved', {'title':rows[0]['title']})
        assert self.getItem('saved')['title'] == rows[0]['title']
        return {'list':[{'vod_id':rows[0]['id'], 'vod_name':rows[0]['title']}]}
    def playerContent(self, flag, id, vipFlags):
        media = self.renderPage('https://fixture.invalid/watch')['media'][0]
        return {'parse':0, 'url':media['url'], 'header':media['headers']}
"""
        self.assertTrue(call('fixture', 'load', script=source)['ok'])
        item = self.value('home')[0]
        self.assertEqual(item['title'], '动态结果')
        chapters = self.value('chapters', {'id':item['id']})
        content = self.value('content', {'id':item['id'], 'chapterId':chapters[0]['id']})
        self.assertEqual(content['url'], 'https://fixture.invalid/video.mp4')
        self.assertEqual(content['headers']['Referer'], 'https://fixture.invalid/watch')
        render = next(request for request in CALLS if request['method'] == 'web.render')
        self.assertEqual(render['payload']['steps'][0]['selector'], '#go')

    def test_bundle_relative_and_delayed_import_isolation_and_cleanup(self):
        def bundle(title):
            files = {'pkg/main.py': FIXTURE + '\nfrom dataclasses import dataclass\n@dataclass\nclass Entry: title: str\nfrom . import helper\nSpider.homeContent = lambda self, filter: {"class":[{"type_id":"1","type_name":Entry(helper.title()).title}]}',
                     'pkg/__init__.py': '', 'pkg/helper.py': 'def title():\n from .value import TITLE\n return TITLE',
                     'pkg/value.py': 'TITLE = ' + repr(title)}
            data = {'entry': 'pkg/main.py', 'runtime': 'python', 'files': {name: base64.b64encode(value.encode()).decode() for name, value in files.items()}}
            return '# LumeRuntime: python\n# LumeBundle: ' + base64.b64encode(json.dumps(data).encode()).decode()
        for source in ('one','two'):
            result = call(source, 'load', script=bundle(source))
            self.assertTrue(result['ok'], result)
        for source in ('one','two','one'):
            result = call(source, method='categories')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['value'][0]['title'], source)
        self.assertNotIn('pkg.helper', sys.modules)
        root = Path(host._contexts['one']['root'])
        self.assertTrue(root.exists())
        call('one','dispose')
        self.assertFalse(root.exists())

    def test_local_proxy_text_binary_base64_and_range_headers(self):
        script = FIXTURE + '''
def local(self, params):
    kind = params.get('kind')
    if kind == 'binary': return [206, 'video/mp2t', bytes([0,255,1]), {'Content-Range':'bytes 0-2/3'}]
    if kind == 'encoded': return [200, 'video/mp2t', 'AP8B', {}, 1]
    return [200, 'application/vnd.apple.mpegurl', '#EXTM3U\\n' + params['headers']['range']]
Spider.localProxy = local
Spider.playerContent = lambda *args: {'url': args[0].getProxyUrl() + '&kind=binary'}
'''
        result=call('proxy','load',script=script)
        self.assertTrue(result['ok'],result)
        content=call('proxy',method='content',argument={'chapterId':json.dumps({'id':'a'})})
        self.assertTrue(content['ok'],content)
        self.assertIn('?do=py&kind=binary',content['value']['url'])
        for kind in ['binary','encoded']:
            reply=call('proxy','proxy',params={'kind':kind})
            self.assertTrue(reply['ok'],reply)
            self.assertEqual(base64.b64decode(reply['value']['body']),bytes([0,255,1]))
        reply=call('proxy','proxy',params={},headers={'range':'bytes=0-'})
        self.assertEqual(base64.b64decode(reply['value']['body']),b'#EXTM3U\nbytes=0-')

    def value(self, method, arg=None):
        result = call("fixture", method=method, argument=arg)
        self.assertTrue(result["ok"], result)
        return result["value"]

    def test_spider_end_to_end_and_line_identity(self):
        self.assertEqual(self.value("categories")[0]["title"], "电影")
        self.assertEqual(self.value("home")[0]["title"], "首页")
        self.assertEqual(self.value("list", {"keyword": "电影", "page": 2})["items"][0]["title"], "电影2")
        self.assertTrue(self.value("list", {"keyword": "电影"})["hasMore"])
        self.assertEqual(self.value("detail", {"id": "one"})["title"], "详情")
        chapters = self.value("chapters", {"id": "one"})
        self.assertEqual(len(chapters), 3)
        self.assertNotEqual(chapters[0]["id"], chapters[2]["id"])
        content = self.value("content", {"id": "one", "chapterId": chapters[0]["id"]})
        self.assertEqual(content["url"], "https://fixture.invalid/token1.mp4")
        self.assertIn("Referer", content["headers"])

    def test_two_argument_search_does_not_fabricate_more_pages(self):
        source = FIXTURE.replace("def searchContent(self, key, quick, pg='1')", "def searchContent(self, key, quick)").replace("key + pg", "key")
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("list", {"keyword": "电影", "page": 2})["items"], [])

    def test_requests_cookies_redirects_and_urllib(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        import requests, urllib.request, http.client
        session = requests.Session()
        response = session.get('https://fixture.invalid/redirect')
        assert session.cookies.get('fixture') == 'session'
        assert response.status_code == 200
        urllib.request.urlopen('https://fixture.invalid/page').read()
        conn = http.client.HTTPSConnection('fixture.invalid')
        conn.request('GET', '/direct')
        assert conn.getresponse().status == 200
        return {'list':[{'vod_id':'ok','vod_name':'网络通过'}]}
'''
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("home")[0]["title"], "网络通过")
        self.assertEqual(len(CALLS), 4)

    def test_source_remounting_connection_pool_still_uses_app_network(self):
        source = FIXTURE + '''
    def init(self, extend):
        import requests
        from requests.adapters import HTTPAdapter
        from urllib3.util.retry import Retry
        self.session = requests.Session()
        for scheme in ('http://', 'https://'):
            self.session.mount(scheme, HTTPAdapter(pool_connections=10, pool_maxsize=20, max_retries=Retry(total=1)))
    def homeVideoContent(self):
        import requests
        from requests.adapters import HTTPAdapter
        first = self.session.get('https://fixture.invalid/cookie').json()
        with requests.Session() as session:
            session.mount('https://fixture.invalid/', HTTPAdapter())
            second = session.get('https://fixture.invalid/cookie').json()
        assert first['ok'] and second['ok']
        return {'list':[{'vod_id':'bridge','vod_name':'连接池兼容'}]}
'''
        from unittest.mock import patch
        with patch('requests.adapters.HTTPAdapter.send', side_effect=AssertionError('不应绕过 App 网络桥')) as direct_send:
            self.assertTrue(call('remounted', 'load', script=source)['ok'])
            result = call('remounted', method='home')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['value'][0]['title'], '连接池兼容')
        direct_send.assert_not_called()
        self.assertEqual(len(CALLS), 2)
        self.assertTrue(all(request['sourceId'] == 'remounted' for request in CALLS))

    def test_namespace_cache_dispose_and_missing_dependency(self):
        self.assertTrue(call("second", "load", script=FIXTURE)["ok"])
        host._contexts["fixture"]["cache"]["key"] = "secret"
        self.assertEqual(host._contexts["second"]["cache"], {})
        self.assertTrue(call("fixture", "dispose")["ok"])
        self.assertFalse(call("fixture", method="categories")["ok"])
        bad = call("bad", "load", script="import a_missing_spider_dependency\n" + FIXTURE)
        self.assertIn("a_missing_spider_dependency", bad["error"]["message"])

    def test_background_range_server_survives_call_deadline_and_closes_on_dispose(self):
        import socket
        source = FIXTURE + r"""
    def homeVideoContent(self):
        import threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                import requests
                assert requests.get('https://fixture.invalid/cookie').json()['ok']
                body = b'fixture-media'
                self.send_response(206)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Range', 'bytes 0-12/13')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return {'list':[{'vod_id':str(self.server.server_port), 'vod_name':'本地流'}]}
"""
        self.assertTrue(call('background-range', 'load', script=source)['ok'])
        result = call('background-range', method='home')
        self.assertTrue(result['ok'], result)
        port = int(result['value'][0]['id'].removeprefix('py:'))
        # The originating player/home call has ended and its budget has expired.
        host._contexts['background-range']['deadline'] = 0
        self.assertTrue(call('other-foreground', 'load', script=FIXTURE)['ok'])
        self.assertTrue(call('other-foreground', method='categories')['ok'])
        CALLS.clear()
        with socket.create_connection(('127.0.0.1', port), timeout=3) as connection:
            connection.sendall(b'GET /media HTTP/1.0\r\nHost: localhost\r\nRange: bytes=0-12\r\n\r\n')
            parts = []
            while True:
                part = connection.recv(4096)
                if not part: break
                parts.append(part)
        response = b''.join(parts)
        self.assertIn(b'206', response.split(b'\r\n', 1)[0])
        self.assertIn(b'Content-Range: bytes 0-12/13', response)
        self.assertTrue(response.endswith(b'fixture-media'))
        self.assertEqual(CALLS[-1]['sourceId'], 'background-range')
        self.assertGreater(CALLS[-1]['timeout'], 0)
        self.assertLessEqual(CALLS[-1]['timeout'], 30)
        self.assertTrue(call('background-range', 'dispose')['ok'])
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', port), timeout=1)

    def test_threadpool_retains_source_identity(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as executor:
            replies = list(executor.map(lambda _: self.fetch('https://fixture.invalid/cookie').json(), range(2)))
        assert all(reply['ok'] for reply in replies)
        return {'list':[{'vod_id':'thread','vod_name':'线程通过'}]}
'''
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("home")[0]["title"], "线程通过")
        self.assertTrue(all(request["sourceId"] == "fixture" for request in CALLS))

    def test_aliases_alternate_signatures_and_function_modules(self):
        source = '''
def initialize(): pass
def getHomeContent(): return {'class':[{'type_id':'1','type_name':'电影'}]}
def getCategoryContent(tid, pg=1, extend=None):
    assert isinstance(pg, int)
    return {'list':[{'vod_id':'id','vod_name':extend['year']}], 'page':pg, 'pagecount':3}
def search(key, page=1):
    assert isinstance(page, int)
    return {'list':[{'vod_id':'id','vod_name':str(page)}]}
def getDetailContent(ids): return {'list':[{'vod_id':ids[0],'vod_name':'别名'}]}
def getPlayerContent(flag, id): return {'url':'https://fixture.invalid/video.mp4'}
'''
        self.assertTrue(call('fixture', 'load', script=source)['ok'])
        self.assertEqual(self.value('categories')[0]['title'], '电影')
        self.assertEqual(self.value('list', {'keyword':'q','page':2})['items'][0]['title'], '2')
        self.assertEqual(self.value('list', {'categoryId':'1','page':2,'filters':{'year':'2026'}})['items'][0]['title'], '2026')
        self.assertEqual(self.value('detail', {'id':'id'})['title'], '别名')

    def test_xpath_pyquery_httpx_and_async_client(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        import asyncio, httpx
        from lxml import etree, html
        from pyquery import PyQuery as pq
        document = etree.HTML('<div class="cards"><a href="/one">第一集</a><a href="/two">第二集</a></div>')
        assert document.xpath('//div[contains(@class,"cards")]/a/@href') == ['/one', '/two']
        assert document.xpath('count(//a)') == 2
        assert document.xpath('//a')[0].getparent().tag == 'div'
        assert pq('<a href="/one">第一集</a>')('a').attr('href') == '/one'
        assert self.cleanText('<b>文字</b>') == '文字'
        assert httpx.get('https://fixture.invalid/cookie').json()['ok']
        with httpx.Client(headers={'User-Agent':'fixture-custom-UA'}) as client:
            assert client.get('https://fixture.invalid/cookie').json()['ok']
        async def run():
            async with httpx.AsyncClient() as client:
                return (await client.get('https://fixture.invalid/cookie')).json()['ok']
        assert asyncio.run(run())
        return {'list':[{'vod_id':'https://fixture.invalid/album/1','vod_name':'通用兼容'}]}
'''
        result = call('fixture', 'load', script=source)
        self.assertTrue(result['ok'], result)
        item = self.value('home')[0]
        self.assertEqual(item['title'], '通用兼容')
        self.assertEqual(item['id'], 'py:https://fixture.invalid/album/1')
        self.assertTrue(any(request['payload'].get('headers', {}).get('user-agent') == 'fixture-custom-UA' for request in CALLS))

    def test_legacy_encoding_and_dependency_diagnostics(self):
        encoded = base64.b64encode(('# coding: gbk\n' + FIXTURE).encode('gbk')).decode()
        result = call('fixture', 'load', script='# LumePythonBytes: ' + encoded)
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.value('categories')[0]['title'], '电影')
        optional = FIXTURE + '\n    def android_only(self):\n        from java.lang import Runtime\n'
        result = call('fixture', 'load', script=optional)
        self.assertTrue(result['ok'], result)
        self.assertTrue(any('Android' in item for item in result['value']['warnings']))
        from Crypto.Hash import SHA256, HMAC
        self.assertEqual(SHA256.new(b'abc').hexdigest(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        self.assertEqual(len(HMAC.new(b'key', b'message', SHA256).digest()), 32)

    def test_cpu_timeout_and_web_parse(self):
        source = FIXTURE.replace("def homeContent(self, filter): return", "def homeContent(self, filter):\n        while True:\n            pass\n        return")
        self.assertTrue(call("loop", "load", script=source)["ok"])
        result = call("loop", method="categories")
        self.assertEqual(result["error"]["kind"], "timeout")
        source = FIXTURE.replace("'parse':0", "'parse':1")
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        chapter = self.value("chapters", {"id": "one"})[0]
        self.assertTrue(self.value("content", {"id": "one", "chapterId": chapter["id"]})["webParse"])

    @unittest.skipUnless(importlib.util.find_spec("cryptography"), "RSA tests require the bundled cryptography backend")
    def test_rsa_import_cipher_and_signature_compatibility(self):
        from cryptography.hazmat.primitives.asymmetric import rsa, padding
        from cryptography.hazmat.primitives import hashes, serialization
        from Crypto.PublicKey import RSA
        from Crypto.Cipher import PKCS1_v1_5, PKCS1_OAEP
        from Crypto.Signature import pkcs1_15
        from Crypto.Hash import SHA256
        backend = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        private_pem = backend.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        public_pem = backend.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        private, public = RSA.importKey(private_pem), RSA.import_key(public_pem)
        self.assertTrue(private.has_private())
        self.assertFalse(public.has_private())
        self.assertEqual(RSA.importKey(public.exportKey()).n, private.n)
        self.assertEqual(RSA.construct((private.n, private.e, private.d)).n, private.n)
        message = b"lumebox-rsa-compatibility"
        ciphertext = PKCS1_v1_5.new(public).encrypt(message)
        self.assertEqual(backend.decrypt(ciphertext, padding.PKCS1v15()), message)
        self.assertEqual(PKCS1_v1_5.new(private).decrypt(ciphertext, b"failed"), message)
        self.assertEqual(PKCS1_v1_5.new(private).decrypt(b"invalid", b"failed"), b"failed")
        for digest, algorithm in ((None, hashes.SHA1()), (SHA256, hashes.SHA256())):
            cipher = PKCS1_OAEP.new(public, hashAlgo=digest)
            encrypted = cipher.encrypt(message)
            self.assertEqual(backend.decrypt(encrypted, padding.OAEP(mgf=padding.MGF1(algorithm), algorithm=algorithm, label=None)), message)
            self.assertEqual(PKCS1_OAEP.new(private, hashAlgo=digest).decrypt(encrypted), message)
        digest = SHA256.new(message)
        signature = pkcs1_15.new(private).sign(digest)
        backend.public_key().verify(signature, message, padding.PKCS1v15(), hashes.SHA256())
        pkcs1_15.new(public).verify(digest, signature)
        with self.assertRaises(ValueError):
            pkcs1_15.new(public).verify(SHA256.new(b"changed"), signature)
        script = FIXTURE + "\nfrom Crypto.PublicKey import RSA\nfrom Crypto.Cipher import PKCS1_v1_5, PKCS1_OAEP\nkey = RSA.importKey(" + repr(public_pem) + ")\n"
        self.assertTrue(call("rsa-spider", "load", script=script)["ok"])

    @unittest.skipUnless(importlib.util.find_spec("cryptography"), "ECC tests require cryptography")
    def test_ecc_import_export_and_dss_interoperability(self):
        from Crypto.PublicKey import ECC
        from Crypto.Signature import DSS
        from Crypto.Hash import SHA256
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from cryptography.hazmat.primitives import hashes, serialization
        message = b"LumeBox ECC compatibility"
        for curve in ('P-256', 'P-384', 'P-521'):
            key = ECC.construct(curve=curve, d=7)
            public = key.public_key()
            for form in ('PEM', 'DER'):
                restored = ECC.import_key(key.export_key(format=form))
                self.assertEqual(restored.d, 7)
                self.assertEqual(restored.pointQ.x, key.pointQ.x)
            for compressed in (False, True):
                raw = public.export_key(format='SEC1', compress=compressed)
                restored = ECC.import_key(raw, curve_name=curve)
                self.assertEqual(restored.pointQ.y, public.pointQ.y)
            for mode in ('fips-186-3', 'deterministic-rfc6979'):
                for encoding in ('binary', 'der'):
                    signer = DSS.new(key, mode, encoding=encoding)
                    signature = signer.sign(SHA256.new(message))
                    if mode == 'deterministic-rfc6979':
                        self.assertEqual(signature, signer.sign(SHA256.new(message)))
                    verifier = DSS.new(public, mode, encoding=encoding)
                    verifier.verify(SHA256.new(message), signature)
                    with self.assertRaises(ValueError):
                        verifier.verify(SHA256.new(b'changed'), signature)
                    if encoding == 'binary':
                        size = len(signature) // 2
                        der = utils.encode_dss_signature(int.from_bytes(signature[:size], 'big'), int.from_bytes(signature[size:], 'big'))
                    else:
                        der = signature
                    backend = serialization.load_pem_public_key(public.export_key(format='PEM').encode())
                    backend.verify(der, message, ec.ECDSA(hashes.SHA256()))
        script = FIXTURE + "\nfrom Crypto.PublicKey import ECC\nfrom Crypto.Signature import DSS\nkey = ECC.construct(curve='P-256', d=7)\n"
        self.assertTrue(call('ecc-spider', 'load', script=script)['ok'])

    def test_user_scripts_load_dependencies_and_categories(self):
        for index, path in enumerate(USER_SCRIPTS):
            with self.subTest(script=path.name):
                source_id = "user_" + str(index)
                loaded = call(source_id, "load", script=path.read_text(encoding="utf-8-sig"))
                self.assertTrue(loaded["ok"], {"file": path.name, "result": loaded})
                categories = call(source_id, method="categories")
                self.assertTrue(categories["ok"], {"file": path.name, "result": categories})
                self.assertGreater(len(categories["value"]), 0)
                print("Validated load/dependencies/categories:", path.name)
                if path.name in ("金牌.py", "影探4K.py"):
                    home = call(source_id, method="home")
                    self.assertTrue(home["ok"], home)
                    self.assertTrue(home["value"], '真实脚本首页应有推荐或分类首屏')
                    search = call(source_id, method="list", argument={"keyword": "测试", "page": 1})
                    self.assertTrue(search["ok"], search)
                    item = search["value"]["items"][0]
                    detail = call(source_id, method="detail", argument={"id": item["id"]})
                    self.assertTrue(detail["ok"], detail)
                    episodes = call(source_id, method="chapters", argument={"id": item["id"]})
                    self.assertTrue(episodes["ok"], episodes)
                    content = call(source_id, method="content", argument={"id": item["id"], "chapterId": episodes["value"][0]["id"]})
                    self.assertTrue(content["ok"], content)
                    self.assertEqual(content["value"]["url"], "https://fixture.invalid/video.mp4")
                    print("Validated offline search/detail/episodes/play:", path.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scripts", nargs="*", type=Path)
    options = parser.parse_args()
    USER_SCRIPTS.extend(options.scripts)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
