# LumeSource: {"id":"pypack_549496d6e862b0db","name":"成人B站","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import sys
import os
import json
import re
import ssl
import urllib.request
import urllib.parse
import urllib.error
import gzip
import zlib

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass

RECT_178_STYLE = {"type": "rect", "ratio": 1.78}

CLASSES_CACHE = [
    {"type_id": "7", "type_name": "国产大制作"},
    {"type_id": "6", "type_name": "偷拍自拍"},
    {"type_id": "10", "type_name": "黑料网曝"},
    {"type_id": "29", "type_name": "会所技师"},
    {"type_id": "31", "type_name": "探花约炮"},
    {"type_id": "30", "type_name": "国产推荐"},
    {"type_id": "33", "type_name": "国产直播"},
    {"type_id": "34", "type_name": "淫妻绿帽"},
    {"type_id": "35", "type_name": "制服诱惑"},
    {"type_id": "8", "type_name": "乱伦毁三观"},
    {"type_id": "9", "type_name": "主播女网红"},
    {"type_id": "21", "type_name": "淫乱学生妹"},
    {"type_id": "3", "type_name": "欧美精品"},
    {"type_id": "13", "type_name": "高清无码"},
    {"type_id": "14", "type_name": "中文字幕"},
    {"type_id": "24", "type_name": "高清有码"},
    {"type_id": "27", "type_name": "无码流出"},
    {"type_id": "28", "type_name": "FC2"},
    {"type_id": "22", "type_name": "动漫精选"},
    {"type_id": "32", "type_name": "韩国直播"},
    {"type_id": "36", "type_name": "重口猎奇"},
    {"type_id": "37", "type_name": "东京热"},
    {"type_id": "38", "type_name": "一本道"}
]

class Spider(BaseSpider):
    def __init__(self):
        super(Spider, self).__init__()
        self.api_base = "https://fqzy.me/api.php/provide/vod"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            "Accept": "application/json,text/javascript,*/*;q=0.01",
            "Connection": "keep-alive"
        }

    def init(self, extend=""):
        pass

    def _http_get(self, url):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                raw_data = resp.read()
                encoding = resp.headers.get("Content-Encoding", "").lower()
                if "gzip" in encoding:
                    try:
                        raw_data = gzip.decompress(raw_data)
                    except Exception:
                        pass
                elif "deflate" in encoding:
                    try:
                        raw_data = zlib.decompress(raw_data)
                    except Exception:
                        pass
                charset = resp.headers.get_content_charset() or "utf-8"
                try:
                    return raw_data.decode(charset, errors="ignore")
                except Exception:
                    return raw_data.decode("utf-8", errors="ignore")
        except Exception:
            return ""

    def homeContent(self, filter):
        return {
            "class": CLASSES_CACHE,
            "filters": {},
            "style": RECT_178_STYLE
        }

    def homeVideoContent(self):
        return {"list": [], "style": RECT_178_STYLE}

    def categoryContent(self, tid, pg, filter, extend):
        page_num = str(pg) if pg else "1"
        url = "%s/?ac=videolist&t=%s&pg=%s" % (self.api_base, tid, page_num)
        json_str = self._http_get(url)
        
        cards = []
        pagecount = 1
        total = 0

        if json_str:
            try:
                data = json.loads(json_str)
                pagecount = int(data.get("pagecount", 1))
                total = int(data.get("total", 0))
                for item in data.get("list", []):
                    vid = str(item.get("vod_id", ""))
                    name = item.get("vod_name", "").strip()
                    pic = item.get("vod_pic", "").strip()
                    remarks = item.get("vod_remarks", "").strip() or item.get("type_name", "").strip()
                    brand_remarks = "蝴蝶影视 | %s" % remarks if remarks else "蝴蝶影视"
                    cards.append({
                        "vod_id": vid,
                        "vod_name": name,
                        "vod_pic": pic,
                        "vod_remarks": brand_remarks,
                        "style": RECT_178_STYLE
                    })
            except Exception:
                pass

        return {
            "page": int(page_num),
            "pagecount": pagecount,
            "limit": len(cards),
            "total": total,
            "list": cards,
            "style": RECT_178_STYLE
        }

    def detailContent(self, ids):
        vod_id = ids[0] if isinstance(ids, list) else str(ids)
        if "@@" in vod_id:
            vod_id = vod_id.split("@@", 1)[0]

        url = "%s/?ac=detail&ids=%s" % (self.api_base, vod_id)
        json_str = self._http_get(url)

        matched_item = None
        play_url = ""

        if json_str:
            try:
                data = json.loads(json_str)
                v_list = data.get("list", [])
                if v_list:
                    matched_item = v_list[0]
                    p_url = matched_item.get("vod_play_url", "")
                    if p_url:
                        play_url = p_url
            except Exception:
                pass

        if not play_url:
            play_url = "第1集$https://fqm3u8.cc/index.m3u8"

        name = matched_item.get("vod_name", "蝴蝶影视") if matched_item else "蝴蝶影视"
        pic = matched_item.get("vod_pic", "") if matched_item else ""
        tname = matched_item.get("type_name", "精选") if matched_item else "精选"
        year = matched_item.get("vod_year", "2026") if matched_item else "2026"
        area = matched_item.get("vod_area", "中国") if matched_item else "中国"

        vod_item = {
            "vod_id": vod_id,
            "vod_name": name,
            "vod_pic": pic,
            "type_name": tname,
            "vod_year": year,
            "vod_area": area,
            "vod_remarks": "蝴蝶影视",
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": "🦋 官方交流群: @tvshare23 | 严禁外传与非法贩售，请在24小时内删除。",
            "vod_play_from": "蝴蝶专线",
            "vod_play_url": play_url
        }
        return {"list": [vod_item]}

    def playerContent(self, flag, id, vipFlags):
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        }
        if id.startswith("http") and (".m3u8" in id or ".mp4" in id):
            return {
                "parse": 0,
                "playUrl": "",
                "url": id,
                "header": headers
            }
        return {
            "parse": 1,
            "playUrl": "",
            "url": id,
            "header": headers
        }

    def searchContent(self, key, quick, pg="1"):
        page_num = str(pg) if pg else "1"
        encoded_key = urllib.parse.quote(key)
        url = "%s/?ac=videolist&wd=%s&pg=%s" % (self.api_base, encoded_key, page_num)
        json_str = self._http_get(url)
        
        cards = []
        pagecount = 1
        total = 0

        if json_str:
            try:
                data = json.loads(json_str)
                pagecount = int(data.get("pagecount", 1))
                total = int(data.get("total", 0))
                for item in data.get("list", []):
                    vid = str(item.get("vod_id", ""))
                    name = item.get("vod_name", "").strip()
                    pic = item.get("vod_pic", "").strip()
                    remarks = item.get("vod_remarks", "").strip() or item.get("type_name", "").strip()
                    brand_remarks = "蝴蝶影视 | %s" % remarks if remarks else "蝴蝶影视"
                    cards.append({
                        "vod_id": vid,
                        "vod_name": name,
                        "vod_pic": pic,
                        "vod_remarks": brand_remarks,
                        "style": RECT_178_STYLE
                    })
            except Exception:
                pass

        return {
            "page": int(page_num),
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
        return [200, "text/plain", ""]

    def manualVideoCheck(self):
        return False

    def isVideoFormat(self, url):
        return False

    def destroy(self):
        pass