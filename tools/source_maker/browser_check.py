import json
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class LocalHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Set-Cookie', 'fixture=accepted; HttpOnly; Path=/')
        self.end_headers()
        if self.path == '/robots.txt':
            self.wfile.write(b'User-agent: *\nAllow: /\n')
        elif self.path == '/item/1':
            self.wfile.write(b'<h1>Public lesson</h1><video src="/lesson.mp4"></video>')
        elif self.path == '/static':
            self.wfile.write(b'<title>Public lessons</title><article class="video-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>')
        elif self.path == '/slow-media':
            self.wfile.write(b'<h1>Public lesson</h1><script type="application/ld+json">{"@type":"VideoObject","name":"Lesson"}</script><main id="player"></main><script>setTimeout(()=>{document.querySelector("#player").innerHTML="<video src=/lesson.mp4></video>"},1300)</script>')
        elif self.path.startswith('/api'):
            self.wfile.write(b'{"title":"Local API fixture","token":"must-be-redacted"}')
        elif self.path == '/interactive':
            self.wfile.write(b'<title>Actions</title><button id="more" onclick="fetch(\'/api?token=secret\').then(r=>r.json()).then(v=>{document.querySelector(\'#content\').innerHTML=\'<article class=video-card><a href=/item/1>Lesson</a><img src=/cover.jpg></article>\'})">More</button><div id="content"></div>')
        else:
            self.wfile.write(b'<title>Local fixture</title><header><a href="/"><img src="/logo.svg"></a></header><a href="/privacy">Privacy</a><div id="root"></div><script>setTimeout(()=>{document.querySelector("#root").innerHTML="<p class=ready>dynamic fixture</p><article class=video-card><a href=/item/1>Lesson</a><img src=/cover.jpg></article>"},750)</script>')


def embed_checks():
    from browser_session import BrowserSession
    class Child(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            self.wfile.write(b'<video src="/lesson.mp4"></video>')
    child = ThreadingHTTPServer(('127.0.0.1', 0), Child)
    child_url = f'http://127.0.0.1:{child.server_port}/player'
    class Parent(Child):
        def do_GET(self):
            self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
            self.wfile.write(f'<iframe id="video" src="{child_url}"></iframe>'.encode())
    parent = ThreadingHTTPServer(('127.0.0.1', 0), Parent)
    for server in (child, parent):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    browser = None
    try:
        url = f'http://127.0.0.1:{parent.server_port}/'
        browser = BrowserSession(url, hidden_test=True, engine='playwright')
        browser.get(url, purpose='media')
        final, html = browser.get(child_url, purpose='media')
        assert final == child_url and '<video src="/lesson.mp4">' in html
        try:
            browser.get(child_url + '/unrelated', purpose='media')
        except ValueError:
            pass
        else:
            raise AssertionError('Unadvertised foreign URL must be rejected')
        assert browser.current_page()[0] == url
        return {'ok': True, 'cross_origin_frame': True, 'foreign_url_rejected': True}
    finally:
        if browser: browser.close()
        for server in (parent, child):
            server.shutdown(); server.server_close()


def browser_checks(report):
    from browser_session import BrowserSession
    from batch_crawler import crawl_public_pages
    from core import discover
    from verifier import verify_config
    server = ThreadingHTTPServer(('127.0.0.1', 0), LocalHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/'
    results = {}
    try:
        engines = ('webview', 'playwright', 'selenium', 'scrapling-browser', 'scrapling-async-browser', 'scrapling-browser-session', 'scrapling-async-browser-session')
        from mcp_backend import server_command
        try:
            server_command()
            engines += ('mcp-playwright',)
        except ValueError:
            pass  # Optional companion; ordinary installations do not require Node.js.
        for engine in engines:
            browser = None
            try:
                browser = BrowserSession(url, hidden_test=True, engine=engine)
                final, html = browser.get(url, selector='.ready')
                assert '<p class="ready">dynamic fixture</p>' in html, html
                if engine != 'mcp-playwright':
                    assert browser.cookie_count >= 1
                _, delayed_list = browser.get(url + 'slow-list', purpose='list')
                assert '<article class="video-card">' in delayed_list
                _, delayed_media = browser.get(url + 'slow-media', purpose='media')
                assert '<video src="/lesson.mp4">' in delayed_media
                results.setdefault(engine, {})['delayed_media'] = True
                config, rows, _ = discover(url, 'video', browser)
                config['useBrowser'] = True
                chain = verify_config(config, rows, browser)
                results[engine] = {'ok': True, 'cookies': browser.cookie_count, 'dynamic': True, 'delayed_media': True, 'chain': chain}
                browser.actions = {'click':'#more','clicks':1,'wait':'.video-card'}
                _, acted = browser.get(url + 'interactive', selector='.video-card')
                assert '<article class="video-card">' in acted
                results[engine]['click_wait'] = True
                if engine in ('webview', 'playwright', 'selenium', 'mcp-playwright'):
                    current_url, current_html = browser.current_page()
                    assert current_url == url + 'interactive', current_url
                    assert '<article class="video-card">' in current_html
                    from browser_session import CurrentPageFetcher
                    captured = CurrentPageFetcher(browser, current_url, current_html)
                    current_config, current_rows, _ = discover(current_url, 'video', captured)
                    assert current_config['url'] == current_url and current_rows
                    results[engine]['current_page'] = True
                else:
                    try:
                        browser.current_page()
                    except ValueError as error:
                        assert 'Scrapling' in str(error), error
                    else:
                        raise AssertionError('Scrapling must report unsupported manual tab capture')
                if engine not in ('webview', 'mcp-playwright'):
                    records = browser.network()
                    assert any('Local API fixture' in json.dumps(r) for r in records), records
                    assert 'must-be-redacted' not in json.dumps(records)
                    results[engine]['api_records'] = True
            except Exception as e:
                results[engine] = {'ok': False, 'error': str(e)}
            finally:
                if browser:
                    browser.close()
        for engine in ('scrapling-fetcher','scrapling-async','scrapling-session','scrapling-async-session'):
            browser = None
            try:
                browser = BrowserSession(url + 'static', hidden_test=True, engine=engine)
                config, rows, _ = discover(url + 'static', 'video', browser)
                result = verify_config(config, rows, browser)
                results[engine] = {'ok':True,'chain':result}
            except Exception as error:
                results[engine] = {'ok':False,'error':str(error)}
            finally:
                if browser:
                    browser.close()
        pages = crawl_public_pages([url])
        results['scrapy'] = {'ok': 'Local fixture' in pages[url].get('html', ''), 'error': pages[url].get('error')}
        import tempfile
        from batch_crawler import batch_convert
        with tempfile.TemporaryDirectory() as directory:
            reports = batch_convert([url + 'static', url + 'item/1'], 'video', directory)
            assert reports[0]['ok'], reports
            assert not reports[1]['ok'], reports
            assert Path(directory, reports[0]['file']).exists()
            assert Path(directory, '采集诊断.json').exists()
            resumed = batch_convert([url + 'static', url + 'item/1'], 'video', directory)
            assert resumed[0]['file'] == reports[0]['file']
            assert len(list(Path(directory).glob('*.js'))) == 1
            stop = threading.Event(); stop.set()
            paused = batch_convert([url + 'static', url + 'item/1'], 'video', directory, stop=stop)
            assert paused[0]['ok']
            results['batch_conversion'] = {'ok': True, 'validated_export': True, 'invalid_page_rejected': True, 'checkpoint_resume':True,'pause':True}
    finally:
        server.shutdown()
        server.server_close()
    Path(report).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    return results
