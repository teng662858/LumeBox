# LumeSource: {"id":"pypack_452b42090c617199","name":"喵特影视","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
"""
喵特影视 
站点: https://www.nyato.com/
"""
import sys
import re
import json
import requests
from urllib.parse import urljoin, quote

sys.path.append('..')
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider(object):
        pass


class Spider(BaseSpider):

    def __init__(self):
        self.host = "https://www.nyato.com"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 "
                          "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
            "Referer": self.host + "/",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        }
        self.session = requests.Session()
        self.session.headers.update(self.headers)
        self.categories = [
            {"type_id": "2",   "type_name": "电视剧"},
            {"type_id": "3",   "type_name": "综艺"},
            {"type_id": "4",   "type_name": "动漫"},
            {"type_id": "40",  "type_name": "短剧"},
            {"type_id": "63",  "type_name": "午夜剧场"},
        ]
        # 分类页的筛选后缀：show/{id}-----------{area}-{year}-{lang}-{letter}---{order}.html
        # 这里只做 sort（按最新/最热）
        self.sort_map = {
            "默认": "",
            "最新": "time",
            "最热": "hit",
            "评分": "score",
        }

    # ---------- 基础方法 ----------
    def getName(self):
        return "喵特影视"

    def init(self, extend=""):
        self.extend = extend
        return

    def isVideoFormat(self, url):
        if not url:
            return False
        return any(x in url for x in (".m3u8", ".mp4", ".flv", ".mkv"))

    def manualVideoCheck(self):
        return False

    def destroy(self):
        try:
            self.session.close()
        except Exception:
            pass

    def localProxy(self, param):
        return None

    def _get(self, url, **kw):
        try:
            kw.setdefault("timeout", 15)
            r = self.session.get(url, **kw)
            r.encoding = "utf-8"
            return r.text if r.status_code == 200 else ""
        except Exception:
            return ""

    # ---------- 首页 ----------
    def homeContent(self, filter):
        result = {"class": self.categories}
        if filter:
            filters = {}
            sorts = [{"key": k, "name": k} for k in self.sort_map.keys()]
            for c in self.categories:
                filters[c["type_id"]] = [{"key": "sort", "name": "排序", "value": sorts}]
            result["filters"] = filters

        # 首页推荐（用短剧板块最新）
        html = self._get(self.host + "/")
        videos = self._parse_list(html)[:30]
        result["list"] = videos
        return result

    def homeVideoContent(self):
        html = self._get(self.host + "/")
        return {"list": self._parse_list(html)[:30]}

    # ---------- 分类 ----------
    def categoryContent(self, tid, pg, filter, extend):
        pg = int(pg) if str(pg).isdigit() else 1
        sort = ""
        if isinstance(extend, dict):
            s = extend.get("sort")
            if s:
                sort = self.sort_map.get(s, "")

        # 分类页: https://www.nyato.com/type/40.html
        # 翻页:   https://www.nyato.com/type/40/page/2.html （或 ?page=2）
        if pg <= 1:
            url = "{}/type/{}.html".format(self.host, tid)
        else:
            url = "{}/type/{}/page/{}.html".format(self.host, tid, pg)

        html = self._get(url)
        videos = self._parse_list(html)

        # 若首页第一页没内容，尝试备用翻页形式
        if not videos and pg > 1:
            url2 = "{}/type/{}.html?page={}".format(self.host, tid, pg)
            html2 = self._get(url2)
            videos = self._parse_list(html2)

        # 是否需要排序筛选，这里仅在存在时使用
        if sort and pg == 1:
            url_sorted = "{}/show/{}{}.html".format(self.host, tid, "-----------/" + sort + "/1")
            html_sorted = self._get(url_sorted)
            v2 = self._parse_list(html_sorted)
            if v2:
                videos = v2

        # 页数：通常站点无法直接获知总数，这里给一个上限
        pagecount = 9999 if len(videos) >= 12 else pg
        return {
            "list": videos,
            "page": pg,
            "pagecount": pagecount,
            "limit": 30,
            "total": pagecount * 30,
        }

    # ---------- 详情 ----------
    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) else str(ids)
        # vid 形如: /husou/4982328.html 或 4982328 或完整 URL
        detail_url = self._normalize_detail_url(vid)
        html = self._get(detail_url)
        if not html:
            return {"list": []}

        # 基本信息
        vod = {
            "vod_id": vid,
            "vod_name": self._m(html, r'<h1 class="[^"]*title[^"]*">(.*?)<span'),
            "vod_pic": self._m(html, r'class="[^"]*lazyload"[^>]*src="(.*?)"') or
                       self._m(html, r'<img[^>]*src="(/upload/[^"]+)"'),
            "vod_year": self._m(html, r'<span class="[^"]*year[^"]*">\((\d{4})\)'),
            "vod_remarks": self._m(html, r'<span class="[^"]*pic-text[^"]*">([^<]+)</span>'),
            "vod_content": self._m(html, r'<span>简介：</span>(.*?)<a', dotall=True),
            "vod_actor": "",
            "vod_director": "",
        }

        # 主演 / 导演
        actor = self._m(html, r'<span class="[^"]*text-muted[^"]*">主演：</span>(.*?)</p>', dotall=True)
        director = self._m(html, r'<span class="[^"]*text-muted[^"]*">导演：</span>(.*?)</p>', dotall=True)
        vod["vod_actor"] = self._clean(actor)
        vod["vod_director"] = self._clean(director)
        vod["vod_content"] = self._clean(vod.get("vod_content") or "")
        if vod["vod_pic"] and not vod["vod_pic"].startswith("http"):
            vod["vod_pic"] = urljoin(self.host, vod["vod_pic"])

        # 播放列表：从详情页提取所有 tab 面板（豆瓣① 等）
        play_from_list = []
        play_url_list = []

        # 抓取每个 tab：<div id="playlistN"> 下的 <ul>...
        panels = re.findall(
            r'<div id="(playlist\d+)"[^>]*>(.*?)</div>\s*(?:</div>|<div class="tab-pane|$)',
            html, re.S
        )
        # 名称映射
        tab_names = re.findall(r'<a href="#(playlist\d+)"[^>]*>([^<]+)</a>', html)

        name_map = {pid: name.strip() for pid, name in tab_names}

        for pid, block in panels:
            episodes = self._parse_episodes(block)
            if not episodes:
                continue
            play_from_list.append(name_map.get(pid, pid))
            play_url_list.append("#".join(
                ["{}${}".format(ep["name"], ep["url"]) for ep in episodes]
            ))

        # 兜底：直接抽取播放链接
        if not play_url_list:
            eps = self._parse_episodes(html)
            if eps:
                play_from_list.append("默认")
                play_url_list.append("#".join(
                    ["{}${}".format(ep["name"], ep["url"]) for ep in eps]
                ))

        vod["vod_play_from"] = "$$$".join(play_from_list) if play_from_list else "默认"
        vod["vod_play_url"] = "$$$".join(play_url_list) if play_url_list else ""

        return {"list": [vod]}

    # ---------- 搜索 ----------
    def searchContent(self, key, quick, pg="1"):
        pg = int(pg) if str(pg).isdigit() else 1
        url = "{}/search/{}{}.html".format(
            self.host, "-------------.html?wd=", quote(key)
        )
        # 站点搜索常见形式: /search/-------------.html?wd=xxx&page=2
        if pg > 1:
            url = "{}/search/-------------.html?wd={}&page={}".format(
                self.host, quote(key), pg
            )
        html = self._get(url)
        videos = self._parse_list(html)
        # 有些页面在 <a class="search_wd"...> 里，用更宽的匹配
        if not videos:
            videos = self._parse_search_list(html)
        return {"list": videos, "page": pg}

    # ---------- 播放 ----------
    def playerContent(self, flag, id, vipFlags):
        # id 是 /play/4982328-1-1.html 或完整 URL
        play_url = id if id.startswith("http") else urljoin(self.host, id)
        html = self._get(play_url)
        if not html:
            return {"parse": 0, "playUrl": "", "url": "", "header": self.headers}

        # 从 player_aaaa 变量中提取
        m = re.search(r'var player_aaaa=(\{.*?\});', html, re.S)
        if m:
            try:
                data = json.loads(m.group(1))
                url = data.get("url", "")
                if url:
                    return {
                        "parse": 0,
                        "playUrl": "",
                        "url": url,
                        "header": {
                            "User-Agent": self.headers["User-Agent"],
                            "Referer": play_url,
                        },
                    }
            except Exception:
                pass

        # 兜底：直接搜 m3u8
        m2 = re.search(r'["\'](https?://[^"\']+\.m3u8[^"\']*)["\']', html)
        if m2:
            return {
                "parse": 0,
                "playUrl": "",
                "url": m2.group(1),
                "header": {
                    "User-Agent": self.headers["User-Agent"],
                    "Referer": play_url,
                },
            }

        # 交给壳的嗅探
        return {
            "parse": 1,
            "playUrl": play_url,
            "url": play_url,
            "header": self.headers,
        }

    # ---------- 解析工具 ----------
    def _m(self, html, pattern, dotall=False):
        flags = re.S if dotall else 0
        m = re.search(pattern, html, flags)
        return m.group(1).strip() if m else ""

    def _clean(self, s):
        if not s:
            return ""
        s = re.sub(r'<[^>]+>', '', s)
        s = s.replace("&nbsp;", " ").replace("&amp;", "&")
        s = s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
        return s.strip()

    def _normalize_detail_url(self, vid):
        if vid.startswith("http"):
            return vid
        if vid.startswith("/"):
            return urljoin(self.host, vid)
        # 纯数字
        return "{}/husou/{}.html".format(self.host, vid)

    def _parse_list(self, html):
        """从首页/分类页/搜索页解析影片列表"""
        videos = []
        if not html:
            return videos
        # 每个影片卡片 li 里包含: <a class="...myui-vodlist__thumb..." href="..." title="..." data-original="...">
        # 匹配 <li ...> ... href="xxx" title="yyy" ... (背景图 data-original)
        pattern = re.compile(
            r'<li[^>]*>\s*.*?'
            r'<a[^>]*class="[^"]*myui-vodlist__thumb[^"]*"[^>]*'
            r'href="(?P<href>[^"]+)"[^>]*'
            r'title="(?P<title>[^"]*)"[^>]*'
            r'data-original="(?P<pic>[^"]*)"[^>]*>'
            r'(?P<inner>.*?)</a>',
            re.S
        )
        for m in pattern.finditer(html):
            href = m.group("href")
            title = self._clean(m.group("title"))
            pic = m.group("pic")
            inner = m.group("inner")

            # remarks
            rem = self._m(inner, r'<span class="[^"]*pic-text[^"]*">([^<]+)</span>')
            if not rem:
                rem = self._m(inner, r'class="[^"]*pic-text[^"]*"[^>]*>([^<]+)<')

            # 过滤一些明显不是影片的链接
            if not re.search(r'/(husou|group|works|play)/\d+', href):
                continue

            # 提取 id
            vid = href
            if pic and not pic.startswith("http"):
                pic = urljoin(self.host, pic)
            videos.append({
                "vod_id": vid,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": rem,
            })
        # 去重
        seen = set()
        uniq = []
        for v in videos:
            if v["vod_id"] in seen:
                continue
            seen.add(v["vod_id"])
            uniq.append(v)
        return uniq

    def _parse_search_list(self, html):
        """搜索页兜底解析"""
        videos = []
        # 搜索页通常是 <a href="/husou/xxx.html" class="..." title="...">
        for m in re.finditer(
            r'<a[^>]*href="(/(?:husou|group|works)/\d+\.html)"[^>]*title="([^"]+)"',
            html
        ):
            videos.append({
                "vod_id": m.group(1),
                "vod_name": self._clean(m.group(2)),
                "vod_pic": "",
                "vod_remarks": "",
            })
        return videos

    def _parse_episodes(self, block):
        """解析播放列表 <ul> 里每个 <li><a href="/play/xxx-sid-nid.html">集数名</a></li>"""
        eps = []
        if not block:
            return eps
        for m in re.finditer(
            r'<a[^>]*href="([^"]*?/play/[^"]+\.html)"[^>]*>([^<]+)</a>',
            block
        ):
            href = m.group(1)
            name = self._clean(m.group(2)) or "播放"
            if not href.startswith("http"):
                href = urljoin(self.host, href)
            eps.append({"name": name, "url": href})
        # 有些页面是 /html/xxx.html 上一集/下一集这种形式，忽略

        # 去重
        seen = set()
        uniq = []
        for e in eps:
            if e["url"] in seen:
                continue
            seen.add(e["url"])
            uniq.append(e)
        return uniq