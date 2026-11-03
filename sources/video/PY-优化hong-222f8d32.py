# LumeSource: {"id":"pypack_080362d6222f8d32","name":"优化hong","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-

import re
import json
import ssl
import urllib.parse
import urllib.request
from urllib.parse import quote
from base.spider import Spider as BaseSpider

# 预创建全局 SSL 上下文，避免每次 localProxy 请求重复初始化，加快握手速度
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE


def _fix_key_uri(ln, playlist_url):
    s = ln.strip()
    if s.startswith("#EXT-X-KEY:"):
        m = re.search(r'URI="([^"]+)"', ln)
        if m and not m.group(1).lower().startswith("http"):
            absu = urllib.parse.urljoin(playlist_url, m.group(1))
            ln = ln.replace('URI="%s"' % m.group(1), 'URI="%s"' % absu)
    return ln


def _strip_ad(text, playlist_url):
    """去除广告段落逻辑，运算仅需毫秒级"""
    text = (text or "").replace("\r", "")
    lines = text.split("\n")
    
    head_end = len(lines)
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.startswith("#EXTINF") or (s and not s.startswith("#")):
            head_end = i
            break
    head = [_fix_key_uri(ln, playlist_url) for ln in lines[:head_end]]
    body = lines[head_end:]

    segs = []
    pending = None
    for idx, ln in enumerate(body):
        s = ln.strip()
        if s.startswith("#EXTINF"):
            try:
                dur = float(s.split(":", 1)[1].split(",", 1)[0])
            except Exception:
                dur = 0.0
            pending = (idx, dur)
        elif pending is not None and s and not s.startswith("#"):
            segs.append({
                "dur": pending[1],
                "abs": urllib.parse.urljoin(playlist_url, s),
                "extinf_idx": pending[0],
                "uri_idx": idx
            })
            pending = None

    def _path(sg):
        return sg["abs"].rsplit("/", 1)[0]

    drop_idx = set()
    dropped = 0
    if segs:
        stat = {}
        for sg in segs:
            k = _path(sg)
            stat[k] = stat.get(k, 0.0) + sg["dur"]
        total = sum(stat.values())
        main_key = max(stat.items(), key=lambda x: x[1])[0]
        ad_dur = total - stat[main_key]
        
        if 0 < ad_dur < total * 0.5:
            for sg in segs:
                if _path(sg) != main_key:
                    drop_idx.add(sg["extinf_idx"])
                    drop_idx.add(sg["uri_idx"])
                    dropped += 1
                    
        if not drop_idx:
            cut = None
            for i, ln in enumerate(body):
                if ln.strip() == "#EXT-X-DISCONTINUITY":
                    cut = i
                    break
            if cut is not None:
                first_dur = sum(sg["dur"] for sg in segs if sg["uri_idx"] < cut)
                if 0 < first_dur <= 180:
                    for sg in segs:
                        if sg["uri_idx"] < cut:
                            drop_idx.add(sg["extinf_idx"])
                            drop_idx.add(sg["uri_idx"])
                            dropped += 1

    orig_disc = sum(1 for ln in body if ln.strip() == "#EXT-X-DISCONTINUITY")
    out = []
    need_disc = False
    emitted_seg = False
    pending_tags = []
    
    for idx, ln in enumerate(body):
        if idx in drop_idx:
            continue
        s = ln.strip()
        if s == "#EXT-X-DISCONTINUITY":
            need_disc = True
            continue
        if s.startswith("#EXTINF"):
            if need_disc and emitted_seg:
                out.append("#EXT-X-DISCONTINUITY")
            for t in pending_tags:
                if not out or out[-1] != t:
                    out.append(t)
            pending_tags = []
            need_disc = False
            out.append(ln)
            continue
        if s.startswith("#"):
            ln = _fix_key_uri(ln, playlist_url)
            if need_disc:
                pending_tags.append(ln)
            else:
                out.append(ln)
            continue
        if s:
            out.append(urllib.parse.urljoin(playlist_url, s))
            emitted_seg = True
            continue
        out.append(ln)
    out.extend(pending_tags)

    text = "\n".join(head + out)
    if dropped:
        text = re.sub(r"#EXT-X-MEDIA-SEQUENCE:\d+",
                      "#EXT-X-MEDIA-SEQUENCE:%d" % dropped, text, count=1)
        new_disc = out.count("#EXT-X-DISCONTINUITY")
        if orig_disc > new_disc:
            def _dec_seq(m):
                v = int(m.group(1)) - (orig_disc - new_disc)
                return "#EXT-X-DISCONTINUITY-SEQUENCE:%d" % max(v, 0)
            text = re.sub(r"#EXT-X-DISCONTINUITY-SEQUENCE:(\d+)", _dec_seq, text, count=1)
    return text


class Spider(BaseSpider):
    CATS = [
        ("1", "三级电影"), ("2", "传媒剧情"), ("6", "欧美无码"),
        ("7", "主播自慰"), ("8", "制服诱惑"), ("9", "强奸乱伦"),
        ("10", "中文字幕"), ("11", "AI明星"),
    ]

    _LI = re.compile(r'<li>\s*<a href="/index\.php/vod/detail/id/(\d+)\.html"[^>]*title="([^"]*)"[^>]*>\s*<img[^>]*data-original="([^"]*)"', re.S)
    _PAGE = re.compile(r'/page/(\d+)\.html')
    _TITLE = re.compile(r'<title>(.*?)</title>', re.S)
    _TITLE_CLEAN = re.compile(r'(详情介绍|在线观看|迅雷下载).*$')
    _DESC = re.compile(r'<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)</div>', re.S)
    _PLAY_LINK = re.compile(r'<a[^>]*href="(/index\.php/vod/play/id/\d+/sid/\d+/nid/\d+\.html)"[^>]*>([^<]*)</a>')
    
    # 恢复高兼容的正侧，防止部分特殊页面结构解析为空
    _PLAYER = re.compile(r'player_aaaa\s*=\s*(\{.*?\})', re.S)
    _M3U8_FALLBACK = re.compile(r'https?://[^\s"\'<>]+\.m3u8[^\s"\'<>]*')

    def getName(self):
        return "Haohaogan"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self.extend = extend or ""
        self.host = "https://www.pingguodiannao.shop"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Referer": self.host + "/",
        }

    def isVideoFormat(self, url):
        if not url: return False
        return bool(re.search(r'\.(m3u8|mp4|flv|ts|mkv|avi|mov)(\?|$)', str(url), re.I))

    def manualVideoCheck(self):
        return False

    def destroy(self):
        pass

    def _get(self, url, headers=None):
        # 恢复使用原生的 fetch 接口，兼容所有的 TVBox 壳子环境
        for _ in range(2):
            try:
                res = self.fetch(url, headers=headers or self.headers)
                if res:
                    text = getattr(res, "text", None)
                    if text is None and hasattr(res, "content"):
                        text = res.content.decode("utf-8", "ignore")
                    if text and len(text) > 200:
                        return text
            except Exception:
                pass
        return ""

    def parse_list(self, html):
        if not html: return []
        items, seen = [], set()
        for m in self._LI.finditer(html):
            vid, title, pic = m.group(1), m.group(2), m.group(3)
            if vid not in seen:
                seen.add(vid)
                items.append({"vod_id": vid, "vod_name": title.strip(), "vod_pic": pic})
        return items

    def homeContent(self, filter=None):
        return {"class": [{"type_id": cid, "type_name": cname} for cid, cname in self.CATS], "filters": {}}

    def homeVideoContent(self):
        html = self._get(self.host + "/")
        return {"list": self.parse_list(html)}

    def categoryContent(self, tid, pg, filter=None, extend=None):
        pg = max(1, int(pg or 1))
        url = f"{self.host}/index.php/vod/type/id/{tid}.html" if pg == 1 else f"{self.host}/index.php/vod/type/id/{tid}/page/{pg}.html"
        html = self._get(url)
        items = self.parse_list(html)
        if not items:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 24, "total": 0}
        nums = [int(n) for n in self._PAGE.findall(html)]
        pc = max(nums) if nums else 999
        return {"list": items, "page": pg, "pagecount": pc, "limit": 24, "total": pc * 24}

    def detailContent(self, ids):
        vid = str(ids[0] if isinstance(ids, (list, tuple)) else ids)
        url = f"{self.host}/index.php/vod/detail/id/{vid}.html"
        html = self._get(url)
        if not html:
            return {"list": []}
            
        tm = self._TITLE.search(html)
        title = self._TITLE_CLEAN.sub("", re.sub(r"\s+", " ", tm.group(1)).strip()).strip() if tm else ""
        dm = self._DESC.search(html)
        desc = re.sub(r"<[^>]+>", "", dm.group(1)).strip() if dm else ""
        
        plays = self._PLAY_LINK.findall(html)
        if not plays:
            play_url = f"正片${self.host}/index.php/vod/play/id/{vid}/sid/1/nid/1.html"
        else:
            play_urls, seen_u = [], set()
            for href, txt in plays:
                if href not in seen_u:
                    seen_u.add(href)
                    ep_name = txt.strip() or f"线路{len(play_urls) + 1}"
                    play_urls.append(f"{ep_name}${self.host}{href}")
            play_url = "#".join(play_urls)
            
        return {"list": [{"vod_id": vid, "vod_name": title, "vod_pic": "", "vod_content": desc, "vod_play_from": "Haohaogan", "vod_play_url": play_url}]}

    def searchContent(self, key, quick=False, pg="1"):
        pg_n = max(1, int(pg or 1))
        url = f"{self.host}/index.php/vod/search.html?wd={quote(key)}&page={pg_n}"
        return {"list": self.parse_list(self._get(url)), "page": pg_n, "limit": 24}

    def _proxy_base(self):
        try:
            if hasattr(self, "getProxyUrl"):
                base = self.getProxyUrl() or ""
                if base: return base
        except Exception:
            pass
        return "http://127.0.0.1:9978/proxy?do=py"

    def playerContent(self, flag, id, vipFlags=None):
        full_url = id if str(id).startswith("http") else self.host + str(id)
        stream, play_page = "", full_url

        if re.search(r'\.(m3u8|mp4)(\?|$)', full_url, re.I):
            stream, play_page = full_url, self.host + "/"
        else:
            html = self._get(full_url)
            if html:
                m = self._PLAYER.search(html)
                if m:
                    try:
                        stream = (json.loads(m.group(1)).get("url") or "").replace("\\/", "/")
                    except Exception:
                        pass
                if not stream:
                    mb = self._M3U8_FALLBACK.search(html)
                    if mb: stream = mb.group(0)

        if not stream:
            return {"parse": 1, "url": full_url, "header": self.headers}

        referer = play_page or (self.host + "/")
        req_headers = {"User-Agent": self.headers["User-Agent"], "Referer": referer}

        if ".m3u8" in stream:
            base = self._proxy_base()
            sep = "&" if "?" in base else "?"
            
            # 【保留提速大招】：尾部加上 &ext=.m3u8
            # 这能骗过 ExoPlayer 强制其直接走 HLS 解析流，省去几秒钟的盲猜探测时间
            proxy_url = "%s%stype=ak_adfree&url=%s&referer=%s&ext=.m3u8" % (
                base, sep, urllib.parse.quote(stream, safe=""), urllib.parse.quote(referer, safe="")
            )
            return {"parse": 0, "playUrl": "", "url": proxy_url, "header": req_headers}

        return {"parse": 0, "url": stream, "header": req_headers}

    def localProxy(self, params):
        # 恢复高兼容性的字典参数解析逻辑
        try:
            if not isinstance(params, dict):
                params = {}

            def _first(d, *ks):
                for k in ks:
                    v = d.get(k)
                    if v:
                        return v[0] if isinstance(v, list) else v
                return ""

            action = _first(params, "type", "do", "action")
            if action != "ak_adfree":
                return [404, "text/plain", "not found"]

            m3u8_url = urllib.parse.unquote(_first(params, "url"))
            referer = urllib.parse.unquote(_first(params, "referer")) or (self.host + "/")
            if not m3u8_url.startswith("http"):
                return [404, "text/plain", "bad url"]

            # 使用最稳定的 urllib 避免环境缺失报错
            h = {"User-Agent": self.headers["User-Agent"], "Referer": referer}
            req = urllib.request.Request(m3u8_url, headers=h)
            
            with urllib.request.urlopen(req, timeout=10, context=_SSL_CTX) as r:
                text = r.read().decode("utf-8", "ignore")

            # 处理内嵌二级 m3u8
            if "#EXT-X-STREAM-INF" in text:
                mm = re.search(r"^(?!#)(.+\.m3u8.*)$", text, re.M)
                if mm:
                    sub = urllib.parse.urljoin(m3u8_url, mm.group(1).strip())
                    req2 = urllib.request.Request(sub, headers=h)
                    with urllib.request.urlopen(req2, timeout=10, context=_SSL_CTX) as r2:
                        text = r2.read().decode("utf-8", "ignore")
                    m3u8_url = sub

            clean_m3u8 = _strip_ad(text, m3u8_url)
            return [200, "application/vnd.apple.mpegurl", clean_m3u8]
        except Exception as e:
            return [500, "text/plain", "proxy error: %s" % e]