# LumeSource: {"id":"pypack_9192fd18fc6d2a1f","name":"糯米短剧(2)","version":"1.0.0","category":"video","contentCategory":"movie","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
糯米短剧 (8728.mrsvj.com) 爬虫 - TVBox / 影视仓 Spider 插件
支持: 首页、分类(标签/排行)浏览、搜索、详情获取、播放链接解析

站点结构说明 (基于 H5 前端 JS 逆向 + 实测, 2026-10 修复):
- 站点: https://1378.j7yr8.com/h5/  (糯米短剧, 资源由 _b_base() 动态下发)
- API 前台 (写死在前端 index.js 的 baseURL):
    https://g4s65124fwg5sdg.wlqwh88.com/api/web/v1
  (旧 4gf56465fg112.hongjiuchang.com 与更早域名均已失效)

【全站接口加密】(本次"没内容"的根因: 站点新增了加密, 明文请求返回的 data 是密文):
  1) 请求体不再是明文 JSON, 而是:
       a. 明文参数 + signature 两个字段合成一个对象
            signature = {"t": 毫秒时间戳*1000+3位随机, "s": md5}
            s = md5( urlencode(按参数名排序后的扁平化参数) + t + token + AES_KEY )
            token 未登录(游客)为空字符串
       b. 整体 JSON 字符串 -> AES-128-ECB/PKCS7 加密 -> base64
       c. 实际 POST: {"encrypt_data": "<base64密文>"}
  2) 响应的 data 字段是 base64 密文, 用同一 KEY AES-128-ECB 解密后才是 JSON:
       data -> AES解密 -> {"list": [...]} / {"info": {...}} / {"config": {...}}
  3) AES KEY (前端 index.js 硬编码, UTF-8 16 字节):  eC2gG2gM0bH4aF1l

- 资源域名 (封面 / 视频) 来自运行期 /config/load 解密后的 data.config, 关键字段:
    data.config.static_domain     -> 封面前缀 (如 https://rvS3YP.ws4ge.com)
    data.config.video_domain      -> 播放地址前缀 (如 https://666996.drephjq.com)
    data.config.video_domain_out  -> 播放备用线路 (如 https://98991.cg22d.com)
  (前端 Tg(url, domain): 已是完整 http(s) 链接则原样返回, 否则 domain + "/" + path)
- 列表 / 分类:
    POST /video/list            {pageNum}                  -> 全部短剧
    POST /tags/list             {}                         -> 标签(分类)列表
    POST /tags/video            {pageNum, tag}             -> 按标签筛选
    POST /rank/hot|new|rating|search {pageNum}             -> 各类排行榜
- 搜索:
    POST /search/list           {text, pageNum}
- 详情:
    POST /video/detail-info     {id, from:""}  -> data.info.setList=[{i(集号), l(点赞), v(is_vip), s(status)}]
- 播放 (核心):
    POST /video/set-info        {id, set} -> data.info.url_m3u8 (相对路径, 需拼 video_domain)
  注意: 播放地址为 m3u8(HLS, 内置 AES-128 KEY 分段), 播放器需支持 HLS;
  解析时统一带上 Referer / Origin / UA。
"""

import re
import json
import time
import random
import base64
import hashlib
import logging
import os
import sys
import warnings
from urllib.parse import urlencode

import requests

# 该站点 CDN 证书环境异常, 关闭 verify 以避免握手失败, 同时抑制由此产生的告警刷屏
requests.packages.urllib3.disable_warnings()
warnings.filterwarnings("ignore")

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
try:
    from base.spider import Spider as BaseSpider
except ImportError:
    BaseSpider = object

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# ==================== AES-128-ECB 加解密 (PKCS7) ====================
# 优先使用 pycryptodome (更快); 未安装时回退到内置纯 Python 实现, 保证任意环境可用
try:
    from Crypto.Cipher import AES as _PyCryptoAES
    from Crypto.Util.Padding import pad as _pc_pad, unpad as _pc_unpad
    _HAS_PYCRYPTO = True
except Exception:
    _HAS_PYCRYPTO = False

_SBOX = None
_INV_SBOX = None


def _rotl8(x, n):
    return ((x << n) | (x >> (8 - n))) & 0xFF


def _build_sbox():
    """标准 AES S盒生成算法"""
    sbox = [0] * 256
    p = q = 1
    while True:
        # p *= 3 (GF(2^8))
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        # q /= 3 (GF(2^8))
        q ^= (q << 1) & 0xFF
        q ^= (q << 2) & 0xFF
        q ^= (q << 4) & 0xFF
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4)
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    inv = [0] * 256
    for i, v in enumerate(sbox):
        inv[v] = i
    return sbox, inv


def _ensure_tables():
    global _SBOX, _INV_SBOX
    if _SBOX is None:
        _SBOX, _INV_SBOX = _build_sbox()


def _gmul(a, b):
    """GF(2^8) 乘法"""
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def _expand_key(key):
    """AES-128 密钥扩展 (44 个 4 字节字)"""
    _ensure_tables()
    rcon = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]
    w = [list(key[4 * i:4 * (i + 1)]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= rcon[i // 4 - 1]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return w


def _enc_block(blk, w):
    s = [[blk[r + 4 * c] for c in range(4)] for r in range(4)]

    def ark(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd * 4 + c][r]

    def shift():
        s[1] = s[1][1:] + s[1][:1]
        s[2] = s[2][2:] + s[2][:2]
        s[3] = s[3][3:] + s[3][:3]

    def mix():
        for c in range(4):
            a0, a1, a2, a3 = s[0][c], s[1][c], s[2][c], s[3][c]
            s[0][c] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3
            s[1][c] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3
            s[2][c] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3)
            s[3][c] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2)

    ark(0)
    for rnd in range(1, 10):
        for r in range(4):
            for c in range(4):
                s[r][c] = _SBOX[s[r][c]]
        shift()
        mix()
        ark(rnd)
    for r in range(4):
        for c in range(4):
            s[r][c] = _SBOX[s[r][c]]
    shift()
    ark(10)
    return bytes(s[r][c] for c in range(4) for r in range(4))


def _dec_block(blk, w):
    s = [[blk[r + 4 * c] for c in range(4)] for r in range(4)]

    def ark(rnd):
        for c in range(4):
            for r in range(4):
                s[r][c] ^= w[rnd * 4 + c][r]

    def inv_shift():
        s[1] = s[1][-1:] + s[1][:-1]
        s[2] = s[2][-2:] + s[2][:-2]
        s[3] = s[3][-3:] + s[3][:-3]

    def inv_sub():
        for r in range(4):
            for c in range(4):
                s[r][c] = _INV_SBOX[s[r][c]]

    def inv_mix():
        for c in range(4):
            a0, a1, a2, a3 = s[0][c], s[1][c], s[2][c], s[3][c]
            s[0][c] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9)
            s[1][c] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13)
            s[2][c] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11)
            s[3][c] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14)

    ark(10)
    for rnd in range(9, 0, -1):
        inv_shift()
        inv_sub()
        ark(rnd)
        inv_mix()
    inv_shift()
    inv_sub()
    ark(0)
    return bytes(s[r][c] for c in range(4) for r in range(4))


def _pkcs7_pad(data):
    n = 16 - (len(data) % 16)
    return data + bytes([n]) * n


def _pkcs7_unpad(data):
    n = data[-1]
    if n < 1 or n > 16 or data[-n:] != bytes([n]) * n:
        raise ValueError("bad padding")
    return data[:-n]


def aes_encrypt_b64(text, key):
    """AES-128-ECB/PKCS7 加密 -> base64 字符串"""
    data = text.encode("utf-8")
    if _HAS_PYCRYPTO:
        return base64.b64encode(
            _PyCryptoAES.new(key, _PyCryptoAES.MODE_ECB).encrypt(_pc_pad(data, 16))
        ).decode()
    w = _expand_key(key)
    data = _pkcs7_pad(data)
    out = b"".join(_enc_block(data[i:i + 16], w) for i in range(0, len(data), 16))
    return base64.b64encode(out).decode()


def aes_decrypt_b64(b64, key):
    """base64 密文 -> AES-128-ECB/PKCS7 解密 -> 明文字符串"""
    raw = base64.b64decode(b64)
    if not raw or len(raw) % 16 != 0:
        raise ValueError("bad ciphertext length")
    if _HAS_PYCRYPTO:
        return _pc_unpad(_PyCryptoAES.new(key, _PyCryptoAES.MODE_ECB).decrypt(raw), 16).decode("utf-8")
    w = _expand_key(key)
    out = b"".join(_dec_block(raw[i:i + 16], w) for i in range(0, len(raw), 16))
    return _pkcs7_unpad(out).decode("utf-8")


class Spider(BaseSpider):
    """糯米短剧 爬虫"""

    # API 域名 (新前台 1378.j7yr8.com 的前端 JS 硬编码 baseURL)
    API_HOST = "https://g4s65124fwg5sdg.wlqwh88.com"
    API_BASE = API_HOST + "/api/web/v1"

    # 站点来源 (用于 Referer / Origin, 部分 CDN 会校验)
    SITE = "https://1378.j7yr8.com"

    # 全站接口加密 KEY (前端 index.js 硬编码, UTF-8 16 字节)
    AES_KEY = b"eC2gG2gM0bH4aF1l"

    HEADERS = {
        "User-Agent": "Mozilla/5.0 (Linux; Android 10; SM-G975F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Content-Type": "application/json;charset=UTF-8",
        "Referer": SITE + "/h5/",
        "Origin": SITE,
    }

    # 排行榜分类 (type_id 前缀 rank_)
    RANK_MAP = {
        "rank_hot": ("热播榜", "hot"),
        "rank_new": ("最新榜", "new"),
        "rank_rating": ("好评榜", "rating"),
        "rank_search": ("热搜榜", "search"),
    }

    # 资源域名兜底值 (与当前 /config/load 返回一致, 防止接口异常时完全不可用)
    FALLBACK_STATIC_DOMAIN = "https://rvS3YP.ws4ge.com"
    FALLBACK_VIDEO_DOMAIN = "https://666996.drephjq.com"
    FALLBACK_VIDEO_DOMAIN_OUT = "https://98991.cg22d.com"

    def __init__(self):
        try:
            super().__init__()
        except Exception:
            pass
        self.session = requests.Session()
        self.session.verify = False
        self.session.headers.update(self.HEADERS)
        # 资源域名 (运行期从 /config/load 获取, 懒加载并缓存)
        self._static_domain = ""
        self._video_domain = ""
        self._video_domain_out = ""    # 备用(出口)线路, 主线路不可达时自动切换
        self._active_video_domain = ""  # 探活后选定的实际可用线路
        self._tags_cache = None
        self._token = ""  # 游客 token 为空串

    def init(self, extend):
        pass

    def getName(self):
        return "糯米短剧"

    # ==================== 配置 / 资源域名 ====================
    def _ensure_config(self):
        """拉取 /config/load, 缓存 static_domain / video_domain (失败则用兜底值)"""
        if self._static_domain and self._video_domain:
            return
        try:
            data = self._post_json("/config/load", {}) or {}
            conf = data.get("config") if isinstance(data.get("config"), dict) else data
            sd = conf.get("static_domain") or ""
            vd = conf.get("video_domain") or ""
            vdo = conf.get("video_domain_out") or ""
            if sd:
                self._static_domain = sd
            if vd:
                self._video_domain = vd
            if vdo:
                self._video_domain_out = vdo
        except Exception as e:
            logger.error(f"获取 config 失败: {e}")
        if not self._static_domain:
            self._static_domain = self.FALLBACK_STATIC_DOMAIN
        if not self._video_domain:
            self._video_domain = self.FALLBACK_VIDEO_DOMAIN
        if not self._video_domain_out:
            self._video_domain_out = self.FALLBACK_VIDEO_DOMAIN_OUT

    # ==================== 网络请求 (加签 + 加密) ====================
    def _sign(self, params):
        """
        按前端 7879 模块逻辑生成 signature 字符串:
          参数扁平化(嵌套用 a[b] 形式) -> 按参数名排序 -> urlencode
          s = md5(query + t + token + AES_KEY) 小写
          t = 毫秒时间戳 * 1000 + 3位随机数 (前端为 `${ms}${100~999}`)
        """
        items = []

        def flat(prefix, v):
            if isinstance(v, dict):
                for k, vv in v.items():
                    flat(f"{prefix}[{k}]" if prefix else k, vv)
            elif isinstance(v, list):
                for i, vv in enumerate(v):
                    flat(f"{prefix}[{i}]" if prefix else str(i), vv)
            else:
                items.append((prefix, "" if v is None else str(v)))

        flat("", params)
        q = urlencode(sorted(items))
        t = int(f"{int(time.time() * 1000)}{random.randint(100, 999)}")
        s = hashlib.md5((q + str(t) + self._token + self.AES_KEY.decode()).encode("utf-8")).hexdigest().lower()
        return json.dumps({"t": t, "s": s}, separators=(",", ":"))

    def _post_json(self, path, body):
        """
        POST 请求 (整体 AES-ECB 加密包裹为 encrypt_data), 返回解密后的 data 层 dict。
        兼容站点日后关闭加密 (data 直接为对象) 的情况。失败返回 None。
        """
        try:
            a = dict(body or {})
            a["signature"] = self._sign(a)
            payload = {"encrypt_data": aes_encrypt_b64(json.dumps(a, separators=(",", ":")), self.AES_KEY)}
            resp = self.session.post(self.API_BASE + path, json=payload, timeout=30)
            if resp.status_code != 200:
                logger.error(f"请求失败 {path}: HTTP {resp.status_code}")
                return None
            data = resp.json()
            if not isinstance(data, dict):
                return None
            if data.get("code") not in (None, 10000):
                logger.error(f"接口错误 {path}: code={data.get('code')} msg={data.get('msg')}")
                return None
            raw = data.get("data")
            if isinstance(raw, str) and raw:
                raw = aes_decrypt_b64(raw, self.AES_KEY)
            if isinstance(raw, str):
                raw = json.loads(raw)
            return raw if isinstance(raw, dict) else {}
        except Exception as e:
            logger.error(f"请求失败 {path}: {e}")
            return None

    # ==================== 工具 ====================
    @staticmethod
    def _join(base, path):
        """拼资源URL: 已是完整 http(s)/协议相对则原样返回, 否则 base + '/' + path"""
        if not path:
            return ""
        if re.match(r'^(https?:|//|data:)', path):
            return path
        base = (base or "").rstrip("/")
        path = path.lstrip("/")
        return base + "/" + path if base else path

    def _cover(self, url):
        self._ensure_config()
        return self._join(self._static_domain, url)

    def _video_base(self, raw_url):
        """
        播放线路自动探活: 返回当前一条真实可达的视频域名。
        优先用主线路 video_domain; 若主线路拉不到 m3u8(设备/网络不可达),
        自动切换到备用 out 线路 video_domain_out; 选定的线路做缓存避免每次播放都探活。
        """
        self._ensure_config()
        # 已有可用选择则直接复用
        if self._active_video_domain:
            return self._active_video_domain

        candidates = []
        if self._video_domain:
            candidates.append(self._video_domain)
        if self._video_domain_out and self._video_domain_out != self._video_domain:
            candidates.append(self._video_domain_out)
        if not candidates:
            candidates = [self.FALLBACK_VIDEO_DOMAIN]

        for d in candidates:
            probe = self._join(d, raw_url)
            try:
                r = self.session.get(probe, timeout=8, stream=True)
                ok = r.status_code == 200
                r.close()
                if ok:
                    self._active_video_domain = d
                    logger.info(f"播放线路探测可用: {d}")
                    return d
            except Exception:
                continue
        # 全失败则退回主线路(minimum harm), 由播放器自行兜底
        self._active_video_domain = self._video_domain
        return self._video_domain

    @staticmethod
    def _build_remarks(item):
        sets = item.get("sets") or 0
        if str(item.get("is_over")) == "0" and sets:
            rem = f"更新至{sets}集"
        elif sets:
            rem = f"全{sets}集"
        else:
            rem = ""
        if str(item.get("is_vip")) == "1":
            rem = (rem + " ") if rem else ""
            rem += "付费"
        return rem.strip()

    def _parse_items(self, items):
        """把 API 返回的 items 列表转为 TVBox 视频卡片"""
        videos = []
        for it in items or []:
            vid = it.get("id")
            if not vid:
                continue
            videos.append({
                "vod_id": str(vid),
                "vod_name": it.get("title", ""),
                "vod_pic": self._cover(it.get("cover", "")),
                "vod_remarks": self._build_remarks(it),
            })
        return videos

    @staticmethod
    def _paginate(payload, page):
        """从列表响应中提取分页信息, 兼容有无 total/hasMore"""
        page = int(page) if page else 1
        if not isinstance(payload, dict):
            return 1, 0
        total = payload.get("total") or 0
        has_more = payload.get("hasMore")
        page_size = payload.get("pageSize") or (len(payload.get("list") or []) or 20)
        if total:
            pagecount = (int(total) + int(page_size) - 1) // int(page_size)
        elif has_more is not None:
            pagecount = page + 1 if has_more else page
        else:
            pagecount = page  # 未知时不分页, 由 TVBox 自行停止
        return pagecount, total

    # ==================== 首页 ====================
    def homeContent(self, filter=False):
        try:
            payload = self._post_json("/video/list", {"pageNum": 1}) or {}
            items = payload.get("list") or []

            # 分类: 全部 + 排行榜 + 标签(来自 /tags/list)
            classes = [{"type_id": "all", "type_name": "推荐"}]
            for tid, tname in self.RANK_MAP.items():
                classes.append({"type_id": tid, "type_name": tname[0]})
            for tag in self._get_tags():
                classes.append({"type_id": str(tag.get("id")), "type_name": tag.get("t", "")})

            return {
                "class": classes,
                "filters": {},
                "list": self._parse_items(items),
            }
        except Exception as e:
            logger.error(f"获取首页失败: {e}")
            return {}

    def homeVideoContent(self):
        payload = self._post_json("/video/list", {"pageNum": 1}) or {}
        items = payload.get("list") or []
        return {"list": self._parse_items(items)}

    # ==================== 标签(分类)列表 ====================
    def _get_tags(self):
        if self._tags_cache is not None:
            return self._tags_cache
        try:
            self._tags_cache = (self._post_json("/tags/list", {}) or {}).get("list") or []
        except Exception as e:
            logger.error(f"获取标签失败: {e}")
            self._tags_cache = []
        return self._tags_cache

    # ==================== 分类 ====================
    def categoryContent(self, tid, pg, filter, ext):
        try:
            page = int(pg) if pg else 1

            # 排行榜分类
            if tid in self.RANK_MAP:
                _, rank_type = self.RANK_MAP[tid]
                payload = self._post_json(f"/rank/{rank_type}", {"pageNum": page}) or {}
            # 全部
            elif tid == "all":
                payload = self._post_json("/video/list", {"pageNum": page}) or {}
            # 标签筛选
            else:
                payload = self._post_json("/tags/video", {"pageNum": page, "tag": int(tid)}) or {}

            items = payload.get("list") or []
            pagecount, total = self._paginate(payload, page)

            return {
                "list": self._parse_items(items),
                "page": page,
                "pagecount": pagecount,
                "limit": payload.get("pageSize") or 20,
                "total": total,
            }
        except Exception as e:
            logger.error(f"获取分类内容失败: {e}")
            return {"list": [], "page": int(pg) if pg else 1, "pagecount": 1, "limit": 20, "total": 0}

    # ==================== 详情 ====================
    def detailContent(self, ids):
        try:
            vod_id = ids[0] if isinstance(ids, list) else str(ids)
            data = self._post_json("/video/detail-info", {"id": vod_id, "from": ""}) or {}
            info = data.get("info") or {}
            if not info:
                return {"list": []}

            set_list = info.get("setList") or []
            # 集号按数字大小排序 (i 为集号)
            eps = sorted(set_list, key=lambda x: int(x.get("i") or 0))

            episodes = []
            for ep in eps:
                idx = ep.get("i")
                if idx is None:
                    continue
                # id 格式: {vod_id}|{集号}  供 playerContent 解析
                episodes.append(f"第{idx}集${vod_id}|{idx}")

            if episodes:
                play_url = "#".join(episodes)
                remarks = f"共{len(episodes)}集"
            else:
                play_url = ""
                remarks = ""

            # 标签名 / 年份 (可选字段, 失败不影响主流程)
            type_name = ""
            try:
                tmap = {str(t.get("id")): t.get("t", "") for t in self._get_tags()}
                names = []
                for tid in str(info.get("tags") or "").split(","):
                    nm = tmap.get(tid.strip(), "")
                    if nm and nm not in names:
                        names.append(nm)
                type_name = ",".join(names[:4])
            except Exception:
                pass
            vod_year = ""
            try:
                st = info.get("start_time")
                if st:
                    vod_year = time.strftime("%Y", time.localtime(int(st)))
            except Exception:
                pass

            vod = {
                "vod_id": vod_id,
                "vod_name": info.get("title") or vod_id,
                "vod_pic": self._cover(info.get("cover", "")),
                "type_name": type_name,
                "vod_year": vod_year,
                "vod_area": "",
                "vod_remarks": remarks,
                "vod_actor": "",
                "vod_director": "",
                "vod_content": info.get("summary", ""),
                "vod_play_from": self.getName(),
                "vod_play_url": play_url,
            }
            return {"list": [vod]}
        except Exception as e:
            logger.error(f"获取详情失败: {e}")
            return {"list": []}

    # ==================== 播放 (核心) ====================
    def playerContent(self, flag, id, vipFlags):
        """
        返回单集 m3u8 播放地址。
        id 格式: "{vod_id}|{集号}"  (由 detailContent 拼装)
        """
        try:
            parts = str(id).split("|")
            if len(parts) < 2:
                return {}
            vod_id, set_no = parts[0], parts[1]

            data = self._post_json("/video/set-info", {"id": vod_id, "set": int(set_no)}) or {}
            info = data.get("info") or {}
            raw_url = info.get("url_m3u8") or ""
            if not raw_url:
                logger.error(f"未找到播放地址: {vod_id}, {set_no}")
                return {}

            play_url = self._join(self._video_base(raw_url), raw_url)

            return {
                "parse": 0,
                "playUrl": "",
                "url": play_url,
                "header": {
                    "User-Agent": self.HEADERS["User-Agent"],
                    "Referer": self.SITE + "/h5/",
                    "Origin": self.SITE,
                },
            }
        except Exception as e:
            logger.error(f"解析播放失败: {e}")
            return {}

    # ==================== 搜索 ====================
    def searchContent(self, key, quick, pg="1"):
        try:
            page = int(pg) if pg else 1
            payload = self._post_json("/search/list", {"text": key, "pageNum": page}) or {}
            items = payload.get("list") or []
            pagecount, total = self._paginate(payload, page)

            return {
                "list": self._parse_items(items),
                "page": page,
                "pagecount": pagecount,
                "limit": payload.get("pageSize") or 20,
                "total": total,
            }
        except Exception as e:
            logger.error(f"搜索失败: {e}")
            return {"list": [], "page": int(pg) if pg else 1, "pagecount": 1, "limit": 20, "total": 0}


# ==================== 本地自检 (直接用 python 运行验证, 不影响 TVBox 加载) ====================
if __name__ == "__main__":
    sp = Spider()
    print("===== 首页 / 分类 =====")
    home = sp.homeContent(filter=True)
    print("分类数:", len(home.get("class", [])))
    print("首页条目:", len(home.get("list", [])))
    if home.get("list"):
        print("示例:", home["list"][0])
    else:
        print("首页获取失败")
        sys.exit(1)

    print("\n===== 详情 =====")
    vid = home["list"][0]["vod_id"]
    det = sp.detailContent([vid])
    if det.get("list"):
        v = det["list"][0]
        print("名称:", v["vod_name"], "|", v["vod_remarks"])
        print("播放集数:", len(v["vod_play_url"].split("#")) if v["vod_play_url"] else 0)
        first_ep = v["vod_play_url"].split("#")[0]
        ep_id = first_ep.split("$")[1]
        print("首集 id:", ep_id)

        print("\n===== 播放 =====")
        play = sp.playerContent(sp.getName(), ep_id, "")
        print("play url:", play.get("url"))

    print("\n===== 搜索 =====")
    sr = sp.searchContent("总裁", quick=False, pg="1")
    print("搜索结果:", len(sr.get("list", [])), "条 / 总", sr.get("total"))
    if sr.get("list"):
        print("示例:", sr["list"][0])
