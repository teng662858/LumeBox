# LumeSource: {"id":"pypack_1fd0a1be766d7b05","name":"eporner大站","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding=utf-8
# Eporner (www.eporner.com) spider for TVBox / FongMi
# 列表/搜索走官方 API v2；播放走视频页 vid+hash -> base36 -> /xhr/video 还原直链(mp4/hls)
from base.spider import Spider as BaseSpider
import sys, time, re

sys.setrecursionlimit(10000)


class Spider(BaseSpider):

    host = "https://www.eporner.com"
    api = "https://www.eporner.com/api/v2/video/search/"
    UA = ("Mozilla/5.0 (Linux; Android 12; K) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36")

    def getHeader(self, referer=None):
        return {
            "User-Agent": self.UA,
            "Referer": referer or (self.host + "/"),
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        }

    def init(self, extend=""):
        return

    def getName(self):
        return "Eporner"

    def getDependence(self):
        return []

    def isVideoFormat(self, url):
        u = (url or "").lower()
        return any(x in u for x in [".m3u8", ".mp4", ".ts"])

    def manualVideoCheck(self):
        return False

    def destroy(self):
        return

    # ---------- fetch helpers (兼容 FongMi requests 版 fetch，显式长超时) ----------
    def _get_text(self, url, referer=None):
        try:
            rsp = self.fetch(url, headers=self.getHeader(referer), timeout=20)
            if hasattr(rsp, "text") and rsp.text:
                return rsp.text
            if hasattr(rsp, "content"):
                return rsp.content.decode("utf-8", "ignore")
        except Exception as e:
            self.log("get_text err %s" % e)
        return ""

    def _get_json(self, url, referer=None):
        import json as _j
        txt = self._get_text(url, referer)
        if not txt:
            return {}
        try:
            return _j.loads(txt)
        except Exception as e:
            self.log("get_json err %s" % e)
            return {}

    def _vod_from_api(self, v):
        thumb = ""
        dt = v.get("default_thumb") or {}
        if isinstance(dt, dict):
            thumb = dt.get("src", "")
        if not thumb:
            ths = v.get("thumbs") or []
            if ths and isinstance(ths[0], dict):
                thumb = ths[0].get("src", "")
        views = v.get("views", "")
        remarks = v.get("length_min", "") or ""
        if views not in ("", None):
            remarks += "  %s views" % views
        return {
            "vod_id": v.get("id", ""),
            "vod_name": v.get("title", ""),
            "vod_pic": thumb,
            "vod_remarks": remarks.strip(),
        }

    # ---------- play source resolve ----------
    def _b36(self, n):
        if n == 0:
            return "0"
        s = "0123456789abcdefghijklmnopqrstuvwxyz"
        out = ""
        while n:
            n, r = divmod(n, 36)
            out = s[r] + out
        return out

    def _conv_hash(self, h):
        # 32位md5 -> 每8位hex转int再转base36 拼接
        try:
            return "".join(self._b36(int(h[i:i + 8], 16)) for i in range(0, 32, 8))
        except Exception:
            return h

    def _resolve(self, vid):
        # 返回 (title, pic, streams)；streams=有序 [{"label","url","kind"}]，高清在前，HLS 最后
        page_url = "%s/video-%s/" % (self.host, vid)
        page = self._get_text(page_url, referer=self.host + "/")
        title = ""
        mt = re.search(r'<meta\s+property="og:title"\s+content="([^"]*)"', page)
        if mt:
            title = mt.group(1)
            try:
                import html as _h
                title = _h.unescape(title)
            except Exception:
                pass
            title = re.sub(r'\s*-\s*EPORNER\s*$', '', title, flags=re.I).strip()
        pic = ""
        mp = re.search(r'<meta\s+property="og:image"\s+content="([^"]*)"', page)
        if mp:
            pic = mp.group(1)
        mv = re.search(r"EP\.video\.player\.vid\s*=\s*'([^']+)'", page)
        mh = re.search(r"EP\.video\.player\.hash\s*=\s*'([a-f0-9]+)'", page)
        streams = []
        if mh:
            real_vid = mv.group(1) if mv else vid
            ch = self._conv_hash(mh.group(1))
            xhr = ("%s/xhr/video/%s?hash=%s&domain=www.eporner.com&fallback=false"
                   "&embed=false&supportedFormats=dash,hls,mp4&_=%d"
                   % (self.host, real_vid, ch, int(time.time() * 1000)))
            data = self._get_json(xhr, referer=page_url)
            src = data.get("sources", {}) or {}
            mp4 = src.get("mp4", {}) or {}
            order = ["2160p", "1440p", "1080p HD", "1080p", "720p HD", "720p",
                     "480p", "360p", "240p", "144p"]
            keys = sorted(mp4.keys(),
                          key=lambda k: order.index(k) if k in order else 99)
            mp4_streams = []
            for q in keys:
                info = mp4[q]
                u = info.get("src", "") if isinstance(info, dict) else info
                if u:
                    label = q.replace(" HD", "").replace("p", "P")
                    mp4_streams.append({"label": label, "url": u, "kind": "mp4"})
            h = src.get("hls", {}) or {}
            if isinstance(h, dict):
                au = h.get("auto")
                hu = au.get("src", "") if isinstance(au, dict) else (au if isinstance(au, str) else "")
                if hu:
                    # HLS 放首位做默认线路：ExoPlayer 原生自适应，兼容性最好
                    streams.append({"label": "HLS自适应", "url": hu, "kind": "hls"})
            streams.extend(mp4_streams)
        return title or vid, pic, streams

    # ---------- home ----------
    def homeContent(self, filter):
        cates = [
            ("milf", "MILF"), ("teen", "Teen"), ("amateur", "Amateur"),
            ("anal", "Anal"), ("asian", "Asian"), ("ebony", "Ebony"),
            ("latina", "Latina"), ("big tits", "Big Tits"), ("big ass", "Big Ass"),
            ("blonde", "Blonde"), ("brunette", "Brunette"), ("blowjob", "Blowjob"),
            ("creampie", "Creampie"), ("cumshot", "Cumshot"), ("hardcore", "Hardcore"),
            ("lesbian", "Lesbian"), ("pov", "POV"), ("public", "Public"),
            ("threesome", "Threesome"), ("mature", "Mature"), ("hentai", "Hentai"),
            ("japanese", "Japanese"), ("massage", "Massage"), ("compilation", "Compilation"),
        ]
        classes = [{"type_id": k, "type_name": n} for k, n in cates]
        orders = ["latest", "most-popular", "top-rated", "longest", "top-weekly", "top-monthly"]
        order_names = ["最新", "最热", "评分", "最长", "周榜", "月榜"]
        vals = [{"n": order_names[i], "v": orders[i]} for i in range(len(orders))]
        filters = {}
        for k, _ in cates:
            filters[k] = [{"key": "order", "name": "排序", "value": vals}]
        result = {"class": classes, "filters": filters}
        d = self._get_json(self.api + "?query=all&per_page=30&page=1&thumbsize=big&order=latest&format=json")
        result["list"] = [self._vod_from_api(v) for v in d.get("videos", [])]
        return result

    def homeVideoContent(self):
        d = self._get_json(self.api + "?query=all&per_page=30&page=1&thumbsize=big&order=latest&format=json")
        return {"list": [self._vod_from_api(v) for v in d.get("videos", [])]}

    # ---------- category ----------
    def categoryContent(self, tid, pg, filter, extend):
        import urllib.parse as _up
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        order = (extend or {}).get("order", "latest")
        query = tid if tid else "all"
        url = (self.api + "?query=%s&per_page=30&page=%d&thumbsize=big&order=%s&format=json"
               % (_up.quote(query), page, order))
        d = self._get_json(url)
        vlist = [self._vod_from_api(v) for v in d.get("videos", [])]
        try:
            total_pages = int(d.get("total_pages", page))
        except Exception:
            total_pages = page
        return {"list": vlist, "page": page, "pagecount": total_pages,
                "limit": 30, "total": d.get("total_count", len(vlist))}

    # ---------- detail ----------
    def detailContent(self, ids):
        vid = ids[0]
        title, pic, streams = self._resolve(vid)
        froms, urls = [], []
        for i, st in enumerate(streams):
            froms.append(st["label"])
            # 线路名$播放id —— id 用 vid@@@索引，纯数字无空格，不含标题，round-trip 安全
            urls.append("%s$%s@@@%d" % (st["label"], vid, i))
        if not froms:
            froms = ["默认"]
            urls = ["默认$%s@@@0" % vid]
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": pic,
            "vod_remarks": "",
            "vod_content": title,
            "vod_play_from": "$$$".join(froms),
            "vod_play_url": "$$$".join(urls),
        }
        return {"list": [vod]}

    # ---------- search ----------
    def searchContent(self, key, quick, pg="1"):
        import urllib.parse as _up
        try:
            page = max(1, int(pg))
        except Exception:
            page = 1
        url = (self.api + "?query=%s&per_page=30&page=%d&thumbsize=big&order=most-popular&format=json"
               % (_up.quote(key), page))
        d = self._get_json(url)
        vlist = [self._vod_from_api(v) for v in d.get("videos", [])]
        try:
            total_pages = int(d.get("total_pages", page))
        except Exception:
            total_pages = page
        return {"list": vlist, "page": page, "pagecount": total_pages}

    # ---------- player ----------
    def playerContent(self, flag, id, vipFlags):
        vid, _, idx = id.partition("@@@")
        try:
            idx = int(idx)
        except Exception:
            idx = 0
        play = ""
        try:
            title, pic, streams = self._resolve(vid)
            if streams:
                if 0 <= idx < len(streams):
                    play = streams[idx]["url"]
                else:
                    play = streams[0]["url"]
        except Exception as e:
            self.log("player err %s" % e)
        return {
            "parse": 0,
            "playUrl": "",
            "url": play,
            "header": self.getHeader(referer="%s/video-%s/" % (self.host, vid)),
        }

    def localProxy(self, param):
        return [404, "text/plain", {}]
