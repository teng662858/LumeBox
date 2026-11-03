# LumeSource: {"id":"pypack_3042d332a8ee89e5","name":"美不胜收（免翻）","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
# coding=utf-8
import re
import urllib.request
import urllib.parse
import ssl
import json

class Spider(object):
    def getName(self):
        # 【品牌烙印】规范命名
        return "美不胜收(免翻)"

    def init(self, extend=""):
        pass

    # ==========================================
    # 模块 1：网络配置模块
    # ==========================================
    def _fetch(self, url):
        req = urllib.request.Request(url, headers={
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
            'Referer': 'https://mbss3.xyz/'
        })
        context = ssl._create_unverified_context()
        try:
            response = urllib.request.urlopen(req, context=context, timeout=10)
            return response.read().decode('utf-8', errors='ignore')
        except Exception:
            return ""

    # ==========================================
    # 模块 2：分类路由模块
    # ==========================================
    def homeContent(self, filter):
        # 探针 4.0 获取的真实分类字典
        classes = [
            {"type_id": "20", "type_name": "在线一区"},
            {"type_id": "21", "type_name": "国产色情"},
            {"type_id": "22", "type_name": "主播直播"},
            {"type_id": "23", "type_name": "亚洲精品"},
            {"type_id": "24", "type_name": "中文字幕"},
            {"type_id": "25", "type_name": "人妻熟女"},
            {"type_id": "26", "type_name": "强奸乱伦"},
            {"type_id": "27", "type_name": "欧美精品"},
            {"type_id": "28", "type_name": "成人动漫"},
            {"type_id": "29", "type_name": "在线二区"},
            {"type_id": "30", "type_name": "自拍偷拍"},
            {"type_id": "31", "type_name": "制服丝袜"},
            {"type_id": "32", "type_name": "变态另类"},
            {"type_id": "33", "type_name": "AI换脸"},
            {"type_id": "34", "type_name": "三级伦理"},
            {"type_id": "35", "type_name": "AV解说"},
            {"type_id": "36", "type_name": "传媒探花"},
            {"type_id": "37", "type_name": "美乳巨乳"}
        ]
        return {"class": classes}

    def categoryContent(self, tid, pg, filter, extend):
        # 探针 5.0 获取的真实分页路由
        url = f"https://mbss3.xyz/index.php/vod/type/id/{tid}/page/{pg}.html"
        html = self._fetch(url)
        videos = self._parse_cards(html)
        
        return {
            "list": videos,
            "page": pg,
            "pagecount": 999,
            "limit": len(videos),
            "total": 9999
        }

    # ==========================================
    # 模块 3：UI卡片解析模块 (探针6.0 最终修复版)
    # ==========================================
    def _parse_cards(self, html):
        videos = []
        
        # 完整的卡片包裹在 <li> 标签中
        items = re.findall(r'<li.*?>(.*?)</li>', html, re.I | re.S)
        if not items:
            items = re.findall(r'(<a class="thumbnail".*?</div>)', html, re.I | re.S)

        for item in items:
            # 1. 提取链接和封面
            href_match = re.search(r'<a class="thumbnail" href=["\']([^"\']+)["\']', item, re.I)
            pic_match = re.search(r'data-original=["\']([^"\']+)["\']', item, re.I)
            
            if not href_match or not pic_match:
                continue
                
            vod_id = href_match.group(1)
            pic = pic_match.group(1)
            if not vod_id.startswith('http'):
                vod_id = urllib.parse.urljoin("https://mbss3.xyz/", vod_id)
            
            # 2. 提取真正完整的标题
            title_match = re.search(r'<h5>\s*<a[^>]*>(.*?)</a>', item, re.I | re.S)
            vod_name = title_match.group(1).strip() if title_match else "未知视频"
            
            # 3. 提取角标状态信息 (极限压缩适配 10 字符宽)
            remark_match = re.search(r'<p class="vodtitle">(.*?)</p>', item, re.I | re.S)
            if remark_match:
                raw_remark = re.sub(r'<[^>]+>', '', remark_match.group(1)).strip()
                
                # 舍弃年份，只留月-日 (MM-DD)
                date_match = re.search(r'\d{4}-(\d{2}-\d{2})', raw_remark)
                view_match = re.search(r'观看:\s*(\d+)', raw_remark)
                
                tags = []
                if date_match:
                    tags.append(date_match.group(1))
                    
                if view_match:
                    views = int(view_match.group(1))
                    # 观看数过万时进行缩写处理
                    if views >= 10000:
                        tags.append(f"👁{round(views/10000, 1)}w")
                    else:
                        tags.append(f"👁{views}")
                        
                # 仅用一个空格连接，确保最紧凑
                vod_remarks = " ".join(tags) if tags else "高清"
            else:
                vod_remarks = "高清"

                
            videos.append({
                "vod_id": vod_id,
                "vod_name": vod_name,
                "vod_pic": pic.strip(),
                "vod_remarks": vod_remarks
            })
            
        return videos




    # ==========================================
    # 模块 4 & 5：解密引擎与播放直连模块 (探针2.0 验证版)
    # ==========================================
    def detailContent(self, ids):
        target_url = ids[0] if isinstance(ids, (list, tuple)) else str(ids)
        
        vod = {
            "vod_id": target_url,
            "vod_name": "美不胜收(免翻)",
            "vod_director": "YJ-Gemini",
            "vod_play_from": "YJ-Gemini 专线",
            "vod_play_url": f"原画直连${target_url}"
        }
        return {"list": [vod]}

    def playerContent(self, flag, id, vipFlags):
        """通过请求 /play/ 页面提取 player_aaaa 数据"""
        detail_html = self._fetch(id)
        best_link = ""
        
        play_match = re.search(r'href=["\'](/index\.php/vod/play/[^"\']+)["\']', detail_html)
        if play_match:
            play_url = urllib.parse.urljoin("https://mbss3.xyz/", play_match.group(1))
            play_html = self._fetch(play_url)
            
            mac_player = re.search(r'player_aaaa\s*=\s*(\{.*?\})', play_html)
            if mac_player:
                try:
                    json_str = mac_player.group(1).replace('\\/', '/')
                    player_data = json.loads(json_str)
                    if "url" in player_data:
                        best_link = urllib.parse.unquote(player_data["url"])
                except Exception:
                    pass
                    
            if not best_link:
                m3u8_links = re.findall(r'(https?://[^\s\'"]+\.(?:m3u8|mp4))', play_html)
                if m3u8_links:
                    best_link = m3u8_links[0]
                    
        if not best_link:
            return {"parse": 1, "jx": 0, "url": id}

        return {
            "parse": 0, 
            "jx": 0, 
            "url": best_link,
            "header": {
                "User-Agent": "Mozilla/5.0",
                "Referer": "https://mbss3.xyz/"
            }
        }

    # ==========================================
    # 模块 6：搜索模块
    # ==========================================
    def searchContent(self, key, quick):
        # MacCMS 标准搜索路由
        url = f"https://mbss3.xyz/index.php/vod/search.html?wd={urllib.parse.quote(key)}"
        html = self._fetch(url)
        videos = self._parse_cards(html)
        return {"list": videos}
