# LumeSource: {"id":"pypack_188d3d5770e9c9dc","name":"桃花视频","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import json
import ssl
import sys
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass

RECT_178_STYLE = {"type": "rect", "ratio": 1.78}

CLASSES_CACHE = [
    {"type_id": "6", "type_name": "国产精品"},
    {"type_id": "7", "type_name": "华语AV"},
    {"type_id": "8", "type_name": "黑料吃瓜"},
    {"type_id": "22", "type_name": "学生"},
    {"type_id": "23", "type_name": "乱伦"},
    {"type_id": "24", "type_name": "探花"},
    {"type_id": "9", "type_name": "欧美"},
    {"type_id": "10", "type_name": "禁漫"},
    {"type_id": "25", "type_name": "日本无码"},
    {"type_id": "26", "type_name": "日本有码"},
    {"type_id": "27", "type_name": "主播网红"},
    {"type_id": "28", "type_name": "日本素人"},
    {"type_id": "29", "type_name": "AI短剧"}
]

class Spider(BaseSpider):
    API_URL = "https://thzy1.me/api.php/provide/vod/"

    def __init__(self):
        self.ssl_ctx = ssl.create_default_context()
        self.ssl_ctx.check_hostname = False
        self.ssl_ctx.verify_mode = ssl.CERT_NONE

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        return {
            "class": CLASSES_CACHE,
            "filters": {},
            "style": RECT_178_STYLE
        }

    def homeVideoContent(self):
        return {"list": []}

    def _fetch_json(self, url, timeout=10):
        req_headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        }
        req = urllib.request.Request(url, headers=req_headers)
        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=timeout) as resp:
                raw = resp.read()
                encoding = resp.headers.get_content_charset() or "utf-8"
                return json.loads(raw.decode(encoding, errors="replace"))
        except Exception:
            return {}

    def _format_remarks(self, raw_remarks):
        raw_remarks = (raw_remarks or "").strip()
        if raw_remarks:
            return "蝴蝶影视 | %s" % raw_remarks
        return "蝴蝶影视"

    def categoryContent(self, tid, pg, filter, extend):
        page_num = int(pg) if str(pg).isdigit() else 1
        url = "%s?ac=detail&t=%s&pg=%d" % (self.API_URL, str(tid), page_num)
        data = self._fetch_json(url)
        
        cards = []
        raw_list = data.get("list", []) or []
        for item in raw_list:
            cards.append({
                "vod_id": str(item.get("vod_id", "")),
                "vod_name": item.get("vod_name", ""),
                "vod_pic": item.get("vod_pic", ""),
                "vod_remarks": self._format_remarks(item.get("vod_remarks", "")),
                "style": RECT_178_STYLE
            })

        pagecount = int(data.get("pagecount", 1))
        total = int(data.get("total", len(cards)))
        return {
            "page": page_num,
            "pagecount": pagecount,
            "limit": len(cards),
            "total": total,
            "list": cards,
            "style": RECT_178_STYLE
        }

    def detailContent(self, ids):
        vod_id = ids[0] if isinstance(ids, list) and ids else str(ids)
        url = "%s?ac=detail&ids=%s" % (self.API_URL, str(vod_id))
        data = self._fetch_json(url)
        
        raw_list = data.get("list", []) or []
        if not raw_list:
            return {"list": []}
            
        item = raw_list[0]
        vod_play_from = item.get("vod_play_from", "")
        vod_play_url = item.get("vod_play_url", "")
        
        play_flags = []
        play_urls = []
        if vod_play_from and vod_play_url:
            from_list = vod_play_from.split("$$$")
            url_list = vod_play_url.split("$$$")
            for idx in range(len(from_list)):
                line_name = "蝴蝶专线" if idx == 0 else "蝴蝶专线%d" % (idx + 1)
                play_flags.append(line_name)
                current_url_group = url_list[idx] if idx < len(url_list) else ""
                play_urls.append(current_url_group)

        final_play_from = "$$$".join(play_flags) if play_flags else "蝴蝶专线"
        final_play_url = "$$$".join(play_urls) if play_urls else vod_play_url

        raw_blurb = (item.get("vod_blurb", "") or item.get("vod_content", "") or "").strip()
        formatted_content = "【蝴蝶影视】交流TG群: @tvshare23 | 严禁盗卖\n%s" % raw_blurb

        detail = {
            "vod_id": str(item.get("vod_id", vod_id)),
            "vod_name": item.get("vod_name", ""),
            "vod_pic": item.get("vod_pic", ""),
            "type_name": item.get("type_name", ""),
            "vod_year": item.get("vod_year", ""),
            "vod_area": item.get("vod_area", ""),
            "vod_remarks": self._format_remarks(item.get("vod_remarks", "")),
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": formatted_content,
            "vod_play_from": final_play_from,
            "vod_play_url": final_play_url
        }
        return {"list": [detail]}

    def playerContent(self, flag, id, vipFlags):
        return {
            "parse": 0,
            "playUrl": "",
            "url": id,
            "header": {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
        }

    def searchContent(self, key, quick, pg="1"):
        page_num = int(pg) if str(pg).isdigit() else 1
        encoded_key = urllib.parse.quote(key)
        url = "%s?ac=detail&wd=%s&pg=%d" % (self.API_URL, encoded_key, page_num)
        data = self._fetch_json(url)

        cards = []
        raw_list = data.get("list", []) or []
        for item in raw_list:
            cards.append({
                "vod_id": str(item.get("vod_id", "")),
                "vod_name": item.get("vod_name", ""),
                "vod_pic": item.get("vod_pic", ""),
                "vod_remarks": self._format_remarks(item.get("vod_remarks", "")),
                "style": RECT_178_STYLE
            })

        pagecount = int(data.get("pagecount", 1))
        total = int(data.get("total", len(cards)))
        return {
            "page": page_num,
            "pagecount": pagecount,
            "limit": len(cards),
            "total": total,
            "list": cards,
            "style": RECT_178_STYLE
        }

    def action(self, action):
        pass

    def liveContent(self):
        pass

    def localProxy(self, params):
        pass

    def manualVideoCheck(self):
        pass

    def isVideoFormat(self, url):
        return False

    def destroy(self):
        pass