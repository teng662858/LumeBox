# LumeSource: {"id":"pypack_c8c7380efd79eaa4","name":"babestation","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding: utf-8
import re, time, json
from urllib.parse import quote, urlencode
from base.spider import Spider as BaseSpider

_HOST = "https://www.babestation.tv"

# 导航分类（slug -> 名称）
_CLASSES = [
    ("girls", "全部模特"), ("new-models", "新模特"), ("teens", "Teen 18+"),
    ("young", "Young 20+"), ("milfs", "MILF"), ("mature", "熟女"), ("grannies", "老妇"),
    ("bbw", "BBW"), ("curvy", "丰腴"), ("petite", "娇小"), ("athletic", "运动型"),
    ("slender", "纤细"), ("blonde", "金发"), ("brunette", "棕发"), ("redhead", "红发"),
    ("big-tits", "巨乳"), ("huge-tits", "爆乳"), ("small-tits", "小胸"), ("big-ass", "巨臀"),
    ("pawg", "PAWG"), ("babes", "辣妹"), ("lesbian", "拉拉"), ("couples", "情侣"),
    ("trans", "跨性"), ("anal", "肛交"), ("bdsm", "BDSM"), ("bondage", "捆绑"),
    ("femdom", "女S"), ("roleplay", "角色扮演"), ("asian", "亚洲"), ("black", "黑人"),
    ("european", "欧洲"), ("latin-america", "拉丁"), ("white", "白人"),
]


class Spider(BaseSpider):

    def getName(self):
        return "Babestation"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self.host = _HOST
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 14; 22127RK46C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": self.host + "/",
        }
        self._opener = None
        self._csrf = None
        self._cache = {}
        self._fallback = None

    # ---------- 网络 ----------
    def _ensure_session(self):
        """GET 首页/模特页拿 session cookie + CSRF token（Laravel 匿名可用）"""
        import urllib.request, ssl, http.cookiejar
        from urllib.error import HTTPError
        if self._opener is None:
            cj = http.cookiejar.CookieJar()
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self._opener = urllib.request.build_opener(
                urllib.request.HTTPCookieProcessor(cj),
                urllib.request.HTTPSHandler(context=ctx),
            )
        if self._csrf:
            return True
        try:
            req = urllib.request.Request(self.host + "/girls", headers=self.headers)
            try:
                resp = self._opener.open(req, timeout=10)
            except HTTPError as e:
                resp = e
            html = resp.read().decode("utf-8", "ignore")
            self._csrf = self._extract_token(html)
            return bool(self._csrf)
        except Exception:
            return False

    @staticmethod
    def _extract_token(html):
        m = re.search(r'data-page="(.*?)"\s*>', html or "", re.S)
        if not m:
            m = re.search(r"data-page='(.*?)'\s*>", html or "", re.S)
        if not m:
            return None
        try:
            raw = m.group(1)
            raw = raw.replace("&quot;", '"').replace("&#039;", "'").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            return json.loads(raw).get("props", {}).get("csrfToken") or None
        except Exception:
            return None

    def _get_page(self, url, ttl=60):
        """GET 页面并解析 data-page（Inertia props）"""
        import urllib.request
        from urllib.error import HTTPError
        now = time.time()
        c = self._cache.get("pg:" + url)
        if c and c[0] > now:
            return c[1]
        text = ""
        try:
            req = urllib.request.Request(url, headers=self.headers)
            try:
                resp = self._opener.open(req, timeout=10)
            except HTTPError as e:
                resp = e
            text = resp.read().decode("utf-8", "ignore")
        except Exception:
            text = ""
        props = self._parse_page(text)
        if props:
            self._cache["pg:" + url] = (now + ttl, props)
        return props

    def _parse_page(self, html):
        m = re.search(r'data-page="(.*?)"\s*>', html or "", re.S)
        if not m:
            m = re.search(r"data-page='(.*?)'\s*>", html or "", re.S)
        if not m:
            return None
        try:
            raw = m.group(1).replace("&quot;", '"').replace("&#039;", "'").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            return json.loads(raw).get("props", {})
        except Exception:
            return None

    def _post_search(self, page=1, category=""):
        """POST /live/cams/search → 模特列表 JSON"""
        import urllib.request
        from urllib.error import HTTPError
        if not self._ensure_session():
            return {}
        body = {"page": str(page)}
        if category:
            body["category"] = category
        try:
            req = urllib.request.Request(
                self.host + "/live/cams/search",
                data=urlencode(body).encode("utf-8"),
                headers={
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": self.host + "/cams",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-CSRF-TOKEN": self._csrf or "",
                    "Accept": "application/json",
                    "X-Requested-With": "XMLHttpRequest",
                },
            )
            try:
                resp = self._opener.open(req, timeout=10)
            except HTTPError as e:
                resp = e
            return json.loads(resp.read().decode("utf-8", "ignore") or "{}")
        except Exception:
            return {}

    # ---------- 解析 ----------
    @staticmethod
    def _parse_profiles(props, limit=36):
        """/girls 页 props.profiles → vod 列表"""
        out = []
        for it in props.get("profiles") or []:
            slug = it.get("url_slug")
            name = it.get("name")
            if not slug or not name:
                continue
            out.append({
                "vod_id": f"{_HOST}/girls/{slug}",
                "vod_name": name,
                "vod_pic": it.get("profile_picture") or "",
                "vod_remarks": "在线" if it.get("is_live") else "",
            })
        return out

    def _parse_search(self, data):
        """POST search 响应 → vod 列表"""
        out = []
        for it in data.get("babestation") or []:
            slug = it.get("slug")
            name = it.get("stagename") or it.get("username")
            if not slug or not name:
                continue
            out.append({
                "vod_id": f"{self.host}/girls/{slug}",
                "vod_name": name,
                "vod_pic": it.get("image_profile") or it.get("headshot") or "",
                "vod_remarks": "直播" if it.get("status") == "online" else "",
            })
        return out

    def _parse_detail(self, props):
        """模特页 props.profile.members_content → 视频剧集"""
        profile = props.get("profile") or {}
        name = profile.get("name") or ""
        pic = ""
        pp = profile.get("profile_picture") or {}
        if isinstance(pp, dict):
            pic = pp.get("url") or ""
        eps = []
        for it in profile.get("members_content") or []:
            if it.get("type") != "video":
                continue
            url = it.get("vip_preview")
            if not url:
                continue
            title = it.get("title") or f"{name} 视频"
            eps.append(f"{title}${url}")
        return name, pic, eps

    # ---------- 接口 ----------
    def homeContent(self, filter):
        return {"class": [{"type_id": s, "type_name": n} for s, n in _CLASSES], "list": []}

    def homeVideoContent(self):
        props = self._get_page(self.host + "/girls", 120)
        if props:
            return {"list": self._parse_profiles(props)}
        # 兜底：search API 首页
        data = self._post_search(1, "")
        return {"list": self._parse_search(data)}

    def categoryContent(self, tid, pg, filter, extend):
        try:
            page = int(pg) if str(pg).isdigit() else 1
            data = self._post_search(page, str(tid))
            lst = self._parse_search(data)
            pag = data.get("pagination") or {}
            pagecount = int(pag.get("last_page") or 1)
            return {"list": lst, "page": page, "pagecount": pagecount, "limit": 24, "total": int(pag.get("total") or len(lst))}
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 0, "total": 0}

    def detailContent(self, ids):
        try:
            vod_id = ids[0]
            slug = vod_id
            if vod_id.startswith("http"):
                slug = vod_id.rstrip("/").split("/")[-1]
            props = self._get_page(f"{self.host}/girls/{slug}", 60)
            vod = {"vod_id": vod_id, "vod_name": "", "vod_pic": "", "vod_content": "",
                   "vod_play_from": "Babestation", "vod_play_url": ""}
            if not props:
                return {"list": [vod]}
            name, pic, eps = self._parse_detail(props)
            vod["vod_name"] = name or slug
            vod["vod_pic"] = pic
            vod["vod_content"] = name
            vod["vod_play_url"] = "#".join(eps)
            return {"list": [vod]}
        except Exception:
            return {"list": []}

    def searchContent(self, key, quick, pg="1"):
        try:
            # API 不支持服务端关键词过滤：取前 3 页后客户端过滤（提高命中率）
            key = key.lower()
            hits = []
            for p in (1, 2, 3):
                data = self._post_search(p, "")
                hits += [v for v in self._parse_search(data) if key in v["vod_name"].lower()]
                if len(hits) >= 30:
                    break
            return {"list": hits, "page": 1, "pagecount": 1, "limit": len(hits), "total": len(hits)}
        except Exception:
            return {"list": [], "page": 1, "pagecount": 1, "limit": 0, "total": 0}

    def playerContent(self, flag, id, vipFlags):
        if id.startswith("http") and (id.endswith(".mp4") or ".mp4" in id):
            return {"parse": 0, "url": id, "header": {"User-Agent": self.headers["User-Agent"], "Referer": self.host + "/"}}
        return {"parse": 0, "url": id, "header": {"User-Agent": self.headers["User-Agent"], "Referer": self.host + "/"}}

    def localProxy(self, param):
        return [200, "video/mp4", "", {}]

    def destroy(self):
        self._cache.clear()
