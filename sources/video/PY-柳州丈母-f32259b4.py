# LumeSource: {"id":"pypack_daf13bb5f32259b4","name":"柳州丈母","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import re
import json
import ssl
import html as html_lib
import urllib.request
import urllib.parse
import gzip
import zlib

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass


class Spider(BaseSpider):

    def __init__(self):
        super(Spider, self).__init__()
        self.host = "https://913453.lzzmn101.top"
        self.base = self.host + "/lzzmn"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Referer": self.base + "/",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "close"
        }

    def getName(self):
        return "柳州丈母"

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def _get(self, url):
        try:
            ctx = ssl._create_unverified_context()
        except Exception:
            ctx = None

        req = urllib.request.Request(url, headers=self.headers)
        for _ in range(3):
            try:
                if ctx:
                    resp = urllib.request.urlopen(req, context=ctx, timeout=12)
                else:
                    resp = urllib.request.urlopen(req, timeout=12)

                raw_data = resp.read()
                encoding = resp.headers.get("Content-Encoding", "").lower()
                if "gzip" in encoding:
                    try:
                        return gzip.decompress(raw_data).decode("utf-8", "ignore")
                    except Exception:
                        return raw_data.decode("utf-8", "ignore")
                elif "deflate" in encoding:
                    try:
                        return zlib.decompress(raw_data).decode("utf-8", "ignore")
                    except Exception:
                        return raw_data.decode("utf-8", "ignore")
                else:
                    return raw_data.decode("utf-8", "ignore")
            except Exception:
                continue
        return ""

    def _abs(self, u):
        if not u:
            return ""
        if u.startswith("http://") or u.startswith("https://"):
            return u
        if u.startswith("//"):
            return "https:" + u
        if u.startswith("/"):
            return self.host + u
        return self.base + "/" + u

    def _pick_pic(self, block):
        for attr in ["data-original", "data-src", "src"]:
            m = re.search(r'<img[^>]*?\b' + attr + r'=["\']([^"\']+)["\']', block)
            if m:
                u = m.group(1).strip()
                if not u or "data:image" in u:
                    continue
                low = u.lower()
                if any(k in low for k in ["loading", "load.svg", "placeholder", "blank"]):
                    continue
                return self._abs(u)
        return ""

    def _cards(self, h):
        lst = []
        seen = set()
        for m in re.finditer(r'<li>(.*?)</li>', h, re.S):
            block = m.group(1)
            um = re.search(r'href=["\'](/lzzmn/index\.php/vod/detail/id/(\d+)\.html)["\']', block)
            if not um:
                continue
            vid = um.group(2)
            if vid in seen:
                continue
            seen.add(vid)
            nm = re.search(r'<h5><a[^>]*>([^<]+)</a></h5>', block)
            name = html_lib.unescape(nm.group(1).strip()) if nm else ""
            if not name:
                continue

            lst.append({
                "vod_id": vid,
                "vod_name": name,
                "vod_pic": self._pick_pic(block),
                "vod_remarks": "蝴蝶影视 | 高清",
                "style": {"type": "rect", "ratio": 1.78}
            })
        return lst

    def homeContent(self, filter):
        try:
            h = self._get(self.base + "/")
            cats = []
            seen = set()
            for m in re.finditer(r'<div class="category-subs">(.*?)</div>', h, re.S):
                for cid, n in re.findall(r'href="/lzzmn/index\.php/vod/type/id/(\d+)\.html"[^>]*>([^<]+)</a>', m.group(1)):
                    name = n.strip()
                    if cid in seen or not name:
                        continue
                    seen.add(cid)
                    cats.append({"type_id": str(cid), "type_name": html_lib.unescape(name)})
            return {"class": cats, "filters": {}}
        except Exception:
            return {"class": [], "filters": {}}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        try:
            page_num = int(pg) if str(pg).isdigit() else 1
            if page_num <= 1:
                url = "%s/index.php/vod/type/id/%s.html" % (self.base, tid)
            else:
                url = "%s/index.php/vod/type/id/%s/page/%d.html" % (self.base, tid, page_num)
            h = self._get(url)
            lst = self._cards(h)
            return {
                "list": lst,
                "page": page_num,
                "pagecount": page_num + 1 if len(lst) >= 12 else page_num,
                "limit": 20,
                "total": 9999
            }
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}

    def detailContent(self, ids):
        try:
            vid = ids[0] if isinstance(ids, list) else ids
            h = self._get("%s/index.php/vod/detail/id/%s.html" % (self.base, vid))
            t = re.search(r'<title>([^<]+)</title>', h)
            name = ""
            if t:
                name = html_lib.unescape(t.group(1).split("在线播放")[0].split("-")[0].strip())
            plays = []
            for u, n in re.findall(r'href=["\'](/lzzmn/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)["\'][^>]*>([^<]{1,15})</a>', h):
                n = html_lib.unescape(n.strip())
                if n and u and "thumbnail" not in h[max(0, h.find(u) - 200):h.find(u)]:
                    plays.append("%s$%s" % (n, self._abs(u)))
            seen_url = set()
            uniq_plays = []
            for p in plays:
                u = p.split("$", 1)[1]
                if u not in seen_url:
                    seen_url.add(u)
                    uniq_plays.append(p)

            vod = {
                "vod_id": vid,
                "vod_name": name,
                "vod_pic": self._pick_pic(h),
                "type_name": "蝴蝶专区",
                "vod_year": "2026",
                "vod_area": "华语",
                "vod_remarks": "蝴蝶影视 | 高清原画",
                "vod_actor": "🦋 TG群: @tvshare23",
                "vod_director": "🦋 蝴蝶影视",
                "vod_content": "🦋 蝴蝶影视 | TG群: @tvshare23\n蝴蝶影视官方正版资源，关注TG群获取最新动态与防失联地址。",
                "vod_play_from": "蝴蝶秒播云",
                "vod_play_url": "#".join(uniq_plays) if uniq_plays else "正片$%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (self.base, vid)
            }
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick, pg="1"):
        try:
            url = "%s/index.php/vod/search/wd/%s.html" % (self.base, urllib.parse.quote(key, safe=""))
            h = self._get(url)
            return {"list": self._cards(h)}
        except Exception:
            return {"list": []}

    def _parse_player_json(self, h, varname):
        idx = h.find("var %s=" % varname)
        if idx < 0:
            return None
        seg = h[idx:idx + 12000]
        start = seg.find("{")
        if start < 0:
            return None
        depth = 0
        for i, c in enumerate(seg[start:], start):
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(seg[start:i + 1])
                    except Exception:
                        return None
        return None

    def _decode_url(self, url, encrypt):
        if not url:
            return ""
        try:
            if encrypt == 1:
                return urllib.parse.unquote(url)
            if encrypt == 2:
                import base64
                return urllib.parse.unquote(base64.b64decode(urllib.parse.unquote(url)).decode("utf-8", "ignore"))
        except Exception:
            pass
        return url

    def _extract_play_url(self, h):
        for varname in ["player_aaaa", "player_data"]:
            data = self._parse_player_json(h, varname)
            if data and data.get("url"):
                u = self._decode_url(data["url"], data.get("encrypt", 0))
                if u:
                    return u
        m = re.search(r'MacPlayer\.PlayUrl\s*=\s*["\']([^"\']+)["\']', h)
        if m and m.group(1).strip():
            return m.group(1).strip()
        m = re.search(r'<iframe[^>]+src=["\']([^"\']+)["\']', h)
        if m:
            return m.group(1)
        for m in re.finditer(r'"url"\s*:\s*"([^"]+)"', h):
            u = m.group(1).replace("\\/", "/").replace("\\", "")
            if re.search(r'\.(?:m3u8|mp4)(\?|$)', u) and u.startswith("http"):
                return u
        return ""

    def playerContent(self, flag, id, vipFlags):
        try:
            h = self._get(id)
            url = self._extract_play_url(h)
            if not url:
                return {"parse": 1, "playUrl": "", "url": id}

            if url.startswith("/"):
                url = self._abs(url)

            if not re.search(r'\.(?:m3u8|mp4)(\?|$)', url, re.I):
                share_h = self._get(url)
                if share_h:
                    dp_m = re.search(r'url\s*:\s*["\']([^"\']+\.m3u8[^"\']*)["\']', share_h, re.I)
                    if not dp_m:
                        dp_m = re.search(r'["\'](https?://[^"\']+\.m3u8[^"\']*)["\']', share_h, re.I)
                    if dp_m:
                        url = dp_m.group(1).replace("\\/", "/")

            return {
                "parse": 0,
                "playUrl": "",
                "url": url,
                "header": json.dumps({"User-Agent": "Mozilla/5.0", "Referer": id})
            }
        except Exception:
            return {"parse": 1, "playUrl": "", "url": id}

    def isVideoFormat(self, url):
        u = url.split("?")[0].lower()
        return u.endswith(".m3u8") or u.endswith(".mp4")

    def localProxy(self, params):
        return [200, "text/plain; charset=utf-8", ""]

    def action(self, action):
        return {}

    def liveContent(self):
        return {}

    def manualVideoCheck(self):
        return False