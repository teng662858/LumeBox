"""Bounded MCP stdio client. It never exposes server instructions as application commands."""
import json
import os
import queue
import subprocess
import threading
import time

MAX_MESSAGE = 16 * 1024 * 1024


class StdioClient:
    def __init__(self, command, cancel=None):
        self.cancel = cancel or threading.Event()
        self.inbox = queue.Queue()
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.sequence = 0
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        threading.Thread(target=self._read, daemon=True).start()
        try:
            initialized = self.request('initialize', {'protocolVersion': '2025-03-26',
                'capabilities': {}, 'clientInfo': {'name': 'LumeBox-SourceMaker', 'version': '0.8.0'}}, timeout=25)
            if initialized.get('protocolVersion') not in ('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'):
                raise ValueError('MCP 服务使用尚未支持的协议版本')
            self.notify('notifications/initialized', {})
            self.tools = {}
            cursor = None
            for _ in range(10):
                result = self.request('tools/list', {'cursor': cursor} if cursor else {})
                self.tools.update({tool['name']: tool for tool in result.get('tools', [])})
                cursor = result.get('nextCursor')
                if not cursor:
                    break
            else:
                raise ValueError('MCP 工具列表超过限制')
        except Exception:
            self.close()
            raise

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_MESSAGE + 1)
                if not line:
                    break
                if len(line) > MAX_MESSAGE or not line.endswith(b'\n'):
                    raise ValueError('MCP 响应超过大小限制')
                value = json.loads(line)
                # Requests from the server cannot invoke sampling, roots or local code.
                if 'method' in value and 'id' in value:
                    if value['method'] == 'ping':
                        self._send({'jsonrpc': '2.0', 'id': value['id'], 'result': {}})
                    else:
                        self._send({'jsonrpc': '2.0', 'id': value['id'], 'error': {'code': -32601, 'message': 'Unsupported server request'}})
                elif 'id' in value:
                    self.inbox.put(value)
        except Exception as error:
            self.inbox.put(error)
        finally:
            self.inbox.put(ValueError('MCP 服务已断开，请重新连接'))

    def _send(self, value):
        raw = json.dumps(value, ensure_ascii=True).encode() + b'\n'
        if len(raw) > MAX_MESSAGE:
            raise ValueError('MCP 请求超过大小限制')
        with self.write_lock:
            self.process.stdin.write(raw)
            self.process.stdin.flush()

    def notify(self, method, params):
        self._send({'jsonrpc': '2.0', 'method': method, 'params': params})

    def request(self, method, params, timeout=30):
        with self.lock:
            self.sequence += 1
            ident = self.sequence
            self._send({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params})
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if self.cancel.is_set():
                    self.close()
                    raise InterruptedError('已取消 MCP 操作')
                try:
                    value = self.inbox.get(timeout=min(.1, max(.001, deadline-time.monotonic())))
                except queue.Empty:
                    continue
                if isinstance(value, Exception):
                    raise ValueError(str(value))
                if value.get('id') != ident:
                    continue
                if 'error' in value:
                    raise ValueError('MCP 调用失败：' + str(value['error'].get('message', '未知错误'))[:300])
                return value.get('result', {})
            self.close()  # Do not let a late response become the next call's result.
            raise ValueError('MCP 调用超时，请重新连接')

    def call(self, name, arguments=None):
        if name not in self.tools:
            raise ValueError('MCP 服务未提供所需工具：' + name)
        result = self.request('tools/call', {'name': name, 'arguments': arguments or {}})
        if result.get('isError'):
            raise ValueError('MCP 浏览器执行失败：' + '\n'.join(c.get('text', '') for c in result.get('content', []) if c.get('type') == 'text')[:400])
        return result

    def close(self):
        if self.process.poll() is None:
            if os.name == 'nt':
                try:
                    subprocess.run(['taskkill', '/PID', str(self.process.pid), '/T', '/F'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        creationflags=subprocess.CREATE_NO_WINDOW, timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout):
            try:
                stream.close()
            except (OSError, ValueError):
                pass
