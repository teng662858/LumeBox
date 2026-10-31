import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from adaptive_rules import AdaptiveProfiles
from app import App


class Pages:
    def get(self, url):
        if url.rstrip('/') == 'https://fixture.test':
            html = '<title>教学视频</title><article class="video-card"><a href="/item/1">第一课</a><img src="/cover.jpg"></article>'
        else:
            html = '<h1>第一课</h1><video src="https://media.test/lesson.mp4"></video>'
        return url, html


class SimpleAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.profiles = AdaptiveProfiles(self.temp.name)
        with patch('adaptive_rules.AdaptiveProfiles', return_value=self.profiles):
            self.app = App()
        self.app.attributes('-alpha', 0)
        self.app.adaptive_enabled = False
        self.app.fetcher = Pages()
        self.app.update()

    def tearDown(self):
        self.app.close_app()
        self.temp.cleanup()

    def wait(self):
        deadline = time.monotonic() + 8
        while self.app.busy and time.monotonic() < deadline:
            self.app.update()
            time.sleep(.01)
        self.app.update()
        self.assertFalse(self.app.busy, '制作流程未在时限内结束')

    def make(self):
        self.app.url.set('https://fixture.test/')
        self.app.make_source()
        self.wait()

    def test_simple_layout_keeps_main_actions_visible(self):
        for geometry in ('820x660', '980x760'):
            self.app.geometry(geometry)
            self.app.update()
            self.assertFalse(self.app.advanced_pane.winfo_ismapped())
            self.assertFalse(self.app.log.winfo_ismapped())
            for button in (self.app.analyze_btn, self.app.export_btn, self.app.next_btn, self.app.current_page_btn, self.app.ai_btn):
                self.assertTrue(button.winfo_ismapped())
                bottom = button.winfo_rooty() - self.app.winfo_rooty() + button.winfo_height()
                self.assertLessEqual(bottom, self.app.winfo_height())
        self.app.toggle_advanced()
        self.app.update()
        self.assertTrue(self.app.advanced_pane.winfo_ismapped())
        self.app.toggle_advanced()
        self.app.update()
        self.assertFalse(self.app.advanced_pane.winfo_ismapped())
        self.app.geometry('820x660')
        self.app.toggle_details()
        self.app.update()
        self.assertTrue(self.app.log.winfo_ismapped())
        self.assertGreater(self.app.log.winfo_height(), 70)
        self.assertGreater(self.app.treeframe.winfo_height(), 30)
        self.assertLess(self.app.log.winfo_rooty() - self.app.winfo_rooty() + self.app.log.winfo_height(), self.app.winfo_height())

    def test_one_action_checks_and_saves_real_js_without_code_popup(self):
        with patch.object(self.app, 'show_source') as popup:
            self.make()
        popup.assert_not_called()
        self.assertEqual(self.app.artifact[1], '.js')
        self.assertNotIn('disabled', self.app.export_btn.state())
        output = Path(self.temp.name) / 'lesson.js'
        with patch('app.filedialog.asksaveasfilename', return_value=str(output)), patch('app.messagebox.showinfo'):
            self.app.export()
        self.assertTrue(output.read_text(encoding='utf-8').startswith('// LumeSource:'))
        self.app.fields['name'].set('我的教学源')
        self.assertIsNone(self.app.artifact)
        self.app.make_source()
        self.wait()
        self.assertEqual(self.app.collect()['name'], '我的教学源')
        self.assertNotIn('disabled', self.app.export_btn.state())

    def test_js_failure_requires_yes_before_python_is_attempted(self):
        targets = []
        def verify(config, rows, fetcher):
            targets.append(config['target'])
            if config['target'] == 'video':
                raise ValueError('JS fixture failure')
            return 'PY fixture passed'
        with patch('verifier.verify_config', side_effect=verify):
            self.make()
            self.assertEqual(targets, ['video'])
            self.assertIsNone(self.app.artifact)
            self.assertIn('disabled', self.app.export_btn.state())
            self.assertNotIn('disabled', self.app.python_btn.state())
            self.assertIn('JS fixture failure', self.app.status.get())
            self.assertTrue(self.app.log.winfo_ismapped())
            with patch('app.messagebox.askyesno', return_value=False):
                self.app.confirm_python()
            self.assertEqual(targets, ['video'])
            with patch('app.messagebox.askyesno', return_value=True) as confirm:
                self.app.confirm_python()
                self.wait()
            confirm.assert_called_once()
            self.assertEqual(targets, ['video', 'video', 'python'])
            self.assertEqual(self.app.artifact[1], '.py')
            self.assertNotIn('disabled', self.app.export_btn.state())

    def test_manual_python_selection_can_be_declined(self):
        with patch('app.messagebox.askyesno', return_value=False) as confirm:
            self.app.category.set('PY')
        confirm.assert_called_once()
        self.assertEqual(self.app.category.get(), '视频')

    def test_navigation_shell_uses_browser_instead_of_exporting_privacy(self):
        class FooterPages:
            def get(self, url):
                return url, '<title>Dynamic catalogue</title><div id="root"></div><a href="/privacy">Privacy</a><a href="/terms">Terms</a>'
        self.app.fetcher = FooterPages()
        with patch.object(self.app, 'verify_in_browser') as browser:
            self.make()
        browser.assert_called_once_with(auto_verify=True)
        self.assertEqual(self.app.category.get(), '视频')
        self.assertEqual(self.app.rows, [])
        self.assertIsNone(self.app.artifact)

    def test_input_change_discards_inflight_results(self):
        entered, release = threading.Event(), threading.Event()
        class SlowPages(Pages):
            def get(self, url):
                entered.set()
                release.wait(3)
                return super().get(url)
        self.app.fetcher = SlowPages()
        self.app.url.set('https://fixture.test/')
        self.app.make_source()
        self.assertTrue(entered.wait(2))
        self.app.url.set('https://changed.test/')
        release.set()
        self.wait()
        self.assertIsNone(self.app.config_data)
        self.assertIsNone(self.app.artifact)
        self.assertIn('disabled', self.app.export_btn.state())

    def test_cancel_unblocks_ui_and_late_result_cannot_replace_new_source(self):
        release = threading.Event()
        completed = threading.Event()
        old_result = []
        def blocked():
            release.wait(3)
            completed.set()
            return 'old result'
        self.app.work(blocked, old_result.append)
        started = time.monotonic()
        self.app.cancel_operation()
        self.assertLess(time.monotonic() - started, .5)
        self.assertFalse(self.app.busy)
        self.assertNotIn('disabled', self.app.analyze_btn.state())
        try:
            self.make()
            signature = self.app.artifact[0]
            release.set()
            self.assertTrue(completed.wait(2))
            until = time.monotonic() + .3
            while time.monotonic() < until:
                self.app.update()
                time.sleep(.01)
            self.assertEqual(self.app.artifact[0], signature)
            self.assertEqual(old_result, [])
        finally:
            release.set()

    def test_next_source_clears_rules_and_can_make_and_save_again(self):
        self.make()
        first = Path(self.temp.name) / 'first.js'
        with patch('app.filedialog.asksaveasfilename', return_value=str(first)), patch('app.messagebox.showinfo'):
            self.app.export()
        self.app.browser_actions = {'click': '#old-site'}
        self.app.content_category.set('成人')
        self.app.new_source()
        self.assertEqual(self.app.url.get(), '')
        self.assertIsNone(self.app.config_data)
        self.assertIsNone(self.app.artifact)
        self.assertEqual(self.app.rows, [])
        self.assertFalse(self.app.browser_actions)
        self.assertTrue(all(value.get() == '' for value in self.app.fields.values()))
        self.assertEqual(self.app.content_category.get(), '自动识别')
        self.assertEqual(self.app.last_saved, first)
        self.assertIn('disabled', self.app.export_btn.state())
        self.make()
        second = Path(self.temp.name) / 'second.js'
        with patch('app.filedialog.asksaveasfilename', return_value=str(second)), patch('app.messagebox.showinfo'):
            self.app.export()
        self.assertTrue(first.exists() and second.exists())

    def test_changing_url_automatically_clears_old_site_actions(self):
        self.make()
        self.app.browser_actions = {'click': '#previous-site'}
        self.app.content_category.set('成人')
        self.app.url.set('https://fixture.test/catalogue')
        with patch.object(self.app, 'analyze') as analyze:
            self.app.make_source()
        analyze.assert_called_once_with(auto_verify=True)
        self.assertFalse(self.app.browser_actions)
        self.assertIsNone(self.app.config_data)
        self.assertEqual(self.app.url.get(), 'https://fixture.test/catalogue')
        self.assertEqual(self.app.content_category.get(), '自动识别')

    def test_next_source_cancels_old_worker_and_detaches_browser(self):
        from unittest.mock import Mock
        release, finished = threading.Event(), threading.Event()
        old_results = []
        def blocked():
            release.wait(3)
            finished.set()
            return 'old'
        self.app.work(blocked, old_results.append)
        browser = self.app.browser = Mock()
        self.app.new_source()
        browser.cancel.assert_called_once()
        self.assertIsNone(self.app.browser)
        self.make()
        signature = self.app.artifact[0]
        release.set()
        self.assertTrue(finished.wait(2))
        until = time.monotonic() + .3
        while time.monotonic() < until:
            self.app.update()
            time.sleep(.01)
        self.assertEqual(self.app.artifact[0], signature)
        self.assertEqual(old_results, [])

    def test_read_current_page_uses_real_list_url_and_verifies(self):
        from unittest.mock import Mock
        class ManualBrowser(Pages):
            cancel = Mock()
            close = Mock()
            def get(self, url, **kwargs):
                return super().get('https://fixture.test/' if url.endswith('/catalogue') else url)
        browser = ManualBrowser()
        browser.url = 'https://fixture.test/'
        browser.ready = browser.browser_mode = True
        browser.current_page = Mock(return_value=('https://fixture.test/catalogue', Pages().get('https://fixture.test/')[1]))
        browser.closed = threading.Event()
        self.app.browser = browser
        self.app.read_browser_page()
        self.wait()
        browser.current_page.assert_called_once()
        self.assertIsNotNone(self.app.config_data, self.app.status.get())
        self.assertEqual(self.app.collect()['url'], 'https://fixture.test/catalogue')
        self.assertTrue(self.app.collect()['useBrowser'])
        self.assertEqual(self.app.rows[0]['id'], 'https://fixture.test/item/1')
        self.assertNotIn('disabled', self.app.export_btn.state(), self.app.status.get())

    def test_ai_proposal_requires_application_and_real_chain_check(self):
        self.app.url.set('https://fixture.test/')
        self.app.ai_settings = {'endpoint':'https://model.test/chat/completions','model':'test','key':'must-not-export'}
        rules = {'listSelector':'article.video-card', 'linkSelector':'a[href]', 'titleSelector':'a', 'coverSelector':'img'}
        with patch('ai_assist.propose',return_value=rules), patch('app.messagebox.askyesno',return_value=False):
            self.app.ai_analyze()
            self.wait()
        self.assertIsNone(self.app.config_data)
        with patch('ai_assist.propose',return_value=rules), patch('app.messagebox.askyesno',return_value=True):
            self.app.ai_analyze()
            self.wait()
        self.assertIsNotNone(self.app.artifact,self.app.status.get())
        self.assertNotIn('disabled',self.app.export_btn.state())
        self.assertNotIn(b'must-not-export',self.app.artifact[2])

    def test_continue_after_detail_verification_reuses_ready_browser(self):
        from unittest.mock import Mock
        self.app.browser=Mock()
        self.app.browser.ready=True
        with patch.object(self.app,'make_source') as make:
            self.app.accept_browser()
        make.assert_called_once()
        self.app.browser.accept.assert_not_called()
