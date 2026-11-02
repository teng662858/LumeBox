"""Spider host for embedded CPython. Imported scripts are trusted application code.

The network adapters use the same Dart LumeHttp client as JS sources. No pip,
subprocess, local server or JIT is needed to load an ordinary Spider script.
"""
import base64
import contextvars
import io
import json
import re
import os
import hashlib
import hmac
import sys
import time
import threading
import types
import inspect
import ast
import tempfile
from pathlib import Path, PurePosixPath
import importlib.util
import warnings as python_warnings
import urllib.error
import urllib.request
from urllib.parse import urljoin, urlsplit, unquote
from contextlib import contextmanager, redirect_stdout, redirect_stderr

import _lume_host
import requests
from requests.adapters import BaseAdapter
from requests.structures import CaseInsensitiveDict

_contexts = {}
_active = contextvars.ContextVar("lume_source")
_aliases = {
    "init": ("init", "initialize"),
    "homeContent": ("homeContent", "getHomeContent", "home"),
    "homeVideoContent": ("homeVideoContent", "getHomeVideoContent", "homeVod"),
    "categoryContent": ("categoryContent", "getCategoryContent", "category"),
    "searchContent": ("searchContent", "getSearchContent", "search"),
    "detailContent": ("detailContent", "getDetailContent", "detail"),
    "playerContent": ("playerContent", "getPlayerContent", "play"),
    "imageContent": ("imageContent", "getImageContent", "chapterContent", "getChapterContent"),
}


def _method(spider, name):
    for alias in _aliases.get(name, (name,)):
        candidate = getattr(spider, alias, None)
        if callable(candidate):
            return candidate
    return None


def _invoke(spider, name, args=(), named=None):
    function = _method(spider, name)
    if function is None:
        raise ValueError("Python 源缺少接口：" + name)
    parameters = list(inspect.signature(function).parameters.values())
    if any(p.kind == p.VAR_POSITIONAL for p in parameters):
        return function(*args)
    named = named or {}
    positional, keywords = [], {}
    index = 0
    for param in parameters:
        if param.kind == param.VAR_KEYWORD:
            continue
        if param.name.lower() in named:
            value = named[param.name.lower()]
        elif index < len(args):
            value = args[index]
        elif param.default != param.empty:
            continue
        else:
            raise ValueError("Python 接口参数不兼容：" + name + "." + param.name)
        if param.name.lower() in ("pg", "page", "pagenum", "pagenumber"):
            value = int(value) if param.annotation is int or isinstance(param.default, int) else str(value)
        if param.kind == param.KEYWORD_ONLY:
            keywords[param.name] = value
        else:
            positional.append(value)
            index += 1
    return function(*positional, **keywords)


def _host(method, payload):
    state = _active.get()
    remaining = state["deadline"] - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Python 源执行超时")
    reply = json.loads(_lume_host.invoke(json.dumps({
        "method": method, "payload": payload,
        "sourceId": state["source_id"],
        "timeout": min(remaining, 30),
    })))
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error", "宿主请求失败"))
    return reply.get("value")


class _HttpAdapter(BaseAdapter):
    def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
        body = request.body or b""
        if isinstance(body, str):
            body = body.encode("utf-8")
        if not isinstance(body, bytes):
            raise ValueError("Python 源暂不支持流式上传")
        spider = _active.get().get("spider")
        prepare = getattr(spider, "prepareRequest", None) or getattr(spider, "prepare_request", None)
        sign = getattr(spider, "sign", None)
        if prepare or sign:
            changed = (prepare or sign)({"url":request.url,"method":request.method,
                "body":body,"pageHtml":"", "bridge":lume_tools.bridge}) or {}
            request.headers.update(changed.get("headers", {}) if prepare else changed)
            if prepare and "body" in changed:
                body = changed["body"]
                if isinstance(body, str): body = body.encode("utf-8")
                if not isinstance(body, bytes): raise ValueError("签名钩子必须返回文本或字节正文")
                request.headers.pop("Content-Length", None)
        value = _host("http", {
            "url": request.url, "method": request.method,
            "headers": dict(request.headers), "body": base64.b64encode(body).decode(),
        })
        response = requests.Response()
        response.status_code = value["status"]
        response.headers = CaseInsensitiveDict(value["headers"])
        response._content = base64.b64decode(value["body"])
        response._content_consumed = True
        response.raw = io.BytesIO(response._content)
        from email.message import Message
        message = Message()
        for key, item in value["headers"].items():
            message[key] = item
        response.raw._original_response = types.SimpleNamespace(msg=message)
        response.url = request.url
        response.request = request
        response.encoding = requests.utils.get_encoding_from_headers(response.headers)
        return response

    def close(self):
        pass


_original_session_init = requests.Session.__init__


def _session_init(self):
    _original_session_init(self)
    self.trust_env = False
    self.headers.pop("User-Agent", None)
    self.mount("http://", _HttpAdapter())
    self.mount("https://", _HttpAdapter())


requests.Session.__init__ = _session_init


_original_get_adapter = requests.Session.get_adapter


def _session_get_adapter(self, url):
    adapter = _original_get_adapter(self, url)
    # Spiders often remount HTTPAdapter to configure pools/retries after init.
    # Their requests must still use Dart's session, cancellation and network.
    if _active.get(None) is not None and isinstance(adapter, requests.adapters.HTTPAdapter):
        return _HttpAdapter()
    return adapter


requests.Session.get_adapter = _session_get_adapter


class _UrlResponse(io.BytesIO):
    def __init__(self, value, url):
        from email.message import Message
        super().__init__(base64.b64decode(value["body"]))
        self.code = self.status = value["status"]
        self.url = url
        self.reason = ""
        self.msg = self.reason
        self.headers = Message()
        for key, item in value["headers"].items():
            self.headers[key] = item

    def info(self):
        return self.headers

    def getcode(self):
        return self.code

    def geturl(self):
        return self.url

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def getheaders(self):
        return list(self.headers.items())


class _UrlHandler(urllib.request.HTTPHandler, urllib.request.HTTPSHandler):
    handler_order = 400

    def http_open(self, request):
        data = request.data or b""
        if not isinstance(data, bytes):
            raise ValueError("仅支持 bytes 请求体")
        value = _host("http", {
            "url": request.full_url, "method": request.get_method(),
            "headers": dict(request.header_items()),
            "body": base64.b64encode(data).decode(),
        })
        return _UrlResponse(value, request.full_url)

    https_open = http_open


_build_opener = urllib.request.build_opener


def _opener(*handlers):
    # Prevent custom HTTPSHandler/context from silently bypassing the host.
    handlers = [h for h in handlers if not isinstance(h, (urllib.request.HTTPHandler, urllib.request.HTTPSHandler))]
    return _build_opener(*handlers, _UrlHandler())


urllib.request.build_opener = _opener
urllib.request.install_opener(_opener())

# Some Spiders use http.client directly rather than requests / urllib.
import http.client


def _connection_request(self, method, url, body=None, headers=None, *, encode_chunked=False):
    if url.startswith(("http://", "https://")):
        target = url
    else:
        scheme = "https" if isinstance(self, http.client.HTTPSConnection) else "http"
        host = self.host
        if ":" in host and not host.startswith("["):
            host = "[" + host + "]"
        target = "%s://%s:%s%s" % (scheme, host, self.port, url)
    data = body.encode("utf-8") if isinstance(body, str) else body or b""
    self._lume_response = _UrlResponse(_host("http", {
        "url": target, "method": method, "headers": headers or {},
        "body": base64.b64encode(data).decode(),
    }), target)


def _connection_response(self):
    response = getattr(self, "_lume_response", None)
    if response is None:
        raise http.client.ResponseNotReady()
    self._lume_response = None
    return response


http.client.HTTPConnection.request = _connection_request
http.client.HTTPConnection.getresponse = _connection_response


# Explicit on-device tools; no downloads, subprocesses or proxy tunnels.
lume_tools = types.ModuleType("lume_tools")
lume_tools.run = lambda **options: _host("tools", options)
lume_tools.digest = lambda algorithm, data: hashlib.new(algorithm, data.encode() if isinstance(data, str) else data).hexdigest()
lume_tools.aes = lambda **options: _host("tools", dict(options, operation="aes"))
lume_tools.rsa = lambda **options: _host("tools", dict(options, operation="rsa"))
lume_tools.base64_encode = lambda text: base64.b64encode(text.encode()).decode()
lume_tools.base64_decode = lambda text: base64.b64decode(text).decode()
lume_tools.url_encode = lambda text: __import__("urllib.parse", fromlist=["quote"]).quote(text, safe="")
lume_tools.url_decode = lambda text: __import__("urllib.parse", fromlist=["unquote"]).unquote(text)
lume_tools.inflate = lambda data, raw=False: base64.b64decode(_host("tools", {"operation":"inflate", "data":base64.b64encode(data).decode(), "raw":raw}))
lume_tools.media = lambda operation, **options: _host("media", dict(options, operation=operation))
lume_tools.set_user_agent = lambda url, ua: _host("session.configure", {"url":url, "userAgent":ua})
lume_tools.bridge = types.SimpleNamespace(
    configure=lambda **options: _host("web.bridge.configure", options),
    request=lambda **options: _host("web.bridge.request", options))
sys.modules["lume_tools"] = lume_tools


class _Spider:
    def fetch(self, url, **kwargs):
        return requests.get(url, **kwargs)

    def post(self, url, **kwargs):
        return requests.post(url, **kwargs)

    def log(self, message):
        # Script output can contain credentials; it is deliberately not exported.
        pass

    def html(self, text):
        from lxml import etree
        return etree.HTML(text)

    htmlParser = html

    def getText(self, document, xpath):
        values = document.xpath(xpath)
        return values[0] if isinstance(values, list) and values else values if not isinstance(values, list) else ""

    def getArray(self, document, xpath):
        values = document.xpath(xpath)
        return values if isinstance(values, list) else [values]

    def regStr(self, pattern, text, index=1):
        match = re.search(pattern, text)
        return match.group(index) if match else ""

    def cleanText(self, text):
        from bs4 import BeautifulSoup
        return BeautifulSoup(text or "", "html.parser").get_text(" ", strip=True)

    def getCache(self, key):
        value = _active.get()["cache"].get(str(key))
        if isinstance(value, tuple) and len(value) == 2:
            if value[0] and time.monotonic() > value[0]:
                self.delCache(key)
                return None
            return value[1]
        return value

    def setCache(self, key, value, expire=0):
        _active.get()["cache"][str(key)] = (time.monotonic() + expire if expire else 0, value)

    def delCache(self, key):
        _active.get()["cache"].pop(str(key), None)

    def renderPage(self, url, **options):
        """Render with the phone's WebKit session; returns html/result/media."""
        return _host("web.render", {**options, "url": str(url)})

    def extractHtml(self, html, fields, rowSelector="", baseUrl=""):
        return _host("html.extract", {"html": str(html), "fields": fields,
            "rowSelector": rowSelector, "baseUrl": baseUrl})

    def getItem(self, key, default=None):
        return _host("storage", {"operation": "get", "key": str(key), "defaultValue": default})

    def setItem(self, key, value):
        return _host("storage", {"operation": "set", "key": str(key), "value": value})

    def removeItem(self, key):
        return _host("storage", {"operation": "remove", "key": str(key)})

    def getProxyUrl(self, *args):
        return _host("proxy", {})


_base = types.ModuleType("base")
_spider = types.ModuleType("base.spider")
_spider.Spider = _Spider
_spider.SpiderBase = _Spider
_base.spider = _spider
sys.modules["base"] = _base
sys.modules["base.spider"] = _spider
sys.modules["spider"] = _spider


def _crypto_module():
    """The subset used by imported Spiders, backed by host PointyCastle."""
    crypto = types.ModuleType("Crypto")
    crypto.__path__ = []
    cipher = types.ModuleType("Crypto.Cipher")
    cipher.__path__ = []
    util = types.ModuleType("Crypto.Util")
    util.__path__ = []
    padding = types.ModuleType("Crypto.Util.Padding")

    def pad(data, block_size, style="pkcs7"):
        if style != "pkcs7" or not 1 <= block_size <= 255:
            raise ValueError("仅支持 PKCS7 padding")
        count = block_size - len(data) % block_size
        return data + bytes([count]) * count

    def unpad(data, block_size, style="pkcs7"):
        if style != "pkcs7" or not data or len(data) % block_size:
            raise ValueError("无效的 PKCS7 padding")
        count = data[-1]
        if not 1 <= count <= block_size or data[-count:] != bytes([count]) * count:
            raise ValueError("无效的 PKCS7 padding")
        return data[:-count]

    padding.pad, padding.unpad = pad, unpad

    class Cipher:
        def __init__(self, algorithm, key, mode, iv=b"", nonce=b"", segment_size=8):
            self.algorithm, self.key, self.mode = algorithm, bytes(key), mode
            self.iv, self.nonce, self.aad = bytes(iv), bytes(nonce), b""
            self.segment_size = segment_size

        def update(self, data):
            self.aad += bytes(data)

        def _run(self, data, encrypt, tag=b""):
            encode = lambda value: base64.b64encode(value).decode()
            value = _host("crypto", {
                "algorithm": self.algorithm, "mode": self.mode,
                "key": encode(self.key), "iv": encode(self.iv),
                "nonce": encode(self.nonce), "aad": encode(self.aad),
                "data": encode(bytes(data) + bytes(tag)), "encrypt": encrypt,
                "segmentSize": self.segment_size,
            })
            return base64.b64decode(value)

        def encrypt(self, data):
            return self._run(data, True)

        def decrypt(self, data):
            return self._run(data, False)

        def encrypt_and_digest(self, data):
            value = self._run(data, True)
            return value[:-16], value[-16:]

        def decrypt_and_verify(self, data, tag):
            return self._run(data, False, tag)

    aes = types.ModuleType("Crypto.Cipher.AES")
    aes.MODE_ECB, aes.MODE_CBC, aes.MODE_GCM, aes.block_size = 1, 2, 11, 16
    aes.MODE_CFB, aes.MODE_OFB, aes.MODE_CTR = 3, 5, 6
    def aes_new(key, mode, iv=b"", **kw):
        if len(key) not in (16, 24, 32) or mode not in (1, 2, 3, 5, 6, 11):
            raise ValueError("不支持的 AES 密钥长度或模式")
        if "counter" in kw:
            raise ValueError("AES CTR 请使用 nonce 与 initial_value；自定义 counter 尚未支持")
        if kw.get("mac_len", 16) != 16:
            raise ValueError("认证加密当前支持 16 字节认证标签")
        nonce = kw.get("nonce", os.urandom(12) if mode == 11 else os.urandom(8) if mode == 6 else b"")
        if mode == 6:
            if len(nonce) >= 16:
                raise ValueError("AES CTR nonce 过长")
            iv = nonce + int(kw.get("initial_value", 0)).to_bytes(16 - len(nonce), "big")
        elif mode in (2, 3, 5):
            iv = kw.get("iv", kw.get("IV", iv)) or os.urandom(16)
        return Cipher("aes", key, mode, iv=iv, nonce=nonce, segment_size=kw.get("segment_size", 8))
    aes.new = aes_new
    chacha = types.ModuleType("Crypto.Cipher.ChaCha20_Poly1305")
    chacha.new = lambda *, key, nonce: Cipher("chacha", key, 0, nonce=nonce)
    cipher.AES, cipher.ChaCha20_Poly1305 = aes, chacha
    crypto.Cipher, crypto.Util, util.Padding = cipher, util, padding
    for module in (crypto, cipher, aes, chacha, util, padding):
        sys.modules[module.__name__] = module
    hashes = types.ModuleType("Crypto.Hash")
    hashes.__path__ = []
    for name in ("MD5", "SHA1", "SHA224", "SHA256", "SHA384", "SHA512"):
        digest = types.ModuleType("Crypto.Hash." + name)
        digest._name = name.lower()
        digest.new = lambda data=b"", _name=name.lower(), **kw: hashlib.new(_name, data)
        digest.digest_size = hashlib.new(name.lower()).digest_size
        setattr(hashes, name, digest)
        sys.modules[digest.__name__] = digest
    hmac_module = types.ModuleType("Crypto.Hash.HMAC")
    hmac_module.new = lambda key, msg=b"", digestmod=hashes.MD5: hmac.new(key, msg, digestmod if isinstance(digestmod, str) else digestmod._name)
    hashes.HMAC = hmac_module
    crypto.Hash = hashes
    random = types.ModuleType("Crypto.Random")
    random.get_random_bytes = os.urandom
    crypto.Random = random
    for module in (hashes, hmac_module, random):
        sys.modules[module.__name__] = module
    import lume_rsa
    lume_rsa.install(crypto, cipher)
    import lume_ecc
    lume_ecc.install(crypto)


_crypto_module()

import lume_html
import lume_httpx
lume_html.install()
lume_httpx.install(_host)

# Spider search helpers sometimes use ThreadPoolExecutor. Bind each newly
# created worker to its source context; contextvars do not inherit on 3.13.
_thread_init = threading.Thread.__init__
_thread_run = threading.Thread.run


def _source_thread_init(self, *args, **kwargs):
    _thread_init(self, *args, **kwargs)
    self._lume_context = contextvars.copy_context()


def _source_thread_run(self):
    return self._lume_context.run(_thread_run, self)


threading.Thread.__init__ = _source_thread_init
threading.Thread.run = _source_thread_run


@contextmanager
def _budget(state, seconds):
    state["deadline"] = time.monotonic() + min(max(float(seconds), 1), 60)
    token = _active.set(state)
    previous = sys.gettrace()

    def trace(frame, event, arg):
        if time.monotonic() > state["deadline"]:
            raise TimeoutError("Python 源执行超时")
        return trace

    sys.settrace(trace)
    try:
        class Quiet:
            def write(self, value):
                return len(value)
            def flush(self):
                pass
        with _source_modules(state), redirect_stdout(Quiet()), redirect_stderr(Quiet()):
            yield
    finally:
        sys.settrace(previous)
        _active.reset(token)


@contextmanager
def _source_modules(state):
    """Serial native calls temporarily install only this source's imports."""
    root = state.get("root")
    root = Path(root) if root else None
    roots = {path.stem if path.suffix == '.py' else path.name for path in root.iterdir()} if root else set()
    entry_module = state.get('entry_module')
    if entry_module:
        roots.add(entry_module.__name__.split('.')[0])
    saved = {name: module for name, module in sys.modules.copy().items() if name.split('.')[0] in roots}
    for name in saved:
        sys.modules.pop(name, None)
    sys.modules.update(state.get("modules", {}))
    if entry_module:
        sys.modules[entry_module.__name__] = entry_module
    old_path = sys.path[:]
    if root:
        sys.path[:0] = [str(root), str(root / PurePosixPath(state["entry"]).parent)]
    importlib.invalidate_caches()
    try:
        yield
    finally:
        owned = {}
        for name, module in sys.modules.copy().items():
            file = getattr(module, "__file__", None)
            if module is entry_module or (root and file and Path(file).is_relative_to(root)):
                owned[name] = module
                sys.modules.pop(name, None)
        state["modules"] = owned
        sys.modules.update(saved)
        sys.path[:] = old_path
        importlib.invalidate_caches()


def _close_source(state):
    if state:
        directory = state.get("directory")
        state.clear()
        if directory:
            directory.cleanup()


def _unpack_source(state, script):
    marker = re.search(r"^# LumeBundle: ([A-Za-z0-9+/=]+)$", script, re.M)
    if not marker:
        return script, "imported_source.py"
    bundle = json.loads(base64.b64decode(marker[1], validate=True))
    files = bundle.get("files", {})
    if len(files) > 256:
        raise ValueError("源包文件过多")
    directory = tempfile.TemporaryDirectory(prefix="lume_source_")
    root = Path(directory.name)
    state.update(directory=directory, root=str(root), entry=bundle["entry"])
    total = 0
    for name, encoded in files.items():
        path = PurePosixPath(name)
        if not name or path.is_absolute() or any(part in ("..", ".", "") for part in name.split('/')) or '\\' in name or ':' in name:
            raise ValueError("源包路径越界")
        if path.suffix.lower() in ('.so', '.pyd', '.dylib', '.fwork', '.dex', '.jar', '.apk'):
            raise ValueError("源包原生代码须在 iOS 构建时签名；Java/DEX 需要 Android 后端")
        data = base64.b64decode(encoded, validate=True)
        total += len(data)
        if total > 8 * 1024 * 1024:
            raise ValueError("源包解压后超过 8MB")
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    entry = bundle["entry"]
    if entry not in files:
        raise ValueError("源包缺少入口")
    target = root / entry
    return target.read_bytes(), str(target)


def _proxy_response(state, request):
    spider = state["spider"]
    if not state["initialized"]:
        if _method(spider, "init"):
            _invoke(spider, "init", (state.get("config", {}).get("extend", ""),))
        state["initialized"] = True
    params = dict(request.get("params") or {})
    params.setdefault("headers", request.get("headers") or {})
    if params['headers'].get('range'):
        params.setdefault('range', params['headers']['range'])
    params.setdefault('method', request.get('method', 'GET'))
    result = _invoke(spider, "localProxy", (params,))
    if not isinstance(result, (list, tuple)) or len(result) < 3:
        raise ValueError("localProxy 须返回 [状态码, MIME, 响应体, 可选响应头, 可选Base64标记]")
    status, mime, body = result[:3]
    headers = result[3] if len(result) > 3 and isinstance(result[3], dict) else {}
    if len(result) > 4 and str(result[4]) == '1':
        body = base64.b64decode(body, validate=True)
    elif isinstance(body, str):
        body = body.encode('utf-8')
    elif hasattr(body, 'read'):
        body = body.read(6 * 1024 * 1024 + 1)
    body = bytes(body)
    if len(body) > 6 * 1024 * 1024:
        raise ValueError("本地代理单次响应超过 6MB，请使用分段或 Range 请求")
    return {"status": int(status), "mime": str(mime), "headers": headers, "body": base64.b64encode(body).decode()}


def _decoded(value):
    if isinstance(value, str):
        return json.loads(value) if value.strip() else {}
    return value or {}


def _items(value):
    raw = _decoded(value)
    entries = raw if isinstance(raw, list) else raw.get("list", [])
    if not isinstance(entries, (list, tuple)):
        return []
    return [{"id": "py:" + str(x.get("vod_id", x.get("id", ""))),
             "title": str(x.get("vod_name", x.get("name", ""))),
             "cover": x.get("vod_pic", x.get("pic", "")),
             "mediaType": x.get("mediaType", x.get("contentType", x.get("kind", ""))),
             "subtitle": str(x.get("vod_remarks", x.get("remarks", "")))}
            for x in entries if isinstance(x, dict) and x.get("vod_id", x.get("id")) is not None]


def _detail(state, item_id):
    if state.get("detail_id") != item_id:
        value = _decoded(_invoke(state["spider"], "detailContent", ([item_id],), {"ids": [item_id], "array": [item_id], "id": item_id, "vod_id": item_id}))
        entries = value.get("list", [value] if value.get("vod_id") is not None else []) if isinstance(value, dict) else value
        state["detail"] = entries[0] if entries else {}
        state["detail_id"] = item_id
    return state["detail"]


def _home_metadata(state):
    """Share one short-lived category/filter response during page startup."""
    cached = state.get("home_metadata")
    if cached and time.monotonic() - cached[0] < 30:
        return json.loads(cached[1])
    value = _decoded(_invoke(state["spider"], "homeContent", (True,)))
    if not isinstance(value, dict):
        return {}
    # Serialize a private copy: script-owned data and filter reads cannot mutate it.
    state["home_metadata"] = (time.monotonic(), json.dumps(value, ensure_ascii=False))
    return value


def _home(state):
    """Prefer real recommendations; otherwise show real category first pages."""
    spider = state["spider"]
    failure = None
    metadata = {}
    if _method(spider, "homeVideoContent"):
        try:
            items = _items(_invoke(spider, "homeVideoContent"))
            if items:
                return items
        except TimeoutError:
            raise
        except Exception as error:
            failure = error
    if _method(spider, "homeContent"):
        try:
            metadata = _home_metadata(state)
            items = _items(metadata)
            if items:
                return items
        except TimeoutError:
            raise
        except Exception as error:
            failure = error
        try:
            items = _items(_invoke(spider, "homeContent", (False,)))
            if items:
                return items
        except TimeoutError:
            raise
        except Exception as error:
            failure = error
    if not _method(spider, "homeContent") or not _method(spider, "categoryContent"):
        if failure:
            raise failure
        return []
    if not isinstance(metadata, dict):
        return []
    filter_groups = metadata.get("filters") or {}
    if not isinstance(filter_groups, dict):
        filter_groups = {}
    boards, seen = [], set()
    for category in metadata.get("class") or []:
        if not isinstance(category, dict) or category.get("type_id") is None:
            continue
        category_id = str(category["type_id"])
        if not category_id or category_id in seen:
            continue
        if len(seen) >= 3:
            break
        seen.add(category_id)
        filters = {}
        for group in filter_groups.get(category_id) or []:
            if not isinstance(group, dict):
                continue
            values = group.get("value", [])
            if group.get("key") and values:
                filters[str(group["key"])] = values[0].get("v", "")
        try:
            page = _dispatch(state, "list", {"categoryId": category_id, "page": 1, "filters": filters})
            if page["items"]:
                boards.append({"title": str(category.get("type_name") or category_id),
                               "moreUrl": category_id, "items": page["items"][:12]})
                # A usable screen should not wait for two more serial site calls.
                return boards
        except TimeoutError:
            # Keep completed boards within the existing call budget.
            if boards:
                return boards
            raise
        except Exception as error:
            failure = error
    if not boards and failure:
        raise failure
    return boards


def _image_content(raw, chapter):
    value = _decoded(raw)
    entries = value.get("images", value.get("pages", [])) if isinstance(value, dict) else value
    if not isinstance(entries, (list, tuple)) or not entries:
        raise ValueError("漫画 PY 必须返回非空图片列表 images，不能返回视频或网页地址")
    shared = _decoded(value.get("headers", value.get("header", {}))) if isinstance(value, dict) else {}
    per_image = value.get("imageHeaders", {}) if isinstance(value, dict) else {}
    images, headers = [], {}
    base = unquote(chapter)
    for entry in entries:
        address = entry.get("url", entry.get("src", "")) if isinstance(entry, dict) else entry
        if not isinstance(address, str) or not address.strip():
            raise ValueError("漫画 PY 返回了无效的图片地址")
        url = urljoin(base, address.strip())
        if urlsplit(url).scheme not in ("http", "https") or not urlsplit(url).hostname:
            raise ValueError("漫画 PY 图片地址须为 http(s) 网址")
        image_headers = dict(shared) if isinstance(shared, dict) else {}
        if isinstance(per_image, dict):
            image_headers.update(per_image.get(address, per_image.get(url, {})))
        if isinstance(entry, dict):
            image_headers.update(entry.get("headers", entry.get("header", {})))
        images.append(url)
        if image_headers:
            headers[url] = {str(k): str(v) for k, v in image_headers.items()}
    return {"kind": "images", "images": images, "imageHeaders": headers}


def _dispatch(state, method, arg):
    spider = state["spider"]
    if not state["initialized"]:
        if _method(spider, "init"):
            _invoke(spider, "init", (state.get("config", {}).get("extend", ""),))
        state["initialized"] = True
    arg = arg or {}
    if method == "home":
        return _home(state)
    if method in ("categories", "filters"):
        if not _method(spider, "homeContent"):
            return []
        value = _home_metadata(state)
        if method == "categories":
            return [{"id": str(x["type_id"]), "title": str(x["type_name"])} for x in value.get("class", [])]
        groups = value.get("filters", {})
        return [{"id": x["key"], "title": x.get("name", x["key"]),
                 "options": [{"id": str(v.get("v", "")), "title": str(v.get("n", ""))} for v in x.get("value", [])]}
                for x in groups.get(str(arg.get("categoryId", "")), [])]
    if method == "list":
        if arg.get("keyword"):
            search = _method(spider, "searchContent")
            if search is None:
                return {"items": [], "hasMore": False}
            parameters = list(inspect.signature(search).parameters.values())
            if len(parameters) >= 3 or any(p.kind == p.VAR_POSITIONAL or p.name.lower() in ("page", "pg", "pagenum") for p in parameters):
                raw = _invoke(spider, "searchContent", (arg["keyword"], False, arg.get("page", 1)), {"key": arg["keyword"], "keyword": arg["keyword"], "wd": arg["keyword"], "quick": False, "page": arg.get("page", 1), "pg": arg.get("page", 1)})
            elif arg.get("page", 1) == 1:
                raw = _invoke(spider, "searchContent", (arg["keyword"], False))
            else:
                return {"items": [], "hasMore": False}
        elif arg.get("categoryId"):
            if not _method(spider, "categoryContent"):
                return {"items": [], "hasMore": False}
            raw = _invoke(spider, "categoryContent", (str(arg["categoryId"]), arg.get("page", 1), True, arg.get("filters", {})), {"tid": str(arg["categoryId"]), "cid": str(arg["categoryId"]), "id": str(arg["categoryId"]), "pg": arg.get("page", 1), "page": arg.get("page", 1), "filter": True, "extend": arg.get("filters", {}), "ext": arg.get("filters", {}), "filters": arg.get("filters", {})})
        else:
            raw = _invoke(spider, "homeVideoContent") if _method(spider, "homeVideoContent") else _invoke(spider, "homeContent", (False,)) if _method(spider, "homeContent") else {"list": []}
        value = _decoded(raw)
        items = _items(value)
        more = False
        if isinstance(value, dict):
            try:
                more = int(value.get("page", arg.get("page", 1))) < int(value.get("pagecount", value.get("page_count", 0)))
                if not value.get("pagecount", value.get("page_count")):
                    more = bool(items) and (len(items) >= int(value["limit"]) if value.get("limit") else bool(arg.get("keyword") or arg.get("categoryId")))
            except (ValueError, TypeError):
                pass
        return {"items": items, "hasMore": more}
    if method in ("detail", "chapters"):
        item_id = str(arg["id"])
        raw = _detail(state, item_id[3:] if item_id.startswith("py:") else item_id)
        if method == "detail":
            return {"id": item_id, "title": raw.get("vod_name", ""),
                    "cover": raw.get("vod_pic", ""), "subtitle": raw.get("vod_remarks", ""),
                    "description": raw.get("vod_content", ""),
                    "mediaType": raw.get("mediaType", raw.get("contentType", raw.get("kind", "")))}
        flags = str(raw.get("vod_play_from", "")).split("$$$")
        chapters = []
        for index, line in enumerate(str(raw.get("vod_play_url", "")).split("$$$")):
            flag = flags[index] if index < len(flags) else ""
            for entry in line.split("#"):
                if not entry.strip():
                    continue
                title, sep, target = entry.partition("$")
                chapters.append({"id": json.dumps({"flag": flag, "id": target if sep else title}),
                                 "title": (flag + " · " if len(flags) > 1 else "") + (title if sep else "播放")})
        return chapters
    if method == "content":
        episode = json.loads(arg["chapterId"])
        item_id = str(arg.get("id", ""))
        item_id = item_id[3:] if item_id.startswith("py:") else item_id
        detail = state.get("detail", {}) if state.get("detail_id") == item_id else {}
        hint = str(detail.get("mediaType", detail.get("contentType", detail.get("kind", "")))).lower()
        use_images = state.get("section") == "comic" and _method(spider, "imageContent") and hint not in ("video", "text", "novel", "html", "audio", "audiobook", "webplayer")
        if use_images:
            raw = _invoke(spider, "imageContent", (episode["id"],), {"id": episode["id"], "chapterid": episode["id"], "chapter_id": episode["id"], "flag": episode.get("flag", "")})
        else:
            raw = _invoke(spider, "playerContent", (episode.get("flag", ""), episode["id"], []), {"flag": episode.get("flag", ""), "id": episode["id"], "video_id": episode["id"], "vipflags": []})
        value = _decoded(raw) if not isinstance(raw, list) else raw
        if isinstance(value, dict):
            kind = str(value.get("kind", "")).lower()
            if kind in ("text", "novel", "html"):
                body = value.get("text", value.get("body", value.get("html")))
                if not isinstance(body, str):
                    raise ValueError("小说章节缺少正文")
                return {"kind": kind, "text": body, "format": value.get("format", "html" if "html" in value else "text")}
            if kind in ("images", "image") or isinstance(value.get("images"), list):
                return _image_content(value, episode["id"])
        explicit_video = isinstance(value, dict) and str(value.get("kind", "")).lower() in ("video", "audio", "audiobook", "webplayer")
        if state.get("section") == "comic" and not explicit_video:
            return _image_content(raw, episode["id"])
        raw = value
        url = str(raw.get("url") or raw.get("pageUrl") or "")
        if not url:
            raise ValueError("源未返回播放地址；请检查站点、外部解析后端或 Android 专属依赖")
        headers = _decoded(raw.get("header", raw.get("headers", {})))
        return {"kind": raw.get("kind") if raw.get("kind") in ("audio", "audiobook") else "video", "url": url, "headers": headers,
                "webPlayer": raw.get("webPlayer") is True or raw.get("kind") == "webplayer",
                "pageUrl": str(raw.get("pageUrl") or url),
                "webParse": str(raw.get("parse", 0)) == "1" or (str(raw.get("jx", 0)) == "1" and not re.search(r"\.(?:mp4|m3u8|mp3|m4a|aac|flac|mkv|webm|mpd)(?:$|[?#])", url, re.I))}
    raise ValueError("Python 源不提供接口：" + method)


def execute(request):
    request = json.loads(request)
    source_id, action = request["sourceId"], request["action"]
    if action == "dispose":
        _close_source(_contexts.pop(source_id, None))
        return {"ok": True, "value": None}
    if action == "load":
        state = {"source_id": source_id, "cache": {}, "config": {}, "initialized": False,
                 "section": request.get("section", "video")}
        _close_source(_contexts.pop(source_id, None))
        _contexts[source_id] = state
        source, filename = _unpack_source(state, request["script"])
        extend_header = re.search(r'^# LumeTVBoxExtend: ([^\r\n]+)', source, re.M) if isinstance(source, str) else None
        if extend_header:
            state['tvbox_extend'] = json.loads(extend_header[1])
            state['config']['extend'] = state['tvbox_extend']
        package = '.'.join(PurePosixPath(state.get('entry', '')).parts[:-1])
        module_name = (package + '.' + Path(filename).stem) if package else 'lume_import_' + hashlib.sha256(source_id.encode()).hexdigest()[:16]
        module = types.ModuleType(module_name)
        module.__file__, module.__package__ = filename, package
        module.__spec__ = importlib.util.spec_from_file_location(module_name, filename)
        state['entry_module'] = module
        with _budget(state, request.get("timeout", 15)):
            encoded = re.search(r"^# LumePythonBytes: ([A-Za-z0-9+/=]+)$", source, re.M) if isinstance(source, str) else None
            if encoded:
                source = base64.b64decode(encoded[1], validate=True)
            namespace = module.__dict__
            exec(compile(source, filename, "exec"), namespace)
            cls = namespace.get("Spider")
            spider = cls() if isinstance(cls, type) else namespace.get("spider") or types.SimpleNamespace(**namespace)
            required = ["detailContent"]
            if state['section'] != 'comic' or not _method(spider, "imageContent"):
                required.append("playerContent")
            for name in required:
                if not _method(spider, name):
                    raise ValueError("Python 源缺少接口：" + name)
            if not any(_method(spider, name) for name in ("homeContent", "homeVideoContent", "categoryContent", "searchContent")):
                raise ValueError("Python 源必须提供首页、分类或搜索接口")
            state.update(namespace=namespace, spider=spider)
            _contexts[source_id] = state
        warnings = []
        imports = set()
        with python_warnings.catch_warnings(action="ignore", category=SyntaxWarning):
            parsed = ast.parse(source)
        for node in ast.walk(parsed):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split('.')[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imports.add(node.module.split('.')[0])
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                if isinstance(node.func.value, ast.Name) and node.func.value.id in ("os", "subprocess") and node.func.attr in ("system", "popen", "Popen", "run", "fork", "execv"):
                    warnings.append("含系统进程接口；iOS 无法执行该路径")
        for name in sorted(imports):
            if name in ("java", "jnius", "android", "dalvik", "chaquopy"):
                warnings.append("含 Android 专属依赖 " + name + "；对应功能需要其他实现或外部后端")
            elif name not in sys.modules and name not in state.get("modules", {}):
                try:
                    bundled = state.get("root") and ((Path(state["root"]) / (name + '.py')).exists() or (Path(state["root"]) / name).is_dir())
                    found = True if bundled else importlib.util.find_spec(name)
                except (ValueError, ImportError, AttributeError):
                    found = None
                if found is None:
                    warnings.append("含尚未内置的可选/延迟依赖：" + name)
        return {"ok": True, "value": {"methods": ["categories", "list", "detail", "chapters", "content"] + (["filters"] if _method(spider, "homeContent") else []) + (["home"] if _method(spider, "homeVideoContent") or _method(spider, "homeContent") else []), "warnings": list(dict.fromkeys(warnings))}}
    state = _contexts.get(source_id)
    if state is None:
        raise ValueError("Python 源已释放，请重新选择")
    if action == "config":
        if 'tvbox_extend' in state:
            request.setdefault('config', {}).setdefault('extend', state['tvbox_extend'])
        if state.get("config") != request.get("config", {}):
            state.pop("home_metadata", None)
        state["config"] = request.get("config", {})
        state["spider"].config = state["config"]
        return {"ok": True, "value": None}
    with _budget(state, request.get("timeout", 30)):
        return {"ok": True, "value": _proxy_response(state, request) if action == "proxy" else _dispatch(state, request["method"], request.get("argument"))}


def run(request):
    try:
        result = execute(request)
        encoded = json.dumps(result, ensure_ascii=False)
        if len(encoded.encode("utf-8")) > 8 * 1024 * 1024:
            raise ValueError("Python 源结果超过 8MB")
        return encoded
    except Exception as error:
        try:
            failed = json.loads(request)
            if failed.get("action") == "load":
                _close_source(_contexts.pop(failed.get("sourceId"), None))
        except (ValueError, AttributeError):
            pass
        if isinstance(error, (TimeoutError, MemoryError)):
            try:
                _close_source(_contexts.pop(json.loads(request).get("sourceId"), None))
            except (ValueError, AttributeError):
                pass
        # No traceback or arguments: these often include tokens and passwords.
        message = str(error)
        if isinstance(error, ModuleNotFoundError):
            message = "Python 源缺少依赖：" + str(error.name)
        return json.dumps({"ok": False, "error": {
            "kind": "timeout" if isinstance(error, TimeoutError) else "script",
            "message": (type(error).__name__ + ": " + message)[:1000],
        }}, ensure_ascii=False)
