# LumeSource: {"id":"pypack_d58b04a02d1b7300","name":"freeok","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# FreeOK (freeok.la / freeok.one / freeok.click) TVBox/默影视 桥接 Spider
# 链路:
#   分类  /vodshow/id/{1..5}/page/{n}.html   (1电影 2剧集 3爽剧 4综艺 5动漫)
#   搜索  /vodsearch.html?wd={kw}
#   详情  /vod/{id}.html  多线路(YD蓝光/C2蓝光/BB蓝光...) 按sid分组
#   播放  GET /play/{id}-{sid}-{nid}.html → player_aaaa.url(vid密文)
#         POST /jx/api.php (vid=urlencode) → {url密文, urlmode}
#   解密  urlmode=2: b64 → 每3字符取第2位 → 表移位 (idx+59)%62   [已验证]
#         urlmode=1: b64d → XOR md5('test') → b64d → split('/') →
#                    parts[1]/parts[0]=双表JSON → 正文按 表2[表1.indexOf(c)] 映射 [已验证]
#   人机验证: /robot.php encrypt 逆运算自动过验 (+3移位+随机夹层+b64)
# 兼容: 有 requests 用 Session; 无则 urllib+CookieJar 纯标准库, 无第三方依赖
# 仅用于学习研究, 请于 24 小时内删除
import base64
import hashlib
import json
import random
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar

try:
    import requests
except Exception:
    requests = None

try:
    from base.spider import Spider as _BaseSpider
    _HAVE_BASESPIDER = True
except Exception:
    _HAVE_BASESPIDER = False
    _BaseSpider = object


def _ssl_ctx():
    """独立于基类: 默影视自带 base.spider 无此方法, 不能挂在 _BaseSpider 上"""
    try:
        return ssl._create_unverified_context()
    except Exception:
        return None


HOSTS = ['https://freeok.one']
# 注: www.freeok.la 是图形验证码墙(/captcha.php 人工输码, py 无法自动过),
#     freeok.click 是 Cloudflare 导航页(无内容), 均不可用为数据源;
#     若手机网络下 one 不通, 可在源 ext 里配置 la 的浏览器 cookie:
#     {"host": "https://www.freeok.la", "cookie": "PHPSESSID=xxx; ..."}
UA = ('Mozilla/5.0 (Linux; Android 13; M2012K11AC) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
REFERER = None  # 运行期 = 当前 HOST + '/'

_T = 'PXhw7UT1B0a9kQDKZsjIASmOezxYG4CHo5Jyfg2b8FLpEvRr3WtVnlqMidu6cN'
_MD5_KEY = hashlib.md5(b'test').hexdigest()  # hook 实测 customStrDecode 的 md5 入参

CATS = [('1', '电影'), ('2', '剧集'), ('3', '爽剧'), ('4', '综艺'), ('5', '动漫')]

_EMPTY_RET = {
    'homeVideoContent': {'list': []},
    'categoryContent': {'list': []},
    'searchContent': {'list': []},
    'detailContent': {'list': []},
    'playerContent': {'parse': '1', 'playUrl': '', 'url': '',
                      'header': {'User-Agent': UA, 'Referer': HOSTS[0] + '/'}},
}


def _safe_api(fn):
    """默影视壳对异常零容忍: 任何接口异常兜成空结构, 错误写 stderr (logcat 可查)"""
    def wrapper(self, *a, **kw):
        try:
            return fn(self, *a, **kw)
        except Exception as e:
            try:
                sys.stderr.write('[freeok] %s: %s: %s\n' % (fn.__name__, type(e).__name__, e))
            except Exception:
                pass
            if fn.__name__ == 'homeContent':
                return {'class': [{'type_id': c, 'type_name': n} for c, n in CATS]}
            return _EMPTY_RET.get(fn.__name__)
    wrapper.__name__ = fn.__name__
    return wrapper


# ---------------- 解密原语 ----------------

def _fk_encrypt(s):
    """人机验证加密端: 每字符 +3 移位, 两侧插随机字符, 再 b64 (逆自 Decode2)"""
    body = ''
    for ch in s:
        idx = _T.find(ch)
        code = ch if idx < 0 else _T[(idx + 3) % 62]
        body += _T[random.randrange(62)] + code + _T[random.randrange(62)]
    return base64.b64encode(body.encode('ascii')).decode('ascii')


def _decode2(s):
    """urlmode=2: b64 → 每3字符取第2位 → (idx+59)%62 表移位"""
    raw = base64.b64decode(s)
    try:
        raw = raw.decode('utf-8')
    except Exception:
        raw = raw.decode('latin-1')
    out = []
    for i in range(1, len(raw), 3):
        c = raw[i]
        idx = _T.find(c)
        out.append(c if idx < 0 else _T[(idx + 59) % 62])
    return ''.join(out)


def _b64d(s):
    s = s.strip().replace(' ', '+')
    if not s:
        return ''
    return base64.b64decode(s + '=' * (-len(s) % 4)).decode('utf-8', 'replace')


_B64_CHARS = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=')


def _js_b64d(s):
    """复刻 jsjiami 站内 Base64.decode: 剥离非法字符 + utf8_decode"""
    s = ''.join(c for c in s if c in _B64_CHARS)
    if not s:
        return ''
    raw = base64.b64decode(s + '=' * (-len(s) % 4))
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c < 0x80:
            out.append(chr(c))
            i += 1
        elif 0xbf < c < 0xe0 and i + 1 < n:
            out.append(chr(((c & 0x1f) << 6) | (raw[i + 1] & 0x3f)))
            i += 2
        elif c >= 0xe0 and i + 2 < n:
            out.append(chr(((c & 0x0f) << 12) | ((raw[i + 1] & 0x3f) << 6) | (raw[i + 2] & 0x3f)))
            i += 3
        else:
            out.append(chr(c))
            i += 1
    return ''.join(out)


def _decode1(s):
    """urlmode=1 (已验证): customStrDecode + sign
    链路: b64decode → XOR md5('test') → b64decode → split('/')
    parts[1]→表1, parts[0]→表2, 其余重拼 b64decode 为正文
    deString 映射: 字符在表2中 → 表2[表1.indexOf(字符)]"""
    raw = _js_b64d(s)
    klen = len(_MD5_KEY)
    code = ''.join(chr(ord(c) ^ ord(_MD5_KEY[i % klen])) for i, c in enumerate(raw))
    mid = _js_b64d(code)                    # 第二次 decode (decode-decode 链)
    parts = mid.split('/')
    if len(parts) < 3:
        return mid
    try:
        t1 = json.loads(_js_b64d(parts[1]))  # deString 参数1
        t2 = json.loads(_js_b64d(parts[0]))  # deString 参数2
        body = _js_b64d('/'.join(parts[2:]))
    except Exception:
        return mid
    out = []
    for ch in body:
        if ch in t2 and ch in t1:
            out.append(t2[t1.index(ch)])
        else:
            out.append(ch)
    return ''.join(out)


# ---------------- HTTP 层 (Session/Cookie + 人机验证) ----------------

# 浏览器 location.href 形态: 保留 RFC 常见符号与 % (已编码序列不二次编码)
_URL_SAFE = "%;/?:@&=+$-_.!~*'()#,[]"


def _norm_url(url):
    """未编码中文等 → percent-encoded, 已编码 % 保持不变 (对齐浏览器 href)"""
    try:
        return urllib.parse.quote(url, safe=_URL_SAFE)
    except Exception:
        return url


def _unwrap(text):
    """部分响应是 JSON 字符串包装的 HTML ("<!DOCTYPE ...") → 解包"""
    t = text.strip() if text else ''
    if t[:1] == '"':
        try:
            v = json.loads(t)
            if isinstance(v, str) and len(v) > 200:
                return v
        except Exception:
            pass
    return text


class _Http(object):
    def __init__(self, host):
        self.host = host
        self._sess = None
        if requests is not None:
            try:
                self._sess = requests.Session()
                self._sess.verify = False
                self._sess.trust_env = False
                self._sess.headers.update({
                    'User-Agent': UA,
                    'Accept-Language': 'zh-CN,zh;q=0.9',
                })
            except Exception:
                self._sess = None
        self._jar = CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._jar),
            urllib.request.HTTPSHandler(context=_ssl_ctx()))

    def set_cookie(self, s):
        """注入浏览器 cookie (la 过验证码后从浏览器复制, 供 ext 配置用)"""
        if not s:
            return
        dom = self.host.split('//', 1)[-1]
        if self._sess is not None:
            try:
                for kv in s.split(';'):
                    if '=' in kv:
                        k, v = kv.split('=', 1)
                        self._sess.cookies.set(k.strip(), v.strip(), domain=dom)
            except Exception:
                pass
        try:
            from http.cookiejar import Cookie as _C
            for kv in s.split(';'):
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    self._jar.set_cookie(_C(
                        0, k.strip(), v.strip(), None, False,
                        dom, True, False, '/', True, False, None, False, None, None, {}))
        except Exception:
            pass

    def request(self, method, url, referer=None, data=None, timeout=15):
        headers = {'Accept': 'text/html,application/xhtml+xml,application/json,*/*;q=0.8'}
        if referer:
            headers['Referer'] = referer
        if data is not None:
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
            headers['X-Requested-With'] = 'XMLHttpRequest'
        if self._sess is not None:
            try:
                r = self._sess.request(method, url, headers=headers, data=data,
                                       timeout=timeout, allow_redirects=True)
                return r.status_code, r.text
            except Exception:
                pass
        req = urllib.request.Request(url, data=data.encode('utf-8') if data else None)
        req.add_header('User-Agent', UA)
        for k, v in headers.items():
            req.add_header(k, v)
        try:
            resp = self._opener.open(req, timeout=timeout)
            body = resp.read()
            return getattr(resp, 'status', 200), body.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode('utf-8', 'replace')
        except Exception:
            return 0, ''

    def get(self, url, referer=None, timeout=15):
        url = _norm_url(url)
        st, text = self.request('GET', url, referer=referer, timeout=timeout)
        # 人机验证自动过验 (最多 3 轮; 疑似验证页即重试, 防偶发抖动)
        for _ in range(3):
            if '人机验证' not in text and 'verifyBox' not in text:
                break
            if not self._pass_robot(url, text):
                time.sleep(1)
            st, text = self.request('GET', url, referer=referer, timeout=timeout)
        return st, _unwrap(text)

    def post(self, url, data, referer=None, timeout=15):
        st, text = self.request('POST', url, referer=referer, data=data, timeout=timeout)
        for _ in range(2):
            if '人机验证' not in text and 'verifyBox' not in text:
                break
            if not self._pass_robot(url, text):
                time.sleep(1)
            st, text = self.request('POST', url, referer=referer, data=data, timeout=timeout)
        return st, _unwrap(text)

    def _pass_robot(self, url, html):
        m = re.search(r'token = encrypt\("([^"]+)"\);', html)
        if not m:
            return False
        try:
            page = _norm_url(url)   # value 必须与服务端记录的浏览器 href 形态一致
            value = urllib.parse.quote(_fk_encrypt(page))
            token = urllib.parse.quote(_fk_encrypt(m.group(1)))
            body = 'value=%s&token=%s' % (value, token)
            if self._sess is not None:
                self._sess.post(self.host + '/robot.php', data=body,
                                headers={'Referer': page,
                                         'X-Requested-With': 'XMLHttpRequest',
                                         'Content-Type': 'application/x-www-form-urlencoded'},
                                timeout=15)
            else:
                req = urllib.request.Request(self.host + '/robot.php', data=body.encode('utf-8'))
                req.add_header('User-Agent', UA)
                req.add_header('Referer', page)
                req.add_header('X-Requested-With', 'XMLHttpRequest')
                req.add_header('Content-Type', 'application/x-www-form-urlencoded')
                self._opener.open(req, timeout=15)
            return True
        except Exception:
            return False


# ---------------- 工具 ----------------

_IP_PIC_RE = re.compile(r'^http://(\d{1,3}\.){3}\d{1,3}')


def _fix_pic(u):
    """Android 9+ 禁明文 http 图片: 非IP型 http:// 封面升级 https://"""
    if not u:
        return ''
    u = u.strip()
    if u.startswith('http://') and not _IP_PIC_RE.match(u):
        return 'https://' + u[7:]
    return u


_TAG_RE = re.compile(r'<[^>]+>')
_AMP_RE = re.compile(r'&[a-z]+;')


def _clean(s):
    if not s:
        return ''
    s = _TAG_RE.sub('', s)
    s = s.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&quot;', '"')
    s = s.replace('&#39;', "'").replace('&lt;', '<').replace('&gt;', '>')
    return re.sub(r'\s+', ' ', s).strip()


_ITEM_RE = re.compile(r'<a[^>]*href="/vod/(\d+)\.html"[^>]*>')
_TITLE_ATTR_RE = re.compile(r'title="([^"]*)"')
_PIC_RE = re.compile(r'data-original="(http[^"]+)"')
_ALT_RE = re.compile(r'<img[^>]*alt="([^"]*)"')
_STRONG_RE = re.compile(r'<strong>([^<]+)</strong>')
_NOTE_RE = re.compile(r'module-item-note[^>]*>([^<]+)<')


def _parse_items(html, limit=0):
    """列表条目: 分类页标题在 <a title>, 搜索页在 <img alt>/<strong>; 就近海报+备注"""
    out, seen = [], set()
    for m in _ITEM_RE.finditer(html):
        vid = m.group(1)
        seg = html[m.end():m.end() + 900]
        name = ''
        tm = _TITLE_ATTR_RE.search(m.group(0))
        if tm and tm.group(1).strip():
            name = tm.group(1)
        if not name:
            am = _ALT_RE.search(seg)
            if am and am.group(1).strip():
                name = am.group(1)
        if not name:
            sm = _STRONG_RE.search(seg)
            if sm:
                name = sm.group(1)
        if not name or vid in seen:
            continue
        pm = _PIC_RE.search(seg)
        nm = _NOTE_RE.search(seg)
        seen.add(vid)
        out.append({
            'vod_id': vid,
            'vod_name': name.strip(),
            'vod_pic': _fix_pic(pm.group(1)) if pm else '',
            'vod_remarks': nm.group(1).strip() if nm else '',
        })
        if limit and len(out) >= limit:
            break
    return out


_EP_RE = re.compile(
    r'<a[^>]*href="/play/(\d+)-(\d+)-(\d+)\.html"[^>]*>\s*<span>([^<]*)</span>', re.S)


def _extract_detail_info(html):
    """标题/海报/年份/地区/类型/演员/导演/简介"""
    info = {}
    m = re.search(r'<h1[^>]*class="module-info-heading"[^>]*>([^<]+)<', html)
    if not m:
        m = re.search(r'<h1[^>]*>([^<]+)</h1>', html)
    info['title'] = m.group(1).strip() if m else ''
    m = re.search(r'data-original="(http[^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"', html)
    if not m:
        m = re.search(r'"(http[^"]+(?:vcover|cover|douban)[^"]*)"', html)
    info['pic'] = _fix_pic(m.group(1)) if m else ''
    m = re.search(r'href="/vodshow/[^"]*?/year/(\d{4})\.html"[^>]*>\s*(\d{4})\s*<', html)
    if not m:
        m = re.search(r'>(\d{4})\s*<span class="slash"', html)
    info['year'] = m.group(1) if m else ''
    for tag, key in (('area', 'area'), ('class', 'cls')):
        mm = re.search(r'href="/vodshow/%s/[^"]*"[^>]*>([^<]{1,20})<' % tag, html)
        info[key] = mm.group(1).strip() if mm else ''
    m = re.search(r'(?:主演|演员)[：</>a-z"\s]*</div>\s*<div[^>]*>([^<]{2,300})<', html)
    if not m:
        m = re.search(r'module-info-item-content[^>]*>([^<]{2,300})<', html)
    info['actor'] = m.group(1).strip() if m else ''
    m = re.search(r'module-info-introduction.*?module-info-item-content[^>]*>(.*?)</div>', html, re.S)
    info['desc'] = _clean(m.group(1))[:500] if m else ''
    m = re.search(r'module-item-note[^>]*>([^<]+)<', html)
    info['remarks'] = m.group(1).strip() if m else ''
    return info


class Spider(_BaseSpider):
    @_safe_api
    def init(self, ext=None):
        self._http = _Http(HOSTS[0])
        self._probe_cache = {}
        # ext 可选配置: {"host": "...", "cookie": "..."} 或纯 cookie 字符串
        if ext:
            cfg = None
            try:
                if isinstance(ext, str) and ext.strip().startswith('{'):
                    cfg = json.loads(ext)
            except Exception:
                cfg = None
            try:
                if cfg and cfg.get('host'):
                    self._http = _Http(str(cfg['host']).rstrip('/'))
                if cfg and cfg.get('cookie'):
                    self._http.set_cookie(str(cfg['cookie']))
                elif isinstance(ext, str) and '=' in ext and cfg is None:
                    self._http.set_cookie(ext)
            except Exception:
                pass

    def destroy(self):
        self._http = None

    # ---------- 兜底 host 切换 ----------
    def _switch_host(self):
        for h in HOSTS:
            if h == self._http.host:
                continue
            st, text = _Http(h).get(h + '/')
            if st == 200 and '人机验证' not in text and '系统安全验证' not in text \
                    and len(text) > 5000:
                self._http = _Http(h)
                return True
        return False

    def _reset_http(self):
        """重建会话: 站点对同 session 搜索限频(第2次起返回空壳页), 重建即恢复"""
        try:
            self._http = _Http(self._http.host)
        except Exception:
            pass

    def _safe_get(self, path, referer=None):
        st, text = self._http.get(self._http.host + path, referer)
        if st != 200 or len(text) < 500:
            self._switch_host()
            st, text = self._http.get(self._http.host + path, referer)
        return text

    # ---------- 默影视标准接口 ----------

    @_safe_api
    def homeContent(self, filter):
        return {'class': [{'type_id': cid, 'type_name': name} for cid, name in CATS]}

    @_safe_api
    def homeVideoContent(self):
        html = self._safe_get('/vodshow/id/1.html')
        items = _parse_items(html, 24)
        if not items:
            items = _parse_items(self._safe_get('/vodshow/id/2.html'), 24)
        return {'list': items}

    @_safe_api
    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        pg = max(1, pg)
        html = self._safe_get('/vodshow/id/%s/page/%d.html' % (tid, pg))
        items = _parse_items(html)
        return {'list': items, 'page': pg, 'pagecount': 9999,
                'limit': len(items) or 40, 'total': 999999}

    @_safe_api
    def detailContent(self, ids):
        vid = str(ids[0]).split('-')[0]
        html = self._safe_get('/vod/%s.html' % vid)
        info = _extract_detail_info(html)
        # 线路名 (data-dropdown-value 顺序 = sid 顺序)
        lines = re.findall(r'data-dropdown-value="([^"]+)"', html)
        # 剧集按 sid 分组
        groups = {}
        order = []
        for m in _EP_RE.finditer(html):
            _vid, sid, nid, name = m.group(1), m.group(2), m.group(3), m.group(4)
            if sid not in groups:
                groups[sid] = []
                order.append(sid)
            groups[sid].append(('%s-%s-%s' % (vid, sid, nid), name))
        if not groups:  # 电影可能无剧集列表, 构造单集
            m = re.search(r'/play/%s-(\d+)-(\d+)\.html' % vid, html)
            if m:
                sid, nid = m.group(1), m.group(2)
                groups[sid] = [('%s-%s-%s' % (vid, sid, nid), '播放')]
                order.append(sid)
                lines = lines or ['正片']
        play_from = '$$$'.join(lines[:len(order)]) if lines else ['正片'] * len(order)
        play_url = '$$$'.join(
            '#'.join('%s$%s' % (name or '第%s集' % nid, path) for path, name in groups[sid])
            for sid in order)
        vod = {
            'vod_id': vid,
            'vod_name': info.get('title') or ('ID:%s' % vid),
            'vod_pic': info.get('pic', ''),
            'type_name': info.get('cls', ''),
            'vod_year': info.get('year', ''),
            'vod_area': info.get('area', ''),
            'vod_remarks': info.get('remarks', ''),
            'vod_actor': info.get('actor', ''),
            'vod_director': '',
            'vod_content': info.get('desc', ''),
            'vod_play_from': play_from,
            'vod_play_url': play_url,
        }
        return {'list': [vod]}

    @_safe_api
    def searchContent(self, key, quick, pg='1'):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        kw = urllib.parse.quote(key)   # 必须预编码, 否则人机验证 value 校验失败
        if pg > 1:
            path = '/vodsearch.html?wd=%s&page=%d' % (kw, pg)
        else:
            path = '/vodsearch.html?wd=%s' % kw
        html = self._safe_get(path)
        items = _parse_items(html)
        if not items and ('系统提示' in html or not html):
            # 同 session 搜索限频 → 重建会话重试一次
            self._reset_http()
            items = _parse_items(self._safe_get(path))
        return {'list': items, 'page': pg}

    @_safe_api
    def playerContent(self, flag, id, vipFlags):
        try:
            vid, sid, nid = str(id).split('-')[:3]
        except Exception:
            return {'parse': '1', 'playUrl': '', 'url': ''}
        play_path = '/play/%s-%s-%s.html' % (vid, sid, nid)
        html = self._safe_get(play_path, referer=self._http.host + '/vod/%s.html' % vid)
        m = re.search(r'player_aaaa\s*=\s*(\{.*?\})\s*<', html, re.S)
        if not m:
            return {'parse': '1', 'playUrl': '', 'url': '',
                    'header': {'User-Agent': UA, 'Referer': self._http.host + '/'}}
        try:
            pdata = json.loads(m.group(1))
        except Exception:
            try:
                pdata = json.loads(m.group(1).replace('\\"', '"'))
            except Exception:
                return {'parse': '1', 'playUrl': '', 'url': ''}
        enc = pdata.get('url', '')
        direct = self._resolve_vid(enc)   # 全线路统一走 /jx/api.php 解析
        if not direct:
            # 解析失败 → 同 session 可能被限频, 重建会话整链路重试一次
            self._reset_http()
            html = self._safe_get(play_path, referer=self._http.host + '/vod/%s.html' % vid)
            m = re.search(r'player_aaaa\s*=\s*(\{.*?\})\s*<', html, re.S)
            if m:
                try:
                    p2 = json.loads(m.group(1))
                except Exception:
                    try:
                        p2 = json.loads(m.group(1).replace('\\"', '"'))
                    except Exception:
                        p2 = {}
                if p2.get('url'):
                    direct = self._resolve_vid(p2.get('url', ''))
        if not direct:
            # 兜底: encrypt=1/2 的标准处理
            try:
                enc2 = pdata.get('url', '')
                enc_mode = str(pdata.get('encrypt', '0'))
                if enc_mode == '1':
                    direct = urllib.parse.unquote(enc2)
                elif enc_mode == '2':
                    direct = urllib.parse.unquote(_b64d(enc2))
                elif enc2.startswith('http'):
                    direct = enc2
            except Exception:
                direct = ''
        header = {'User-Agent': UA, 'Referer': self._http.host + '/'}
        if direct and not direct.startswith('http'):
            direct = ''
        return {
            'parse': '0' if direct else '1',
            'playUrl': '',
            'url': direct,
            'header': header,
        }

    def _resolve_vid(self, enc):
        """播放页密文 → POST /jx/api.php → Decode1/Decode2 解密 (全线路通用)"""
        if not enc:
            return ''
        if enc.startswith('http'):
            return enc
        try:
            body = 'vid=' + urllib.parse.quote(enc, safe='')
            api = self._http.host + '/jx/api.php'
            # 对齐真实浏览器: Referer 必须是带 vid 的解析页
            ref = self._http.host + '/jx/player.php?vid=' + urllib.parse.quote(enc, safe='')
            st, text = self._http.post(api, body, referer=ref)
            j = json.loads(text)
            d = j.get('data') or {}
            raw = str(d.get('url', ''))
            if not raw:
                return ''
            mode = str(d.get('urlmode', ''))
            if mode == '2':
                outs = [_decode2(raw), _decode1(raw)]
            elif mode == '1':
                outs = [_decode1(raw), _decode2(raw)]
            else:
                outs = [_decode2(raw), _decode1(raw)]
            for o in outs:
                if o and o.startswith('http'):
                    return o
            return outs[0] if outs else ''
        except Exception:
            return ''

    def isVideoFormat(self, url):
        return True

    def manualVideoCheck(self):
        return False

    def localProxy(self, param):
        return []
