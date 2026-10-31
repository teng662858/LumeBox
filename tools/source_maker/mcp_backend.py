"""Actual Microsoft Playwright MCP integration; optional Node.js companion runtime."""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

from mcp_client import StdioClient

VERSION = '0.0.83'


def server_command(hidden=False, output=None):
    node = shutil.which('node')
    package = Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'LumeBox/SourceMaker/mcp/node_modules/@playwright/mcp'
    if not node or not (package / 'cli.js').is_file():
        raise ValueError('Playwright MCP 尚未安装：安装 Node.js 18+，再运行工具目录中的 install_mcp.ps1；普通推荐浏览器不受影响')
    metadata = json.loads((package / 'package.json').read_text(encoding='utf-8'))
    if metadata['version'] != VERSION:
        raise ValueError('Playwright MCP 版本不匹配，请重新运行 install_mcp.ps1')
    command = [node, str(package / 'cli.js'), '--browser', 'msedge', '--isolated']
    if hidden:
        command.append('--headless')
    if output:
        command.extend(['--output-dir', output])
    return command


def evaluate_result(result):
    """Decode the JSON result section, not the accessibility snapshot or generated code."""
    for block in result.get('content', []):
        if block.get('type') != 'text':
            continue
        text = block.get('text', '')
        if '### Result\n' in text:
            text = text.split('### Result\n', 1)[1]
        text = text.lstrip()
        try:
            value, _ = json.JSONDecoder().raw_decode(text)
            if isinstance(value, str) and value.startswith('LUME_JSON:'):
                return json.loads(value[len('LUME_JSON:'):])
        except (ValueError, TypeError):
            continue
    raise ValueError('Playwright MCP 未返回兼容的页面结果')


class MCPPage:
    def __init__(self, hidden=False):
        self.directory = tempfile.TemporaryDirectory(prefix='lume-mcp-')
        try:
            self.client = StdioClient(server_command(hidden, self.directory.name))
            for name in ('browser_navigate', 'browser_evaluate'):
                if name not in self.client.tools:
                    raise ValueError('Playwright MCP 缺少工具：' + name)
        except Exception:
            self.close()
            raise

    def evaluate(self, expression):
        return evaluate_result(self.client.call('browser_evaluate', {'function': 'async () => "LUME_JSON:" + JSON.stringify(await (' + expression + '))'}))

    def snapshot(self):
        return self.evaluate('({url:location.href,html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,ua:navigator.userAgent,title:document.title})')

    def navigate(self, url):
        self.client.call('browser_navigate', {'url': url})

    def close(self):
        if getattr(self, 'client', None):
            self.client.close()
        self.directory.cleanup()


def run_worker(options, send):
    from browser_session import same_site, LIMIT
    from browser_actions import program
    from core import validate_url
    from page_verification import requires_verification
    page = None
    try:
        url = validate_url(options['url'])
        page = MCPPage(options.get('hidden_test', False))
        page.navigate(url)
        accepted = False
        def capture():
            value = page.snapshot()
            if not same_site(url, value['url']):
                raise ValueError('当前页属于其他站点，请返回原站点或重新连接')
            if len(value['html'].encode('utf-8')) > LIMIT:
                raise ValueError('网页超过 6MB')
            if value['ready'] not in ('interactive', 'complete') or requires_verification(value['html']):
                raise ValueError('页面仍在加载或验证，请手动完成后继续')
            return value
        def accept():
            nonlocal accepted
            try:
                value = capture()
                accepted = True
                send({'ok': True, 'url': value['url'], 'user_agent': value['ua'], 'cookie_count': 0})
            except Exception as error:
                send({'event': 'notice', 'message': str(error)})
        if options.get('hidden_test'):
            accept()
        for line in sys.stdin:
            request = json.loads(line)
            action = request.get('action')
            if action == 'close':
                break
            if action == 'accept':
                if not accepted:
                    accept()
                continue
            try:
                if not accepted:
                    raise ValueError('请先完成网页验证')
                if action == 'network':
                    raise ValueError('MCP 引擎当前提供 DOM 采集；JSON 响应体记录请用推荐浏览器或 Selenium')
                if action == 'embed':
                    raise ValueError('跨站播放器 DOM 读取当前请使用推荐浏览器 / Playwright')
                if action not in ('get', 'snapshot'):
                    raise ValueError('不支持的 MCP 页面操作')
                if action == 'get':
                    target = validate_url(request['url'])
                    if not same_site(url, target):
                        raise ValueError('当前会话仅用于当前站点')
                    if page.snapshot()['url'] != target:
                        page.navigate(target)
                    page.evaluate(program(request.get('actions'), request.get('selector', ''), request.get('purpose', '')))
                value = capture()
                send({'ok': True, 'url': value['url'], 'html': value['html']})
            except Exception as error:
                send({'ok': False, 'error': str(error)})
    except Exception as error:
        send({'ok': False, 'error': 'Playwright MCP：' + str(error)})
    finally:
        if page:
            page.close()
