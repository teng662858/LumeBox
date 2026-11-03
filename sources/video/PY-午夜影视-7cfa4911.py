# LumeSource: {"id":"pypack_035ad44c7cfa4911","name":"午夜影视","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import sys
import os
import json
import ssl
import re
import time
import html
import urllib.request
import urllib.parse
import http.cookiejar

try:
    from base.spider import Spider
except Exception:
    class Spider(object):
        def __init__(self):
            pass

class Spider(Spider):
    def __init__(self):
        super(Spider, self).__init__()
        self.site_url = "https://xn--5us888dtla.wuye.mom"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Connection": "keep-alive"
        }
        self.ssl_ctx = ssl._create_unverified_context()
        self.cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=self.ssl_ctx),
            urllib.request.HTTPCookieProcessor(self.cookie_jar)
        )

    def getName(self):
        return "蝴蝶影视"

    def init(self, extend=""):
        pass

    def isVideoFormat(self, url):
        return 0

    def manualVideoCheck(self):
        return 0

    def action(self, action):
        return {}

    def liveContent(self):
        return {}

    def localProxy(self, params):
        return []

    def destroy(self):
        pass

    def _fetch(self, url, retry=2):
        for attempt in range(retry + 1):
            try:
                req = urllib.request.Request(url, headers=self.headers)
                resp = self.opener.open(req, timeout=12)
                code = resp.getcode()
                raw_data = resp.read()
                charset = "utf-8"
                content_type = resp.headers.get("Content-Type", "")
                match = re.search(r"charset=([\w\-]+)", content_type, re.IGNORECASE)
                if match:
                    charset = match.group(1)
                text = raw_data.decode(charset, errors="ignore")
                if len(text) > 500:
                    return code, text
            except Exception:
                if attempt == retry:
                    break
                time.sleep(0.3)
        return 0, ""

    def homeContent(self, filter):
        classes = [
            {"type_id": "4", "type_name": "新电影"},
            {"type_id": "5", "type_name": "电视剧"},
            {"type_id": "9", "type_name": "热短剧"},
            {"type_id": "7", "type_name": "火动漫"},
            {"type_id": "6", "type_name": "综艺片"},
            {"type_id": "1", "type_name": "国产区"},
            {"type_id": "2", "type_name": "日韩区"},
            {"type_id": "3", "type_name": "精品区"},
            {"type_id": "8", "type_name": "伦理片"},
            {"type_id": "10", "type_name": "体育赛事"}
        ]
        filters = {
            "4": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "动漫电影", "v": "78"},
                {"n": "动作片", "v": "38"},
                {"n": "爱情片", "v": "39"},
                {"n": "喜剧片", "v": "40"},
                {"n": "科幻片", "v": "41"},
                {"n": "恐怖片", "v": "42"},
                {"n": "剧情片", "v": "43"},
                {"n": "战争片", "v": "44"},
                {"n": "惊悚片", "v": "45"},
                {"n": "纪录片", "v": "46"}
            ]}],
            "5": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "国产剧", "v": "47"},
                {"n": "香港剧", "v": "48"},
                {"n": "韩剧", "v": "49"},
                {"n": "欧美剧", "v": "50"},
                {"n": "日本剧", "v": "51"},
                {"n": "泰国剧", "v": "52"},
                {"n": "台湾剧", "v": "53"},
                {"n": "海外剧", "v": "54"}
            ]}],
            "9": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "重生民国", "v": "64"},
                {"n": "穿越现代", "v": "65"},
                {"n": "反转爽剧", "v": "66"},
                {"n": "言情总裁", "v": "67"},
                {"n": "现代都市", "v": "68"},
                {"n": "古装仙侠", "v": "69"},
                {"n": "悬疑烧脑", "v": "70"}
            ]}],
            "7": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "国产动漫", "v": "60"},
                {"n": "日本动漫", "v": "61"},
                {"n": "欧美动漫", "v": "62"},
                {"n": "海外动漫", "v": "63"}
            ]}],
            "6": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "大陆综艺", "v": "55"},
                {"n": "日韩综艺", "v": "56"},
                {"n": "港台综艺", "v": "57"},
                {"n": "欧美综艺", "v": "58"},
                {"n": "演唱会", "v": "59"}
            ]}],
            "1": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "强奸迷奸", "v": "11"},
                {"n": "网曝黑料", "v": "12"},
                {"n": "国产厂牌", "v": "13"},
                {"n": "丝袜制服", "v": "14"},
                {"n": "主播网红", "v": "15"},
                {"n": "AI换脸", "v": "16"},
                {"n": "家庭乱伦", "v": "17"},
                {"n": "SM调教", "v": "18"},
                {"n": "群交多P", "v": "19"}
            ]}],
            "2": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "学生萝莉", "v": "20"},
                {"n": "自拍偷拍", "v": "21"},
                {"n": "口交自慰", "v": "22"},
                {"n": "国产三级", "v": "23"},
                {"n": "素人特摄", "v": "24"},
                {"n": "无码高清", "v": "25"},
                {"n": "经典有码", "v": "26"},
                {"n": "中文字幕", "v": "27"},
                {"n": "日韩三级", "v": "28"}
            ]}],
            "3": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "日韩精选", "v": "29"},
                {"n": "国产精选", "v": "30"},
                {"n": "欧美精选", "v": "31"},
                {"n": "VR专区", "v": "32"},
                {"n": "厂牌经典", "v": "33"},
                {"n": "重口调教", "v": "34"},
                {"n": "人兽动物", "v": "35"},
                {"n": "激情H漫", "v": "36"},
                {"n": "异族风情", "v": "37"}
            ]}],
            "10": [{"key": "sub", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "篮球", "v": "71"},
                {"n": "足球", "v": "72"},
                {"n": "网球", "v": "73"},
                {"n": "斯诺克", "v": "74"},
                {"n": "LPL", "v": "75"}
            ]}]
        }
        return {"class": classes, "filters": filters, "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        actual_tid = str(tid)
        if extend and isinstance(extend, dict) and extend.get("sub"):
            actual_tid = str(extend.get("sub"))

        page_int = int(pg) if str(pg).isdigit() else 1
        
        if page_int <= 1:
            req_url = "%s/vodshow/%s-----------.html" % (self.site_url, actual_tid)
        else:
            req_url = "%s/vodshow/%s--------%d---.html" % (self.site_url, actual_tid, page_int)

        videos = []
        page_count = page_int
        total_records = 0

        try:
            code, raw_html = self._fetch(req_url)
            page_text = html.unescape(raw_html)
            
            card_blocks = re.findall(r'<li[^>]*class=[\'"][^\'"]*stui-vodlist__item[^\'"]*[\'"][^>]*>([\s\S]*?)</li>', page_text)
            if not card_blocks:
                card_blocks = re.findall(r'(<a[^>]*class=[\'"][^\'"]*stui-vodlist__thumb[^\'"]*[\'"][\s\S]*?</a>)', page_text)

            for block in card_blocks:
                id_match = re.search(r'href=[\'"][^\'"]*?/voddetail/(\d+)\.html[\'"]', block)
                if not id_match:
                    continue
                vod_id = id_match.group(1)

                name_match = re.search(r'title=[\'"]([^\'"]+)[\'"]', block)
                vod_name = name_match.group(1).strip() if name_match else ""

                pic_match = re.search(r'data-original=[\'"]([^\'"]+)[\'"]', block)
                if not pic_match:
                    pic_match = re.search(r'src=[\'"]([^\'"]+)[\'"]', block)
                vod_pic = pic_match.group(1) if pic_match else ""
                if vod_pic and not vod_pic.startswith("http"):
                    vod_pic = urllib.parse.urljoin(self.site_url, vod_pic)

                remarks_match = re.search(r'<span[^>]*class=[\'"][^\'"]*pic-text[^\'"]*[\'"][^>]*>([\s\S]*?)</span>', block)
                raw_remarks = remarks_match.group(1).strip() if remarks_match else ""
                clean_remarks = re.sub(r"<[^>]+>", "", raw_remarks).strip()
                
                if clean_remarks:
                    final_remarks = "蝴蝶影视 | %s" % clean_remarks
                else:
                    final_remarks = "蝴蝶影视"

                videos.append({
                    "vod_id": vod_id,
                    "vod_name": vod_name,
                    "vod_pic": vod_pic,
                    "vod_remarks": final_remarks
                })

            page_numbers = re.findall(r'/vodshow/[0-9\-]+?(\d+)---\.html', page_text)
            if page_numbers:
                page_count = max([int(x) for x in page_numbers if x.isdigit()] + [page_int])
            else:
                page_count = page_int + 1 if len(videos) >= 20 else page_int

            total_records = page_count * len(videos) if len(videos) > 0 else 0

        except Exception:
            pass

        return {
            "page": page_int,
            "pagecount": page_count,
            "limit": len(videos),
            "total": total_records,
            "list": videos
        }

    def detailContent(self, ids):
        target_id = ids[0] if isinstance(ids, list) and ids else str(ids)
        detail_url = "%s/voddetail/%s.html" % (self.site_url, target_id)
        
        detail_item = {
            "vod_id": str(target_id),
            "vod_name": "",
            "vod_pic": "",
            "type_name": "",
            "vod_year": "",
            "vod_area": "",
            "vod_remarks": "蝴蝶影视",
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": "",
            "vod_play_from": "",
            "vod_play_url": ""
        }

        try:
            code, raw_html = self._fetch(detail_url)
            page_text = html.unescape(raw_html)

            name_match = re.search(r'<h1[^>]*class=[\'"][^\'"]*title[^\'"]*[\'"][^>]*>([\s\S]*?)</h1>', page_text)
            if not name_match:
                name_match = re.search(r'<title>(.*?)</title>', page_text)
            if name_match:
                raw_name = re.sub(r"<[^>]+>", "", name_match.group(1)).strip()
                detail_item["vod_name"] = raw_name.split("-")[0].replace("剧情介绍", "").strip()

            pic_match = re.search(r'<div[^>]*class=[\'"][^\'"]*stui-content__thumb[^\'"]*[\'"][\s\S]*?<img[^>]*data-original=[\'"]([^\'"]+)[\'"]', page_text)
            if not pic_match:
                pic_match = re.search(r'<div[^>]*class=[\'"][^\'"]*stui-content__thumb[^\'"]*[\'"][\s\S]*?<img[^>]*src=[\'"]([^\'"]+)[\'"]', page_text)
            if pic_match:
                pic_url = pic_match.group(1)
                if not pic_url.startswith("http"):
                    pic_url = urllib.parse.urljoin(self.site_url, pic_url)
                detail_item["vod_pic"] = pic_url

            real_desc = ""
            desc_patterns = [
                r'<span[^>]*class=[\'"][^\'"]*(?:detail-content|desc|data)[^\'"]*[\'"][^>]*>([\s\S]*?)</span>',
                r'<div[^>]*class=[\'"][^\'"]*stui-content__desc[^\'"]*[\'"][^>]*>([\s\S]*?)</div>',
                r'<p[^>]*class=[\'"][^\'"]*desc[^\'"]*[\'"][^>]*>([\s\S]*?)</p>'
            ]
            for pattern in desc_patterns:
                desc_match = re.search(pattern, page_text)
                if desc_match:
                    candidate = re.sub(r"<[^>]+>", "", desc_match.group(1)).strip()
                    if len(candidate) > len(real_desc):
                        real_desc = candidate

            official_notice = "🦋 TG群: @tvshare23\n🦋 蝴蝶影视 独家定制\n\n"
            if real_desc:
                detail_item["vod_content"] = official_notice + real_desc
            else:
                detail_item["vod_content"] = official_notice + "暂无剧情简介"

            from_list = []
            url_list = []

            playlist_blocks = re.findall(r'<ul[^>]*class=[\'"][^\'"]*(?:stui-content__playlist|playlist)[^\'"]*[\'"][^>]*>([\s\S]*?)</ul>', page_text)
            if not playlist_blocks:
                playlist_blocks = re.findall(r'<ul[^>]*class=[\'"][^\'"]*clearfix[^\'"]*[\'"][^>]*>([\s\S]*?)</ul>', page_text)

            for idx, block in enumerate(playlist_blocks):
                episodes = re.findall(r'<a[^>]*href=[\'"]([^\'"]*?/vodplay/([^\'"]+)\.html)[\'"][^>]*>([\s\S]*?)</a>', block)
                if not episodes:
                    continue
                
                ep_strs = []
                for full_play_href, play_route, ep_name in episodes:
                    c_name = re.sub(r"<[^>]+>", "", ep_name).strip()
                    ep_strs.append("%s$%s" % (c_name, play_route))

                if ep_strs:
                    from_list.append("播放线路 %d" % (idx + 1))
                    url_list.append("#".join(ep_strs))

            if from_list:
                detail_item["vod_play_from"] = "$$$".join(from_list)
                detail_item["vod_play_url"] = "$$$".join(url_list)

        except Exception:
            pass

        return {"list": [detail_item]}

    def playerContent(self, flag, id, vipFlags):
        play_url = "%s/vodplay/%s.html" % (self.site_url, id)
        final_video_url = ""

        try:
            code, html_content = self._fetch(play_url)
            player_match = re.search(r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*</script>', html_content)
            if player_match:
                try:
                    pobj = json.loads(player_match.group(1))
                    if isinstance(pobj, dict) and pobj.get("url"):
                        raw_stream = pobj.get("url")
                        if raw_stream.startswith("http"):
                            final_video_url = raw_stream
                        else:
                            final_video_url = urllib.parse.unquote(raw_stream)
                except Exception:
                    pass

            if not final_video_url:
                streams = re.findall(r'[\'"](https?://[^\'"\s]+\.(?:m3u8|mp4)[^\'"\s]*)[\'"]', html_content)
                if streams:
                    final_video_url = streams[0]

        except Exception:
            pass

        if not final_video_url:
            final_video_url = play_url

        return {
            "parse": 0,
            "url": final_video_url,
            "header": self.headers
        }

    def searchContent(self, key, quick, pg="1"):
        page_int = int(pg) if str(pg).isdigit() else 1
        encoded_wd = urllib.parse.quote(key)
        if page_int <= 1:
            search_url = "%s/vodsearch/-------------.html?wd=%s" % (self.site_url, encoded_wd)
        else:
            search_url = "%s/vodsearch/%s----------%d---.html?wd=%s" % (self.site_url, encoded_wd, page_int, encoded_wd)

        videos = []
        try:
            code, raw_html = self._fetch(search_url)
            page_text = html.unescape(raw_html)

            card_blocks = re.findall(r'<li[^>]*class=[\'"][^\'"]*stui-vodlist__item[^\'"]*[\'"][^>]*>([\s\S]*?)</li>', page_text)
            if not card_blocks:
                card_blocks = re.findall(r'(<a[^>]*class=[\'"][^\'"]*stui-vodlist__thumb[^\'"]*[\'"][\s\S]*?</a>)', page_text)

            for block in card_blocks:
                id_match = re.search(r'href=[\'"][^\'"]*?/voddetail/(\d+)\.html[\'"]', block)
                if not id_match:
                    continue
                vod_id = id_match.group(1)

                name_match = re.search(r'title=[\'"]([^\'"]+)[\'"]', block)
                vod_name = name_match.group(1).strip() if name_match else ""

                pic_match = re.search(r'data-original=[\'"]([^\'"]+)[\'"]', block)
                if not pic_match:
                    pic_match = re.search(r'src=[\'"]([^\'"]+)[\'"]', block)
                vod_pic = pic_match.group(1) if pic_match else ""
                if vod_pic and not vod_pic.startswith("http"):
                    vod_pic = urllib.parse.urljoin(self.site_url, vod_pic)

                remarks_match = re.search(r'<span[^>]*class=[\'"][^\'"]*pic-text[^\'"]*[\'"][^>]*>([\s\S]*?)</span>', block)
                raw_remarks = remarks_match.group(1).strip() if remarks_match else ""
                clean_remarks = re.sub(r"<[^>]+>", "", raw_remarks).strip()
                
                if clean_remarks:
                    final_remarks = "蝴蝶影视 | %s" % clean_remarks
                else:
                    final_remarks = "蝴蝶影视"

                videos.append({
                    "vod_id": vod_id,
                    "vod_name": vod_name,
                    "vod_pic": vod_pic,
                    "vod_remarks": final_remarks
                })
        except Exception:
            pass

        return {
            "page": page_int,
            "pagecount": page_int + 1 if len(videos) >= 20 else page_int,
            "limit": len(videos),
            "total": len(videos),
            "list": videos
        }