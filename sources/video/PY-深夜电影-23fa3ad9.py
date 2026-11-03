# LumeSource: {"id":"pypack_8834e2ad23fa3ad9","name":"深夜电影","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding=utf-8
import base64
import html
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.append('..')

try:
    from base.spider import Spider as BaseSpider
except Exception:
    class BaseSpider(object):
        def log(self, msg):
            pass

_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE

DEFAULT_URL = "https://xn--essr89b.shenye.sbs"
UA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

MODULES = [
    ("9", "短剧区"),
    ("4", "好电影"),
    ("5", "新剧集"),
    ("7", "动漫区"),
    ("6", "综艺片"),
    ("1", "十八禁"),
    ("2", "私密区"),
    ("3", "午夜区"),
    ("8", "伦理区"),
    ("10", "体育区")
]

SUB_FILTERS = {
    "9": [
        {"n": "全部", "v": "9"},
        {"n": "重生", "v": "64"},
        {"n": "穿越", "v": "65"},
        {"n": "反转", "v": "66"},
        {"n": "言情", "v": "67"},
        {"n": "现代", "v": "68"},
        {"n": "古装", "v": "69"},
        {"n": "悬疑", "v": "70"}
    ],
    "4": [
        {"n": "全部", "v": "4"},
        {"n": "动漫", "v": "78"},
        {"n": "动作", "v": "38"},
        {"n": "爱情", "v": "39"},
        {"n": "喜剧", "v": "40"},
        {"n": "科幻", "v": "41"},
        {"n": "恐怖", "v": "42"},
        {"n": "剧情", "v": "43"},
        {"n": "战争", "v": "44"},
        {"n": "惊悚", "v": "45"},
        {"n": "纪录", "v": "46"}
    ],
    "5": [
        {"n": "全部", "v": "5"},
        {"n": "国产", "v": "47"},
        {"n": "香港", "v": "48"},
        {"n": "韩剧", "v": "49"},
        {"n": "欧美", "v": "50"},
        {"n": "日本", "v": "51"},
        {"n": "泰国", "v": "52"},
        {"n": "台湾", "v": "53"},
        {"n": "海外", "v": "54"}
    ],
    "7": [
        {"n": "全部", "v": "7"},
        {"n": "国产", "v": "60"},
        {"n": "日本", "v": "61"},
        {"n": "欧美", "v": "62"},
        {"n": "海外", "v": "63"}
    ],
    "6": [
        {"n": "全部", "v": "6"},
        {"n": "大陆", "v": "55"},
        {"n": "日韩", "v": "56"},
        {"n": "港台", "v": "57"},
        {"n": "欧美", "v": "58"},
        {"n": "演唱", "v": "59"}
    ],
    "1": [
        {"n": "全部", "v": "1"},
        {"n": "强奸", "v": "11"},
        {"n": "网曝", "v": "12"},
        {"n": "国产", "v": "13"},
        {"n": "丝袜", "v": "14"},
        {"n": "主播", "v": "15"},
        {"n": "AI", "v": "16"},
        {"n": "家庭", "v": "17"},
        {"n": "SM", "v": "18"},
        {"n": "群交", "v": "19"}
    ],
    "2": [
        {"n": "全部", "v": "2"},
        {"n": "学生", "v": "20"},
        {"n": "自拍", "v": "21"},
        {"n": "口交", "v": "22"},
        {"n": "国产", "v": "23"},
        {"n": "素人", "v": "24"},
        {"n": "无码", "v": "25"},
        {"n": "经典", "v": "26"},
        {"n": "中文", "v": "27"},
        {"n": "日韩", "v": "28"}
    ],
    "3": [
        {"n": "全部", "v": "3"},
        {"n": "日韩", "v": "29"},
        {"n": "国产", "v": "30"},
        {"n": "欧美", "v": "31"},
        {"n": "VR", "v": "32"},
        {"n": "厂牌", "v": "33"},
        {"n": "重口", "v": "34"},
        {"n": "人兽", "v": "35"},
        {"n": "激情", "v": "36"},
        {"n": "异族", "v": "37"}
    ]
}

def _s(v):
    if v is None:
        return ""
    if isinstance(v, (dict, list, tuple)):
        return ""
    return str(v).strip()

def _to_int(v, dft=0, low=None, high=None):
    try:
        n = int(float(str(v).strip()))
    except Exception:
        n = dft
    if low is not None and n < low:
        n = low
    if high is not None and n > high:
        n = high
    return n

def _clean_text(s):
    t = _s(s)
    if not t:
        return ""
    t = html.unescape(t)
    t = re.sub(r'<[^>]+>', '', t)
    t = re.sub(r'[\r\n\t]+', ' ', t)
    return re.sub(r'\s+', ' ', t).strip()

class Spider(BaseSpider):
    def __init__(self):
        self.host = DEFAULT_URL
        self.ua = UA
        self._detail_cache = {}
        self._play_cache = {}
        self._opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=_ssl_ctx))

    def getName(self):
        return "深夜电影"

    def init(self, extend=""):
        if extend:
            self.host = extend.rstrip('/')

    def isVideoFormat(self, url):
        return False

    def manualVideoCheck(self):
        return False

    def action(self, action):
        return None

    def liveContent(self):
        return []

    def _fetch(self, url, headers=None, timeout=6):
        req_headers = {
            "User-Agent": self.ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Connection": "keep-alive",
            "Referer": self.host + "/"
        }
        if headers:
            req_headers.update(headers)
        req = urllib.request.Request(url, headers=req_headers)
        try:
            with self._opener.open(req, timeout=timeout) as resp:
                final_url = resp.geturl()
                status = resp.status
                body = resp.read()
                try:
                    html_text = body.decode("utf-8")
                except Exception:
                    html_text = body.decode("gbk", "ignore")
                return status, final_url, html_text
        except urllib.error.HTTPError as e:
            try:
                body = e.read().decode("utf-8", "ignore")
            except Exception:
                body = ""
            return e.code, url, body
        except Exception as e:
            return 0, url, str(e)

    def _abs(self, u):
        u = _s(u)
        if not u:
            return ""
        if u.startswith('//'):
            return "https:" + u
        if u.startswith('/'):
            return self.host + u
        return u

    def homeContent(self, filter=True):
        classes = []
        for tid, name in MODULES:
            classes.append({"type_id": tid, "type_name": name})

        filters = {}
        for tid, sub_items in SUB_FILTERS.items():
            filters[tid] = [
                {
                    "key": "sub_tid",
                    "name": "子类",
                    "value": sub_items
                }
            ]

        return {"class": classes, "filters": filters}

    def homeVideoContent(self):
        return {"list": []}

    def _parse_cards(self, html_content):
        vlist = []
        if not html_content:
            return vlist
        link_matches = re.findall(r'<a[^>]+href=["\'](/vod(?:play|detail)/(\d+)[^"\']*)["\'][^>]*>(.*?)</a>', html_content, re.I | re.S)
        seen_ids = set()
        for href, vid, inner in link_matches:
            if vid in seen_ids:
                continue

            title = ""
            title_m = re.search(r'title=["\']([^"\']+)["\']', inner, re.I)
            if title_m:
                title = _clean_text(title_m.group(1))
            if not title:
                alt_m = re.search(r'alt=["\']([^"\']+)["\']', inner, re.I)
                if alt_m:
                    title = _clean_text(alt_m.group(1))
            if not title:
                clean_inner = _clean_text(inner)
                if 1 < len(clean_inner) <= 30 and not re.match(r'^\d+(\.\d+)?$', clean_inner):
                    title = clean_inner

            if not title:
                continue

            pic = ""
            pic_m = re.search(r'(?:data-original|data-src|src)=["\']([^"\']+)["\']', inner, re.I)
            if pic_m:
                pic = self._abs(pic_m.group(1))

            remarks_raw = ""
            rem_m = re.search(r'<(?:span|em|i)[^>]*>([^<]+)</(?:span|em|i)>', inner, re.I)
            if rem_m:
                r_text = _clean_text(rem_m.group(1))
                if r_text != title and len(r_text) <= 15:
                    remarks_raw = r_text

            if remarks_raw:
                remarks = "蝴蝶影视 | %s" % remarks_raw
            else:
                remarks = "蝴蝶影视"

            seen_ids.add(vid)
            vlist.append({
                "vod_id": vid,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": remarks
            })
        return vlist

    def categoryContent(self, tid, pg="1", filter=None, extend=None):
        page = _to_int(pg, 1, 1)
        ext = extend if isinstance(extend, dict) else {}
        sub_id = _s(ext.get("sub_tid"))
        target_id = sub_id if sub_id else _s(tid)

        base_clean = self.host.rstrip('/')
        url = "%s/vodshow/%s--------%s---.html" % (base_clean, target_id, page)
        status, final_url, html_content = self._fetch(url, timeout=6)

        vlist = []
        if status == 200 and html_content:
            vlist = self._parse_cards(html_content)

        max_page_found = page
        if html_content:
            all_page_nums = re.findall(r'/vodshow/\d+--------(\d+)---.html', html_content)
            for p_str in all_page_nums:
                p_val = _to_int(p_str, 0)
                if p_val > max_page_found:
                    max_page_found = p_val

        if max_page_found > page:
            total_pages = max_page_found
        elif len(vlist) > 0:
            total_pages = page + 10
        else:
            total_pages = page

        return {
            "list": vlist,
            "page": page,
            "pagecount": total_pages,
            "limit": len(vlist) if vlist else 18,
            "total": total_pages * (len(vlist) if vlist else 18)
        }

    def _extract_stream_from_html(self, html_content):
        if not html_content:
            return ""
        player_m = re.search(r'var\s+player_aaaa\s*=\s*({[^;]+?});?', html_content, re.I)
        if player_m:
            try:
                cfg_str = player_m.group(1).strip()
                p_obj = json.loads(cfg_str)
                raw_u = _s(p_obj.get("url"))
                if raw_u.startswith("http"):
                    return raw_u
                elif raw_u:
                    return self._abs(raw_u)
            except Exception:
                pass

        url_assign_m = re.search(r'["\']url["\']\s*:\s*["\'](https?://[^"\']+?\.m3u8[^"\']*?)["\']', html_content, re.I)
        if url_assign_m:
            return url_assign_m.group(1).replace('\\/', '/')

        m3u8_matches = re.findall(r'(https?://[^"\'\s<>\\]+?\.(?:m3u8|mp4)[^"\'\s<>\\]*)', html_content, re.I)
        if m3u8_matches:
            return m3u8_matches[0].replace('\\/', '/')
        return ""

    def detailContent(self, ids):
        vid = ""
        if isinstance(ids, (list, tuple)):
            vid = _s(ids[0]) if ids else ""
        else:
            vid = _s(ids)
        if not vid:
            return {"list": []}

        now_ts = time.time()
        cached = self._detail_cache.get(vid)
        if cached and (now_ts - cached[0] < 300):
            return {"list": [cached[1]]}

        base_clean = self.host.rstrip('/')
        play_direct_url = "%s/vodplay/%s-1-1.html" % (base_clean, vid)
        status, final_url, html_content = self._fetch(play_direct_url, timeout=6)

        if not html_content:
            return {"list": []}

        first_stream = self._extract_stream_from_html(html_content)
        if first_stream:
            self._play_cache[play_direct_url] = first_stream

        title = ""
        t_m = re.search(r'<h1[^>]*>([^<]+)</h1>', html_content, re.I)
        if t_m:
            title = _clean_text(t_m.group(1))
        if not title:
            meta_m = re.search(r'<title>([^<_]+)', html_content, re.I)
            if meta_m:
                title = _clean_text(meta_m.group(1))

        pic = ""
        pic_m = re.search(r'<div[^>]+class=["\'][^"\']*(?:poster|pic|thumb)[^"\']*["\'][^>]*>.*?<img[^>]+src=["\']([^"\']+)["\']', html_content, re.I | re.S)
        if pic_m:
            pic = self._abs(pic_m.group(1))
        if not pic:
            og_pic = re.search(r'<meta property="og:image" content="([^"]+)"', html_content, re.I)
            if og_pic:
                pic = self._abs(og_pic.group(1))

        desc = ""
        desc_m = re.search(r'<(?:div|p)[^>]+class=["\'][^"\']*(?:desc|content|detail-sketch)[^"\']*["\'][^>]*>(.*?)</(?:div|p)>', html_content, re.I | re.S)
        if desc_m:
            desc = _clean_text(desc_m.group(1))
        if not desc:
            meta_desc = re.search(r'<meta name="description" content="([^"]+)"', html_content, re.I)
            if meta_desc:
                desc = _clean_text(meta_desc.group(1))

        notice = "🦋 TG群: @tvshare23 提醒您：请勿相信视频中任何内嵌广告！"
        full_desc = "%s\n%s" % (notice, desc) if desc else notice

        ep_links = re.findall(r'<a[^>]+href=["\'](/vodplay/%s-(\d+)-(\d+)\.html)["\'][^>]*>(.*?)</a>' % vid, html_content, re.I | re.S)
        
        play_dict = {}
        if ep_links:
            for ep_href, sid_str, nid_str, ep_name in ep_links:
                sid = _to_int(sid_str, 1)
                nid = _to_int(nid_str, 1)
                clean_name = _clean_text(ep_name)
                if not clean_name or len(clean_name) > 20:
                    clean_name = "第%s集" % nid
                if sid not in play_dict:
                    play_dict[sid] = []
                play_item = "%s$%s" % (clean_name, self._abs(ep_href))
                if play_item not in play_dict[sid]:
                    play_dict[sid].append(play_item)

        if not play_dict:
            play_dict[1] = ["正片$%s" % play_direct_url]

        from_list = []
        url_list = []
        for sid in sorted(play_dict.keys()):
            from_list.append("线路%s" % sid)
            url_list.append("#".join(play_dict[sid]))

        vod_item = {
            "vod_id": vid,
            "vod_name": title if title else "影视正片",
            "vod_pic": pic,
            "vod_actor": "🦋 TG群: @tvshare23",
            "vod_director": "🦋 蝴蝶影视",
            "vod_content": full_desc,
            "vod_remarks": "蝴蝶影视",
            "vod_play_from": "$$$".join(from_list),
            "vod_play_url": "$$$".join(url_list)
        }

        self._detail_cache[vid] = (now_ts, vod_item)
        if len(self._detail_cache) > 50:
            self._detail_cache.clear()

        return {"list": [vod_item]}

    def playerContent(self, flag, id, vipFlags):
        res = {"parse": 0, "url": ""}
        raw_url = _s(id)
        if not raw_url:
            return res

        play_page_url = self._abs(raw_url)
        header = {
            "User-Agent": self.ua,
            "Referer": play_page_url
        }

        cached_stream = self._play_cache.get(play_page_url)
        if cached_stream:
            res["url"] = cached_stream
            res["header"] = header
            res["parse"] = 0
            return res

        status, final_url, html_content = self._fetch(play_page_url, timeout=5)
        direct_url = self._extract_stream_from_html(html_content)

        if not direct_url:
            iframe_m = re.search(r'<iframe[^>]+src=["\']([^"\']+)["\']', html_content, re.I)
            if iframe_m:
                iframe_src = self._abs(iframe_m.group(1))
                qs = urllib.parse.urlparse(iframe_src).query
                params = urllib.parse.parse_qs(qs)
                cand_keys = ["url", "v", "vid", "link"]
                for k in cand_keys:
                    if k in params and params[k]:
                        param_u = params[k][0]
                        if param_u.startswith("http"):
                            direct_url = param_u
                            break

        if direct_url:
            self._play_cache[play_page_url] = direct_url
            if len(self._play_cache) > 100:
                self._play_cache.clear()
            res["url"] = direct_url
            res["header"] = header
            res["parse"] = 0
        else:
            res["url"] = play_page_url
            res["header"] = header
            res["parse"] = 1

        return res

    def searchContent(self, key, quick, pg="1"):
        kw = _s(key)
        page = _to_int(pg, 1, 1)
        if not kw:
            return {"list": [], "page": page, "pagecount": page, "limit": 18, "total": 0}

        base_clean = self.host.rstrip('/')
        encoded_kw = urllib.parse.quote(kw)
        search_url = "%s/vodsearch/%s----------%s---.html" % (base_clean, encoded_kw, page)
        status, final_url, html_content = self._fetch(search_url, timeout=6)

        vlist = []
        if status == 200 and html_content:
            vlist = self._parse_cards(html_content)

        max_page_found = page
        if html_content:
            all_page_nums = re.findall(r'/vodsearch/[^/]+----------(\d+)---.html', html_content)
            for p_str in all_page_nums:
                p_val = _to_int(p_str, 0)
                if p_val > max_page_found:
                    max_page_found = p_val

        total_pages = max_page_found if max_page_found > page else (page + 1 if len(vlist) >= 15 else page)

        return {
            "list": vlist,
            "page": page,
            "pagecount": total_pages,
            "limit": len(vlist) if vlist else 18,
            "total": total_pages * (len(vlist) if vlist else 18)
        }

    def localProxy(self, params):
        return [404, "text/plain", ""]

    def destroy(self):
        pass