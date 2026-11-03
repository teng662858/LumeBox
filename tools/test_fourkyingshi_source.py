"""Regression checks for the user supplied 4kyingshi.net Spider."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]


class FourkSourceTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fourk_source', ROOT / 'sources/archive/python/4K影视-HTTP错误修复.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.spider = self.module.Spider()

    def test_rejected_page_is_an_error_not_empty_library(self):
        with patch('requests.get', return_value=Mock(status_code=403, text='<h1>403 Forbidden</h1>')) as get:
            with self.assertRaisesRegex(RuntimeError, 'HTTP 403'):
                self.spider.homeVideoContent()
            self.assertEqual(get.call_count, 1, 'Do not repeat a rejected request through three transports')

    def test_captcha_page_is_not_parsed_as_empty(self):
        with patch('requests.get', return_value=Mock(status_code=200, text='<title>Just a moment</title>')):
            with self.assertRaisesRegex(RuntimeError, 'NEED_WEBVIEW_VERIFY'):
                self.spider.homeVideoContent()

    def test_site_override_updates_paths_and_referer(self):
        self.spider.config = {'domain': 'https://mirror.test'}
        self.spider.init()
        with patch('requests.get', return_value=Mock(status_code=200, text='<html>ok</html>')) as get:
            self.spider.categoryContent('1', 1, False, {})
            self.assertEqual(get.call_args.args[0], 'https://mirror.test/4kyingshitype/1.html')
            self.assertEqual(get.call_args.kwargs['headers']['Referer'], 'https://mirror.test/')

    def test_successful_cards_still_parse(self):
        import json
        html = '<div class="public-list-div"><a class="public-list-exp" href="/4kyingshidetail/123.html" title="电影"><img data-src="https://images.test/123.jpg"></a><footer>'
        with patch('requests.get', return_value=Mock(status_code=200, text=html)):
            data = json.loads(self.spider.homeVideoContent())
            self.assertEqual(data['list'][0]['vod_id'], '123')
            self.assertEqual(data['list'][0]['vod_pic'], 'https://images.test/123.jpg')


if __name__ == '__main__':
    unittest.main()
