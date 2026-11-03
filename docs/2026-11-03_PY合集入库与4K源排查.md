# PY 合集入库与导入

2026-11-03。304 份 Spider 内容源已加入独立 PY 订阅及现有总订阅。通过的是生产宿主离线加载与导入链路，尚未逐站验证账号、分类列表、封面和播放。部分 Android、可选依赖或服务端接口仍可能不可用。

## 导入

在 App 的“总订阅导入导出”刷新现有总订阅即可；视频类进入视频板块的 PY 分类，漫画和音频进入漫画板块对应分类。只要 PY 合集时，导入以下任一 JSON 总订阅：

- [国内 CDN PY 订阅](https://cdn.jsdelivr.net/gh/teng662858/LumeBox-Sources@main/subscriptions/cdn/python.json)
- [GitHub PY 订阅](https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/subscriptions/python.json)

总订阅分别引用 `python-video.txt` 与 `python-comic.txt`，避免跨板块导入。普通分类清单不重复列合集；兼容用的合并 videos/comics 清单仍包含全部对应源。CDN 子清单采用内容寻址文件名，自建部署生成器也已覆盖 PY 清单及正确的音频归属。

## 入库范围

用户提供 `D:\PY源合集包`。361 个已解压 Python 文件，按完整 SHA256 去重为 321 份不同内容。脚本文本只增加身份/运行时头，统一 UTF-8/LF；不擅自合并同站不同版本。身份基于原相对路径生成，后续更换脚本内容可以沿用 ID。原始路径、原文件 SHA256、规范化正文 SHA256 和初始检查记录见合集索引 JSON。

| 状态 | 数量 | 处理 |
| --- | ---: | --- |
| 当前宿主离线加载通过 | 304 | 加入独立 PY 清单与总订阅 |
| 加载失败 | 13 | 保存在 archive/python，不进入自动订阅 |
| Android 本地管理工具 | 3 | 非内容源，不发布脚本 |
| Spider 示例 | 1 | 非真实站点，不进入订阅 |
| 完全重复的副本 | 40 | 仅收录一次，所有原路径保留在索引 |

本次分类计数：{"video": 72, "movie": 215, "audiobook": 16, "comic": 1}。音频使用 category=comic、mediaType=audio；漫画不声明影视 movie 标签。明确成人源同步登记 App ID 表与源仓库分级。

## 验证与限制

- 304/304 当前生产 Python 宿主离线加载成功；每源独立进程，禁止网络、原生调用、文件写入和子进程。此结果只验证导入/协议，不等于实站可播。
- App 生产订阅解析器从 PY 总订阅递归展开全部 304 个源，核对 ID、Python 运行时、板块归属且没有静默跳过。
- 源仓库测试验证 GitHub/CDN 总订阅各源恰好出现一次、失败脚本不进入清单、正文哈希和自建部署归属。
- 同步原站与 CDN 后下载核对清单和源文件 SHA256；交付信息记录实际提交号与下载结果。

App 仓库复验：

```powershell
python tools/check_python_collection.py
flutter test test/python_collection_import_test.dart test/source_content_rating_test.dart
python -m unittest tools/test_fourkyingshi_source.py
```

源仓库复验：

```powershell
python tools/build_catalog.py --check
python -m unittest discover -s tools -p 'test_*py'
```

## 本次额外排查：4K影视.py

用户桌面文件针对 `www.4kyingshi.net`，与原有 `fourk_video`（4kvms.org）是不同站点。本机用原脚本 Baidu UA 与浏览器 UA、www/裸域/HTTP 跳转和分类路径，均得到 nginx HTTP 403；原脚本忽略状态码并把拒绝页解析成空列表。

修复副本在 `archive/python/4K影视-HTTP错误修复.py`，身份 `fourkyingshi_python_video`、版本 1.0.1：拒绝访问/HTTP 错误/网页校验/空响应均明确报错，单次走宿主请求，移除三条通道重复请求；支持源设置的自定义域名并同步 Referer。四个回归用例覆盖 403、200 校验页、切换域名和成功卡片解析。实站仍 403，未确认可用镜像，因此暂不进入总订阅，不声称已恢复播放。

## 待适配源

- `PY合集/cctv.py`：ValueError: Python 源缺少接口：detailContent。
- `PY合集/乱伦淫窝.py`：RuntimeError: OFFLINE_CHECK: file writes disabled。
- `直播/[直]哔哩直播.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `py精选源/星芽短剧.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `影视/[影]努努影院.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `影视/[影]华数TV.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `影视/[影]华谊影视.py`：RuntimeError: OFFLINE_CHECK: network and native calls disabled。
- `影视/[影]橘汁视频.py`：RuntimeError: OFFLINE_CHECK: network and native calls disabled。
- `影视/[影]饭团影视.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `瑟瑟/[瑟]花都影院.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `短剧/[短]喜福短剧.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `短剧/[短]悟圣短剧.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
- `音/[音]枫叶音乐.py`：ImportError: cannot import name 'ARC4' from 'Crypto.Cipher' (unknown location)。
