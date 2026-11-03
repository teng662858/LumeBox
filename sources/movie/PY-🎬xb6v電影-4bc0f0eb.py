# LumeSource: {"id":"pypack_ad3bda6e4bc0f0eb","name":"🎬xb6v電影","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
6v电影 xb6v.com —— TVBox type=3 Python spider
数据源: https://www.xb6v.com/ (新版6v电影/旧版66影视)
类型: 高清电影下载站
说明: 已优化「展开所有分类」，将子分类（国产剧、短剧等）直接平铺至主导航标签，无需使用有兼容性问题的二级筛选器。
"""
import sys
import re
import gzip
import urllib.request
import urllib.parse

sys.path.append('..')
try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        def getCache(self, key): return None
        def setCache(self, key, value): return "fail"
        def delCache(self, key): return "fail"

HOST = "https://www.xb6v.com"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 基础分类
TOPS = [
    ("xijupian", "喜剧片"), ("dongzuopian", "动作片"), ("aiqingpian", "爱情片"),
    ("kehuanpian", "科幻片"), ("kongbupian", "恐怖片"), ("juqingpian", "剧情片"),
    ("zhanzhengpian", "战争片"), ("jilupian", "纪录片"), ("donghuapian", "动画片"),
    ("dianshiju", "电视剧"), ("ZongYi", "综艺"),
]
# 子分类
SUB = {
    "dianshiju": [("guoju", "国产剧"), ("duanju", "短剧"),
                  ("rihanju", "日韩剧"), ("oumeiju", "欧美剧")],
}

def _fetch(url, post=None, timeout=20):
    try:
        data = urllib.parse.urlencode(post).encode() if post else None
        req = urllib.request.Request(url, data=data, headers={
            "User-Agent": UA, "Referer": HOST + "/", "Accept-Encoding": "identity",
            "Content-Type": "application/x-www-form-urlencoded" if post else ""})
        raw = urllib.request.urlopen(req, timeout=timeout).read()
        if raw[:2] == b"\x1f\x8b":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        try:
            return raw.decode("utf-8")
        except Exception:
            return raw.decode("gbk", "ignore")
    except Exception:
        return ""


def _cards(html):
    out, seen = [], set()
    pat = (r'<a[^>]*href="(/[^"]*?/[^"]*?\d+\.html)"[^>]*title="([^"]+)"[^>]*>'
           r'[\s\S]{0,300}?<img[^>]*src="([^"]+)"')
    for m in re.finditer(pat, html or ""):
        try:
            href, title, pic = m.group(1), m.group(2), m.group(3)
            if not href or not title or href in seen:
                continue
            seen.add(href)
            out.append({"vod_id": href, "vod_name": title.strip(),
                        "vod_pic": pic, "vod_remarks": ""})
        except Exception:
            continue
    return out


class Spider(BaseSpider):
    def __init__(self):
        try:
            super(Spider, self).__init__()
        except Exception:
            pass
        self.name = "6v电影"

    def getName(self):
        return self.name

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def localProxy(self, param):
        return [404, "text/plain", ""]

    def isVideoFormat(self, url):
        low = (url or "").lower()
        return bool(re.search(r'\.(m3u8|mp4|ts|flv|mkv)', low)) or low.startswith("magnet:")

    def manualVideoCheck(self):
        return False

    # ==================== 分类展开核心逻辑 ====================
    def homeContent(self, filter):
        classes = []
        for top, name in TOPS:
            # 1. 压入主分类 (例如：电视剧)
            classes.append({"type_id": top, "type_name": name})
            
            # 2. 检查是否有子分类，如果有则直接平铺展开 (例如：电视剧/国产剧)
            if top in SUB:
                for sub_id, sub_name in SUB[top]:
                    # 组合成新的 type_id 格式（带有斜杠，会被 categoryContent 正确解析）
                    classes.append({
                        "type_id": f"{top}/{sub_id}", 
                        "type_name": sub_name
                    })
                    
        # 抛弃原有的二级 filters，因为已经全部分类直接铺开了，电视遥控器操作更直观
        return {"class": classes, "filters": {}}

    def homeVideoContent(self):
        return {"list": _cards(_fetch(HOST + "/dongzuopian/"))[:24]}

    def categoryContent(self, tid, pg, filter, extend):
        page = int(pg) if str(pg).isdigit() else 1
        tid = str(tid)
        
        # 兼容处理带斜杠的子分类ID，如 tid 为 "dianshiju/guoju" 
        # 会被格式化为合法的路径 "/dianshiju/guoju/"
        path = ("/" + tid.rstrip("/") + "/") if "/" in tid else ("/" + tid + "/")
        url = path if page == 1 else "%sindex_%d.html" % (path, page)
        
        cards = _cards(_fetch(HOST + url))
        return {"list": cards, "page": page,
                "pagecount": 9999 if cards else page,
                "limit": 30, "total": 99999}

    def detailContent(self, ids):
        href = str(ids[0]).split(",")[0].strip() if isinstance(ids, (list, tuple)) else str(ids)
        if not href.startswith("/"):
            href = "/" + href
        html = _fetch(HOST + href)
        if not html:
            return {"list": []}
            
        vod = {"vod_id": href, "vod_name": "", "vod_pic": "", "vod_year": "",
               "vod_actor": "", "vod_director": "",
               "vod_content": "", "vod_remarks": "", "vod_area": ""}
               
        t = re.search(r"<title>([^<]*)", html)
        if t:
            vod["vod_name"] = re.split(r"[_\-]", t.group(1))[0].strip()
        p = re.search(r'<img[^>]*src="([^"]+)"', html)
        if p:
            vod["vod_pic"] = p.group(1)

        def _field(lb):
            pat = r"◎\s*" + r"\s*".join(re.escape(c) for c in lb) + r"[：:]\s*([^\n<◎]{1,80})"
            m = re.search(pat, html)
            return m.group(1).strip().replace("&middot;", "·") if m else ""
            
        vod["vod_year"] = _field("年代")
        area = _field("产地")
        vod["vod_director"] = _field("导演")
        vod["vod_actor"] = _field("主演")
        if area:
            vod["vod_remarks"] = area
            
        dm = re.search(r"◎\s*简\s*介[\s\S]{0,40}?([\s\S]{0,1200}?)<", html)
        if dm:
            vod["vod_content"] = re.sub(r"<[^>]+>", "", dm.group(1)).strip()
            
        lines = {}
        for m in re.finditer(r'(magnet:[^"\'< ]+)|https?://(pan\.\w+\.(?:com|cn|net)[^"\'< ]+)', html):
            if m.group(1):
                lines.setdefault("磁力", []).append(m.group(1))
            elif m.group(2):
                u = m.group(2)
                if "xunlei" in u:
                    lines.setdefault("迅雷云盘", []).append(u)
                elif "quark" in u:
                    lines.setdefault("夸克云盘", []).append(u)
                elif "baidu" in u:
                    lines.setdefault("百度云盘", []).append(u)
                    
        froms, urls = [], []
        for name, eps in lines.items():
            froms.append(name)
            urls.append("#".join("%s$%s" % (name, u.replace("&amp;", "&")) for u in eps))
            
        if froms:
            vod["vod_play_from"] = "$$$".join(froms)
            vod["vod_play_url"] = "$$$".join(urls)
            
        return {"list": [vod]}

    def searchContent(self, key, quick, pg="1"):
        page = int(pg) if str(pg).isdigit() else 1
        kw = (key or "").strip()
        if page > 1 or not kw:
            return {"list": []}
            
        html = _fetch(HOST + "/e/search/so.php",
                      {"keyboard": kw, "show": "title", "tempid": "1",
                       "tbname": "", "mid": "1", "dopost": "1", "submit": "搜索"})
        cards = _cards(html)
        
        if not cards:
            seen = set()
            for m in re.finditer(r'href="(/[^"]*?/[^"]*?\d+\.html)"[^>]*>\s*([^<]{2,60})', html):
                href, title = m.group(1), m.group(2).strip()
                if href and title and href not in seen and "第" not in title[:2]:
                    seen.add(href)
                    cards.append({"vod_id": href, "vod_name": title,
                                  "vod_pic": "", "vod_remarks": ""})
                                  
        return {"list": cards, "page": page,
                "pagecount": page if len(cards) < 20 else page + 1,
                "limit": 20, "total": len(cards)}

    def playerContent(self, flag, id, vipFlags):
        u = str(id or "").replace("&amp;", "&")
        return {"parse": 0, "jx": 0, "url": u,
                "header": {"User-Agent": UA, "Referer": HOST + "/"}}