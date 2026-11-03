# LumeSource: {"id":"pypack_1ca85e9f09038929","name":"XChina","version":"1.0.0","category":"video","contentCategory":"adult","settings":[{"key":"collectionStatus","type":"info","title":"PY合集移植源","description":"保留用户提供的 Spider 脚本；离线加载检查不代表实站、依赖与播放全部可用。部分功能依赖 Android、账号或外部接口。"}]}
# LumeRuntime: python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xchina.tube Hawk 爬虫（开发版）
XChina 中国原创 - API 直调版

关键发现（2026-10-11 实测）：
- API: POST https://v2.xiaoshuo.la/js，body {"url": "/接口路径", "app": "xchina.tube", ...}
- Headers 只需 Content-Type + Authorization: Bearer undefined（服务端不校验 token）
- 响应 {"r": "<base64>"} 是 CryptoJS AES 加密，key="xxx"，OpenSSL Salted__ 格式
- 非 VIP 通过 API 拿到的是完整 m3u8（2 分钟限制是纯前端 JS，前端 timeupdate 到 120 秒 pause）
- m3u8 带时间戳签名，有效期约 2 小时，playerContent 必须现调现取
- Hawk iOS 无 Crypto 库，用纯 Python AES-256 实现
"""
import json
import base64
import hashlib

try:
    from base.spider import Spider as BaseSpider
except ImportError:
    class BaseSpider:
        pass

# ============ 纯 Python AES-256-CBC（EVP_BytesToKey） ============
_AES_SBOX = (
0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16)
_AES_INV_SBOX = [0]*256
for _i, _v in enumerate(_AES_SBOX):
    _AES_INV_SBOX[_v] = _i
_AES_INV_SBOX = tuple(_AES_INV_SBOX)
_AES_RCON = (0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36,0x6c,0xd8,0xab,0x4d,0x9a)

def _xtime(a):
    return (((a << 1) ^ 0x1b) & 0xff) if (a & 0x80) else ((a << 1) & 0xff)

def _gmul(a, b):
    p = 0
    while b:
        if b & 1:
            p ^= a
        a = _xtime(a)
        b >>= 1
    return p

_M09 = tuple(_gmul(i, 0x09) for i in range(256))
_M0B = tuple(_gmul(i, 0x0b) for i in range(256))
_M0D = tuple(_gmul(i, 0x0d) for i in range(256))
_M0E = tuple(_gmul(i, 0x0e) for i in range(256))

def _expand_key_256(key):
    """AES-256 key expansion: 32 -> 240 bytes (15 round keys)"""
    ek = list(key)
    rcon_idx = 0
    while len(ek) < 240:
        t = ek[-4:]
        if len(ek) % 32 == 0:
            t = t[1:] + t[:1]
            t = [_AES_SBOX[b] for b in t]
            t[0] ^= _AES_RCON[rcon_idx]
            rcon_idx += 1
        elif len(ek) % 32 == 16:
            t = [_AES_SBOX[b] for b in t]
        for j in range(4):
            t = [t[k] ^ ek[-32+k] for k in range(4)]
            ek += t
    return [ek[i:i+16] for i in range(0, 240, 16)]

def _decrypt_block(blk, rk, rounds):
    s = [a ^ b for a, b in zip(blk, rk[rounds])]
    for r in range(rounds-1, 0, -1):
        s = [s[0],s[13],s[10],s[7],s[4],s[1],s[14],s[11],s[8],s[5],s[2],s[15],s[12],s[9],s[6],s[3]]
        s = [_AES_INV_SBOX[b] for b in s]
        s = [a ^ b for a, b in zip(s, rk[r])]
        o = [0]*16
        for c in range(4):
            a0,a1,a2,a3 = s[c*4],s[c*4+1],s[c*4+2],s[c*4+3]
            o[c*4]   = _M0E[a0]^_M0B[a1]^_M0D[a2]^_M09[a3]
            o[c*4+1] = _M09[a0]^_M0E[a1]^_M0B[a2]^_M0D[a3]
            o[c*4+2] = _M0D[a0]^_M09[a1]^_M0E[a2]^_M0B[a3]
            o[c*4+3] = _M0B[a0]^_M0D[a1]^_M09[a2]^_M0E[a3]
        s = o
    s = [s[0],s[13],s[10],s[7],s[4],s[1],s[14],s[11],s[8],s[5],s[2],s[15],s[12],s[9],s[6],s[3]]
    s = [_AES_INV_SBOX[b] for b in s]
    return bytes(a ^ b for a, b in zip(s, rk[0]))

def _evp_bytes_to_key(password, salt, key_len=32, iv_len=16):
    d = b""
    while len(d) < key_len + iv_len:
        d += hashlib.md5((d[-16:] if d else b"") + password + salt).digest()
    return d[:key_len], d[key_len:key_len+iv_len]

def _decrypt_api(r_b64):
    """解密 API 响应的 r 字段"""
    data = base64.b64decode(r_b64)
    if data[:8] != b"Salted__":
        raise ValueError("非 Salted__ 格式")
    salt, ct = data[8:16], data[16:]
    key, iv = _evp_bytes_to_key(b"xxx", salt)
    rk = _expand_key_256(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(ct), 16):
        blk = _decrypt_block(ct[i:i+16], rk, 14)
        out += bytes(a ^ b for a, b in zip(blk, prev))
        prev = ct[i:i+16]
    pad = out[-1]
    if 1 <= pad <= 16:
        del out[-pad:]
    return bytes(out).decode("utf-8")


class Spider(BaseSpider):
    # API 域名轮询（2026-10-11 沙盒实测三个可用，手机网络按个试）
    APIS = [
        "https://v2.xiaoshuo.la/js",
        "https://v2.xiaoshuo.info/js",
        "https://v2.madou.ws/js",
    ]
    SITE = "https://xchina.tube"
    UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

    def init(self, extend=""):
        pass

    def _api(self, url_path, extra=None):
        import urllib.request
        import ssl
        # 站点证书链不完整，手机上会报 certificate verify failed，跳过验证
        ctx = ssl._create_unverified_context()
        body = {
            "url": url_path,
            "app": "xchina.tube",
            "deviceInfo": {},
            "theLink": "novaluenull",
            "uuid": "novalue",
            "version": "1.0",
            "isStandalone": False,
        }
        if extra:
            body.update(extra)
        data_bytes = json.dumps(body).encode("utf-8")
        last_err = None
        for api_url in self.APIS:
            try:
                req = urllib.request.Request(
                    api_url,
                    data=data_bytes,
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": "Bearer undefined",
                        "Origin": self.SITE,
                        "Referer": self.SITE + "/",
                        "User-Agent": self.UA,
                    },
                )
                resp = urllib.request.urlopen(req, timeout=15, context=ctx)
                data = json.loads(resp.read().decode("utf-8"))
                return json.loads(_decrypt_api(data["r"]))
            except Exception as e:
                last_err = e
                continue
        raise last_err or Exception("API 全部域名失败")

    def _videos(self, raw):
        if isinstance(raw, dict):
            for k in ("videos", "data", "list"):
                if isinstance(raw.get(k), list):
                    return raw[k]
            return []
        return raw if isinstance(raw, list) else []

    def _vod(self, v):
        vid = v.get("id") or v.get("vId") or v.get("_id") or ""
        title = v.get("title") or v.get("title_en") or ""
        thumbs = v.get("thumbnails") or []
        pic = thumbs[0] if thumbs else ""
        return {
            "vod_id": str(vid),
            "vod_name": title.strip(),
            "vod_pic": pic,
            "vod_remarks": v.get("durationStr") or "",
        }

    def homeContent(self, filter=None):
        # 分类与网站一致（2026-10-11 从 main.js 抠出，id 即 API type）
        cats = [
            {"type_id": "home", "type_name": "推荐"},
            {"type_id": "hot", "type_name": "91Porn大神"},
            {"type_id": "c1", "type_name": "麻豆视频"},
            {"type_id": "c2", "type_name": "91制片厂"},
            {"type_id": "c3", "type_name": "玩偶姐姐"},
            {"type_id": "c4", "type_name": "小鸟酱专题"},
            {"type_id": "c5", "type_name": "糖心Vlog"},
            {"type_id": "c6", "type_name": "天美传媒"},
            {"type_id": "c7", "type_name": "蜜桃传媒"},
            {"type_id": "c8", "type_name": "皇家华人"},
            {"type_id": "c9", "type_name": "星空传媒"},
            {"type_id": "ca", "type_name": "精东影业"},
            {"type_id": "cc", "type_name": "成人头条"},
            {"type_id": "cd", "type_name": "乌鸦传媒"},
            {"type_id": "banana", "type_name": "汝工作室"},
            {"type_id": "japan", "type_name": "日本无码"},
            {"type_id": "high", "type_name": "高清"},
            {"type_id": "recent", "type_name": "最新发布"},
        ]
        try:
            raw = self._api("/sevenVideos?page=1&type=home")
            vods = [self._vod(v) for v in self._videos(raw)]
        except Exception:
            vods = []
        return {"class": cats, "list": vods}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter=None, extend=None):
        pg = int(pg) if str(pg).isdigit() else 1
        try:
            raw = self._api("/sevenVideos?page=%d&type=%s" % (pg, tid))
            vods = [self._vod(v) for v in self._videos(raw)]
        except Exception:
            vods = []
        return {
            "list": vods,
            "page": pg,
            "pagecount": 9999,
            "limit": 24,
            "total": 999999,
        }

    def detailContent(self, ids):
        vid = ids[0] if ids else ""
        vod = {"vod_id": vid, "vod_name": "", "vod_pic": "", "vod_play_from": "默认", "vod_play_url": ""}
        try:
            d = self._api("/sevenVideos/%s" % vid, {"userId": "", "url_search": "", "token": "ufd"})
            thumbs = d.get("thumbnails") or []
            vod["vod_name"] = (d.get("title") or "").strip()
            vod["vod_pic"] = thumbs[0] if thumbs else ""
            vod["vod_remarks"] = d.get("durationStr") or ""
            vod["vod_content"] = d.get("title") or ""
            tags = d.get("keywords_gem") or d.get("tags") or ""
            if isinstance(tags, list):
                tags = " ".join(tags)
            vod["vod_tag"] = str(tags)
            # 播放：正片（m3u8s[0] 是完整视频，前端 2 分钟限制不影响直接播放）
            vod["vod_play_url"] = "正片$" + vid
        except Exception:
            vod["vod_play_url"] = "正片$" + vid
        return {"list": [vod]}

    def searchContent(self, key, quick=False, pg="1"):
        pg = int(pg) if str(pg).isdigit() else 1
        try:
            raw = self._api("/searchSevenVideos", {
                "page": pg, "keywords": key,
                "filterCategory": "", "filterTimeInDays": "",
            })
            vods = [self._vod(v) for v in self._videos(raw)]
        except Exception:
            vods = []
        return {"list": vods}

    def playerContent(self, flag, id, vipFlags=None):
        # id 是视频 id，现调详情拿新鲜 m3u8（签名约 2 小时有效期）
        try:
            d = self._api("/sevenVideos/%s" % id, {"userId": "", "url_search": "", "token": "ufd"})
            m3u8s = d.get("m3u8s") or []
            if m3u8s:
                return {
                    "parse": 0,
                    "url": m3u8s[0],
                    "header": {"User-Agent": self.UA, "Referer": self.SITE + "/"},
                }
        except Exception:
            pass
        # 兜底：丢播放页给 Hawk 嗅探
        return {"parse": 1, "url": "%s/video/%s" % (self.SITE, id)}


if __name__ == "__main__":
    sp = Spider()
    print("== home ==")
    h = sp.homeContent(None)
    print("分类:", [c["type_name"] for c in h["class"]], "首页:", len(h["list"]), "条")
    print("== category hot ==")
    c = sp.categoryContent("hot", "1", None, None)
    print("hot:", len(c["list"]), "条，首条:", c["list"][0]["vod_name"][:30] if c["list"] else "无")
    print("== search 天美 ==")
    s = sp.searchContent("天美", False, "1")
    print("搜索:", len(s["list"]), "条")
    vid = h["list"][0]["vod_id"] if h["list"] else "PPDdGyME4"
    print("== detail", vid, "==")
    d = sp.detailContent([vid])
    print("标题:", d["list"][0]["vod_name"][:40])
    print("封面:", d["list"][0]["vod_pic"][:60])
    print("== player ==")
    p = sp.playerContent("默认", vid, None)
    print("parse:", p["parse"], "url:", p["url"][:80])
