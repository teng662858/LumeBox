import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ai_assist import dossier, propose, validate_rules
from core import html_config

HTML = '<script>secretScript</script><input value="privateValue"><article class="video-card"><a href="/item/1?token=hiddenToken"><img src="/one.jpg" alt="Private title"><h3>Private title</h3></a></article>'


class AssistTests(unittest.TestCase):
    def test_dossier_does_not_send_scripts_values_text_or_query_credentials(self):
        value = dossier(HTML, 'https://fixture.test/?token=hiddenToken')
        for secret in ('secretScript', 'privateValue', 'hiddenToken', 'Private title'):
            self.assertNotIn(secret, value)
        self.assertIn('article.video-card', value)

    def test_real_http_model_contract_and_portable_css_validation(self):
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_POST(self):
                calls.append((self.headers.get('Authorization'), json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                response = {'choices':[{'message':{'content':json.dumps({'rules':{'listSelector':'article.video-card', 'linkSelector':'a[href]','titleSelector':'h3','coverSelector':'img'}})}}]}
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps(response).encode())
        server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            settings = {'endpoint':f'http://127.0.0.1:{server.server_port}/v1/chat/completions','model':'fixture-model','key':'modelSecret'}
            rules = propose(settings, HTML, 'https://fixture.test/')
            config, rows = validate_rules(html_config('https://fixture.test/'), HTML, rules, 'list')
            self.assertEqual(len(rows),1)
            self.assertTrue(config['aiAssisted'])
            self.assertNotIn('modelSecret', json.dumps(config))
            self.assertEqual(calls[0][0], 'Bearer modelSecret')
            self.assertEqual(calls[0][1]['model'], 'fixture-model')
        finally:
            server.shutdown();server.server_close()

    def test_hallucinated_and_incompatible_selectors_are_rejected(self):
        for selector in ('.missing', 'article:has(a)'):
            with self.subTest(selector=selector), self.assertRaises(ValueError):
                validate_rules(html_config('https://fixture.test/'), HTML, {'listSelector':selector}, 'list')

    def test_cancellation_and_endpoint_validation_happen_before_post(self):
        with self.assertRaisesRegex(ValueError, 'HTTPS'):
            propose({'endpoint':'http://remote.test/','model':'x'}, HTML, 'https://fixture.test/')
        cancel = threading.Event();cancel.set()
        with self.assertRaises(InterruptedError):
            propose({'endpoint':'http://127.0.0.1:9/','model':'x'}, HTML, 'https://fixture.test/',cancel=cancel)
