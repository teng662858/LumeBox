import json
import unittest
from unittest.mock import Mock, patch

from core import Fetcher, generate, html_config
from page_verification import requires_verification
from verifier import execute


class VerificationTests(unittest.TestCase):
    def test_challenge_title_is_not_treated_as_empty_work(self):
        for title in ('安全验证','人机验证','访问验证','Just a moment...','Verification Required'):
            self.assertTrue(requires_verification('<title>'+title+'</title><script src="/static/frontend/cap.js"></script>'))
        self.assertFalse(requires_verification('<title>Lesson: how verification works</title><h1>Lesson</h1>'))

    def test_generated_http_and_browser_sources_reject_challenge_html(self):
        class Page:
            def get(self,url,**kwargs):return url,'<title>安全验证</title><div>challenge</div>'
        for browser in (False,True):
            config=html_config('https://fixture.test/');config['useBrowser']=browser
            with self.subTest(browser=browser),self.assertRaisesRegex(ValueError,'NEED_WEBVIEW_VERIFY'):
                execute(generate(config),'LumeSource.list({page:1})',Page())
