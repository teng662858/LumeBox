import re
import unittest
from core import BrowserRequired, discover, generate, guess_pattern, html_config
from verifier import execute


class RecoveryTests(unittest.TestCase):
    def test_semantic_articles_keep_local_hash_items_and_exclude_ad_cards(self):
        html = '<title>Lessons</title><article class="random-layout"><a href="https://ads.test/offer"><img src="/ad.jpg"><h3>Advertisement</h3></a></article>'
        for ident in ('a1'*16,'b2'*16,'c3'*16):
            html += '<article class="random-layout"><a href="/'+ident+'"><img src="/cover.jpg"><h3>Lesson</h3></a></article>'
        class Pages:
            def get(self,url):return url, html if url.endswith('/') else '<h1>Lesson</h1><video src="/lesson.mp4"></video>'
        config,rows,_=discover('https://fixture.test/','video',Pages())
        self.assertEqual(len(rows),3)
        self.assertEqual(config['listSelector'],'article')
        items=execute(generate(config),'LumeSource.list({page:1})',Pages())['items']
        self.assertEqual(len(items),3)
        self.assertTrue(all(item['id'].startswith('https://fixture.test/') for item in items))

    def test_root_html_slugs_and_trailing_slashes_do_not_overfit_first_item(self):
        for urls in (['https://fixture.test/lesson-one-2026.html','https://fixture.test/lesson-two-2025.html'],
                     ['https://fixture.test/video/lesson-one/','https://fixture.test/video/lesson-two/']):
            pattern=guess_pattern([{'id':u,'title':'Lesson','cover':'/one.jpg'} for u in urls], 'https://fixture.test/')
            self.assertTrue(all(re.search(pattern,u) for u in urls),pattern)

    def test_advertised_video_index_is_followed_once_instead_of_people_menu(self):
        calls=[]
        class Pages:
            def get(self,url):
                calls.append(url)
                if url.endswith('/videos'):
                    return url,'<div class="coll-art"><a href="/watch/1"><img src="/one.jpg" alt="Lesson"></a></div>'
                if '/watch/' in url:
                    return url,'<video src="/lesson.mp4"></video>'
                return url,'<a href="/pornstar/person"><img src="/person.jpg">Person</a><a href="/videos">Videos</a>'
        config,rows,_=discover('https://fixture.test/','video',Pages())
        self.assertEqual(config['url'],'https://fixture.test/videos')
        self.assertEqual(rows[0]['id'],'https://fixture.test/watch/1')
        items=execute(generate(config),'LumeSource.list({page:1})',Pages())['items']
        self.assertEqual(len(items),1)

    def test_dynamic_shell_takes_browser_path_and_export_filters_navigation(self):
        class Pages:
            def get(self,url):return url,'<div id="root"></div><a href="/home">Home</a>'
        with self.assertRaises(BrowserRequired):discover('https://fixture.test/home','video',Pages())
        html='<a href="/pornstar/person">Person</a><a href="/a-z/a">Alphabet</a><a href="/watch/1"><img src="/one.jpg">Lesson</a>'
        items=execute(generate(html_config('https://fixture.test/')),'ruleItems('+__import__('json').dumps(html)+',C.url)')
        self.assertEqual([x['id'] for x in items],['https://fixture.test/watch/1'])

    def test_public_kvs_literal_and_explicit_video_iframe_are_recognized(self):
        script = generate(html_config('https://fixture.test/'))
        literal = '<div id="kt_player"></div><script>var flashvars={video_url:"https://media.test/lesson.mp4/"};</script>'
        value = execute(script,'media('+__import__('json').dumps(literal)+',C.url)')
        self.assertEqual(value,'https://media.test/lesson.mp4/')
        protected = literal.replace('https://media.test/', 'https://media.test/function/0/')
        self.assertFalse(execute(script,'media('+__import__('json').dumps(protected)+',C.url)'))
        class Frame:
            def get(self,url):return url,'<video src="/lesson.mp4"></video>'
        value = execute(script,'resolveMedia(\'<iframe id="video" src="/frame"></iframe>\',C.url,0)',Frame())
        self.assertEqual(value['url'],'https://fixture.test/lesson.mp4')

    def test_empty_detail_heading_falls_back_to_title_and_verified_list_name(self):
        import json
        script=generate(html_config('https://fixture.test/'))
        class Page:
            def get(self,url):return url,'<h1></h1><title>Lesson title</title><video src="/lesson.mp4"></video>'
        result=execute(script,'LumeSource.detail({id:"https://fixture.test/item/1"})',Page())
        self.assertEqual(result['title'],'Lesson title')
        class NoTitle:
            def get(self,url):return url,'<h1></h1><video src="/lesson.mp4"></video>'
        result=execute(script,'(async function(){remember([{id:"https://fixture.test/item/1",title:"List lesson"}]);return await LumeSource.detail({id:"https://fixture.test/item/1"});})()',NoTitle())
        self.assertEqual(result['title'],'List lesson')
