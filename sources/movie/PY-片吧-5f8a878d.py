# LumeSource: {"id":"pypack_6a802ce95f8a878d","name":"片吧","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
# @Author  : 基于梦的 JS 版移植 (修复线路/集数/播放)
# @Desc    : 片吧影院 TVBox Python 爬虫 (pbpb.tv, 苹果CMS V10)
# @dependencies: requests, beautifulsoup4

import re
import time
import requests
from urllib.parse import urljoin, urlparse
from bs4 import BeautifulSoup
from base.spider import Spider


class Spider(Spider):

    def getName(self):
        return "片吧影院"

    def init(self, extend=""):
        self.base_url = "https://www.pbpb.tv"
        self.ua = (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/144.0.0.0 Safari/537.36"
        )
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": self.ua,
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        })

        self._list_cache = {}
        self._list_cache_ttl = 900
        self._detail_cache = {}
        self._detail_cache_ttl = 1800
        self._search_cache = {}
        self._search_cache_ttl = 600

        self.categories = [
            {"id": "1",  "name": "全部"},
            {"id": "5",  "name": "动作片"},
            {"id": "6",  "name": "喜剧片"},
            {"id": "7",  "name": "恐怖片"},
            {"id": "8",  "name": "科幻片"},
            {"id": "9",  "name": "爱情片"},
            {"id": "10", "name": "剧情片"},
            {"id": "11", "name": "战争片"},
            {"id": "13", "name": "国产剧"},
            {"id": "14", "name": "港台剧"},
            {"id": "15", "name": "欧美剧"},
            {"id": "16", "name": "日韩剧"},
            {"id": "17", "name": "海外剧"},
            {"id": "21", "name": "动画电影"},
            {"id": "22", "name": "动画剧集"},
            {"id": "23", "name": "节目秀"},
        ]
        self.page_size = 24

    # ---------------- 基础请求与工具 ----------------

    def _get(self, url, timeout=15, headers=None, is_json=False):
        if not url.startswith("http"):
            url = self.base_url + url
        h = dict(self.session.headers)
        if headers:
            h.update(headers)
        try:
            r = self.session.get(url, headers=h, timeout=timeout, verify=False)
            r.raise_for_status()
            if is_json:
                return r.json()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except Exception:
            return None

    def _get_cache(self, cache_dict, key, ttl, producer):
        now = time.time()
        if key in cache_dict:
            val, ts = cache_dict[key]
            if now - ts < ttl:
                return val
        val = producer()
        if val:
            cache_dict[key] = (val, now)
        return val

    def _class_url(self, tid, page):
        pg = max(1, int(page or 1))
        if pg <= 1:
            return f"/class/{tid}-----------.html"
        return f"/class/{tid}--------{pg}---.html"

    @staticmethod
    def _extract_id_from_href(href):
        m = re.search(r"/(?:html|v|play|yun)/(\d+)", href or "")
        return m.group(1) if m else ""

    @staticmethod
    def _absolute_url(url):
        if not url:
            return ""
        if url.startswith("http"):
            return url
        return urljoin("https://www.pbpb.tv", url)

    # ---------------- 列表页解析 ----------------

    def _parse_vod_list(self, html):
        if not html:
            return []
        soup = BeautifulSoup(html, "html.parser")
        result = []
        for el in soup.select(".stui-vodlist__thumb"):
            href = el.get("href", "")
            vid = self._extract_id_from_href(href)
            name = (el.get("title") or "").strip()
            if not name:
                img = el.find("img")
                name = (img.get("alt") if img else "").strip()
            if not vid or not name:
                continue
            pic = el.get("data-original") or ""
            if not pic:
                img = el.find("img")
                if img:
                    pic = img.get("data-original") or img.get("src") or ""
            remarks_el = el.select_one(".pic-text")
            remarks = remarks_el.get_text(strip=True) if remarks_el else ""
            result.append({
                "vod_id": vid,
                "vod_name": name,
                "vod_pic": self._absolute_url(pic),
                "vod_remarks": remarks,
                "vod_year": "",
                "vod_director": "",
                "vod_actor": "",
                "vod_content": "",
            })
        return result

    # ---------------- 首页 ----------------

    def homeContent(self, filter):
        classes = [{"type_id": c["id"], "type_name": c["name"]} for c in self.categories]

        def produce():
            html = self._get(self._class_url("1", 1))
            return self._parse_vod_list(html)[:20]

        videos = self._get_cache(self._list_cache, "home:1", self._list_cache_ttl, produce)
        return {"class": classes, "filters": {}, "list": videos or []}

    def homeVideoContent(self):
        return {"list": []}

    # ---------------- 分类 ----------------

    def categoryContent(self, tid, pg, filter, extend):
        tid = str(tid or "1")
        pg = max(1, int(pg or 1))

        def produce():
            html = self._get(self._class_url(tid, pg))
            return self._parse_vod_list(html)

        videos = self._get_cache(self._list_cache, f"list:{tid}:{pg}", self._list_cache_ttl, produce) or []
        has_more = len(videos) >= self.page_size
        return {
            "page": pg,
            "pagecount": pg + 1 if has_more else pg,
            "limit": self.page_size,
            "total": pg * self.page_size + 1 if has_more else (pg - 1) * self.page_size + len(videos),
            "list": videos,
        }

    # ---------------- 详情 ----------------

    def _build_vod_from_api(self, item, vod_id):
        """把苹果CMS接口返回的条目转成 TVBox 详情对象"""
        vod = {
            "vod_id": str(vod_id),
            "vod_name": (item.get("vod_name") or "").strip(),
            "vod_pic": self._absolute_url(item.get("vod_pic") or ""),
            "vod_remarks": (item.get("vod_remarks") or "").strip(),
            "vod_content": (item.get("vod_content") or "").strip(),
            "vod_year": str(item.get("vod_year") or ""),
            "vod_director": (item.get("vod_director") or "").strip(),
            "vod_actor": (item.get("vod_actor") or "").strip(),
            "vod_area": (item.get("vod_area") or "").strip(),
        }

        play_from = (item.get("vod_play_from") or "").split("$$$")
        play_url = (item.get("vod_play_url") or "").split("$$$")

        froms, urls = [], []
        for i, group in enumerate(play_url):
            if not group:
                continue
            eps = []
            for ep in group.split("#"):
                if not ep:
                    continue
                if "$" in ep:
                    ep_name, _, ep_url = ep.partition("$")
                else:
                    ep_name, ep_url = ep, ep
                ep_name = ep_name.strip()
                ep_url = ep_url.strip()
                if ep_name and ep_url:
                    eps.append(f"{ep_name}${ep_url}")
            if not eps:
                continue
            src_name = play_from[i].strip() if i < len(play_from) and play_from[i].strip() else f"线路{i + 1}"
            froms.append(src_name)
            urls.append("#".join(eps))

        if froms:
            vod["vod_play_from"] = "$$$".join(froms)
            vod["vod_play_url"] = "$$$".join(urls)
        return vod

    def _fetch_detail_api(self, vod_id):
        """尝试多种苹果CMS接口获取详情"""
        candidates = [
            f"/index.php/ajax/data?mid=1&id={vod_id}",
            f"/api.php/provide/vod/?ac=detail&ids={vod_id}",
            f"/api.php/provide/vod/at/json/?ac=detail&ids={vod_id}",
        ]
        for path in candidates:
            data = self._get(path, headers={
                "Accept": "application/json, text/plain, */*",
                "X-Requested-With": "XMLHttpRequest",
            }, is_json=True)
            if not isinstance(data, dict):
                continue
            # 情况1：直接是视频对象
            if data.get("vod_name") or data.get("vod_play_url"):
                vod = self._build_vod_from_api(data, vod_id)
                if vod.get("vod_play_from"):
                    return vod
            # 情况2：苹果CMS api 规范 {code, list:[...]}
            lst = data.get("list")
            if isinstance(lst, list) and lst:
                vod = self._build_vod_from_api(lst[0], vod_id)
                if vod.get("vod_play_from"):
                    return vod
        return None

    def _parse_detail_html(self, html, vod_id):
        """HTML 兜底解析：兼容多种苹果CMS模板"""
        if not html:
            return None
        soup = BeautifulSoup(html, "html.parser")
        vod = {
            "vod_id": str(vod_id),
            "vod_name": "",
            "vod_pic": "",
            "vod_remarks": "",
            "vod_content": "",
            "vod_year": "",
            "vod_director": "",
            "vod_actor": "",
            "vod_area": "",
        }

        # 标题
        for sel in ["h1.title", "h1", ".stui-content__detail h1", ".vod-title"]:
            el = soup.select_one(sel)
            if el and el.get_text(strip=True):
                vod["vod_name"] = el.get_text(strip=True)
                break

        # 封面
        cover = soup.select_one(
            ".stui-content__detail img, .stui-content__thumb img, .vod-img img, .detail-pic img"
        )
        if cover:
            vod["vod_pic"] = self._absolute_url(
                cover.get("data-original") or cover.get("src") or ""
            )

        # 信息段落
        for p in soup.select(".stui-content__detail p, .content p, .detail-info p, .vod-info p"):
            text = p.get_text(" ", strip=True)
            if "：" not in text:
                continue
            key, _, val = text.partition("：")
            key, val = key.strip(), val.strip()
            if not val:
                continue
            if re.search(r"年份|年代", key):
                vod["vod_year"] = val
            elif re.search(r"导演", key):
                vod["vod_director"] = val
            elif re.search(r"主演|演员", key):
                vod["vod_actor"] = val
            elif re.search(r"地区|地域", key):
                vod["vod_area"] = val
            elif re.search(r"类型|分类", key):
                vod["vod_remarks"] = val
            elif re.search(r"状态", key) and not vod["vod_remarks"]:
                vod["vod_remarks"] = val
            elif re.search(r"剧情|简介|描述", key):
                vod["vod_content"] = val

        # 播放线路（多种选择器兼容）
        froms, urls = [], []
        playlists = soup.select(
            ".stui-content__playlist, .playlist, .content_playlist, "
            "ul.content_playlist, #playlist_1, #playlist_2, #playlist_3, #playlist_4"
        )
        seen_groups = set()
        for idx, pl in enumerate(playlists):
            eps = []
            for a in pl.find_all("a"):
                href = a.get("href", "")
                name = a.get_text(strip=True)
                if not href or not name:
                    continue
                # 相对 href 转成绝对，作为 playId
                full = href if href.startswith("http") else urljoin(self.base_url, href)
                if full in seen_groups:
                    continue
                eps.append(f"{name}${full}")
            if not eps:
                continue
            # 去重
            uniq = []
            seen = set()
            for e in eps:
                if e not in seen:
                    seen.add(e)
                    uniq.append(e)
            if not uniq:
                continue
            seen_groups.update(uniq)
            src_name = self._guess_source_name(pl, idx)
            froms.append(src_name)
            urls.append("#".join(uniq))

        if froms:
            vod["vod_play_from"] = "$$$".join(froms)
            vod["vod_play_url"] = "$$$".join(urls)
        return vod

    @staticmethod
    def _guess_source_name(pl, idx):
        """尝试从播放列表前面的标题猜测线路名"""
        prev = pl.find_previous_sibling()
        loop = 0
        while prev and loop < 5:
            cand = ""
            t = prev.select_one("h3, h4, .title, .stui-vodlist__head, .play-title")
            if t:
                cand = t.get_text(strip=True)
            else:
                cand = prev.get_text(strip=True)
            cand = re.sub(r"\s+", " ", cand or "").strip()
            if cand and len(cand) <= 20 and not re.match(
                r"^(选集|播放|线路|点播|高清|国语|粤语|剧情简介|播放列表)$", cand
            ):
                return cand
            prev = prev.find_previous_sibling()
            loop += 1
        return f"线路{idx + 1}"

    def detailContent(self, array):
        if not array:
            return {"list": []}
        vod_id = str(array[0]).strip()
        if not vod_id:
            return {"list": []}

        def produce():
            vod = self._fetch_detail_api(vod_id)
            if vod and vod.get("vod_play_from"):
                return vod
            html = self._get(f"/html/{vod_id}.html")
            return self._parse_detail_html(html, vod_id)

        vod = self._get_cache(self._detail_cache, f"detail:{vod_id}", self._detail_cache_ttl, produce)
        return {"list": [vod] if vod and vod.get("vod_name") else []}

    # ---------------- 搜索 ----------------

    def searchContent(self, key, quick, pg="1"):
        keyword = (key or "").strip()
        pg = max(1, int(pg or 1))
        if not keyword:
            return {"page": 1, "pagecount": 1, "limit": self.page_size, "total": 0, "list": []}

        def produce():
            url = (
                f"{self.base_url}/index.php/ajax/suggest?"
                f"mid=1&wd={requests.utils.quote(keyword)}"
                f"&limit={self.page_size}&page={pg}"
            )
            return self._get(url, headers={
                "Accept": "application/json, text/plain, */*",
                "X-Requested-With": "XMLHttpRequest",
            }, is_json=True)

        data = self._get_cache(self._search_cache, f"search:{keyword}:{pg}", self._search_cache_ttl, produce)
        raw = data.get("list", []) if isinstance(data, dict) else []
        videos = []
        for item in raw:
            vid = str(item.get("id") or "")
            name = (item.get("name") or "").strip()
            if vid and name:
                videos.append({
                    "vod_id": vid,
                    "vod_name": name,
                    "vod_pic": self._absolute_url(item.get("pic") or ""),
                    "vod_remarks": "",
                    "vod_year": "",
                    "vod_director": "",
                    "vod_actor": "",
                    "vod_content": "",
                })

        total = int(data.get("total", len(videos))) if isinstance(data, dict) else len(videos)
        pagecount = max(1, (total + self.page_size - 1) // self.page_size) if total else 1
        return {
            "page": pg,
            "pagecount": pagecount,
            "limit": self.page_size,
            "total": total,
            "list": videos,
        }

    # ---------------- 播放 ----------------

    def playerContent(self, flag, id, vipFlags):
        play_id = str(id or "").strip()
        if not play_id:
            return {"parse": 0, "url": "", "header": {}}

        # 情况1：已经是直链，直接播放
        if re.search(r"\.(m3u8|mp4)(\?|$|#)", play_id, re.I):
            return {
                "parse": 0,
                "url": play_id,
                "header": {
                    "User-Agent": self.ua,
                    "Referer": self.base_url + "/",
                },
                "jx": 0,
            }

        # 情况2：是播放页地址，需要从页面里提取真实视频
        try:
            path = urlparse(play_id).path if play_id.startswith("http") else play_id
            html = self._get(path, timeout=20)
            if not html:
                return {"parse": 0, "url": "", "header": {}}

            real_url = ""
            # 直接匹配 m3u8/mp4 的 url
            m = re.search(r'"url"\s*:\s*"([^"]+?\.(?:m3u8|mp4)[^"]*)"', html, re.I)
            if m:
                real_url = m.group(1).replace("\\/", "/")
            # 从 player_aaaa 块提取
            if not real_url:
                block = re.search(r'\{[^{}]*"flag"\s*:\s*"play"[^{}]*\}', html)
                if block:
                    bm = re.search(r'"url"\s*:\s*"([^"]+)"', block.group(0))
                    if bm:
                        real_url = bm.group(1).replace("\\/", "/")
            # 通用：从 m3u8 关键字抓
            if not real_url:
                m = re.search(r'(https?://[^\s"\'<>]+\.(?:m3u8|mp4)[^\s"\'<>]*)', html)
                if m:
                    real_url = m.group(1).replace("\\/", "/")

            if not real_url:
                return {"parse": 0, "url": "", "header": {}}

            return {
                "parse": 0 if re.search(r"\.(m3u8|mp4)", real_url, re.I) else 1,
                "url": real_url,
                "header": {
                    "User-Agent": self.ua,
                    "Referer": self.base_url + "/",
                    "Origin": self.base_url,
                },
                "jx": 0,
            }
        except Exception:
            return {"parse": 0, "url": "", "header": {}}

    def localProxy(self, params):
        return [200, "video/MP2T", "", ""]