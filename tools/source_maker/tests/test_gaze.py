import unittest
from core import discover, generate, target_config
from exports import export_source
from verifier import execute

MID = '6be8f9058d86abfc118d707883186ac2'
PAGE = 'https://gaze.red/play/' + MID
HOME = f'<title>注视影视</title><article><img src="/static/img/svg/colorful.svg"><img data-src="https://image.example/cover.jpg" alt="铁拳教育"><a href="play/{MID}"></a><h3>铁拳教育</h3></article>'
DETAIL = '<h5 itemprop="name">铁拳教育</h5><meta property="og:image" content="https://image.example/cover.jpg"><div id="play-source-panel-g1"><button type="button" class="playbtn W" data-id="74595">第1集</button><button type="button" class="playbtn W" data-id="74596">第2集</button></div><div id="play-source-panel-g5"><button class="playbtn" data-id="100">广告线路</button></div><video src="blob:https://gaze.red/random"></video>'

class Pages:
    def get(self, url, **kwargs):
        return url, DETAIL if '/play/' in url else HOME

class GazeTests(unittest.TestCase):
    def setUp(self):
        self.config, self.rows, _ = discover('https://gaze.red/', 'video', Pages())
        self.script = generate(self.config)

    def test_discovery_uses_real_cover_and_movie_identity(self):
        self.assertEqual(self.config['mode'], 'gaze')
        self.assertEqual(self.config['contentCategory'], 'movie')
        self.assertEqual(self.rows[0]['cover'], 'https://image.example/cover.jpg')
        row = execute(self.script, 'LumeSource.home()', Pages())[0]['items'][0]
        self.assertEqual(row['cover'], self.rows[0]['cover'])

    def test_default_episodes_and_webplayer_never_blob(self):
        chapters = execute(self.script, f'LumeSource.chapters({{id:"{PAGE}"}})', Pages())
        self.assertEqual(len(chapters), 2)
        value = execute(self.script, f'LumeSource.content({{id:"{PAGE}",chapterId:"{chapters[1]["id"]}"}})', Pages())
        self.assertEqual(value['pageUrl'], PAGE)
        self.assertEqual(value['kind'], 'webplayer')
        self.assertIn('74596', value['webPlayerOptions']['episodeSelector'])
        self.assertNotIn('blob:', str(value))

    def test_foreign_episode_and_challenge_not_exported(self):
        with self.assertRaisesRegex(ValueError, '不属于'):
            execute(self.script, f'LumeSource.content({{id:"{PAGE}",chapterId:"https://gaze.red/play/{"a"*32}#episode=1"}})', Pages())
        with self.assertRaisesRegex(ValueError, '默认线路选集'):
            execute(self.script, f'gazeDetail("{PAGE}")', type('P', (), {'get': lambda s,u,**kw: (u,'<title>访问验证</title>')})())

    def test_unsupported_export_requires_js(self):
        for target in ('python', 'cat', 'kazumi', 'module'):
            with self.assertRaisesRegex(ValueError, '只支持视频 JS'):
                export_source(target_config(self.config, target))

if __name__ == '__main__':
    unittest.main()
