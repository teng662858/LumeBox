# LumeSource: {"id":"pypack_5a4fda6ee8d6b9de","name":"喜马拉雅","version":"1.0.0","category":"comic","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}],"mediaType":"audio"}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
喜马拉雅 TVBox 影视仓爬虫源 (完整版)
站点: https://m.ximalaya.com
功能: 分类栏、子分类筛选、排序、搜索、详情(含翻页)、播放
修复: 翻页、VIP显示、完整分类、安全URL替换

QQ群: 807916734
"""

import json
import re
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider:
        def fetch(self, url, headers=None):
            h = headers or {}
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
                class R:
                    text = data.decode('utf-8', errors='ignore')
                    content = data
                    status_code = resp.status
                return R()


class Spider(BaseSpider):

    HOST = "https://m.ximalaya.com"
    SEARCH_HOST = "https://api.cenguigui.cn"

    HEADERS = {
        "User-Agent": "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36",
        "Accept": "application/json, text/plain, */*",
    }

    # ===== 完整分类体系 =====
    CATEGORIES = [
        {"type_id": "youshengshu", "type_name": "有声书"},
        {"type_id": "ertong", "type_name": "儿童"},
        {"type_id": "yinyue", "type_name": "音乐"},
        {"type_id": "xiangsheng", "type_name": "相声"},
        {"type_id": "yule", "type_name": "娱乐"},
        {"type_id": "guangbojv", "type_name": "广播剧"},
        {"type_id": "lishi", "type_name": "历史"},
        {"type_id": "waiyu", "type_name": "外语"},
        {"type_id": "qinggan", "type_name": "情感"},
        {"type_id": "keji", "type_name": "科技"},
        {"type_id": "caijing", "type_name": "财经"},
        {"type_id": "jiaoyu", "type_name": "教育"},
        {"type_id": "jiankang", "type_name": "健康"},
        {"type_id": "qiche", "type_name": "汽车"},
        {"type_id": "lvxing", "type_name": "旅行"},
        {"type_id": "youxi", "type_name": "游戏"},
        {"type_id": "erciyuan", "type_name": "二次元"},
        {"type_id": "toutiao", "type_name": "头条"},
        {"type_id": "dianying", "type_name": "电影"},
        {"type_id": "dianshiju", "type_name": "电视剧"},
        {"type_id": "3d", "type_name": "3D沉浸"},
        {"type_id": "xiuxian", "type_name": "播客"},
        {"type_id": "xiangsheng2", "type_name": "相声评书"},
        {"type_id": "tuokouxiu", "type_name": "脱口秀"},
    ]

    # ===== 子分类筛选 =====
    FILTERS = {
        "youshengshu": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "小说", "v": "xiaoshuo"},
                {"n": "文学", "v": "wenxue"},
                {"n": "社科", "v": "sheke"},
                {"n": "经管", "v": "jingguan"},
                {"n": "历史", "v": "lishi2"},
                {"n": "悬疑", "v": "xuanyi"},
                {"n": "科幻", "v": "kehuan"},
                {"n": "言情", "v": "yanqing"},
                {"n": "武侠", "v": "wuxia"},
                {"n": "都市", "v": "dushi"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
                {"n": "最多订阅", "v": "3"},
                {"n": "评分最高", "v": "4"},
            ]},
        ],
        "ertong": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "故事", "v": "gushi"},
                {"n": "儿歌", "v": "erge"},
                {"n": "科普", "v": "kepu"},
                {"n": "动画", "v": "donghua"},
                {"n": "国学", "v": "guoxue"},
                {"n": "英语", "v": "yingyu"},
                {"n": "绘本", "v": "huiben"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
                {"n": "最多订阅", "v": "3"},
            ]},
        ],
        "yinyue": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "流行", "v": "liuxing"},
                {"n": "古典", "v": "gudian"},
                {"n": "民谣", "v": "minyao"},
                {"n": "摇滚", "v": "yaogun"},
                {"n": "电子", "v": "dianzi"},
                {"n": "纯音乐", "v": "chunyinyue"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "xiangsheng": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "单口相声", "v": "dankou"},
                {"n": "对口相声", "v": "duikou"},
                {"n": "群口相声", "v": "qunkou"},
                {"n": "相声剧", "v": "xiang sheng ju"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "yule": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "明星", "v": "mingxing"},
                {"n": "八卦", "v": "bagua"},
                {"n": "综艺", "v": "zongyi"},
                {"n": "影视", "v": "yingshi"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "guangbojv": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "现代", "v": "xiandai"},
                {"n": "古风", "v": "gufeng"},
                {"n": "言情", "v": "yanqing2"},
                {"n": "悬疑", "v": "xuanyi2"},
                {"n": "科幻", "v": "kehuan2"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "lishi": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "中国史", "v": "zhongguo"},
                {"n": "世界史", "v": "shijie"},
                {"n": "战争", "v": "zhanzheng"},
                {"n": "人物", "v": "renwu"},
                {"n": "考古", "v": "kaogu"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "waiyu": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "英语", "v": "english"},
                {"n": "日语", "v": "japanese"},
                {"n": "韩语", "v": "korean"},
                {"n": "法语", "v": "french"},
                {"n": "德语", "v": "german"},
                {"n": "西班牙语", "v": "spanish"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "qinggan": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "恋爱", "v": "lianai"},
                {"n": "婚姻", "v": "hunyin"},
                {"n": "家庭", "v": "jiating"},
                {"n": "心理", "v": "xinli"},
                {"n": "治愈", "v": "zhiyu"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "keji": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "互联网", "v": "hulianwang"},
                {"n": "人工智能", "v": "rengongzhineng"},
                {"n": "编程", "v": "biancheng"},
                {"n": "数码", "v": "shuma"},
                {"n": "天文", "v": "tianwen"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "caijing": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "股票", "v": "gupiao"},
                {"n": "基金", "v": "jijin"},
                {"n": "理财", "v": "licai"},
                {"n": "创业", "v": "chuangye"},
                {"n": "管理", "v": "guanli"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "jiaoyu": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "K12", "v": "k12"},
                {"n": "考研", "v": "kaoyan"},
                {"n": "公考", "v": "gongkao"},
                {"n": "外语", "v": "waiyu2"},
                {"n": "职场", "v": "zhichang"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
        "jiankang": [
            {"key": "class", "name": "子分类", "value": [
                {"n": "全部", "v": ""},
                {"n": "养生", "v": "yangsheng"},
                {"n": "中医", "v": "zhongyi"},
                {"n": "健身", "v": "jianshen"},
                {"n": "饮食", "v": "yinshi"},
                {"n": "心理", "v": "xinli2"},
            ]},
            {"key": "sort", "name": "排序", "value": [
                {"n": "综合排序", "v": "0"},
                {"n": "最新上架", "v": "1"},
                {"n": "最多播放", "v": "2"},
            ]},
        ],
    }

    def init(self, extend=""):
        pass

    def getName(self):
        return "ximalaya"

    def isVideoFormat(self, url):
        return any(ext in url.lower() for ext in ['.m4a', '.mp3', '.aac', '.mp4', '.flv'])

    def manualVideoCheck(self):
        return False

    def _fetch(self, url, headers=None):
        h = dict(self.HEADERS)
        if headers:
            h.update(headers)
        try:
            rsp = self.fetch(url, headers=h)
            if hasattr(rsp, 'text'):
                return rsp.text
            elif isinstance(rsp, bytes):
                return rsp.decode('utf-8', errors='ignore')
            elif isinstance(rsp, str):
                return rsp
        except:
            pass
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.read().decode('utf-8', errors='ignore')
        except:
            return ""

    def homeContent(self, filter=False):
        result = {"class": list(self.CATEGORIES)}
        if filter:
            result["filters"] = self.FILTERS
        return result

    def homeVideoContent(self):
        # 首页推荐：有声书第1页
        return self.categoryContent("youshengshu", "1", False, {})

    def categoryContent(self, tid, pg, filter=False, extend={}):
        page = int(pg or 1)
        sort = extend.get("sort", "0") or "0"
        sub = extend.get("class", "")

        url = f"{self.HOST}/m-revision/page/category/queryCategoryAlbumsByPage?sort={sort}&pageSize=50&page={page}&categoryCode={tid}"
        if sub:
            url += f"&secondCategoryCode={sub}"

        html = self._fetch(url)
        if not html:
            return {"list": [], "page": page, "pagecount": 1, "limit": 50, "total": 0}

        try:
            data = json.loads(html).get("data", {})
        except:
            return {"list": [], "page": page, "pagecount": 1, "limit": 50, "total": 0}

        album_list = data.get("albumBriefDetailInfos", [])
        videos = []

        for it in album_list:
            info = it.get("albumInfo", {})
            vip_type = info.get("albumVipPayType", 0)
            album_id = it.get("id") or info.get("id", "")
            if not album_id:
                continue

            # 构建详情页URL（保留原格式，用于翻页解析）
            detail_url = f"http://mobile.ximalaya.com/mobile/others/ca/album/track/{album_id}/true/0/200?albumId={album_id}"

            # VIP标识
            if vip_type == 0:
                remark = "免费"
            elif vip_type == 1:
                remark = "VIP"
            elif vip_type == 2:
                remark = "付费"
            else:
                remark = ""

            videos.append({
                "vod_id": detail_url,
                "vod_name": info.get("title", "未知标题"),
                "vod_pic": f"http://imagev2.xmcdn.com/{info.get('cover', '')}",
                "vod_remarks": remark,
            })

        # 修复翻页: 使用 totalCount / pageSize
        total_count = data.get("totalCount", 0)
        pagecount = max(1, (total_count + 49) // 50) if total_count > 0 else 1

        return {
            "list": videos,
            "page": page,
            "pagecount": pagecount,
            "limit": 50,
            "total": total_count,
        }

    def detailContent(self, ids):
        vid = ids[0] if isinstance(ids, list) else ids

        # 提取 albumId
        m = re.search(r'albumId=(\d+)', vid)
        album_id = m.group(1) if m else ""
        if not album_id:
            return {"list": []}

        html = self._fetch(vid)
        if not html:
            return {"list": []}

        try:
            j = json.loads(html)
        except:
            return {"list": []}

        album = j.get("album", {})
        tracks = j.get("tracks", {})
        data = tracks.get("list", [])
        max_page = tracks.get("maxPageId", 1)

        urls = []
        for it in data:
            play_url = it.get("playPathAacv164", "")
            if play_url:
                urls.append(f"{it.get('title', '未知')}${play_url}")

        # 修复详情页翻页: 安全替换 URL 中的页码
        if max_page > 1:
            for page_num in range(2, max_page + 1):
                # 使用正则安全替换 URL 中的 /0/ 为 /{page_num}/
                page_url = re.sub(r'/0/', f'/{page_num}/', vid, count=1)
                try:
                    page_html = self._fetch(page_url)
                    if not page_html:
                        continue
                    page_j = json.loads(page_html)
                    page_data = page_j.get("tracks", {}).get("list", [])
                    for it in page_data:
                        play_url = it.get("playPathAacv164", "")
                        if play_url:
                            urls.append(f"{it.get('title', '未知')}${play_url}")
                except:
                    pass

        if not urls:
            return {"list": []}

        vod = {
            "vod_id": vid,
            "vod_name": album.get("title", "暂无名称"),
            "vod_pic": album.get("coverLarge", ""),
            "vod_content": album.get("intro", "暂无简介"),
            "vod_remarks": f"共{len(urls)}集",
            "vod_play_from": "喜马拉雅",
            "vod_play_url": "#".join(urls),
        }

        return {"list": [vod]}

    def playerContent(self, flag, id, vipFlags=None):
        if not id:
            return {"parse": 0, "url": "", "header": {}}
        return {"parse": 0, "url": id, "header": {}}

    def searchContent(self, key, quick, pg="1"):
        page = int(pg or 1)
        if not key:
            return {"list": [], "page": page, "pagecount": 0, "limit": 20, "total": 0}

        videos = []
        total = 0
        # 站点自身的 SEO 搜索：无需登录，按专辑返回，支持翻页。
        try:
            url = (
                f"https://www.ximalaya.com/revision/search/seo"
                f"?core=album&kw={urllib.parse.quote(key)}&page={page}"
                f"&spellchecker=true&rows=30&condition=relation&device=iPhone"
            )
            payload = json.loads(self._fetch(url) or "{}")
            album = (payload.get("data") or {}).get("album") or {}
            docs = album.get("docs") or []
            total = int(album.get("total") or 0)
            for it in docs:
                album_id = it.get("albumId")
                if not album_id:
                    continue
                if it.get("isPaid"):
                    remark = "付费"
                elif it.get("isVipFree"):
                    remark = "VIP"
                else:
                    remark = "免费"
                videos.append({
                    "vod_id": self._album_id(album_id),
                    "vod_name": it.get("title", "未知标题"),
                    "vod_pic": f"https://imagev2.xmcdn.com/{it.get('coverPath', '')}",
                    "vod_remarks": remark,
                })
        except Exception:
            pass

        # 搜索接口异常时才退回分类内匹配，避免把慢速遍历当成常规路径。
        if not videos and page == 1:
            videos = self._search_in_categories(key)

        pagecount = max(1, (total + 29) // 30) if total else (1 if videos else 0)
        return {
            "list": videos,
            "page": page,
            "pagecount": pagecount,
            "limit": len(videos),
            "total": total or len(videos),
        }

    @staticmethod
    def _album_id(album_id):
        return f"http://mobile.ximalaya.com/mobile/others/ca/album/track/{album_id}/true/0/200?albumId={album_id}"

    def _search_in_categories(self, key):
        videos = []
        for cat in ("youshengshu", "ertong", "yinyue"):
            for p in (1, 2):
                try:
                    url = f"{self.HOST}/m-revision/page/category/queryCategoryAlbumsByPage?sort=0&pageSize=50&page={p}&categoryCode={cat}"
                    data = json.loads(self._fetch(url) or "{}").get("data", {})
                    for it in data.get("albumBriefDetailInfos", []):
                        info = it.get("albumInfo", {})
                        title = info.get("title", "")
                        if key.lower() not in title.lower():
                            continue
                        album_id = it.get("id") or info.get("id")
                        if not album_id:
                            continue
                        vip_type = info.get("albumVipPayType", 0)
                        videos.append({
                            "vod_id": self._album_id(album_id),
                            "vod_name": title,
                            "vod_pic": f"https://imagev2.xmcdn.com/{info.get('cover', '')}",
                            "vod_remarks": "免费" if vip_type == 0 else ("VIP" if vip_type == 1 else "付费"),
                        })
                        if len(videos) >= 20:
                            return videos
                except Exception:
                    continue
        return videos

    def localProxy(self, param):
        return [200, "text/plain", b""]
