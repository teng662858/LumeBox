# LumeSource: {"id":"pypack_373136a3ed1617f1","name":"hqporner","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
# HQPorner https://m.hqporner.com/ (2026-10-10)
# 欧美 HD 站，64 个分类：
#  分类：/category/{slug}/，翻页 /category/{slug}/{pg}/
#  列表：<a href="/hdporn/{id}-{slug}.html" class="atfib"><img src="//..._main.jpg" alt="标题">
#  详情：/hdporn/{id}-{slug}.html → iframe //mydaddy.cc/video/{hash}/ → MP4 直链
#  播放：MP4 直链（1080p 优先），带签名短时效，详情页实时取
#  注意：MP4 地址时效短，取到后尽快播放

import re
import time
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass


class Spider(BaseSpider):
    def init(self, extend=""):
        self.site_url = "https://m.hqporner.com"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": self.site_url + "/",
        }
        try:
            if extend:
                import json
                ex = json.loads(extend) if isinstance(extend, str) else extend
                if isinstance(ex, dict) and ex.get("host"):
                    self.site_url = ex["host"].rstrip("/")
                    self.headers["Referer"] = self.site_url + "/"
        except Exception:
            pass

    def getName(self):
        return "HQPorner"

    def isVideoFormat(self, url):
        u = (url or "").lower()
        return u.endswith(".mp4") or ".mp4?" in u or u.endswith(".m3u8")

    def manualVideoCheck(self):
        return False

    def destroy(self):
        pass

    def _fetch(self, url, timeout=10):
        for _ in range(2):
            try:
                req = urllib.request.Request(url, headers=self.headers)
                return urllib.request.urlopen(req, timeout=timeout).read().decode("utf-8", "ignore")
            except Exception:
                time.sleep(0.5)
        return ""

    def _parse_cards(self, html):
        result = []
        seen = set()
        for m in re.finditer(r'<a href="(/hdporn/(\d+)-[^"]+\.html)" class="atfib"><img src="([^"]+)"[^>]*alt="([^"]+)"', html):
            href, vid, pic, title = m.group(1), m.group(2), m.group(3), m.group(4)
            if vid in seen:
                continue
            seen.add(vid)
            if pic.startswith("//"):
                pic = "https:" + pic
            result.append({
                "vod_id": href,
                "vod_name": title.strip(),
                "vod_pic": pic,
                "vod_remarks": "",
            })
        return result

    def homeContent(self, filter):
        cats = [
            ("1080p-porn", "1080p Porn"), ("anal-sex-hd", "Anal"), ("4k-porn", "4k Porn"),
            ("milf", "Milf"), ("lesbian", "Lesbian"), ("creampie", "Creampie"),
            ("60fps-porn", "60fps"), ("big-tits", "Big Tits"), ("teen-porn", "Teen Porn"),
            ("pov", "Pov"), ("threesome", "Threesome"), ("asian", "Asian"),
            ("old-and-young", "Old And Young"), ("ebony", "Ebony"), ("big-ass", "Big Ass"),
            ("interracial", "Interracial"), ("mature", "Mature"), ("squirt", "Squirt"),
            ("casting", "Casting"), ("amateur", "Amateur"), ("porn-massage", "Sex Massage"),
            ("gangbang", "Gangbang"), ("stockings", "Stockings"), ("big-dick", "Big Dick"),
            ("latina", "Latina"), ("babe", "Babe"), ("group-sex", "Group Sex"),
            ("russian", "Russian"), ("masturbation", "Masturbation"), ("hairy-pussy", "Hairy Pussy"),
            ("uniforms", "Uniforms"), ("shemale", "Shemale"), ("blonde", "Blonde"),
            ("orgasm", "Orgasm"), ("pickup", "Pickup"), ("bdsm", "Bdsm"),
            ("sex-parties", "Sex Party"), ("public", "Public"), ("japanese-girls-porn", "Japanese"),
            ("redhead", "Redhead"), ("orgy", "Orgy"), ("fetish", "Fetish"),
            ("blowjob", "Blowjob"), ("small-tits", "Small Tits"), ("brunette", "Brunette"),
            ("undressing", "Undressing"), ("cumshot", "Cumshot"), ("outdoor", "Outdoor"),
            ("deepthroat", "Deepthroat"), ("bondage", "Bondage"), ("shaved-pussy", "Shaved Pussy"),
            ("bisexual", "Bisexual"), ("hentai", "Hentai"), ("handjob", "Handjob"),
            ("pussy-licking", "Pussy Licking"), ("fisting", "Fisting"), ("moaning", "Moaning"),
            ("vintage", "Vintage"), ("tattooed", "Tattooed"), ("beach-porn", "Beach"),
            ("vibrator", "Vibrator"), ("fingering", "Fingering"), ("squeezing-tits", "Squeezing Tits"),
            ("long-hair", "Long Hair"),
        ]
        return {"class": [{"type_id": c, "type_name": n} for c, n in cats], "filters": {}}

    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg or 1)
        if pg <= 1:
            url = "%s/category/%s" % (self.site_url, tid)
        else:
            url = "%s/category/%s/%d" % (self.site_url, tid, pg)
        html = self._fetch(url)
        cards = self._parse_cards(html)
        pgcount = pg + 1 if len(cards) >= 20 else pg
        return {"list": cards, "page": pg, "pagecount": pgcount, "limit": 20, "total": 0}

    def detailContent(self, ids):
        href = ids[0]
        url = href if href.startswith("http") else self.site_url + href
        html = self._fetch(url)
        title = re.search(r"<title>([^<-]+)", html)
        # 取 iframe
        play_url = ""
        m = re.search(r'<iframe[^>]*src="(//mydaddy\.cc/video/[^"]+)"', html)
        if m:
            iframe_url = "https:" + m.group(1) if m.group(1).startswith("//") else m.group(1)
            fhtml = self._fetch(iframe_url)
            # 取最高清晰度 MP4（1080p > 720p > 480p > 360p），引号可能被转义
            best = ""
            for q in ["1080", "720", "480", "360"]:
                mm = re.search(r'source src=\\?"?//([^"\\]+\/%s\.mp4)' % q, fhtml)
                if mm:
                    best = "//" + mm.group(1)
                    break
            if not best:
                mm = re.search(r'//(bigcdn\.cc/[^"\\]+\.mp4)', fhtml)
                if mm:
                    best = "//" + mm.group(1)
            if best.startswith("//"):
                best = "https:" + best
            play_url = best
        pic = re.search(r'og:image[^>]*content="([^"]+)"', html)
        return {"list": [{
            "vod_id": href,
            "vod_name": title.group(1).strip() if title else "",
            "vod_pic": pic.group(1) if pic else "",
            "vod_play_from": "在线播放",
            "vod_play_url": "正片$" + play_url if play_url else "",
        }]}

    def playerContent(self, flag, id, vipFlags):
        url = id.strip()
        header = {"User-Agent": self.headers["User-Agent"], "Referer": "https://mydaddy.cc/"}
        return {"parse": 0, "url": url, "header": header}

    def searchContent(self, key, quick, pg="1"):
        # 站内搜索：/?s={kw}（尝试）
        url = "%s/?s=%s" % (self.site_url, urllib.parse.quote(key))
        html = self._fetch(url)
        cards = self._parse_cards(html)
        return {"list": cards, "page": 1, "pagecount": 1, "limit": 20, "total": len(cards)}

    def localProxy(self, params):
        return [200, "text/plain; charset=utf-8", b""]


if __name__ == "__main__":
    sp = Spider()
    sp.init()
    hc = sp.homeContent(None)
    print("分类: %d" % len(hc["class"]))
    assert len(hc["class"]) == 64
    c = sp.categoryContent("1080p-porn", 1, None, None)
    print("列表: %d 条" % len(c["list"]))
    assert len(c["list"]) > 0
    print("首条:", c["list"][0]["vod_name"][:40])
    d = sp.detailContent([c["list"][0]["vod_id"]])
    v = d["list"][0]
    print("详情:", v["vod_name"][:40])
    print("播放:", v["vod_play_url"].split("$", 1)[1][:80] if v["vod_play_url"] else "无")
    print("ALL PASS" if v["vod_play_url"] else "PLAY FAIL")
