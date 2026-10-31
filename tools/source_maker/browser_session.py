"""User-operated WebView2 session in a separate process; credentials stay in IPC.

No page-facing Python API is exposed. Native menu actions mark manual completion.
"""
import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

PREFIX = 'LUME_SESSION:'
LIMIT = 6 * 1024 * 1024


def same_site(a, b):
    left, right = urlsplit(a), urlsplit(b)
    return left.scheme in ('http', 'https') and right.scheme in ('http', 'https') and left.hostname == right.hostname and (left.port or (443 if left.scheme == 'https' else 80)) == (right.port or (443 if right.scheme == 'https' else 80))


class BrowserSession:
    def __init__(self, url, *, hidden_test=False, engine='webview', on_open=None, cancel_event=None):
        from core import validate_url
        self.url = validate_url(url)
        self.engine = engine
        self.lock = threading.Lock()
        self.events = queue.Queue()
        self.ready = False
        self.notice = ''
        self.browser_mode = engine in ('webview', 'playwright', 'selenium', 'mcp-playwright') or 'browser' in engine
        self.actions = {}
        self.embed_urls = set()
        self.worker = None
        self.closed = threading.Event()
        self.cancel_event = cancel_event
        executable = [sys.executable, '--browser-worker'] if getattr(sys, 'frozen', False) else [sys.executable, str(Path(__file__).with_name('app.py')), '--browser-worker']
        flags = subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0
        self.worker = subprocess.Popen(executable, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True, encoding='utf-8', creationflags=flags)
        self.worker.stdin.write(json.dumps({'url': self.url, 'hidden_test': hidden_test, 'engine': engine}) + '\n')
        self.worker.stdin.flush()
        threading.Thread(target=self._read, daemon=True).start()
        if on_open:
            on_open(self)
        try:
            deadline = time.monotonic() + (180 if not hidden_test else 45)
            while True:
                if self.closed.is_set() or (cancel_event and cancel_event.is_set()):
                    raise InterruptedError('已取消浏览器操作')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError('等待浏览器超时。已结束本次连接，可以换网址或引擎重试。')
                try:
                    result = self.events.get(timeout=min(.2, remaining))
                    break
                except queue.Empty:
                    continue
            if self.closed.is_set() or (cancel_event and cancel_event.is_set()):
                raise InterruptedError('已取消浏览器操作')
            if not result.get('ok'):
                raise ValueError(result.get('error', '网页验证已取消'))
            self.url = result['url']
            self.user_agent = result.get('user_agent', '')
            self.cookie_count = result.get('cookie_count', 0)
            self.ready = True
        except Exception:
            self.close()
            raise

    def _read(self):
        try:
            for line in self.worker.stdout:
                if line.startswith(PREFIX):
                    value = json.loads(line[len(PREFIX):])
                    if value.get('event') == 'notice':
                        self.notice = value.get('message', '')
                    else:
                        self.events.put(value)
        except Exception:
            pass
        finally:
            self.events.put({'ok': False, 'error': '网页验证窗口已关闭，请重新打开验证'})

    def accept(self):
        if self.worker and self.worker.poll() is None:
            self.worker.stdin.write('{"action":"accept"}\n')
            self.worker.stdin.flush()

    def get(self, url, selector='', purpose=''):
        from core import validate_url
        url = validate_url(url)
        embedded = not same_site(self.url, url) and purpose == 'media' and url in self.embed_urls
        if not same_site(self.url, url) and not embedded:
            raise ValueError('浏览器会话只用于当前站点；跨域接口需单独适配')
        with self.lock:
            if self.closed.is_set() or not self.ready or self.worker.poll() is not None:
                raise ValueError('网页验证窗口已关闭，请重新打开验证')
            self.worker.stdin.write(json.dumps({'action': 'embed' if embedded else 'get', 'url': url, 'selector': selector, 'actions': {} if embedded else self.actions, 'purpose': purpose}) + '\n')
            self.worker.stdin.flush()
            try:
                result = self.events.get(timeout=38)
            except queue.Empty as e:
                self.ready = False
                raise ValueError('浏览器抓取超时，请重新打开网页验证') from e
            if self.closed.is_set() or not result.get('ok'):
                raise ValueError(result.get('error', '浏览器抓取失败'))
            if not embedded:
                self.register_embeds(result['url'], result['html'])
            return result['url'], result['html']

    def register_embeds(self, url, html):
        if not same_site(self.url, url):
            return
        from bs4 import BeautifulSoup
        from urllib.parse import urljoin
        from core import validate_url
        soup = BeautifulSoup(html, 'html.parser')
        allowed = set()
        for frame in soup.select('#player iframe,.player iframe,iframe#video,iframe[src*="/embed/"],iframe[src*="/player/"],iframe[src*="/play/"]')[:10]:
            try:
                allowed.add(validate_url(urljoin(url, frame.get('src') or frame.get('data-src') or '')))
            except ValueError:
                pass
        self.embed_urls = allowed

    def network(self):
        with self.lock:
            if not self.ready or self.worker.poll() is not None:
                raise ValueError('采集会话已关闭')
            self.worker.stdin.write('{"action":"network"}\n')
            self.worker.stdin.flush()
            result = self.events.get(timeout=10)
            if not result.get('ok'):
                raise ValueError(result.get('error', '接口记录不可用'))
            return result.get('network', [])

    def current_page(self):
        """Read the user's current document without navigating back to the entry URL."""
        from core import validate_url
        with self.lock:
            if self.closed.is_set() or not self.ready or self.worker.poll() is not None:
                raise ValueError('采集会话已关闭，请重新连接浏览器')
            self.worker.stdin.write('{"action":"snapshot"}\n')
            self.worker.stdin.flush()
            try:
                result = self.events.get(timeout=10)
            except queue.Empty as error:
                self.cancel()
                raise ValueError('读取当前页超时，请重新连接浏览器') from error
            if self.closed.is_set() or not result.get('ok'):
                raise ValueError(result.get('error', '无法读取当前页'))
            url, html = validate_url(result['url']), result['html']
            if not same_site(self.url, url):
                raise ValueError('当前页属于其他站点，请返回原站点或重新连接')
            if len(html.encode('utf-8')) > LIMIT:
                raise ValueError('网页超过 6MB，请改用具体列表页')
            self.register_embeds(url, html)
            return url, html

    def cancel(self):
        """Wake waiting callers immediately; never wait for WebView on the UI thread."""
        self.ready = False
        if self.closed.is_set():
            return
        self.closed.set()
        self.events.put({'ok': False, 'error': '已取消浏览器操作'})
        def request_close():
            try:
                if self.worker and self.worker.poll() is None:
                    self.worker.stdin.write('{"action":"close"}\n')
                    self.worker.stdin.flush()
            except (OSError, ValueError):
                pass
        threading.Thread(target=request_close, daemon=True).start()

    def close(self):
        self.cancel()
        process = self.worker
        if process is None:
            return
        try:
            if process.poll() is None:
                process.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            if process.poll() is None:
                if sys.platform == 'win32':
                    # Stop only this tool's worker and its browser descendants.
                    # A stuck WebView cannot process the graceful close command.
                    try:
                        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=subprocess.CREATE_NO_WINDOW, timeout=3)
                    except (OSError, subprocess.TimeoutExpired):
                        pass
            if process.poll() is None:
                process.kill()
                process.wait(timeout=.5)
        finally:
            for stream in (process.stdin, process.stdout):
                if stream:
                    stream.close()


class CurrentPageFetcher:
    """Use the captured DOM for the entry; delegate detail/API requests to the session."""
    def __init__(self, browser, url, html):
        self.browser, self.url, self.html = browser, url, html

    def __getattr__(self, name):
        return getattr(self.browser, name)

    def get(self, url, **kwargs):
        if url == self.url:
            return self.url, self.html
        return self.browser.get(url, **kwargs)


def run_worker():
    def send(value):
        print(PREFIX + json.dumps(value, ensure_ascii=True), flush=True)

    try:
        options = json.loads(sys.stdin.readline())
        from core import validate_url
        url = validate_url(options['url'])
        if options.get('engine') == 'mcp-playwright':
            from mcp_backend import run_worker as mcp_worker
            mcp_worker(options, send)
            return
        if options.get('engine', '').startswith('scrapling-'):
            from scrapling_backend import run_worker as scrapling_worker
            scrapling_worker(options, send)
            return
        if options.get('engine', 'webview') != 'webview':
            from browser_engines import run_automation_worker
            run_automation_worker(options, send)
            return
        import webview
        from webview.menu import Menu, MenuAction
        state = {'accepted': False, 'loaded': threading.Event()}
        window = None

        def snapshot():
            current = window.get_current_url()
            if not current or not same_site(url, current):
                raise ValueError('请回到最初站点完成验证后再继续')
            page = window.evaluate_js('({html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,title:document.title,ua:navigator.userAgent})')
            if not page or page.get('ready') != 'complete':
                raise ValueError('网页尚未加载完成，请稍后再点继续')
            body = page['html']
            if len(body.encode()) > LIMIT:
                raise ValueError('网页超过 6MB，请改用具体列表页')
            from page_verification import requires_verification, MESSAGE
            if requires_verification(body):
                raise ValueError(MESSAGE)
            return current, body, page

        def accept():
            if state['accepted']:
                return
            try:
                current, _, page = snapshot()
                cookies = window.get_cookies()
                state['accepted'] = True
                window.set_title('会话已连接 · 请保留此窗口，返回制源工具继续')
                # Cookie values are never transferred to config files or scripts.
                send({'ok': True, 'url': current, 'user_agent': page.get('ua', ''),
                      'cookie_count': sum(len(cookie) for cookie in cookies)})
            except Exception as e:
                window.set_title('尚未完成：' + str(e))

        def loaded():
            state['loaded'].set()

        def commands():
            if options.get('hidden_test'):
                state['loaded'].wait(25)
                accept()
            for line in sys.stdin:
                try:
                    request = json.loads(line)
                    if request['action'] == 'close':
                        window.destroy()
                        return
                    if request['action'] == 'accept':
                        accept()
                        continue
                    if request['action'] == 'network':
                        send({'ok': False, 'error': '内置浏览器不提供响应记录，请选择 Playwright、Selenium 或 Scrapling 浏览器'})
                        continue
                    if request['action'] == 'snapshot':
                        if not state['accepted']:
                            raise ValueError('请先手动完成网页验证')
                        current, html, _ = snapshot()
                        send({'ok': True, 'url': current, 'html': html})
                        continue
                    if not state['accepted']:
                        raise ValueError('请先手动完成网页验证')
                    target = validate_url(request['url'])
                    if not same_site(url, target):
                        raise ValueError('不允许将当前会话用于其他站点')
                    if window.get_current_url() != target:
                        state['loaded'].clear()
                        window.load_url(target)
                        if not state['loaded'].wait(16):
                            raise ValueError('浏览器加载超时')
                        # Let ordinary client-rendered catalogues finish their first render.
                        time.sleep(.45)
                    selector = '' if request.get('actions') else request.get('selector', '')
                    if selector:
                        until = time.monotonic() + 12
                        while time.monotonic() < until:
                            if window.evaluate_js('!!document.querySelector(' + json.dumps(selector) + ')'):
                                break
                            time.sleep(.2)
                        else:
                            raise ValueError('页面加载后没有出现需要的内容元素')
                    if request.get('actions') or request.get('purpose'):
                        from browser_actions import program
                        window.evaluate_js('window.__lumeActionDone=false;window.__lumeActionError="";' + program(request.get('actions'), request.get('selector', ''), request.get('purpose', '')) + '.then(function(){window.__lumeActionDone=true;},function(e){window.__lumeActionError=String(e);window.__lumeActionDone=true;});undefined;')
                        until = time.monotonic() + 8
                        while time.monotonic() < until:
                            if window.evaluate_js('window.__lumeActionDone===true'):
                                break
                            time.sleep(.1)
                        else:
                            raise ValueError('浏览器操作超时')
                        error = window.evaluate_js('window.__lumeActionError')
                        if error:
                            raise ValueError(error)
                    current, html, _ = snapshot()
                    send({'ok': True, 'url': current, 'html': html})
                except Exception as e:
                    send({'ok': False, 'error': str(e)})
            window.destroy()

        window = webview.create_window('手动验证 · 完成后点击顶部菜单「继续抓取」', url,
            width=1080, height=780, hidden=bool(options.get('hidden_test')),
            menu=[Menu('制源工具', [MenuAction('已完成验证，继续抓取', accept), MenuAction('返回输入网址', lambda: window.load_url(url))])])
        window.events.loaded += loaded
        webview.start(commands, gui='edgechromium', private_mode=True, debug=False)
    except Exception as e:
        send({'ok': False, 'error': '浏览器验证无法启动，请检查 WebView2 Runtime：' + str(e)})
