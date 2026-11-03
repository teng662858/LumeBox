# LumeSource: {"id":"pypack_f02cdca2ef3b69ca","name":"小淫虫","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# -*- coding: utf-8 -*-
import json
import ssl
import re
import urllib.request
import urllib.parse

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        pass

class Spider(BaseSpider):

    RECT_178_STYLE = {"type": "rect", "ratio": 1.78}

    MAIN_CLASSES = [
        {"type_id": "1", "type_name": "杏吧资源"},
        {"type_id": "2", "type_name": "滴滴资源"},
        {"type_id": "3", "type_name": "黄色仓库"}
    ]

    FILTERS_CACHE = {
        "1": [
            {
                "key": "sub_id",
                "name": "子分类",
                "value": [
                    {"n": "全部", "v": "1"},
                    {"n": "日韩无码", "v": "6"},
                    {"n": "国产精品", "v": "7"},
                    {"n": "日韩精品", "v": "8"},
                    {"n": "欧美精品", "v": "9"},
                    {"n": "自拍偷拍", "v": "11"},
                    {"n": "伦理影片", "v": "12"},
                    {"n": "中文字幕", "v": "20"},
                    {"n": "人妻系列", "v": "21"},
                    {"n": "制服诱惑", "v": "22"},
                    {"n": "强奸乱伦", "v": "23"},
                    {"n": "AV明星", "v": "24"},
                    {"n": "SM重味", "v": "25"},
                    {"n": "巨乳系列", "v": "26"},
                    {"n": "颜射系列", "v": "27"},
                    {"n": "口交视频", "v": "28"},
                    {"n": "自慰系列", "v": "29"},
                    {"n": "教师学生", "v": "30"},
                    {"n": "大秀视频", "v": "31"},
                    {"n": "明星换脸", "v": "32"},
                    {"n": "AV解说", "v": "33"}
                ]
            }
        ],
        "2": [
            {
                "key": "sub_id",
                "name": "子分类",
                "value": [
                    {"n": "全部", "v": "2"},
                    {"n": "特色专区", "v": "13"},
                    {"n": "精品动漫", "v": "14"},
                    {"n": "爱豆传媒", "v": "15"},
                    {"n": "国产精品", "v": "17"},
                    {"n": "国产探花", "v": "18"},
                    {"n": "国产乱伦", "v": "34"},
                    {"n": "美女主播", "v": "35"},
                    {"n": "网红大V精选", "v": "36"},
                    {"n": "ASMR", "v": "37"},
                    {"n": "制服诱惑", "v": "38"},
                    {"n": "日本无码", "v": "39"},
                    {"n": "日本有码", "v": "40"},
                    {"n": "网曝门事件", "v": "41"},
                    {"n": "麻豆传媒", "v": "42"},
                    {"n": "中文字幕", "v": "44"},
                    {"n": "欧美专区", "v": "45"},
                    {"n": "AV解说", "v": "46"},
                    {"n": "其他传媒", "v": "47"},
                    {"n": "SM调教", "v": "48"}
                ]
            }
        ],
        "3": [
            {
                "key": "sub_id",
                "name": "子分类",
                "value": [
                    {"n": "全部", "v": "3"},
                    {"n": "人妻熟女", "v": "49"},
                    {"n": "日本无码", "v": "50"},
                    {"n": "美乳巨乳", "v": "51"},
                    {"n": "强制侵犯", "v": "52"},
                    {"n": "制服诱惑", "v": "53"},
                    {"n": "绝色佳人", "v": "54"},
                    {"n": "风俗泡泡浴", "v": "55"},
                    {"n": "家庭乱伦", "v": "56"},
                    {"n": "少女萝莉", "v": "57"},
                    {"n": "SM调教", "v": "58"},
                    {"n": "绝顶潮吹", "v": "59"},
                    {"n": "魔镜系列", "v": "60"},
                    {"n": "时间停止", "v": "61"},
                    {"n": "催眠洗脑", "v": "62"},
                    {"n": "漫改系列", "v": "63"},
                    {"n": "电车痴汉", "v": "64"},
                    {"n": "淫欲痴女", "v": "65"},
                    {"n": "欧美区", "v": "43"},
                    {"n": "中国AV", "v": "16"},
                    {"n": "动漫精品", "v": "10"}
                ]
            }
        ]
    }

    def init(self, extend=""):
        self.site_url = "https://xyc01.eu.cc"
        self.ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        self.headers = {
            "User-Agent": self.ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        }

    def _fetch_html(self, url):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(url, headers=self.headers)
        try:
            resp = urllib.request.urlopen(req, timeout=10, context=ctx)
            content_bytes = resp.read()
            charset = "utf-8"
            content_type = resp.headers.get("Content-Type", "")
            if "charset=" in content_type.lower():
                charset = content_type.lower().split("charset=")[-1].split(";")[0].strip()
            return content_bytes.decode(charset, errors="ignore"), resp.getcode(), resp.geturl()
        except Exception as e:
            return str(e), 500, url

    def _clean_pic(self, pic_url):
        if not pic_url:
            return ""
        clean_pic = pic_url.replace("\\/", "/").strip()
        if not clean_pic.startswith("http"):
            clean_pic = urllib.parse.urljoin(self.site_url, clean_pic)
        return clean_pic

    def _clean_title(self, raw_title):
        if not raw_title:
            return "正片"
        t = re.sub(r'<[^>]+>', '', raw_title).strip()
        t = re.sub(r'\s*-\s*(?:正片|HD|高清观看|小淫虫).*$', '', t, flags=re.IGNORECASE)
        t = re.sub(r'^在线播放\s*', '', t, flags=re.IGNORECASE)
        return t.strip() if t.strip() else "正片"

    def homeContent(self, filter):
        return {
            "class": self.MAIN_CLASSES,
            "filters": self.FILTERS_CACHE,
            "style": self.RECT_178_STYLE
        }

    def homeVideoContent(self):
        return {"list": []}

    def _parse_cards_from_html(self, html):
        cards = []
        pattern = re.compile(
            r'<a\s+[^>]*href=[\'"][^\'"]*?/index\.php/vod/play/id/(\d+)[^\'"]*[\'"][^>]*title=[\'"]([^\'"]+)[\'"][^>]*>([\s\S]*?)(?=<a\s+[^>]*href=[\'"][^\'"]*?/index\.php/vod/play/id/|\Z)',
            re.IGNORECASE
        )
        
        matches = pattern.findall(html)
        if not matches:
            pattern_alt = re.compile(
                r'<a\s+[^>]*title=[\'"]([^\'"]+)[\'"][^>]*href=[\'"][^\'"]*?/index\.php/vod/play/id/(\d+)[^\'"]*[\'"][^>]*>([\s\S]*?)(?=<a\s+[^>]*href=[\'"][^\'"]*?/index\.php/vod/play/id/|\Z)',
                re.IGNORECASE
            )
            for t, v, b in pattern_alt.findall(html):
                matches.append((v, t, b))

        for vid, title, body in matches:
            if "ad-item" in body or "pg43h" in body:
                continue

            pic = ""
            img_tag_m = re.search(r'<img\s+[^>]*src=[\'"]([^\'"]+)[\'"]', body, re.IGNORECASE)
            if img_tag_m:
                candidate = img_tag_m.group(1)
                if "/statics/img/" not in candidate and not candidate.endswith(".gif"):
                    pic = self._clean_pic(candidate)

            if not pic:
                all_imgs = re.findall(r'src=[\'"]([^\'"]+)[\'"]', body, re.IGNORECASE)
                for cand in all_imgs:
                    if "/statics/img/" not in cand and not cand.endswith(".gif") and ("http" in cand or "/upload/" in cand):
                        pic = self._clean_pic(cand)
                        break

            cards.append({
                "vod_id": vid,
                "vod_name": self._clean_title(title) if title else ("编号 %s" % vid),
                "vod_pic": pic,
                "vod_remarks": "蝴蝶影视 | HD",
                "style": self.RECT_178_STYLE
            })
        return cards

    def categoryContent(self, tid, pg, filter, extend):
        target_id = tid
        if extend:
            if isinstance(extend, str):
                try:
                    extend = json.loads(extend)
                except Exception:
                    extend = {}
            if isinstance(extend, dict) and "sub_id" in extend:
                target_id = extend["sub_id"]

        url = "%s/index.php/vod/type/id/%s/page/%s.html" % (self.site_url, target_id, pg)
        html, code, final_url = self._fetch_html(url)

        cards = self._parse_cards_from_html(html)

        total = 0
        pagecount = 1
        page_match = re.search(r'共(\d+)条数据,当前(\d+)/(\d+)页', html)
        if page_match:
            total = int(page_match.group(1))
            pagecount = int(page_match.group(3))

        return {
            "page": int(pg),
            "pagecount": pagecount,
            "limit": len(cards),
            "total": total,
            "list": cards,
            "style": self.RECT_178_STYLE
        }

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) else ids
        play_url = "%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (self.site_url, vid)
        html, code, final_url = self._fetch_html(play_url)

        title_h1 = re.search(r'<h1[^>]*class=[\'"][^\'"]*yt-video-title[^\'"]*[\'"][^>]*>([\s\S]*?)</h1>', html)
        title_tag = re.search(r'<title>([^<]+)</title>', html)

        raw_title = ""
        if title_h1:
            raw_title = title_h1.group(1)
        elif title_tag:
            raw_title = title_tag.group(1)

        final_title = self._clean_title(raw_title)

        pic = ""
        pic_m = re.search(r'vodPic\s*=\s*[\'"]([^\'"]+)[\'"]', html)
        if pic_m and "/statics/img/" not in pic_m.group(1):
            pic = self._clean_pic(pic_m.group(1))

        if not pic:
            all_detail_imgs = re.findall(r'src=[\'"]([^\'"]+)[\'"]', html, re.IGNORECASE)
            for cand in all_detail_imgs:
                if "/statics/img/" not in cand and not cand.endswith(".gif") and ("/upload/" in cand or "xbpic" in cand or "uyjthen" in cand):
                    pic = self._clean_pic(cand)
                    break

        vod = {
            "vod_id": vid,
            "vod_name": final_title,
            "vod_pic": pic,
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": "🦋 官方频道: t.me/huliys9 | 官方交流: t.me/tvshare23",
            "vod_play_from": "蝴蝶专线",
            "vod_play_url": "正片$%s" % vid
        }

        return {"list": [vod]}

    def playerContent(self, flag, id, vipFlags):
        play_url = "%s/index.php/vod/play/id/%s/sid/1/nid/1.html" % (self.site_url, id)
        html, code, final_url = self._fetch_html(play_url)

        final_stream_url = ""
        player_match = re.search(r'var\s+player_aaaa\s*=\s*(\{[\s\S]*?\});', html)
        if player_match:
            raw_json_str = player_match.group(1)
            try:
                pj = json.loads(raw_json_str)
                final_stream_url = pj.get("url", "").replace("\\/", "/")
            except Exception:
                u_m = re.search(r'[\'"]url[\'"]\s*:\s*[\'"](https?:[^\'"]+?\.m3u8[^\'"]*)[\'"]', raw_json_str)
                if u_m:
                    final_stream_url = u_m.group(1).replace("\\/", "/")

        if not final_stream_url:
            m3u8_m = re.search(r'[\'"](https?://[^\'"]+?\.m3u8[^\'"]*)[\'"]', html)
            if m3u8_m:
                final_stream_url = m3u8_m.group(1).replace("\\/", "/")

        play_headers = {
            "User-Agent": self.ua,
            "Referer": self.site_url + "/"
        }

        return {
            "parse": 0,
            "url": final_stream_url,
            "header": play_headers
        }

    def searchContent(self, key, quick, pg="1"):
        url = "%s/index.php/vod/search/page/%s/wd/%s.html" % (self.site_url, pg, urllib.parse.quote(key))
        html, code, final_url = self._fetch_html(url)

        cards = self._parse_cards_from_html(html)

        return {
            "page": int(pg),
            "pagecount": 1,
            "limit": len(cards),
            "total": len(cards),
            "list": cards,
            "style": self.RECT_178_STYLE
        }

    def action(self, action):
        return ""

    def liveContent(self):
        return {}

    def localProxy(self, params):
        return []

    def manualVideoCheck(self):
        return False

    def isVideoFormat(self, url):
        return False

    def destroy(self):
        pass