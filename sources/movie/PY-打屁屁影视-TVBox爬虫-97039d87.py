# LumeSource: {"id":"pypack_1cfb278297039d87","name":"打屁屁影视-TVBox爬虫","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
import json
import re
import sys
import time
import base64
import binascii
import html as _html_mod
import urllib.request
import urllib.parse
from urllib.parse import quote, urlencode

_PROXY_B64 = (
    "aHR0cHM6Ly84OTc0NTYyMTIzLjg4ODg4ODg4"
    "ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4ODg4"
    "LmNjd3UuY2MvP3VybD0="
)

def _cfg(b64_str):
    try:
        return base64.b64decode(b64_str.encode("ascii")).decode("utf-8")
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return ""

try:
    import ssl
    _CTX = ssl.create_default_context()
    _CTX.check_hostname = False
    _CTX.verify_mode = ssl.CERT_NONE
except Exception:
    _CTX = None

sys.path.append('..')
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider:
        def fetch(self, url, headers=None, timeout=20, verify=False):
            req = urllib.request.Request(url, headers=headers or {})
            return urllib.request.urlopen(req, timeout=timeout, context=_CTX)

        def html(self, content):
            return None

class Spider(BaseSpider):
    def __init__(self):
        self.name = "打屁屁影视"
        self.host = "https://www.spankingtube.com"
        self.proxy = _cfg(_PROXY_B64)
        self.headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/146.0.0.0 Safari/537.36"
            ),
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        }
        self.categories = [
            {"type_id": "spanking", "type_name": "Spanking"},
            {"type_id": "otk-spankings", "type_name": "OTK Spankings"},
            {"type_id": "male-spanks-male", "type_name": "MM Spanking"},
            {"type_id": "domestic-discipline", "type_name": "Domestic Discipline"},
            {"type_id": "male-spanks-female", "type_name": "MF Spanking"},
            {"type_id": "caning", "type_name": "Caning"},
            {"type_id": "female-spanks-female", "type_name": "FF Spanking"},
            {"type_id": "women-spanking-men", "type_name": "FM Spanking"},
            {"type_id": "paddling", "type_name": "Paddling"},
            {"type_id": "strapping", "type_name": "Strapping"},
            {"type_id": "hairbrushing", "type_name": "Hairbrushing"},
            {"type_id": "bdsm", "type_name": "BDSM"},
            {"type_id": "femdom", "type_name": "Female Domination"},
            {"type_id": "whipping", "type_name": "Whipping"},
            {"type_id": "bondage", "type_name": "Bondage"},
            {"type_id": "gay-male", "type_name": "Gay (Male)"},
            {"type_id": "gay-male-bondage", "type_name": "Gay Male Bondage"},
            {"type_id": "self-spankings-male", "type_name": "Self Spankings - Male"},
            {"type_id": "self-spankings-female", "type_name": "Self Spankings - Female"},
            {"type_id": "solo-male", "type_name": "Solo Male"},
            {"type_id": "solo-female", "type_name": "Solo Female"},
            {"type_id": "bisexual-male", "type_name": "Bisexual Male"},
            {"type_id": "flogging", "type_name": "Flogging"},
            {"type_id": "schoolgirl-spankings", "type_name": "Schoolgirl Spankings"},
            {"type_id": "corner-time", "type_name": "Corner Time"},
            {"type_id": "outdoor-spankings", "type_name": "Outdoor Spankings"},
            {"type_id": "sex-and-spanking", "type_name": "Sex and Spanking"},
            {"type_id": "sex-and-bondage", "type_name": "Sex and Bondage"},
            {"type_id": "rope-bondage", "type_name": "Rope Bondage"},
            {"type_id": "spanking-machines", "type_name": "Spanking Machines"},
            {"type_id": "spanking-party-and-event", "type_name": "Spanking Party & Event"},
            {"type_id": "wheelbarrow-spanking", "type_name": "Wheelbarrow Spanking"},
            {"type_id": "bath-brush-spanking", "type_name": "Bath Brush Spanking"},
            {"type_id": "breast-spnakings", "type_name": "Breast Spankings"},
            {"type_id": "hand-and-feet-spankings", "type_name": "Hand & Feet Spankings"},
            {"type_id": "lingerie-spankings", "type_name": "Lingerie Spankings"},
            {"type_id": "tawsing", "type_name": "Tawsing"},
            {"type_id": "amateur", "type_name": "Amateur"},
            {"type_id": "ai-generated", "type_name": "AI Generated"},
            {"type_id": "everything-else", "type_name": "Everything Else"},
            {"type_id": "mature", "type_name": "Mature"},
            {"type_id": "lesbian", "type_name": "Lesbian"},
            {"type_id": "anal", "type_name": "Anal"},
            {"type_id": "blowjob", "type_name": "Blowjob"},
            {"type_id": "sex", "type_name": "Sex"},
            {"type_id": "rough-sex", "type_name": "Rough Sex"},
            {"type_id": "pov", "type_name": "POV"},
            {"type_id": "big-ass", "type_name": "Big Ass"},
            {"type_id": "big-tits", "type_name": "Big Tits"},
            {"type_id": "small-tits", "type_name": "Small Tits"},
            {"type_id": "bbw", "type_name": "BBW"},
            {"type_id": "foot-fetish", "type_name": "Foot Fetish"},
            {"type_id": "strapon", "type_name": "Strap-On"},
            {"type_id": "pegging", "type_name": "Pegging"},
            {"type_id": "vibrator", "type_name": "Vibrator"},
            {"type_id": "enema", "type_name": "Enema"},
            {"type_id": "pissing", "type_name": "Pissing"},
            {"type_id": "fisting", "type_name": "Fisting"},
            {"type_id": "suspension", "type_name": "Suspension"},
            {"type_id": "massage", "type_name": "Massage"},
            {"type_id": "tickling", "type_name": "Tickling"},
            {"type_id": "teens-18plus", "type_name": "Teens (18+)"},
        ]
        sort_values = [
            {"n": "最新发布", "v": "mr"},
            {"n": "最多播放", "v": "mv"},
            {"n": "最多评论", "v": "md"},
            {"n": "最高评分", "v": "tr"},
            {"n": "最多收藏", "v": "tf"},
            {"n": "最长时长", "v": "lg"},
            {"n": "正在观看", "v": "bw"},
        ]
        self.filters = {}
        for c in self.categories:
            self.filters[c["type_id"]] = [
                {"key": "o", "name": "排序", "value": sort_values},
            ]
        self.extend = ""
        self._last_ts = 0.0

    def init(self, extend=""):
        self.extend = extend
        return None

    def getName(self):
        return self.name

    def getDependence(self):
        return []

    def isVideoFormat(self, url):
        if not url:
            return False
        url = str(url).lower()
        return any(url.endswith(fmt) for fmt in ['.m3u8', '.mp4', '.flv', '.ts', '.mkv', '.m3u'])

    def manualVideoCheck(self):
        return False

    def liveContent(self, url):
        return ""

    def localProxy(self, param):
        if not param:
            return None
        url = param.get('url') if isinstance(param, dict) else param
        if not url or not str(url).startswith('http'):
            return None
        try:
            req = urllib.request.Request(url, headers=self.headers)
            resp = urllib.request.urlopen(req, timeout=15, context=_CTX)
            body = resp.read()
            content_type = resp.headers.get('Content-Type', 'application/octet-stream')
            return [200, content_type, body]
        except Exception:
            return None

    def destroy(self):
        return "正在Destroy"

    def _throttle(self):
        now = time.time()
        gap = now - self._last_ts
        if gap < 0.35:
            time.sleep(0.35 - gap)
        self._last_ts = time.time()

    def _open(self, url, referer, timeout):
        headers = dict(self.headers)
        headers["Referer"] = referer or (self.host + "/")
        req = urllib.request.Request(url, headers=headers)
        resp = urllib.request.urlopen(req, timeout=timeout, context=_CTX)
        return resp.read()

    def _fetch(self, path, referer=None, timeout=12):
        target = path if str(path).startswith("http") else (self.host + path)
        proxy_url = self.proxy + quote(target, safe="")
        plan = [(proxy_url, 2, timeout), (target, 1, 6)]
        for ch, tries, tmo in plan:
            for _ in range(tries):
                self._throttle()
                try:
                    data = self._open(ch, referer, tmo)
                    if data and len(data) > 3000:
                        return data.decode("utf-8", errors="ignore")
                except Exception:
                    pass
        return ""

    def _wrap(self, url):
        raw = str(url or "").strip()
        if not raw:
            return ""
        if raw.startswith("//"):
            raw = "https:" + raw
        elif raw.startswith("/"):
            raw = self.host + raw
        if not raw.startswith("http"):
            return raw
        if raw.startswith(self.proxy):
            return raw
        return self.proxy + quote(raw, safe="")

    @staticmethod
    def _clean(text):
        value = re.sub(r"<script.*?</script>", " ", str(text or ""), flags=re.S)
        value = re.sub(r"<[^>]+>", " ", value)
        return re.sub(r"\s+", " ", _html_mod.unescape(value.replace("&nbsp;", " "))).strip()

    @staticmethod
    def _fmt_dur(sec):
        try:
            s = int(float(sec))
        except Exception:
            return ""
        return "%02d:%02d" % (s // 60, s % 60)

    def homeContent(self, filter=False):
        return {"class": self.categories, "filters": self.filters}

    def homeVideoContent(self):
        try:
            html = self._fetch("/videos?o=mr")
            items = self._extract_cards(html)
            return {"list": items}
        except Exception:
            return {"list": []}

    def _extract_cards(self, html):
        items = []
        if not html:
            return items
        for ch in re.split(r'class="thumb-overlay"', html)[1:]:
            m = re.search(r'/video/(\d+)/', ch)
            if not m:
                continue
            vid = m.group(1)
            pic = ""
            im = re.search(r'<img src="([^"]+)"', ch)
            if im:
                pic = self._wrap(im.group(1))
            dur = ""
            dm = re.search(r'<div class="duration">\s*([\d:]+)\s*</div>', ch)
            if dm:
                dur = dm.group(1).strip()
            title = ""
            tm = re.search(r'content-title">([^<]*)</span>', ch)
            if tm:
                title = self._clean(tm.group(1))
            if not title:
                am = re.search(r'<img[^>]*title="([^"]*)"', ch)
                title = self._clean(am.group(1)) if am else ""
            if not title:
                title = "未命名"
            views = ""
            vs = re.findall(r'content-views">\s*([^<]+?)\s*<', ch)
            if vs:
                views = self._clean(vs[-1])
            user = ""
            um = re.search(r'content-username">\s*<a href="/user/[^"]*">([^<]+)</a>', ch)
            if um:
                user = self._clean(um.group(1))
            remarks = dur
            if views:
                remarks = (dur + " · " if dur else "") + views
            items.append({
                "vod_id": vid,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": remarks,
                "vod_actor": user,
            })
        return items

    @staticmethod
    def _pagecount(html, pg):
        if not html:
            return pg
        nums = [int(n) for n in re.findall(r'page(?:%3D|=)(\d+)', html)]
        mx = max(nums) if nums else pg
        return max(mx, pg)

    def categoryContent(self, tid, pg, filter=False, extend=""):
        tid = str(tid)
        try:
            pg = int(pg) if pg else 1
        except Exception:
            pg = 1
        sort = ""
        ext = extend
        if isinstance(ext, str) and ext.strip().startswith("{"):
            try:
                ext = json.loads(ext)
            except Exception:
                ext = {}
        if isinstance(ext, dict):
            sort = str(ext.get("o") or ext.get("sort") or "").strip()
        elif ext:
            sort = str(ext).strip()
        if sort not in ("mr", "mv", "md", "tr", "tf", "lg", "bw"):
            sort = ""
        params = {}
        if pg > 1:
            params["page"] = pg
        if sort:
            params["o"] = sort
        path = "/videos/%s" % tid
        if params:
            path += "?" + urlencode(params)
        try:
            html = self._fetch(path)
            items = self._extract_cards(html)
            pagecount = self._pagecount(html, pg)
            if not items:
                pagecount = pg
            return {
                "list": items,
                "page": pg,
                "pagecount": pagecount,
                "limit": 24,
                "total": pagecount * 24,
                "parse": 0,
                "jx": 0,
            }
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 0, "total": 0, "parse": 0, "jx": 0}

    def detailContent(self, ids):
        raw = ids[0] if isinstance(ids, (list, tuple)) and ids else ids
        m = re.search(r'/video/(\d+)', str(raw))
        vid = m.group(1) if m else re.sub(r"\D", "", str(raw)) or str(raw)
        path = "/video/%s" % vid
        html = self._fetch(path, referer=self.host + "/")
        if not html:
            return {"list": [], "parse": 0, "jx": 0}

        title = ""
        tm = re.search(r'<h1 class="float-left">(.*?)</h1>', html, re.S)
        if tm:
            title = self._clean(tm.group(1))
        if not title:
            tm = re.search(r"<title>([^<]*)</title>", html, re.S)
            if tm:
                title = self._clean(tm.group(1)).split(" - SpankingTube")[0]

        content = ""
        dm = re.search(r'property="og:description"\s+content="([^"]*)"', html)
        if not dm:
            dm = re.search(r'content="([^"]*)"\s+property="og:description"', html)
        if dm:
            content = self._clean(dm.group(1))
        if not content:
            dm = re.search(r'vid-titles">Description:\s*</span>([\s\S]{0,4000}?)</div>', html)
            if dm:
                content = self._clean(dm.group(1))

        tags = []
        for t in re.findall(r'<a class="tag" href="/search/videos/[^"]*">([^<]+)</a>', html):
            t = self._clean(t)
            if t and t not in tags:
                tags.append(t)

        actor = ""
        um = re.search(r'video-uploader">[\s\S]{0,400}?/user/([^"]+)"[\s\S]{0,200}?>([^<]+)</span>', html)
        if um:
            actor = self._clean(um.group(2)) or um.group(1)

        views = ""
        vm = re.search(r'fa-eye"></i>\s*([\d,.KM]+)\s*&nbsp;', html)
        if vm:
            views = vm.group(1)
        ago = ""
        am = re.search(r'&nbsp;\s*(\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago)', html)
        if am:
            ago = am.group(1)
        dur = ""
        dm2 = re.search(r'var video_duration\s*=\s*"([\d.]+)"', html)
        if dm2:
            dur = self._fmt_dur(dm2.group(1))

        pic = ""
        pm = re.search(r'<video[^>]*poster="([^"]+)"', html)
        if pm:
            pic = self._wrap(pm.group(1))

        lines = []
        for sm in re.finditer(r'<source src="([^"]+)"[^>]*label=\'([^\']+)\'', html):
            url = self._wrap(sm.group(1).replace("\\/", "/"))
            label = sm.group(2).strip() or "正片"
            if url and url.startswith("http"):
                lines.append("%s$%s" % (label, url))
        if not lines:
            for sm in re.finditer(r"<source src=\"(https?://[^\"]+)\"", html):
                lines.append("正片$%s" % self._wrap(sm.group(1)))
        seen = set()
        uniq = []
        for ln in lines:
            if ln not in seen:
                seen.add(ln)
                uniq.append(ln)
        lines = uniq

        remarks = dur
        meta_bits = []
        if views:
            meta_bits.append(views + " views")
        if ago:
            meta_bits.append(ago)
        if meta_bits:
            remarks = (dur + " · " if dur else "") + " · ".join(meta_bits)

        return {
            "list": [
                {
                    "vod_id": vid,
                    "vod_name": title,
                    "vod_pic": pic,
                    "vod_content": content,
                    "vod_remarks": remarks,
                    "type_name": " · ".join(tags[:8]),
                    "vod_year": "",
                    "vod_area": "",
                    "vod_lang": "",
                    "vod_actor": actor,
                    "vod_director": actor,
                    "vod_play_from": "打屁屁",
                    "vod_play_url": "#".join(lines),
                }
            ],
            "parse": 0,
            "jx": 0,
        }

    def playerContent(self, flag, id, vipFlags=None):
        sid = str(id or "").strip()
        if sid.startswith("http"):
            header = json.dumps({
                "User-Agent": self.headers["User-Agent"],
                "Referer": self.host + "/",
            }, ensure_ascii=False)
            return {"parse": 0, "playUrl": "", "url": sid, "header": header, "jx": 0}
        vid = re.sub(r"\D", "", sid) or sid
        html = self._fetch("/video/%s" % vid, referer=self.host + "/")
        best = ""
        for sm in re.finditer(r'<source src="([^"]+)"[^>]*label=\'([^\']+)\'', html):
            url = self._wrap(sm.group(1).replace("\\/", "/"))
            if not url.startswith("http"):
                continue
            if flag and sm.group(2).strip() == flag:
                best = url
                break
            if not best:
                best = url
        if not best:
            um = re.search(r"<source src=\"(https?://[^\"]+)\"", html)
            if um:
                best = self._wrap(um.group(1))
        if not best:
            return {"parse": 1, "playUrl": "", "url": "", "header": json.dumps(self.headers, ensure_ascii=False), "jx": 0}
        header = json.dumps({
            "User-Agent": self.headers["User-Agent"],
            "Referer": self.host + "/",
        }, ensure_ascii=False)
        return {"parse": 0, "playUrl": "", "url": best, "header": header, "jx": 0}

    def searchContent(self, key, quick=False, pg='1'):
        try:
            pg = int(pg) if pg else 1
        except Exception:
            pg = 1
        kw = quote(str(key))
        path = "/search/videos/%s" % kw
        if pg > 1:
            path += "?page=%d" % pg
        try:
            html = self._fetch(path)
            items = self._extract_cards(html)
            pagecount = self._pagecount(html, pg)
            if not items:
                pagecount = pg
            return {
                "list": items,
                "page": pg,
                "pagecount": pagecount,
                "limit": 24,
                "total": pagecount * 24,
                "parse": 0,
                "jx": 0,
            }
        except Exception:
            return {"list": [], "page": pg, "pagecount": pg, "limit": 0, "total": 0, "parse": 0, "jx": 0}

    def searchContentPage(self, key, quick=False, page='1'):
        return self.searchContent(key, quick, page)

if __name__ == "__main__":
    sp = Spider()
    print("=== homeContent ===")
    home = sp.homeContent(True)
    print("class:", len(home["class"]), "项分类")
    print("filters:", home["filters"]["spanking"])
    print("=== homeVideoContent ===")
    hv = sp.homeVideoContent()
    print("count:", len(hv["list"]))
    if hv["list"]:
        print(hv["list"][0])
    print("=== categoryContent spanking 第1页 ===")
    cat = sp.categoryContent("spanking", 1, False, {})
    print("count:", len(cat["list"]), "pagecount:", cat["pagecount"], "total:", cat["total"])
    if cat["list"]:
        print(cat["list"][:2])
    print("=== categoryContent spanking 第2页 + 最多播放 ===")
    cat2 = sp.categoryContent("spanking", 2, False, {"o": "mv"})
    print("count:", len(cat2["list"]))
    if cat2["list"]:
        print(cat2["list"][0])
    print("=== detailContent 176586 ===")
    det = sp.detailContent(["176586"])
    if det["list"]:
        d = det["list"][0]
        print({k: d[k] for k in ["vod_name", "vod_remarks", "type_name", "vod_actor", "vod_play_from"]})
        print("content:", d["vod_content"][:80])
        print("play_url:", d["vod_play_url"][:160])
    print("=== playerContent（壳子传直链） ===")
    if det["list"]:
        url = det["list"][0]["vod_play_url"].split("$", 1)[1].split("#")[0]
        pl = sp.playerContent("720p", url, None)
        print("url:", (pl.get("url") or "")[:100], "| parse:", pl.get("parse"))
    print("=== playerContent（壳子传 vid） ===")
    pl2 = sp.playerContent("540p", "176586", None)
    print("url:", (pl2.get("url") or "")[:100], "| parse:", pl2.get("parse"))
    print("=== searchContent caning ===")
    s = sp.searchContent("caning", False, 1)
    print("count:", len(s["list"]), "pagecount:", s.get("pagecount"))
    if s["list"]:
        print(s["list"][:2])
