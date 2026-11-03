# LumeSource: {"id":"pypack_78875f382dd4a609","name":"玩物社区","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
玩物社区 (pku.daqbqrri.cc / wanwuu.com) Hawk 爬虫（开发版）

结构（2026-10-12 浏览器实测）：
- 分类：/videos/{slug}/（guochan-sm/rihan-sm/oumei-sm/dongman-sm/tiaojiao-av/zhibo-huifang）
- 列表卡片：<a class="flex aspect-w-16..." href="/videos/{cat}/vd-XXXX-XXXX/">
  标题在 <h2><a> 或 img alt；封面在 img data-src（pic.wirqed.cn，走 imgdecrypt Worker）；
  时长在 .rounded-large div
- 详情：/videos/{cat}/vd-XXXX-XXXX/，内嵌 /videos/embed?id={数字ID}
- 播放：embed 页 <source src="https://yd-hls.tktjpm.cn/...m3u8?auth_key=...">（时效签名，现抓现用）
- 搜索：/videos/search/{URL编码关键词}/
- 翻页：/videos/{slug}/page/{n}/
"""
import re
import json
import threading
import socketserver
import http.server
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider:
        pass

HOST = "https://pku.daqbqrri.cc"
DOMAINS = ["pku.daqbqrri.cc", "wanwuu.com", "c5ad.oqgciumz.cc"]
_FAST_HOST = {"host": HOST}

def _host():
    return _FAST_HOST["host"]

def _pick_fastest():
    """race 选最快域名"""
    import urllib.request
    import ssl
    import threading
    import time
    ctx = ssl._create_unverified_context()
    result = {}
    def _probe(domain):
        try:
            t0 = time.time()
            req = urllib.request.Request(
                "https://%s/" % domain,
                headers={"User-Agent": UA},
                method="HEAD")
            urllib.request.urlopen(req, timeout=8, context=ctx)
            result[domain] = time.time() - t0
        except Exception:
            pass
    threads = [threading.Thread(target=_probe, args=(d,)) for d in DOMAINS]
    for t in threads:
        t.daemon = True
        t.start()
    for t in threads:
        t.join(timeout=10)
    if result:
        best = min(result, key=result.get)
        _FAST_HOST["host"] = "https://" + best
    return _FAST_HOST["host"]
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
# Worker 域名混淆（防白嫖）
_IMGDEC_B64 = "aHR0cHM6Ly9pbWcuNTU2ODk5OS5jYy5jZC9pbWc/dXJsPQ=="
def _imgdec():
    import base64
    return base64.b64decode(_IMGDEC_B64).decode()
IMGDEC = _imgdec()

# ---- 纯 Python AES-128-CBC 解密（封面图是 AES 加密的，key/iv 见 _img_crypt） ----
_AES_SBOX = (
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16)
_AES_INV_SBOX = [0]*256
for _i, _v in enumerate(_AES_SBOX):
    _AES_INV_SBOX[_v] = _i
_AES_INV_SBOX = tuple(_AES_INV_SBOX)
_AES_RCON = (0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36)
def _aes_xtime(a):
    return (((a << 1) ^ 0x1b) & 0xff) if (a & 0x80) else ((a << 1) & 0xff)
def _aes_gmul(a, b):
    p = 0
    while b:
        if b & 1:
            p ^= a
        a = _aes_xtime(a)
        b >>= 1
    return p
_AES_M09 = tuple(_aes_gmul(i, 0x09) for i in range(256))
_AES_M0B = tuple(_aes_gmul(i, 0x0b) for i in range(256))
_AES_M0D = tuple(_aes_gmul(i, 0x0d) for i in range(256))
_AES_M0E = tuple(_aes_gmul(i, 0x0e) for i in range(256))
def _aes_expand_key(key):
    ek = list(key)
    for i in range(10):
        t = ek[-4:]
        t = t[1:] + t[:1]
        t = [_AES_SBOX[b] for b in t]
        t[0] ^= _AES_RCON[i]
        for _j in range(4):
            t = [t[k] ^ ek[-16+k] for k in range(4)]
            ek += t
    return [ek[i:i+16] for i in range(0, 176, 16)]
def _aes_decrypt_block(blk, rk):
    s = [a ^ b for a, b in zip(blk, rk[10])]
    for r in range(9, 0, -1):
        s = [s[0],s[13],s[10],s[7],s[4],s[1],s[14],s[11],s[8],s[5],s[2],s[15],s[12],s[9],s[6],s[3]]
        s = [_AES_INV_SBOX[b] for b in s]
        s = [a ^ b for a, b in zip(s, rk[r])]
        o = [0]*16
        for c in range(4):
            a0,a1,a2,a3 = s[c*4],s[c*4+1],s[c*4+2],s[c*4+3]
            o[c*4]   = _AES_M0E[a0]^_AES_M0B[a1]^_AES_M0D[a2]^_AES_M09[a3]
            o[c*4+1] = _AES_M09[a0]^_AES_M0E[a1]^_AES_M0B[a2]^_AES_M0D[a3]
            o[c*4+2] = _AES_M0D[a0]^_AES_M09[a1]^_AES_M0E[a2]^_AES_M0B[a3]
            o[c*4+3] = _AES_M0B[a0]^_AES_M0D[a1]^_AES_M09[a2]^_AES_M0E[a3]
        s = o
    s = [s[0],s[13],s[10],s[7],s[4],s[1],s[14],s[11],s[8],s[5],s[2],s[15],s[12],s[9],s[6],s[3]]
    s = [_AES_INV_SBOX[b] for b in s]
    return bytes(a ^ b for a, b in zip(s, rk[0]))
class _AesCbc:
    def __init__(self, key, iv):
        self.rk = _aes_expand_key(key)
        self.iv = bytes(iv)
    def decrypt(self, data):
        out = bytearray()
        prev = self.iv
        for i in range(0, len(data)-15, 16):
            blk = _aes_decrypt_block(data[i:i+16], self.rk)
            out += bytes(a ^ b for a, b in zip(blk, prev))
            prev = data[i:i+16]
        pad = out[-1]
        if 1 <= pad <= 16 and bytes(out[-pad:]) == bytes([pad])*pad:
            del out[-pad:]
        return bytes(out)



# ---- pic.wirqed.cn 封面 AES-128-CBC（同 imgdecrypt Worker） ----
_IMG_KEY = b"f5d965df75336270"
_IMG_IV = b"97b60394abc2fbe1"

def _decrypt_img(buf):
    """解密封面，已是明文图则原样返回"""
    if len(buf) > 2 and ((buf[0] == 0xFF and buf[1] == 0xD8) or (buf[0] == 0x89 and buf[1] == 0x50)):
        return buf
    try:
        return _AesCbc(_IMG_KEY, _IMG_IV).decrypt(buf)
    except Exception:
        return buf

# ---- 127.0.0.1 图片中转 ----



# ---- 127.0.0.1 图片中转（无 Worker 版）：抓加密图 → 本地 AES 解密 → 吐 JPEG ----
_IMG_SRV = {"port": 0}
_IMG_LOCK = threading.Lock()

def _img_b64e(s):
    import base64
    return base64.urlsafe_b64encode(s.encode("utf-8")).decode("ascii").rstrip("=")

def _img_b64d(s):
    import base64
    try:
        s = str(s or "")
        s += "=" * (-len(s) % 4)
        return base64.urlsafe_b64decode(s.encode("ascii")).decode("utf-8", "ignore")
    except Exception:
        return ""

class _ImgHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(p.query)
        target = _img_b64d((qs.get("u") or [""])[0])
        if not target.startswith("http"):
            self.send_response(400); self.end_headers(); return
        try:
            import ssl
            ctx = ssl._create_unverified_context()
            req = urllib.request.Request(target, headers={
                "User-Agent": UA, "Referer": HOST + "/",
            })
            data = urllib.request.urlopen(req, timeout=20, context=ctx).read()
            img = _decrypt_img(data)
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(img)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(img)
        except Exception:
            try:
                self.send_response(502); self.end_headers()
            except Exception:
                pass

def _img_srv_start():
    if _IMG_SRV["port"]:
        return _IMG_SRV["port"]
    with _IMG_LOCK:
        if _IMG_SRV["port"]:
            return _IMG_SRV["port"]
        import socketserver
        for port in range(9989, 9999):
            try:
                class _Srv(socketserver.ThreadingMixIn, http.server.HTTPServer):
                    daemon_threads = True
                    allow_reuse_address = True
                    def handle_error(self, *a):
                        pass
                srv = _Srv(("127.0.0.1", port), _ImgHandler)
                _IMG_SRV["port"] = port
                t = threading.Thread(target=srv.serve_forever)
                t.daemon = True
                t.start()
                break
            except Exception:
                continue
        return _IMG_SRV["port"]


def _worker_img(u):
    """Worker 兜底（始终最后）"""
    if not u:
        return ""
    from urllib.parse import quote as _q
    wurl = IMGDEC + _q(u, safe="")
    return "proxy://type=img&url=%s&host=%s" % (
        _q(wurl, safe=""), _q(HOST + "/", safe=""))

def _proxy_img(u):
    """封面三级：直链 -> 127.0.0.1 本地解密 -> Worker（始终最后兜底）"""
    if not u:
        return ""
    # 第一级：非加密图直接走直链
    if "wirqed.cn" not in u:
        return u
    # 第二级：加密图走 127.0.0.1 本地解密
    port = _img_srv_start()
    if port:
        return "http://127.0.0.1:%d/img?u=%s" % (port, _img_b64e(u))
    # 第三级：Worker 始终最后兜底
    return _worker_img(u)


class Spider(BaseSpider):
    def init(self, extend=""):
        try:
            global HOST
            HOST = _pick_fastest()
        except Exception:
            pass
        try:
            _img_srv_start()
        except Exception:
            pass

    def _get(self, url, referer=""):
        import urllib.request
        import ssl
        import http.client
        # 域名故障转移：当前 HOST 失败时试其他域名
        urls = [url]
        for d in DOMAINS:
            alt = url.replace(HOST, "https://" + d, 1)
            if alt != url and alt not in urls:
                urls.append(alt)
        last_err = None
        for u in urls:
            try:
                ctx = ssl._create_unverified_context()
                req = urllib.request.Request(u, headers={
                    "User-Agent": UA,
                    "Referer": referer or HOST + "/",
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    "Accept-Language": "zh-CN,zh;q=0.9",
                })
                try:
                    return urllib.request.urlopen(req, timeout=20, context=ctx).read().decode("utf-8", "ignore")
                except http.client.IncompleteRead as e:
                    return e.partial.decode("utf-8", "ignore") if e.partial else ""
            except Exception as e:
                last_err = e
                continue
        # 都失败则抛最后的异常
        if last_err:
            raise last_err
        return ""

    def _parse_cards(self, html):
        vods = []
        seen = set()
        # 折中：严格优先（带 class）、放宽兜底
        # 1. 先用严 regex（含 class）抓
        strict_pat = r'<a[^>]*class="flex aspect-w-16[^"]*"[^>]*href="(/videos/(?!cate/)[^"]*?/vd-[A-Za-z0-9-]+/?)"[^>]*>(.*?)</a>'
        # 2. 宽 regex（不依赖 class）
        loose_pat = r'<a[^>]*href="(/videos/(?!cate/)[^"]*?/vd-[A-Za-z0-9-]+/?)"[^>]*>(.*?)</a>'
        matches = list(re.finditer(strict_pat, html, re.S))
        if not matches:
            # 严的抓到 0 条，才 fallback 到宽的
            matches = list(re.finditer(loose_pat, html, re.S))
        for m in matches:
            href, inner = m.group(1), m.group(2)
            if href in seen:
                continue
            seen.add(href)
            # 标题：img alt
            tm = re.search(r'alt="([^"]{2,80})"', inner)
            title = tm.group(1).strip() if tm else ""
            # 封面两级：data-src（真图）-> src（过滤占位图）
            pm = re.search(r'data-src="(https?://[^"]+)"', inner)
            pic = pm.group(1) if pm else ""
            if not pic:
                pm = re.search(r'src="((?:https?://|/)[^"]+\.(?:jpg|jpeg|png|webp))"', inner)
                pic = pm.group(1) if pm else ""
            if "poster_loading" in pic or "loading" in pic.split("/")[-1]:
                pic = ""
            # 校验：inner 必须有 data-src 或 alt，否则扔掉（防宽 regex 误抓）
            if 'data-src=' not in inner and 'alt="' not in inner:
                continue
            # 时长
            dm = re.search(r'rounded-large[^"]*">([^<]{1,10})</div>', inner)
            dur = dm.group(1).strip() if dm else ""
            # vod_id 用完整 href（详情需要分类 slug）
            if title:
                vods.append({
                    "vod_id": href,
                    "vod_name": title,
                    "vod_pic": _proxy_img(pic),
                    "vod_remarks": dur,
                })
        return vods

    def _parse_moviesets(self, html):
        """合集列表页：/moviesets/{slug}/ 条目"""
        vods = []
        seen = set()
        for m in re.finditer(r'href="(/moviesets/[A-Za-z0-9-]+/?)"', html):
            href = m.group(1)
            if href in seen or href.rstrip("/") == "/moviesets":
                continue
            seen.add(href)
            seg = html[m.start():m.start() + 6000]
            # 标题在 h2/h3
            tm = re.search(r"<h[23][^>]*>(.*?)</h[23]>", seg, re.S)
            title = re.sub(r"<[^>]+>", "", tm.group(1)).strip() if tm else ""
            # 封面
            pm = re.search(r'data-src="(https?://[^"]+)"', seg)
            pic = pm.group(1) if pm else ""
            if not pic:
                pm = re.search(r'src="((?:https?://|/)[^"]+\.(?:jpg|jpeg|png|webp))"', seg)
                pic = pm.group(1) if pm else ""
            # 集数：X部
            rm = re.search(r">(\d+部)<", seg)
            remark = rm.group(1) if rm else ""
            if title:
                vods.append({
                    "vod_id": "movieset:" + href,
                    "vod_name": title,
                    "vod_pic": _proxy_img(pic),
                    "vod_remarks": remark,
                })
        return vods

    def homeContent(self, filter=None):
        cats = [
            {"type_id": "popular", "type_name": "当前最热"},
            {"type_id": "new", "type_name": "最近更新"},
            {"type_id": "guochan-sm", "type_name": "国产SM"},
            {"type_id": "rihan-sm", "type_name": "日韩SM"},
            {"type_id": "oumei-sm", "type_name": "欧美SM"},
            {"type_id": "dongman-sm", "type_name": "动漫SM"},
            {"type_id": "tiaojiao-av", "type_name": "调教AV"},
            {"type_id": "zhibo-huifang", "type_name": "直播回放"},
            {"type_id": "all", "type_name": "AI全部"},
            {"type_id": "ai-duanju", "type_name": "AI成人短剧"},
            {"type_id": "ai-manju", "type_name": "AI漫剧"},
            {"type_id": "ai-huanlian", "type_name": "AI换脸"},
            {"type_id": "ai-meinv", "type_name": "AI美女"},
            {"type_id": "moviesets", "type_name": "精选合集"},
        ]
        try:
            html = self._get(HOST + "/videos/guochan-sm/")
            vods = self._parse_cards(html)
        except Exception:
            vods = []
        return {"class": cats, "list": vods}

    def homeVideoContent(self):
        return {"list": []}

    def _cat_url(self, tid, pg):
        # 不同分类路径不同：/videos/{slug}/、/ai/{slug}/、/moviesets/
        if tid == "moviesets":
            base = "%s/moviesets/" % HOST
        elif tid == "all":
            base = "%s/ai/all/" % HOST
        elif tid.startswith("ai-"):
            base = "%s/ai/%s/" % (HOST, tid)  # ai-duanju -> /ai/ai-duanju/
        else:
            base = "%s/videos/%s/" % (HOST, tid)
        if pg > 1:
            base += "page/%d/" % pg
        return base

    def categoryContent(self, tid, pg, filter=None, extend=None):
        pg = int(pg) if str(pg).isdigit() else 1
        url = self._cat_url(tid, pg)
        try:
            html = self._get(url)
            if tid == "moviesets":
                vods = self._parse_moviesets(html)
            else:
                vods = self._parse_cards(html)
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": pg,
            "pagecount": 9999,
            "limit": 24,
            "total": 999999,
        }

    def _movieset_detail(self, path):
        """合集内页：视频列表做成选集"""
        vod = {"vod_id": "movieset:" + path, "vod_name": "", "vod_pic": "",
               "vod_play_from": "玩物", "vod_play_url": ""}
        try:
            html = self._get(HOST + path, referer=HOST + "/")
            m = re.search(r"<title>([^<|]+)", html)
            vod["vod_name"] = m.group(1).strip() if m else path
            # 内页视频链接（/videos/cate/vd-xxx/ 或 /videos/{slug}/vd-xxx/）
            eps = []
            seen = set()
            for vm in re.finditer(r'href="((?:/videos/(?!cate/)[a-z0-9-]+/vd-[A-Za-z0-9-]+/?))"', html):
                vh = vm.group(1)
                if vh in seen:
                    continue
                seen.add(vh)
                # 取标题（链接附近的文字）
                seg = html[vm.start():vm.start() + 3000]
                tm = re.search(r'alt="([^"]{2,60})"', seg)
                title = tm.group(1).strip() if tm else vh
                eps.append("%s$%s" % (title[:30], vh))
                if len(eps) >= 100:
                    break
            vod["vod_play_url"] = "#".join(eps)
        except Exception:
            pass
        return {"list": [vod]}
    
    def detailContent(self, ids):
        href = ids[0] if ids else ""
        # 合集：vod_id = "movieset:/moviesets/xxx/"，内页视频做成选集
        if href.startswith("movieset:"):
            return self._movieset_detail(href[9:])
        vod = {"vod_id": href, "vod_name": "", "vod_pic": "",
               "vod_play_from": "玩物", "vod_play_url": ""}
        try:
            url = href if href.startswith("http") else HOST + href
            html = self._get(url, referer=HOST + "/")
            # 标题
            m = re.search(r"<title>([^<|]+)", html)
            title = m.group(1).strip() if m else ""
            # embed id
            em = re.search(r"/videos/embed\?id=(\d+)", html)
            embed_id = em.group(1) if em else ""
            # 封面（详情页可能有 og:image）
            pm = re.search(r'<meta property="og:image" content="([^"]+)"', html)
            pic = pm.group(1) if pm else ""
            vod["vod_name"] = title
            vod["vod_pic"] = _proxy_img(pic)
            if embed_id:
                vod["vod_play_url"] = "正片$embed:%s" % embed_id
            else:
                vod["vod_play_url"] = "正片$href:%s" % href
        except Exception:
            pass
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg="1"):
        from urllib.parse import quote
        pg = int(pg) if str(pg).isdigit() else 1
        url = "%s/videos/search/%s/" % (HOST, quote(key))
        if pg > 1:
            url += "page/%d/" % pg
        try:
            html = self._get(url)
            vods = self._parse_cards(html)
        except Exception:
            vods = []
        return {"list": vods}

    def playerContent(self, flag, id, vipFlags=None):
        # id 格式：embed:{数字ID} 或 href:{详情href}
        embed_id = ""
        if id.startswith("embed:"):
            embed_id = id[6:]
        elif id.startswith("href:"):
            try:
                href = id[5:]
                url = href if href.startswith("http") else HOST + href
                html = self._get(url, referer=HOST + "/")
                em = re.search(r"/videos/embed\?id=(\d+)", html)
                if em:
                    embed_id = em.group(1)
            except Exception:
                pass
        if embed_id:
            try:
                html = self._get(
                    "%s/videos/embed?id=%s" % (HOST, embed_id),
                    referer=HOST + "/")
                m = re.search(r'<source src="([^"]+\.m3u8[^"]*)"', html)
                if m:
                    m3u8 = m.group(1)
                    return {
                        "parse": 0,
                        "url": m3u8,
                        "header": {
                            "User-Agent": UA,
                            "Referer": HOST + "/",
                        },
                    }
            except Exception:
                pass

        # 兜底：embed 页交给 Hawk 嗅探
        if embed_id:
            return {"parse": 1,
                    "url": "%s/videos/embed?id=%s" % (HOST, embed_id)}
        return {"parse": 1, "url": HOST + "/"}


if __name__ == "__main__":
    sp = Spider()
    print("== home ==")
    h = sp.homeContent(None)
    print("分类:", [c["type_name"] for c in h["class"]])
    print("首页:", len(h["list"]), "条")
    if h["list"]:
        v = h["list"][0]
        print("首条:", v["vod_name"][:40])
        print("封面:", v["vod_pic"][:80])
        print("时长:", v["vod_remarks"])
    print("\n== category rihan-sm ==")
    c = sp.categoryContent("rihan-sm", "1", None, None)
    print("日韩:", len(c["list"]), "条")
    print("\n== search ==")
    s = sp.searchContent("黑丝", False, "1")
    print("搜索黑丝:", len(s["list"]), "条")
    if h["list"]:
        print("\n== detail ==")
        d = sp.detailContent([h["list"][0]["vod_id"]])
        print("标题:", d["list"][0]["vod_name"][:40])
        print("播放:", d["list"][0]["vod_play_url"][:40])
        print("\n== player ==")
        p = sp.playerContent("玩物", d["list"][0]["vod_play_url"].split("$")[-1], None)
        print("parse:", p["parse"])
        print("url:", p["url"][:100])
