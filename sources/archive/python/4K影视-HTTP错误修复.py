# LumeSource: {"id":"fourkyingshi_python_video","name":"4K影视（4kyingshi.net）","version":"1.0.1","category":"video","contentCategory":"movie","mirrors":["https://www.4kyingshi.net"],"settings":[{"key":"status","type":"info","title":"站点当前拒绝访问","description":"2026-11-03 实测首页和分类均 HTTP 403。修复版明确报错并支持自定义域名；未确认可用镜像，暂不加入总订阅。与现有 4kvms.org 源是不同站点。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
"""
4K影视 TVBox 采集源（drpy2 / Py 格式）
=====================================
站点：https://www.4kyingshi.net/

功能：
    - 首页推荐 + 五大分类（电视剧/电影/动漫/短剧/综艺）
    - 分类浏览（每页 100+ 部，站点本身为单页全量列表）
    - 影片详情（年份/地区/类型/导演/演员/语言/状态/剧情简介）
    - 多线路选集（实测 8 条线路：亮子线路/无广告播/优质点播……）
    - 播放地址直接取站点 player_aaaa 中的 m3u8 直链（无需解析）
    - 关键词搜索（站点 /search.html 接口）

导入方式：TVBox 中以 Py 源方式导入本文件，或放入 Py 源目录。
"""
import json
import re

try:
    from base.spider import Spider as _Base          # FongMi / dr_py Py 运行时
except Exception:
    _Base = object

HOST = "https://www.4kyingshi.net"
UA = "Baiduspider+(+http://www.baidu.com/search/spider.htm)"
PC_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
         "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
HEADERS = {
    "User-Agent": UA,
    "Referer": HOST + "/",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9",
}

# 一级分类（站点路径 /4kyingshitype/{id}.html）
CATES = [
    ("home", "首页推荐"),
    ("2", "电视剧"),
    ("1", "电影"),
    ("5", "动漫"),
    ("29", "短剧"),
    ("37", "综艺"),
]

# 子分类（站点路径 /vs/{id}.html）
SUBS = {
    2: [(30, "国产剧"), (15, "韩剧"), (14, "美剧"), (13, "港剧"),
        (16, "日剧"), (27, "台剧"), (28, "泰剧")],
    1: [(6, "动作片"), (7, "爱情片"), (58, "动画片"), (8, "科幻片"),
        (9, "恐怖片"), (10, "战争片"), (11, "喜剧片"), (12, "剧情片")],
}


class Spider(_Base):

    # ==================================================================
    # 网络请求
    # ==================================================================
    def _get(self, url, post_data=None):
        """Use the host HTTP channel and report rejected/error pages explicitly."""
        import requests
        try:
            response = (requests.post(url, data=post_data, headers=HEADERS, timeout=20)
                        if post_data is not None else
                        requests.get(url, headers=HEADERS, timeout=20))
        except Exception as error:
            raise RuntimeError("4K影视连接失败，请检查源网址、代理或稍后重试") from error
        status = response.status_code
        if status in (401, 403):
            raise RuntimeError("4K影视站点拒绝访问（HTTP %s），请在源设置检查代理/网址；这不是空片库" % status)
        if status >= 400:
            raise RuntimeError("4K影视站点请求失败（HTTP %s）" % status)
        text = response.text
        if any(marker in text.lower() for marker in ("just a moment", "cf-chl-", "checking your browser")):
            raise RuntimeError("NEED_WEBVIEW_VERIFY：4K影视需要先在网页中完成站点校验")
        if not text.strip():
            raise RuntimeError("4K影视返回空响应，请检查源网址")
        return text

    # ==================================================================
    # 解析工具（纯正则，不依赖 bs4）
    # ==================================================================
    @staticmethod
    def _clean(text):
        """去标签、去实体、去站点注入的 @xxx@ 垃圾串"""
        text = re.sub(r"<[^>]+>", "", text or "")
        text = re.sub(r"@[^@]{1,30}@", "", text)      # 注入广告串
        text = (text.replace("&nbsp;", " ").replace("&amp;", "&")
                    .replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">"))
        return re.sub(r"\s+", " ", text).strip()

    def _parse_cards(self, html):
        """解析列表卡片：分类页/首页/搜索页通用"""
        result, seen = [], set()
        # 卡片外层：分类/首页用 public-list-div，搜索页用 public-list-box
        blocks = re.findall(
            r'<div class="public-list-(?:div|box)[^"]*"[^>]*>(.*?)(?=<div class="public-list-(?:div|box)|<div class="footer|<footer)',
            html, re.S)
        if not blocks:                                 # 兜底：按 <a> 卡片切
            blocks = re.findall(
                r'(<a class="public-list-exp"[^>]*>(.*?)</a>)', html, re.S)
            blocks = [b[0] for b in blocks]

        for blk in blocks:
            m_id = re.search(r'/4kyingshidetail/(\d+)\.html', blk)
            if not m_id or m_id.group(1) in seen:
                continue
            seen.add(m_id.group(1))
            m_title = re.search(r'title="([^"]*)"', blk)
            m_img = re.search(r'data-src="([^"]+)"', blk) or \
                re.search(r'<img[^>]+src="(http[^"]+)"', blk)
            m_note = re.search(r'public-list-prb[^"]*"[^>]*>(?:<i[^>]*>)?\s*([^<]+)', blk)
            name = self._clean(m_title.group(1)) if m_title else ""
            if not name:
                continue
            result.append({
                "vod_id": m_id.group(1),
                "vod_name": name,
                "vod_pic": m_img.group(1) if m_img else "",
                "vod_remarks": self._clean(m_note.group(1)) if m_note else "",
            })
        return result

    # ==================================================================
    # TVBox 标准接口
    # ==================================================================
    def getName(self):
        return "4K影视"

    def init(self, extend=""):
        global HOST, HEADERS
        from urllib.parse import urlsplit
        domain = str(getattr(self, "config", {}).get("domain", "") or "").strip()
        if domain:
            parsed = urlsplit(domain)
            if parsed.scheme not in ("http", "https") or not parsed.netloc:
                raise ValueError("4K影视自定义网址必须是 http(s) 地址")
            HOST = domain.rstrip("/")
            HEADERS = dict(HEADERS, Referer=HOST + "/")

    def destroy(self):
        pass

    def isVideoFormat(self, url):
        return True

    def manualVideoCheck(self):
        return False

    def homeContent(self, filter):
        classes = [{"type_id": tid, "type_name": name} for tid, name in CATES]
        filters = {}
        # 为电视剧 / 电影挂上子分类筛选（对应站点 /vs/{id}.html）
        for tid, name in CATES:
            if tid in ("2", "1"):
                key = int(tid)
                opts = [{"n": "全部", "v": ""}] + \
                       [{"n": n, "v": str(sid)} for sid, n in SUBS.get(key, [])]
                filters[tid] = [{"key": "sub", "name": "类型", "value": opts}]
        return json.dumps({"class": classes, "filters": filters}, ensure_ascii=False)

    def homeVideoContent(self):
        html = self._get(HOST + "/")
        return json.dumps({"list": self._parse_cards(html)[:60]}, ensure_ascii=False)

    def categoryContent(self, tid, pg, filter, extend):
        try:
            pg = int(pg)
        except (TypeError, ValueError):
            pg = 1
        if tid == "home":
            html = self._get(HOST + "/")
            videos = self._parse_cards(html)
        else:
            # 子分类筛选：/vs/{sid}.html
            sub = ""
            if isinstance(extend, dict):
                sub = str(extend.get("sub", "") or "")
            if sub:
                url = f"{HOST}/vs/{sub}.html"
            else:
                url = f"{HOST}/4kyingshitype/{tid}.html"
            # 站点为单页全量列表，第 1 页后即结束
            if pg > 1:
                videos = []
            else:
                html = self._get(url)
                videos = self._parse_cards(html)
        pagecount = 1
        return json.dumps({
            "list": videos,
            "page": pg,
            "pagecount": pagecount,
            "limit": len(videos),
            "total": len(videos),
        }, ensure_ascii=False)

    def detailContent(self, ids):
        mid = ids[0] if isinstance(ids, list) else ids
        mid = re.sub(r"\D", "", str(mid)) or str(mid)
        html = self._get(f"{HOST}/4kyingshidetail/{mid}.html")

        # 片名
        name = ""
        for pat in (r'<h3 class="slide-info-title[^"]*"[^>]*>(.*?)</h3>',
                    r'<h1[^>]*>(.*?)</h1>',
                    r'<title>(.*?)</title>'):
            m = re.search(pat, html, re.S)
            if m:
                name = self._clean(m.group(1)).split("_")[0]
                if name:
                    break
        # 去掉「国产剧《xxx》」这类前缀
        name = re.sub(r"^[^《]{0,6}《(.+?)》.*$", r"\1", name)
        name = re.sub(r"^[《“\"]|[》”\"]$", "", name).split("在线观看")[0].strip()

        # 海报
        m_pic = re.search(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', html)
        if not m_pic:
            m_pic = re.search(r'class="[^"]*detail[^"]*"[^>]*>.*?data-src="([^"]+)"', html, re.S)

        # 信息区：<div class="slide-info"><strong class="r6">类型：</strong>xxx</div>
        info_fields = {}
        for m in re.finditer(
                r'<div class="slide-info[^"]*"[^>]*>\s*(?:<strong[^>]*>)?\s*'
                r'([^<：:]{1,8})\s*[：:]\s*(?:</strong>)?\s*(.*?)</div>', html, re.S):
            key = m.group(1).strip()
            val = self._clean(m.group(2))
            if key and key not in info_fields:
                info_fields[key] = val

        actor = info_fields.get("演员") or info_fields.get("主演", "")
        director = info_fields.get("导演", "")
        language = info_fields.get("语言", "")
        ep_now = info_fields.get("连载") or info_fields.get("备注", "")
        area = info_fields.get("地区") or info_fields.get("国家", "")
        type_name = info_fields.get("类型", "")
        if not type_name:
            mt = re.search(r'<meta[^>]+property="og:video:class"[^>]+content="([^"]*)"', html)
            if mt:
                type_name = mt.group(1)
        year = info_fields.get("年份", "")
        if not year:
            m_year = re.search(r'\b(19|20)\d{2}\b',
                               info_fields.get("", "") or html[:20000])
            if m_year:
                year = m_year.group(0)

        # 剧情简介
        content = ""
        for pat in (r'id="height_limit"[^>]*>(.*?)</div>',
                    r'class="text cor3"[^>]*>(.*?)</div>',
                    r'<meta[^>]+property="og:description"[^>]+content="([^"]+)"'):
            m = re.search(pat, html, re.S)
            if m:
                content = self._clean(m.group(1))
                if len(content) > 10:
                    break

        # 线路名（详情页顶部 tab）
        line_names = []
        for t in re.findall(r'<a class="swiper-slide"[^>]*>(.*?)</a>', html, re.S):
            nm = re.sub(r"\(\s*\d+\s*\)", "", self._clean(t)).strip()
            nm = re.sub(r"^[^\u4e00-\u9fa5A-Za-z]+", "", nm)
            if nm:
                line_names.append(nm)

        # 选集：每个 anthology-list-box 对应一条线路
        groups = re.findall(
            r'<ul class="anthology-list-play[^"]*"[^>]*>(.*?)</ul>', html, re.S)
        play_groups = []
        for g in groups:
            eps = re.findall(
                r'href="(/4kyingshiplay/[^"]+)"[^>]*>(.*?)</a>', g, re.S)
            if not eps:
                continue
            # 站点默认倒序，统一改为正序
            eps = list(reversed(eps))
            play_groups.append(
                "#".join(f"{self._clean(lab)}${url}" for url, lab in eps))

        if not play_groups:
            play_from, play_url = "默认线路", ""
        else:
            if len(line_names) != len(play_groups):
                line_names = [f"线路{i}" for i in range(1, len(play_groups) + 1)]
            play_from = "$$$".join(line_names)
            play_url = "$$$".join(play_groups)

        vod = {
            "vod_id": mid,
            "vod_name": name,
            "vod_pic": m_pic.group(1) if m_pic else "",
            "type_name": type_name,
            "vod_year": year,
            "vod_area": area,
            "vod_language": language,
            "vod_actor": actor,
            "vod_director": director,
            "vod_remarks": ep_now,
            "vod_content": content,
            "vod_play_from": play_from,
            "vod_play_url": play_url,
        }
        return json.dumps({"list": [vod]}, ensure_ascii=False)

    def playerContent(self, flag, id, vipFlags):
        path = id[0] if isinstance(id, list) else id
        if not path.startswith("http"):
            path = HOST + (path if path.startswith("/") else "/" + path)
        html = self._get(path)

        play_url = ""
        m = re.search(r"player_aaaa\s*=\s*(\{.*?\})\s*;?\s*</script>", html, re.S)
        if not m:
            m = re.search(r"player_aaaa\s*=\s*(\{.*?\});", html, re.S)
        if m:
            try:
                data = json.loads(m.group(1))
                play_url = data.get("url", "") or ""
                if play_url.startswith("http"):
                    # 直链无加密，直接交给播放器
                    pass
                else:
                    play_url = ""
            except ValueError:
                play_url = ""

        # 兜底：页面内直接出现的 m3u8 / mp4
        if not play_url:
            mm = re.search(r'(https?://[^\s"\'<>]+?\.(?:m3u8|mp4)[^\s"\'<>]*)', html)
            if mm:
                play_url = mm.group(1)

        return json.dumps({
            "parse": 0,
            "playUrl": "",
            "url": play_url,
            "flag": flag,
            "header": {
                "User-Agent": PC_UA,
                "Referer": HOST + "/",
            },
        }, ensure_ascii=False)

    def searchContent(self, key, quick):
        return self.searchContentPage(key, quick, 1)

    def searchContentPage(self, key, quick, pg):
        from urllib.parse import quote
        url = f"{HOST}/search.html?wd={quote(key)}"
        html = self._get(url)
        return json.dumps({"list": self._parse_cards(html)}, ensure_ascii=False)

    def localProxy(self, param):
        return [200, "text/plain", "", ""]
