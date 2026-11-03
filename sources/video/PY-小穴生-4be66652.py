# LumeSource: {"id":"pypack_491ad8064be66652","name":"小穴生","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import base64
import html
import json
import re
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

class Spider(BaseSpider):
    def __init__(self):
        super(Spider, self).__init__()
        self.site_url = "https://kkb2.sixnicexxs.cc"
        self.default_headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Referer": "https://kkb2.sixnicexxs.cc/"
        }

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        category_names = [
            ("6", "国产自拍"),
            ("7", "网爆黑料"),
            ("8", "无码专区"),
            ("9", "熟女人妻"),
            ("10", "欧美无码"),
            ("11", "麻豆传媒"),
            ("12", "萝莉少女"),
            ("20", "女优明星"),
            ("13", "制服诱惑"),
            ("14", "女同性爱"),
            ("15", "SM调教"),
            ("16", "三级伦理"),
            ("21", "多人群交"),
            ("22", "AV解说"),
            ("23", "AI换脸"),
            ("24", "美乳巨乳"),
            ("25", "中文字幕"),
            ("26", "强奸乱伦"),
            ("27", "卡通动漫"),
            ("28", "抖音视频"),
            ("29", "欧美系列"),
            ("30", "韩国主播"),
            ("31", "美女主播"),
            ("32", "网红头条")
        ]
        classes = []
        for cid, cname in category_names:
            classes.append({
                "type_id": cid,
                "type_name": cname,
                "style": RECT_178_STYLE
            })
        return {
            "class": classes,
            "filters": {},
            "list": [],
            "style": RECT_178_STYLE
        }

    def homeVideoContent(self):
        return {"list": []}

    def _fetch_html(self, url):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        try:
            req = urllib.request.Request(url, headers=self.default_headers)
            with urllib.request.urlopen(req, timeout=8.0, context=ctx) as resp:
                raw_bytes = resp.read()
                try:
                    return raw_bytes.decode("utf-8")
                except UnicodeDecodeError:
                    return raw_bytes.decode("gbk", errors="ignore")
        except Exception:
            return ""

    def _parse_cards_from_html(self, html_text):
        cards = []
        if not html_text:
            return cards

        tail_html = ""
        if "热搜" in html_text:
            tail_html = html_text.split("热搜", 1)[1]
        elif "dx-searchbar" in html_text:
            tail_html = html_text.split("dx-searchbar", 1)[1]
        else:
            tail_html = html_text

        vod_href_matches = re.finditer(r'<a\s+[^>]*href=["\']([^"\']*(?:/vod/play/|/vod/detail/|/detail/)[^"\']*)["\'][^>]*>([\s\S]*?)</a>', tail_html, re.IGNORECASE)

        for m in vod_href_matches:
            href = m.group(1)
            inner = m.group(2)

            id_match = re.search(r'id/(\d+)', href, re.IGNORECASE) or re.search(r'/(\d+)\.html', href, re.IGNORECASE)
            if not id_match:
                continue
            vid = id_match.group(1)

            t_m = re.search(r'title=["\'](.*?)["\']|alt=["\'](.*?)["\']', inner, re.IGNORECASE)
            name = (t_m.group(1) or t_m.group(2)).strip() if t_m else ""
            if not name:
                cleaned = re.sub(r'<[^>]+>', '', inner).strip()
                name = cleaned.split("\n")[0].strip() if cleaned else ""

            p_m = re.search(r'(?:data-original|data-src|data-echo|src)=["\']([^"\']+\.(?:jpg|jpeg|png|webp|gif)[^"\']*)["\']', inner, re.IGNORECASE)
            pic = p_m.group(1).strip() if p_m else ""
            if not pic:
                bg_m = re.search(r'background(?:-image)?:\s*url\((["\']?)([^)"\']+)\1\)', inner, re.IGNORECASE)
                if bg_m:
                    pic = bg_m.group(2).strip()

            if pic.startswith("//"):
                pic = "https:" + pic
            elif pic.startswith("/"):
                pic = self.site_url + pic

            rem_m = re.search(r'class=["\'][^"\']*(?:pic-text|remarks|notes|badge|dx-[^"\']*)[^"\']*["\'][^>]*>(.*?)<', inner, re.IGNORECASE)
            rem = rem_m.group(1).strip() if rem_m else ""
            remarks = "蝴蝶影视 | %s" % rem if rem else "蝴蝶影视"

            if vid not in [c["vod_id"] for c in cards] and name and pic:
                cards.append({
                    "vod_id": vid,
                    "vod_name": name,
                    "vod_pic": pic,
                    "vod_remarks": remarks,
                    "vod_actor": "🦋 TG群: @tvshare23",
                    "vod_director": "🦋 蝴蝶影视",
                    "style": RECT_178_STYLE
                })

        return cards

    def categoryContent(self, tid, pg, filter, extend):
        actual_id = tid if tid else "6"
        cur_page = int(pg) if pg else 1

        if cur_page == 1:
            target_url = "%s/index.php/vod/type/id/%s.html" % (self.site_url, actual_id)
        else:
            target_url = "%s/index.php/vod/type/id/%s/page/%s.html" % (self.site_url, actual_id, cur_page)

        html_text = self._fetch_html(target_url)
        cards = self._parse_cards_from_html(html_text)

        total_pages = cur_page + 1 if len(cards) >= 20 else cur_page

        return {
            "page": cur_page,
            "pagecount": total_pages,
            "limit": len(cards) if cards else 20,
            "total": 9999 if len(cards) >= 20 else (cur_page * 20),
            "list": cards,
            "style": RECT_178_STYLE
        }

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) and ids else str(ids)
        detail_url = "%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (self.site_url, vid)

        vod_detail = {
            "vod_id": vid,
            "vod_name": "蝴蝶影视精选",
            "vod_pic": "",
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": "🦋 官方交流群: @tvshare23 | 严禁传播违规违法内容",
            "vod_play_from": "蝴蝶专线",
            "vod_play_url": "正片$%s" % vid,
            "style": RECT_178_STYLE
        }

        html_text = self._fetch_html(detail_url)
        if html_text:
            title_m = re.search(r"<title>(.*?)</title>", html_text, re.IGNORECASE)
            if title_m:
                t = title_m.group(1).split("-")[0].strip()
                if t:
                    vod_detail["vod_name"] = t

        return {"list": [vod_detail]}

    def playerContent(self, flag, id, vipFlags):
        vid = str(id).strip()
        play_page_url = "%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (self.site_url, vid)
        html_text = self._fetch_html(play_page_url)

        play_url = ""
        config_match = re.search(r'player_data\s*=\s*(\{[\s\S]*?\})\s*;?', html_text, re.IGNORECASE)
        if not config_match:
            config_match = re.search(r'player_aaaa\s*=\s*(\{[\s\S]*?\})\s*;?', html_text, re.IGNORECASE)

        if config_match:
            try:
                cfg_obj = json.loads(config_match.group(1).strip())
                target_url = cfg_obj.get("url", "")
                encrypt_type = cfg_obj.get("encrypt", 0)

                if encrypt_type == 1:
                    target_url = urllib.parse.unquote(target_url)
                elif encrypt_type == 2:
                    target_url = base64.b64decode(target_url).decode("utf-8", errors="ignore")

                if target_url.startswith("http"):
                    play_url = target_url
            except Exception:
                pass

        if not play_url:
            m3u8_matches = re.findall(r'["\'](https?://[^\'"\s<>]+\.m3u8[^\'"\s<>]*)["\']', html_text, re.IGNORECASE)
            if m3u8_matches:
                play_url = m3u8_matches[0]
            else:
                mp4_matches = re.findall(r'["\'](https?://[^\'"\s<>]+\.mp4[^\'"\s<>]*)["\']', html_text, re.IGNORECASE)
                if mp4_matches:
                    play_url = mp4_matches[0]

        return {
            "parse": 0,
            "playUrl": "",
            "url": play_url,
            "header": self.default_headers
        }

    def searchContent(self, key, quick, pg="1"):
        search_url = "%s/index.php/vod/search.html?wd=%s" % (self.site_url, urllib.parse.quote(key))
        html_text = self._fetch_html(search_url)
        cards = self._parse_cards_from_html(html_text)
        return {
            "page": 1,
            "pagecount": 1,
            "limit": len(cards),
            "total": len(cards),
            "list": cards,
            "style": RECT_178_STYLE
        }

    def action(self, action):
        pass

    def liveContent(self):
        return {}

    def localProxy(self, params):
        return [200, "text/plain", "OK"]

    def manualVideoCheck(self):
        return False

    def isVideoFormat(self, url):
        return False

    def destroy(self):
        pass