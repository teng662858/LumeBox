# LumeSource: {"id":"pypack_f837697be39f3e55","name":"huajy_v1_0","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
# TVBox Python 影视源：花街影院（jx2huajy55.a6.yachts）v1.0
# ============================================================
# 站点：MacCMS index.php 路由，全站 HTML 经双重 base64 包在 var str 中
# 分类：/index.php/vod/type/id/{id}.html，翻页 /index.php/vod/type/id/{id}/page/{pg}.html
# 卡片：<li class="content-item"> -> /index.php/vod/detail/id/{id}.html
# 详情：/index.php/vod/detail/id/{id}.html -> 播放页 /index.php/vod/play/id/{id}/sid/1/nid/1.html
# 播放页 var player_aaaa JSON，encrypt=0，url 即 m3u8 明文
# 搜索：/index.php/vod/search.html?wd={kw}
import sys
import ssl
import time
import json
import re
import base64
import urllib.request
import urllib.parse
from http.cookiejar import CookieJar

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass

class Spider(BaseSpider):
    def __init__(self):
        self.site_url = "https://jx2huajy55.a6.yachts"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
        self.cookie_jar = CookieJar()
        self.opener = self._build_opener()
        self._throttle = 0.5
        self._last_req = 0.0
        # 41个分类（首页导航全量）
        self.cats = [
            ("3", "黑料吃瓜"), ("4", "厂牌原创"), ("5", "国产精选"),
            ("6", "明星换脸"), ("7", "AV解说"), ("8", "禁漫精选"),
            ("9", "乱伦"), ("10", "父女"), ("11", "母子"),
            ("12", "兄妹"), ("13", "学生"), ("14", "嫂子"),
            ("15", "姐夫"), ("16", "师生"), ("17", "全家"),
            ("18", "猎奇"), ("28", "国产大片"), ("31", "欧美大片"),
            ("32", "网红直播"), ("33", "探花约炮"), ("34", "三级伦理"),
            ("35", "萝莉开苞"), ("66", "有声小说"), ("68", "cosplay"),
            ("69", "AI魔改"), ("70", "av综艺"), ("72", "嫩妹下海"),
            ("74", "每日甄选"), ("76", "ts人妖"), ("77", "姿势玩法"),
            ("78", "同性恋"), ("79", "真实缅北"), ("80", "恶心恐怖"),
            ("81", "黄金圣水"), ("82", "校园霸凌"), ("83", "战场实录"),
            ("84", "人兽乱交"), ("85", "灵异视频"), ("86", "N号房"),
            ("87", "日韩大片"), ("88", "SM调教"),
        ]

    def _build_opener(self):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        https_handler = urllib.request.HTTPSHandler(context=ctx)
        cookie_handler = urllib.request.HTTPCookieProcessor(self.cookie_jar)
        return urllib.request.build_opener(https_handler, cookie_handler)

    def _fetch(self, url, retry=2, referer=None):
        headers = dict(self.headers)
        if referer:
            headers["Referer"] = referer
        gap = time.time() - self._last_req
        if gap < self._throttle:
            time.sleep(self._throttle - gap)
        self._last_req = time.time()
        import http.client
        for i in range(retry + 1):
            try:
                req = urllib.request.Request(url, headers=headers)
                with self.opener.open(req, timeout=12) as resp:
                    raw = resp.read()
                    try:
                        html = raw.decode("utf-8", errors="ignore")
                    except Exception:
                        html = ""
                    return {"success": True, "html": html}
            except http.client.IncompleteRead as e:
                if e.partial:
                    try:
                        h = e.partial.decode("utf-8", errors="ignore")
                    except Exception:
                        h = ""
                    return {"success": True, "html": h}
            except Exception:
                if i < retry:
                    time.sleep(0.5)
        return {"success": False, "html": ""}

    def _decode_page(self, html_data):
        """本站全站双重 base64，解出真实 HTML"""
        if not html_data:
            return ""
        m = re.search(r"var str = '([^']+)'", html_data)
        if not m:
            return html_data
        try:
            d1 = base64.b64decode(m.group(1)).decode("utf-8", errors="ignore")
            d2 = base64.b64decode(d1.strip()).decode("utf-8", errors="ignore")
            return d2 if len(d2) > 1000 else html_data
        except Exception:
            return html_data

    def _fetch_html(self, url, must_contain=None, referer=None):
        html_data = ""
        for _ in range(3):
            res = self._fetch(url, referer=referer)
            raw = res.get("html", "")
            html_data = self._decode_page(raw)
            if res.get("success") and (not must_contain
                                       or must_contain in html_data):
                return html_data
        return html_data

    @staticmethod
    def _clean(text):
        if not text:
            return ""
        import html as html_mod
        text = html_mod.unescape(text)
        return re.sub(r"<[^>]+>", "", text).strip()

    def _abs_url(self, url):
        if not url:
            return ""
        url = url.strip()
        if url.startswith("http"):
            return url
        if url.startswith("//"):
            return "https:" + url
        return urllib.parse.urljoin(self.site_url, url)

    def _extract_cover(self, inner):
        """封面提取：优先懒加载属性，过滤占位图"""
        if not inner:
            return ""
        for im in re.finditer(r"<img[^>]+>", inner, re.I):
            tag = im.group(0)
            for attr in ("data-original", "data-src", "data-lazy-src",
                         "data-echo", "srcset", "src"):
                am = re.search(r'%s\s*=\s*["\']([^"\']+)["\']' % attr,
                              tag, re.I)
                if not am:
                    continue
                cand = am.group(1).strip().split()[0]
                if not cand or cand.startswith("data:"):
                    continue
                low = cand.lower()
                if any(k in low for k in ("loading.gif", "placeholder",
                                          "blank.", "pixel.", "spinner")):
                    continue
                return self._abs_url(cand)
        return ""

    def _parse_vod_list(self, html_data):
        cards, seen = [], set()
        if not html_data:
            return cards
        # <li class="content-item"> 卡片
        for m in re.finditer(
                r'<li[^>]*class="[^"]*content-item[^"]*"[^>]*>(.*?)</li>',
                html_data, re.S | re.I):
            inner = m.group(1)
            am = re.search(
                r'href="(/index\.php/vod/detail/id/(\d+)\.html)"', inner)
            if not am:
                continue
            vid = am.group(2)
            if vid in seen:
                continue
            seen.add(vid)
            title = ""
            tm = re.search(r'title="([^"]{2,120})"', inner)
            if tm:
                title = tm.group(1).strip()
            title = self._clean(title)
            if not title:
                continue
            pic = self._extract_cover(inner)
            cards.append({
                "vod_id": vid,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": "",
            })
        # 兜底：裸扫 detail 链接
        if not cards:
            for m in re.finditer(
                    r'href="(/index\.php/vod/detail/id/(\d+)\.html)"[^>]*'
                    r'title="([^"]{2,120})"', html_data):
                vid = m.group(2)
                if vid in seen:
                    continue
                seen.add(vid)
                seg = html_data[max(0, m.start() - 500):m.end() + 1500]
                cards.append({
                    "vod_id": vid,
                    "vod_name": self._clean(m.group(3)),
                    "vod_pic": self._extract_cover(seg),
                    "vod_remarks": "",
                })
        return cards

    def _extract_play_url(self, html_data):
        """四层兜底提 m3u8"""
        if not html_data:
            return ""
        # 1. player_aaaa JSON
        m = re.search(r'var player_aaaa\s*=\s*(\{.*?\})\s*</script>', html_data,
                      re.S)
        if not m:
            m = re.search(r'var player_aaaa\s*=\s*(\{.*?\});', html_data, re.S)
        if m:
            try:
                # 手动提 url，避免 JSON 截断问题
                um = re.search(r'"url"\s*:\s*"((?:[^"\\]|\\.)*)"',
                               m.group(1))
                if um:
                    url = um.group(1).replace("\\/", "/").strip()
                    if url and self.isVideoFormat(url) \
                            and not self._is_sample(url):
                        return url
            except Exception:
                pass
        # 2. 直扫 m3u8
        for pat in [r'"(https?://[^"]+\.m3u8[^"]*)"',
                    r"'(https?://[^']+\.m3u8[^']*)'"]:
            for mm in re.findall(pat, html_data, re.I):
                u = mm.replace("\\/", "/")
                if self.isVideoFormat(u) and not self._is_sample(u):
                    return u
        # 3. 裸 m3u8
        for mm in re.findall(r'https?://[^\s"\'<>]+\.m3u8[^\s"\'<>]*',
                             html_data, re.I):
            u = mm.replace("\\/", "/")
            if self.isVideoFormat(u) and not self._is_sample(u):
                return u
        return ""

    @staticmethod
    def _is_sample(url):
        low = (url or "").lower()
        return any(k in low for k in ("sample", "test", "preview", "trailer",
                                      "advert"))

    # ============ 标准接口 ============
    def init(self, extend=""):
        pass

    def getName(self):
        return "花街影院"

    def homeContent(self, filter):
        return {"class": [{"type_id": tid, "type_name": name}
                          for tid, name in self.cats],
                "filters": {}}

    def homeVideoContent(self):
        r = self.categoryContent("74", "1", None, None)
        return {"list": r["list"][:20]}

    def _max_page(self, html_data, tid, pg):
        max_pg = pg
        for pm in re.finditer(
                r"/index\.php/vod/type/id/%s/page/(\d+)\.html" % tid,
                html_data):
            try:
                max_pg = max(max_pg, int(pm.group(1)))
            except Exception:
                pass
        return max_pg

    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        if pg <= 1:
            url = "%s/index.php/vod/type/id/%s.html" % (self.site_url, tid)
        else:
            url = "%s/index.php/vod/type/id/%s/page/%d.html" % (
                self.site_url, tid, pg)
        html_data = self._fetch_html(url, must_contain="vod/detail")
        cards = self._parse_vod_list(html_data)
        max_pg = self._max_page(html_data, tid, pg)
        pagecount = max_pg if max_pg > pg else (pg + 1 if cards else pg)
        return {"list": cards, "page": pg, "pagecount": pagecount,
                "limit": len(cards), "total": 0}

    def detailContent(self, ids):
        vid = str(ids[0]).strip() if ids else ""
        if not vid:
            return {"list": []}
        vod = {"vod_id": vid, "vod_name": vid, "vod_pic": "",
               "vod_remarks": "", "vod_content": "",
               "vod_play_from": "在线播放",
               "vod_play_url": "正片$%s/index.php/vod/play/id/%s/sid/1/nid/1.html"
                               % (self.site_url, vid)}
        try:
            # 详情页解码不稳定，直接从播放页取标题+m3u8
            play_url = "%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (
                self.site_url, vid)
            ph = self._fetch_html(play_url, must_contain="player_aaaa",
                                  referer=self.site_url + "/")
            # 从 player_aaaa 取标题
            start = ph.find("var player_aaaa")
            if start >= 0:
                js = ph.find("{", start)
                if js >= 0:
                    depth, i = 0, js
                    while i < len(ph):
                        if ph[i] == "{":
                            depth += 1
                        elif ph[i] == "}":
                            depth -= 1
                            if depth == 0:
                                break
                        i += 1
                    try:
                        cfg = json.loads(ph[js:i + 1])
                        vd = cfg.get("vod_data", {})
                        if vd.get("vod_name"):
                            vod["vod_name"] = self._clean(
                                str(vd["vod_name"]))
                    except Exception:
                        pass
            m3u8 = self._extract_play_url(ph)
            if m3u8:
                vod["vod_play_url"] = "正片$%s" % m3u8
        except Exception:
            pass
        return {"list": [vod]}

    def playerContent(self, flag, id, vipFlags):
        raw_id = str(id).strip()
        header = {"User-Agent": self.headers["User-Agent"],
                  "Referer": self.site_url + "/"}
        if raw_id.startswith("http") and self.isVideoFormat(raw_id):
            return {"parse": 0, "url": raw_id, "header": header}
        try:
            vid = re.sub(r"\D", "", raw_id)
            if vid:
                d = self.detailContent([vid])
                ep = d["list"][0]["vod_play_url"]
                if "$" in ep:
                    u = ep.split("$", 1)[1]
                    if u.startswith("http") and self.isVideoFormat(u):
                        return {"parse": 0, "url": u, "header": header}
        except Exception:
            pass
        return {"parse": 1, "url": raw_id, "header": header}

    def searchContent(self, key, quick, pg="1"):
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        kw = urllib.parse.quote(str(key).strip())
        if pg <= 1:
            url = "%s/index.php/vod/search.html?wd=%s" % (self.site_url, kw)
        else:
            url = "%s/index.php/vod/search/page/%d/wd/%s.html" % (
                self.site_url, pg, kw)
        html_data = self._fetch_html(url, must_contain="vod/detail")
        cards = self._parse_vod_list(html_data)
        return {"list": cards, "page": pg,
                "pagecount": pg + 1 if cards else pg,
                "limit": len(cards), "total": 0}

    def action(self, action):
        return None

    def liveContent(self):
        return {}

    def localProxy(self, params):
        return [200, "text/plain;charset=utf-8", ""]

    def isVideoFormat(self, url):
        u = (url or "").lower()
        return u.endswith(".m3u8") or ".m3u8?" in u

    def manualVideoCheck(self):
        return False

    def destroy(self):
        pass


if __name__ == "__main__":
    sp = Spider()
    ok = True

    def check(name, cond, extra=""):
        global ok
        print(("PASS " if cond else "FAIL ") + name +
              (" | " + str(extra) if extra else ""))
        if not cond:
            ok = False

    # 1. 首页分类
    hc = sp.homeContent(True)
    check("homeContent", len(hc["class"]) == 41, "%d分类" % len(hc["class"]))

    # 2. 分类第1页
    r1 = sp.categoryContent("3", "1", None, None)
    check("category", len(r1["list"]) > 0, "%d条 pagecount=%s"
          % (len(r1["list"]), r1["pagecount"]))

    # 3. 封面
    cov = sum(1 for c in r1["list"] if c["vod_pic"].startswith("http"))
    check("covers", cov == len(r1["list"]) and cov > 0,
          "%d/%d" % (cov, len(r1["list"])))

    # 4. 标题
    tit = sum(1 for c in r1["list"] if c["vod_name"]
              and not c["vod_name"].isdigit())
    check("titles", tit == len(r1["list"]), "%d/%d" % (tit, len(r1["list"])))

    # 5. 第2页零重叠
    r2 = sp.categoryContent("3", "2", None, None)
    ids1 = set(c["vod_id"] for c in r1["list"])
    ids2 = set(c["vod_id"] for c in r2["list"])
    check("page_no_overlap", len(r2["list"]) > 0 and not (ids1 & ids2),
          "p2=%d条" % len(r2["list"]))

    # 6. 搜索
    rs = sp.searchContent("学生", False, "1")
    check("search", len(rs["list"]) > 0, "%d条" % len(rs["list"]))

    # 7. 首页
    rh = sp.homeVideoContent()
    check("home", len(rh["list"]) > 0, "%d条" % len(rh["list"]))

    # 8. 详情
    vid = r1["list"][0]["vod_id"]
    d = sp.detailContent([vid])
    v = d["list"][0]
    has_m3u8 = "m3u8" in v["vod_play_url"]
    check("detail", bool(v["vod_name"]) and has_m3u8,
          "%s... m3u8=%s" % (v["vod_name"][:15], has_m3u8))

    # 9. 播放
    p = sp.playerContent("在线播放", v["vod_play_url"].split("$", 1)[1], "")
    check("player", p.get("parse") == 0 and "playUrl" not in p,
          "parse=%s" % p.get("parse"))

    # 10. m3u8 可达性
    if p.get("parse") == 0 and p.get("url", "").startswith("http"):
        import urllib.request as _ur
        try:
            req = _ur.Request(p["url"], headers={
                "User-Agent": sp.headers["User-Agent"]})
            with _ur.urlopen(req, timeout=12) as resp:
                body = resp.read(200).decode("utf-8", errors="ignore")
                check("m3u8_http",
                      resp.getcode() == 200 and "#EXTM3U" in body,
                      "HTTP %s" % resp.getcode())
        except Exception as e:
            check("m3u8_http", False, str(e)[:60])
    else:
        check("m3u8_http", False, "无直链")

    print("ALL PASS" if ok else "SOME FAILED")
